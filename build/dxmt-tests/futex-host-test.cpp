/* MADEIRA (WOW64_DESIGN.md, ml1070): host-side race test for DXMT's
 * wait-on-address hand-off primitive
 * (research/dxmt/src/util/util_futex.hpp + util_cpu_fence.hpp).
 *
 * WHAT IS UNDER TEST, AND WHAT IS SUBSTITUTED
 * -------------------------------------------
 * The subject is the ALGORITHM in util_futex.hpp -- the pre-park spin, the
 * value re-check loop around the platform wait, and the store-then-notify
 * pairing that CpuFence and the command-queue rings use.  That is the part
 * that can lose a wakeup, and it is included here verbatim from the shipping
 * header, not re-typed.
 *
 * Exactly one thing is substituted: the three-line platform call.  On the
 * device `dxmt::futex::address_wait/_wake_one/_wake_all` are ntdll's
 * RtlWaitOnAddress / RtlWakeAddressSingle / RtlWakeAddressAll; on the build
 * machine they are `futex(2)`, defined below.  Both are "park on this word,
 * re-comparing it under the same lock the waker takes", so the interleavings
 * the loop has to survive are the same ones.  What this test therefore CANNOT
 * say anything about is whether Wine's RtlWaitOnAddress is itself correct --
 * that is argued from its source in the header comment and from
 * build/host-tests/fastsync-semrace.c one layer down.
 *
 * WHY A CONSUMER THAT WAITS FOR ITS OWN BATCH
 * -------------------------------------------
 * The lesson from build/host-tests/fastsync-semrace.c applies unchanged: an
 * open-loop producer/consumer cannot fail, because a missed wake is collected
 * by the next notify and the arithmetic then reconciles perfectly while the
 * program runs on.  A lost wake only becomes a HANG when nothing else is
 * going to signal.  So every phase below ends with a party that has nothing
 * left to do but wait, and every phase has a liveness deadline.
 *
 * Build and run:  bash build/dxmt-tests/build-futex-host-test.sh
 * Exit code 0 = all phases passed; the last line is PASS or FAIL.
 */

#include "util_futex.hpp"
#include "util_cpu_fence.hpp"

#include <atomic>
#include <chrono>
#include <climits>
#include <cstdint>
#include <cstdio>
#include <cstring>
#include <thread>
#include <vector>

#include <linux/futex.h>
#include <sys/syscall.h>
#include <unistd.h>

/* ---- the substituted platform layer ------------------------------------ */

namespace dxmt::futex {

/* Linux futexes take one naturally aligned 32-bit word, while the shipping
 * primitive takes 1, 2, 4 or 8 bytes at any address.  The model therefore
 * parks on the aligned word CONTAINING the address -- its low half for an
 * 8-byte counter, the word around it for a 1-byte flag -- which is the
 * standard way to build a byte futex out of a word futex and is faithful in
 * both directions that matter:
 *   - no missed wake: every change to the watched bytes changes the word, so
 *     the FUTEX_WAIT comparand no longer matches and the park does not happen
 *     (or the FUTEX_WAKE finds the parked thread);
 *   - only extra wakes: a change to a neighbouring byte in the same word
 *     wakes the waiter spuriously, which the re-check loop in util_futex.hpp
 *     absorbs -- which is precisely the property this test is here to
 *     exercise.
 * It is also why an 8-byte wait works: DXMT's counters all change by amounts
 * that are never a multiple of 2^32. */
static_assert(__BYTE_ORDER__ == __ORDER_LITTLE_ENDIAN__, "this model assumes a little-endian build machine");

static int *
aligned_word(const void *addr) {
  return (int *)((uintptr_t)addr & ~(uintptr_t)(sizeof(int) - 1));
}

WaitBackend
backend() {
  return WaitBackend::AddressWait;
}

void
address_wait(const void *addr, const void *compare, size_t size) {
  int *word = aligned_word(addr);
  unsigned offset = (unsigned)((uintptr_t)addr & (sizeof(int) - 1));
  int expected = __atomic_load_n(word, __ATOMIC_ACQUIRE);

  /* Believe the snapshot only if the watched bytes inside it still match what
   * the caller expects; otherwise the value has already moved and parking
   * would be a wait for a wake that has been and gone. */
  size_t covered = size < sizeof(int) - offset ? size : sizeof(int) - offset;
  if (std::memcmp((const char *)&expected + offset, compare, covered) != 0)
    return;

  syscall(SYS_futex, word, FUTEX_WAIT_PRIVATE, expected, nullptr, nullptr, 0);
}

void
address_wake_one(const void *addr) {
  syscall(SYS_futex, aligned_word(addr), FUTEX_WAKE_PRIVATE, 1, nullptr, nullptr, 0);
}

void
address_wake_all(const void *addr) {
  syscall(SYS_futex, aligned_word(addr), FUTEX_WAKE_PRIVATE, INT_MAX, nullptr, nullptr, 0);
}

} // namespace dxmt::futex

/* ---- harness ------------------------------------------------------------ */

using clock_type = std::chrono::steady_clock;

static int g_failures = 0;

static void
report(const char *phase, bool ok, const char *detail) {
  std::printf("  %-4s %-34s %s\n", ok ? "ok" : "FAIL", phase, detail);
  if (!ok)
    ++g_failures;
}

/* A liveness bound: the whole point of the test.  A lost wake does not
 * corrupt anything, it just stops the program, so every phase is a deadline. */
static constexpr int kDeadlineMs = 15000;

/* A blown deadline means a thread is still parked on a word whose value has
 * already changed -- a lost wakeup -- and joining it would hang the test
 * instead of reporting it.  So say so and leave, which is what turns "the
 * build hangs" into "the build fails". */
static void
join_before_deadline(const char *phase, std::vector<std::thread> &threads, std::atomic<bool> &finished) {
  auto deadline = clock_type::now() + std::chrono::milliseconds(kDeadlineMs);
  while (!finished.load(std::memory_order_acquire)) {
    if (clock_type::now() > deadline) {
      report(phase, false, "deadline exceeded -- a waiter is still parked (LOST WAKEUP)");
      std::printf("FAIL (%d failure%s)\n", g_failures, g_failures == 1 ? "" : "s");
      std::fflush(stdout);
      std::_Exit(1);
    }
    std::this_thread::sleep_for(std::chrono::milliseconds(1));
  }
  for (auto &t : threads)
    t.join();
  threads.clear();
}

/* A short, deliberately varying delay so a signal lands on both sides of the
 * waiter's spin window: sometimes before it parks, sometimes after. */
static void
jitter(unsigned iterations) {
  for (unsigned i = 0; i < iterations; i++)
    dxmt::futex::spin_hint();
}

/* ---- phase 1: CpuFence, one signaller and many waiters ------------------
 *
 * The shape of `cpu_coherent` and `frame_latency_fence_`: a monotonically
 * rising watermark, signalled by the finish thread, waited on by whoever
 * needs a sequence number retired.  Each waiter asks for a value the
 * signaller has not reached yet, so every wait is a real park, and the
 * signaller stops at the last value -- nothing will re-signal to collect a
 * missed wake. */
static void
phase_cpu_fence(unsigned rounds, unsigned waiters_per_round) {
  dxmt::CpuFence fence;
  std::atomic<uint64_t> observed{0};
  std::atomic<bool> finished{false};
  std::vector<std::thread> threads;

  const uint64_t total = uint64_t(rounds) * waiters_per_round;

  for (unsigned w = 0; w < waiters_per_round; w++) {
    threads.emplace_back([&]() {
      for (unsigned r = 0; r < rounds; r++) {
        fence.wait(uint64_t(r) + 1);
        /* The contract CpuFence::wait owes every caller in DXMT: when it
         * returns, the watermark really has reached the requested value. */
        if (fence.signaledValue() < uint64_t(r) + 1) {
          report("cpu-fence watermark", false, "wait returned below the requested value");
          return;
        }
        observed.fetch_add(1, std::memory_order_relaxed);
      }
    });
  }

  threads.emplace_back([&]() {
    for (unsigned r = 0; r < rounds; r++) {
      jitter((r % 97) * 13);
      fence.signal(uint64_t(r) + 1);
    }
  });

  std::thread watcher([&]() {
    auto deadline = clock_type::now() + std::chrono::milliseconds(kDeadlineMs);
    while (observed.load(std::memory_order_relaxed) < total && clock_type::now() < deadline)
      std::this_thread::sleep_for(std::chrono::milliseconds(1));
    finished.store(true, std::memory_order_release);
  });

  join_before_deadline("cpu-fence signal/wait", threads, finished);
  watcher.join();

  char detail[160];
  std::snprintf(detail, sizeof(detail), "rounds=%u waiters=%u observed=%llu/%llu", rounds, waiters_per_round,
                (unsigned long long)observed.load(), (unsigned long long)total);
  report("cpu-fence signal/wait", observed.load() == total, detail);
}

/* ---- phase 2: the chunk ring -------------------------------------------
 *
 * The shape of ready_for_encode / ready_for_commit / chunk_ongoing: a
 * bounded ring where the producer blocks when the ring is full and the
 * consumer blocks when it is empty, so BOTH directions park and either
 * direction can lose a wake.  The ring is deliberately tiny (the shipping
 * kCommandChunkCount is small too), which is what makes both parks common. */
static void
phase_chunk_ring(unsigned items, unsigned depth) {
  std::atomic<uint64_t> produced{1};  /* ready_for_encode */
  std::atomic<uint64_t> in_flight{0}; /* chunk_ongoing */
  std::atomic<uint64_t> consumed{0};
  std::atomic<bool> finished{false};
  std::vector<std::thread> threads;

  threads.emplace_back([&]() { /* consumer: the encode + finish threads */
    uint64_t seq = 1;
    while (seq <= items) {
      dxmt::atomic_wait(produced, seq, std::memory_order_acquire);
      consumed.fetch_add(1, std::memory_order_relaxed);
      in_flight.fetch_sub(1, std::memory_order_release);
      dxmt::atomic_notify_one(in_flight);
      seq++;
    }
    finished.store(true, std::memory_order_release);
  });

  threads.emplace_back([&]() { /* producer: CommitCurrentChunk */
    for (unsigned i = 0; i < items; i++) {
      produced.fetch_add(1, std::memory_order_release);
      dxmt::atomic_notify_one(produced);
      dxmt::atomic_wait(in_flight, uint64_t(depth), std::memory_order_acquire);
      in_flight.fetch_add(1, std::memory_order_relaxed);
    }
  });

  join_before_deadline("chunk ring both directions", threads, finished);

  char detail[160];
  std::snprintf(detail, sizeof(detail), "items=%u depth=%u consumed=%llu in_flight=%llu", items, depth,
                (unsigned long long)consumed.load(), (unsigned long long)in_flight.load());
  report("chunk ring both directions", consumed.load() == items, detail);
}

/* ---- phase 3: a one-byte ready flag ------------------------------------
 *
 * The shape of the shader-ready flags (d3d9 m_ready, d3d11 ready_): a
 * std::atomic<bool>, set once, with an unknown number of threads already
 * parked on it.  Size 1 is a different argument to the platform wait than
 * size 8, so it gets its own phase. */
static void
phase_ready_flag(unsigned rounds, unsigned waiters) {
  std::atomic<uint64_t> woken{0};

  for (unsigned r = 0; r < rounds; r++) {
    std::atomic<bool> ready{false};
    std::vector<std::thread> threads;

    for (unsigned w = 0; w < waiters; w++) {
      threads.emplace_back([&]() {
        while (!ready.load(std::memory_order_acquire))
          dxmt::atomic_wait(ready, false, std::memory_order_acquire);
        woken.fetch_add(1, std::memory_order_relaxed);
      });
    }

    jitter((r % 61) * 29);
    ready.store(true, std::memory_order_release);
    dxmt::atomic_notify_all(ready);

    for (auto &t : threads)
      t.join();
  }

  char detail[160];
  std::snprintf(detail, sizeof(detail), "rounds=%u waiters=%u woken=%llu/%u", rounds, waiters,
                (unsigned long long)woken.load(), rounds * waiters);
  report("ready flag (1 byte) wake-all", woken.load() == uint64_t(rounds) * waiters, detail);
}

/* ---- phase 4: the negative control --------------------------------------
 *
 * A test that cannot fail proves nothing, so this phase runs the SAME ring
 * with the notify deliberately omitted on the producer side and asserts that
 * the deadline IS exceeded.  If this phase passes by completing, the waits
 * are not actually parking and the other three phases were vacuous. */
static void
phase_negative_control(unsigned items, unsigned depth) {
  std::atomic<uint64_t> produced{1};
  std::atomic<uint64_t> in_flight{0};
  std::atomic<uint64_t> consumed{0};
  std::atomic<bool> consumer_done{false};
  std::atomic<int> alive{2};
  std::atomic<bool> stop{false};
  std::vector<std::thread> threads;

  threads.emplace_back([&]() {
    uint64_t seq = 1;
    while (seq <= items && !stop.load(std::memory_order_acquire)) {
      /* No notify from the producer, so this park is released only by the
       * rescue below. */
      dxmt::atomic_wait(produced, seq, std::memory_order_acquire);
      consumed.fetch_add(1, std::memory_order_relaxed);
      in_flight.fetch_sub(1, std::memory_order_release);
      dxmt::atomic_notify_one(in_flight);
      seq++;
    }
    consumer_done.store(true, std::memory_order_release);
    alive.fetch_sub(1, std::memory_order_release);
  });

  threads.emplace_back([&]() {
    for (unsigned i = 0; i < items && !stop.load(std::memory_order_acquire); i++) {
      produced.fetch_add(1, std::memory_order_release);
      /* notify omitted on purpose */
      dxmt::atomic_wait(in_flight, uint64_t(depth), std::memory_order_acquire);
      if (stop.load(std::memory_order_acquire))
        break;
      in_flight.fetch_add(1, std::memory_order_relaxed);
    }
    alive.fetch_sub(1, std::memory_order_release);
  });

  auto deadline = clock_type::now() + std::chrono::milliseconds(1500);
  while (!consumer_done.load(std::memory_order_acquire) && clock_type::now() < deadline)
    std::this_thread::sleep_for(std::chrono::milliseconds(1));

  bool stalled = !consumer_done.load(std::memory_order_acquire);

  /* Rescue: the same wakes a real signaller would have issued, repeated until
   * both parties are out, because with the notify removed either of them can
   * be parked at any instant. */
  stop.store(true, std::memory_order_release);
  auto rescue_deadline = clock_type::now() + std::chrono::milliseconds(kDeadlineMs);
  while (alive.load(std::memory_order_acquire) > 0 && clock_type::now() < rescue_deadline) {
    produced.fetch_add(1, std::memory_order_release);
    dxmt::atomic_notify_all(produced);
    in_flight.store(0, std::memory_order_release);
    dxmt::atomic_notify_all(in_flight);
    std::this_thread::sleep_for(std::chrono::milliseconds(1));
  }
  bool rescued = alive.load(std::memory_order_acquire) == 0;
  for (auto &t : threads)
    t.join();
  threads.clear();

  char detail[160];
  std::snprintf(detail, sizeof(detail), "consumed=%llu/%u before the 1500ms bound",
                (unsigned long long)consumed.load(), items);
  report("negative control STALLS", stalled, detail);
  report("negative control is rescuable", rescued, "wake_all on the same word releases both parties");
}

int
main() {
  std::printf("=== dxmt wait-on-address host test (ml1070) ===\n");
  std::printf("  backend=%s\n",
              dxmt::futex::backend() == dxmt::WaitBackend::AddressWait ? "address-wait (futex model)" : "std::atomic");

  for (int pass = 1; pass <= 3; pass++) {
    std::printf("--- pass %d ---\n", pass);
    phase_cpu_fence(4000, 4);
    phase_chunk_ring(40000, 3);
    phase_ready_flag(400, 4);
  }
  phase_negative_control(40000, 3);

  std::printf("%s (%d failure%s)\n", g_failures ? "FAIL" : "PASS", g_failures, g_failures == 1 ? "" : "s");
  return g_failures ? 1 : 0;
}
