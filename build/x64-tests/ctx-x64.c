/* ctx-x64 — SuspendThread / GetThreadContext / SetThreadContext / ResumeThread
 * on a 64-bit thread that is executing EMULATED code.
 *
 * WHY THIS TEST EXISTS
 * --------------------
 * A managed runtime's stop-the-world (and every debugger, profiler and
 * structured-exception filter that inspects another thread) does exactly this
 * four-call dance, so the emulated context has to survive a full round trip:
 *
 *     SuspendThread(A)
 *     GetThreadContext(A)          -> Rsp must be inside A's own stack
 *                                     Rip must be inside the exe image
 *     ctx.Rip = landing
 *     SetThreadContext(A)
 *     ResumeThread(A)              -> A must actually arrive at `landing`
 *     ... then the ORIGINAL context is put back and A resumes spinning.
 *
 * On an arm64ec host the x64 CONTEXT is a re-labelling of the native ARM64
 * one, and it has no field for six ARM registers — context_x64_to_arm() writes
 * X13 = X14 = X18 = X23 = X24 = X28 = 0 into every native context it builds.
 * When the emulator keeps live state in those registers (a guest RSP, a CPU
 * state pointer), a round trip that looks like a no-op silently destroys the
 * thread. Equally, if GetThreadContext converts the HOST registers of a thread
 * parked in emitted code, the "Rsp" handed back is a host stack pointer and the
 * "Rip" is a code-cache address — neither is a value the caller can reason
 * about, and handing it straight back through SetThreadContext resumes the
 * thread on a stack that is not its own.
 *
 * Both failures are caught here by assertion, not by a crash later.
 *
 * Thread A spins in a loop with no calls in it, so a correctly reported Rip is
 * always inside this exe's image and a correctly reported Rsp is always inside
 * A's stack.  200 iterations.
 *
 * Exit codes:
 *    50  PASS — all 200 iterations round-tripped
 *    51  CreateThread failed
 *    52  thread A never started spinning
 *    53  SuspendThread failed
 *    54  GetThreadContext failed
 *    55  Rsp outside A's stack        <- host stack reported as the guest RSP
 *    56  Rip outside the exe image    <- code-cache address reported as Rip
 *    57  SetThreadContext failed
 *    58  ResumeThread failed
 *    59  redirect lost — A never reached `landing`
 *    60  A did not resume spinning after the original context was restored
 *
 * PART 2 (ml1020) — VEH REWRITES Rip AND RETURNS EXCEPTION_CONTINUE_EXECUTION
 * ---------------------------------------------------------------------------
 * The other half of the same mechanism, and the half a managed runtime uses on
 * every null dereference: instead of another thread setting the context, the
 * FAULTING thread's own vectored handler rewrites CONTEXT.Rip to a recovery
 * routine and returns EXCEPTION_CONTINUE_EXECUTION.
 *
 * On an arm64ec host the recovery Rip is EMULATED x64 code, so the resume cannot
 * be a native branch — the emulator has to be re-entered at the new Rip, and
 * ntdll's dispatch_exception DISCARDS NtContinue's return value: if the continue
 * is dropped it falls straight through to call_seh_handlers and then
 * NtRaiseException( rec, context, FALSE ), which re-dispatches the same record
 * with no host fault. One dropped continue is therefore an unbounded software
 * redelivery loop, and the loop is silent — every probe on that path is
 * sampled, so it looks like ordinary traffic.
 *
 * This test pins BOTH halves of the contract, and the second one is the one the
 * loop would break:
 *    - execution continues at the recovery routine, and
 *    - the handler runs EXACTLY ONCE.
 * A redelivery loop passes the first and fails the second, which is precisely
 * the failure mode that cannot be told apart from healthy traffic in a log.
 *
 *    61  RtlAddVectoredExceptionHandler failed
 *    62  CreateThread for the faulting thread failed
 *    63  the faulting thread never finished
 *    64  the recovery routine was not reached exactly once
 *    65  execution continued PAST the faulting store (the AV never happened)
 *    66  the handler ran more than once — a dropped continue / redelivery loop
 *
 * PART 3 (ml1030) — SAMPLING A THREAD REPEATEDLY MUST SHOW IT MOVING
 * -------------------------------------------------------------------------
 * The shape every stop-the-world actually has, which part 1 does not cover:
 * no SetThreadContext at all, just
 *
 *     for (;;) { SuspendThread(B); GetThreadContext(B); ResumeThread(B); }
 *
 * A managed runtime runs this until the returned Rip is somewhere it is willing
 * to unwind from. If the port hands back a CACHED context — one captured the
 * first time the thread was ever suspended and replayed forever after — every
 * sample is byte-identical, the decision never changes, and the loop never
 * ends. That is a hang with no crash, no error and no log line, and it is
 * invisible to part 1 because part 1 rewrites the context every iteration and
 * so cannot tell a fresh read from a replay of its own last write.
 *
 * Three targets, because the right answer is different for each and only the
 * first one is "a valid code address that changes":
 *
 *   B spinning in a tight loop   Rip inside B's loop function, Rsp inside B's
 *                                stack, and across N samples the pair must not
 *                                be constant — either Rip moves within the loop
 *                                or the counter B is advancing does.
 *   B blocked on an event        Rip and Rsp must be a usable pair (Rsp inside
 *   B blocked on a semaphore     B's stack), they may legitimately be constant
 *                                because B really is not running, and B must
 *                                wake correctly after the last resume.
 *
 * The blocked cases are the ones the device logs show — every sample in both
 * of them was a thread parked in a wait — so "constant" is not a failure there;
 * "not a usable pair", or "never woke up again", is.
 *
 *    70  CreateThread for the sampled thread failed
 *    71  the sampled thread never started
 *    72  SuspendThread failed during sampling
 *    73  GetThreadContext failed during sampling
 *    74  Rsp outside the sampled thread's stack
 *    75  a spinning thread reported the SAME {Rip,Rsp} in every sample AND its
 *        counter never advanced — the context is stale, this is the retry loop
 *    76  a spinning thread stopped advancing after the samples (resume is lost)
 *    77  event/semaphore create failed
 *    78  the blocked thread never reached its wait
 *    79  the blocked thread never woke after being signalled
 */
#include <windows.h>
#include <intrin.h>

static HANDLE g_out;

static void put_str(const char *s)
{
    DWORD w = 0, n = 0;
    while (s[n]) n++;
    WriteFile(g_out, s, n, &w, NULL);
}

static int format_u64(char *buf, unsigned long long v)
{
    char tmp[32];
    int n = 0, i;
    if (!v) { buf[0] = '0'; return 1; }
    while (v) { tmp[n++] = (char)('0' + (v % 10)); v /= 10; }
    for (i = 0; i < n; i++) buf[i] = tmp[n - 1 - i];
    return n;
}

static int format_x64(char *buf, unsigned long long v)
{
    static const char d[] = "0123456789abcdef";
    int n = 0, i;
    char tmp[32];
    buf[n++] = '0'; buf[n++] = 'x';
    if (!v) { buf[n++] = '0'; return n; }
    i = 0;
    while (v) { tmp[i++] = d[v & 0xf]; v >>= 4; }
    while (i) buf[n++] = tmp[--i];
    return n;
}

static void put_kv(const char *prefix, unsigned long long v, int hex)
{
    char buf[40];
    int n = hex ? format_x64(buf, v) : format_u64(buf, v);
    buf[n] = 0;
    put_str(prefix);
    put_str(buf);
    put_str("\n");
}

/* --- shared state ------------------------------------------------------- */

static volatile LONG64 g_spin;        /* advanced by A's loop */
static volatile LONG   g_landed;      /* advanced by `landing` */
static volatile LONG   g_go = 1;      /* A runs while this is 1 */
static volatile ULONG64 g_stack_base; /* published by A from its own TIB */
static volatile ULONG64 g_stack_limit;

/* The redirect target. Never returns: thread B puts the original context back,
 * so this only has to be reachable and to record that it was reached. */
static void __declspec(noinline) landing(void)
{
    InterlockedIncrement(&g_landed);
    for (;;) YieldProcessor();
}

/* A spins with NO calls in the loop body, so its Rip is always inside this
 * image and its Rsp always inside its own stack whenever it is suspended. */
static DWORD WINAPI thread_a(LPVOID unused)
{
    (void)unused;
    /* x64 TIB: gs:[0x08] = StackBase, gs:[0x10] = StackLimit. */
    g_stack_base  = __readgsqword(0x08);
    g_stack_limit = __readgsqword(0x10);
    while (g_go) g_spin++;
    return 0;
}

/* --- image bounds ------------------------------------------------------- */

static ULONG64 g_image_base, g_image_end;

static int image_bounds(void)
{
    const BYTE *base = (const BYTE *)GetModuleHandleW(NULL);
    const IMAGE_DOS_HEADER *dos = (const IMAGE_DOS_HEADER *)base;
    const IMAGE_NT_HEADERS64 *nt;

    if (!base || dos->e_magic != IMAGE_DOS_SIGNATURE) return 0;
    nt = (const IMAGE_NT_HEADERS64 *)(base + dos->e_lfanew);
    if (nt->Signature != IMAGE_NT_SIGNATURE) return 0;
    g_image_base = (ULONG64)base;
    g_image_end  = g_image_base + nt->OptionalHeader.SizeOfImage;
    return 1;
}

static int in_image(ULONG64 a)  { return a >= g_image_base && a < g_image_end; }
static int in_a_stack(ULONG64 a){ return a > g_stack_limit && a <= g_stack_base; }

/* --- part 2: VEH rewrites Rip and returns EXCEPTION_CONTINUE_EXECUTION ---- */

static int fail(const char *what, int code, ULONG64 v);   /* defined below */

static volatile LONG   g_veh_hits;      /* how many times the handler ran */
static volatile LONG   g_recovered;     /* advanced by recover_label */
static volatile LONG   g_past_fault;    /* MUST stay 0 — set after the store */
static volatile ULONG64 g_fault_rip;    /* Rip the handler was handed */

/* Never returns, so it needs no stack discipline of its own: the handler hands
 * it a fresh, 16-byte-aligned slice of the faulting thread's own stack and the
 * thread ends here. */
static void __declspec(noinline) recover_label(void)
{
    InterlockedIncrement(&g_recovered);
    ExitThread(0);
}

/* The escape hatch. If the continue is being dropped and the record is being
 * re-dispatched, the handler stops rewriting after a handful of iterations and
 * ends the thread here instead, so the test reports "ran more than once"
 * (exit 66) rather than hanging the run. */
static void __declspec(noinline) give_up_label(void)
{
    ExitThread(0);
}

static LONG CALLBACK veh_continue(EXCEPTION_POINTERS *ep)
{
    LONG hits;

    if (ep->ExceptionRecord->ExceptionCode != (DWORD)STATUS_ACCESS_VIOLATION)
        return EXCEPTION_CONTINUE_SEARCH;
    if (!in_image((ULONG64)ep->ContextRecord->Rip))
        return EXCEPTION_CONTINUE_SEARCH;

    hits = InterlockedIncrement(&g_veh_hits);
    if (hits == 1) g_fault_rip = ep->ContextRecord->Rip;

    /* x64 entry convention: Rsp ≡ 8 (mod 16) at a function's first instruction.
     * Move down a slice so the recovery routine cannot tread on the frame the
     * fault happened in. */
    ep->ContextRecord->Rsp = ((ep->ContextRecord->Rsp - 1024) & ~(DWORD64)15) - 8;
    ep->ContextRecord->Rip = (DWORD64)(ULONG_PTR)(hits <= 8 ? &recover_label : &give_up_label);
    return EXCEPTION_CONTINUE_EXECUTION;
}

static DWORD WINAPI thread_fault(LPVOID unused)
{
    (void)unused;
    /* A plain store through a bad pointer. Page 0 is never mapped, and the
     * offset keeps it clear of any NULL-page special casing. */
    *(volatile int *)(ULONG_PTR)0x40 = 1;
    /* Reaching this line means the store did not fault at all. */
    InterlockedIncrement(&g_past_fault);
    return 0;
}

static int run_veh_continue_test(void)
{
    PVOID h;
    HANDLE t;
    DWORD tid = 0;

    put_str("MADEIRA-CTX veh-continue start\n");

    h = AddVectoredExceptionHandler(1, veh_continue);
    if (!h) return fail("AddVectoredExceptionHandler", 61, GetLastError());

    t = CreateThread(NULL, 0, thread_fault, NULL, 0, &tid);
    if (!t)
    {
        RemoveVectoredExceptionHandler(h);
        return fail("CreateThread (fault thread)", 62, GetLastError());
    }

    if (WaitForSingleObject(t, 30000) != WAIT_OBJECT_0)
    {
        RemoveVectoredExceptionHandler(h);
        return fail("faulting thread never finished", 63, (ULONG64)g_veh_hits);
    }
    CloseHandle(t);
    RemoveVectoredExceptionHandler(h);

    put_kv("MADEIRA-CTX veh_hits=",    (unsigned)g_veh_hits,  0);
    put_kv("MADEIRA-CTX recovered=",   (unsigned)g_recovered, 0);
    put_kv("MADEIRA-CTX fault_rip=",   g_fault_rip,           1);

    if (g_past_fault != 0)
        return fail("execution continued past the faulting store", 65, (ULONG64)g_past_fault);
    if (g_recovered != 1)
        return fail("recovery routine was not reached exactly once", 64, (ULONG64)g_recovered);
    if (g_veh_hits != 1)
        return fail("handler ran more than once (dropped continue / redelivery loop)", 66, (ULONG64)g_veh_hits);

    put_str("MADEIRA-CTX veh-continue PASS\n");
    return 0;
}

/* --- part 3: repeated sampling must show a live thread ------------------- */

#define SAMPLES 64

static volatile LONG64 g_b_spin;
static volatile LONG   g_b_go = 1;
static volatile LONG   g_b_waiting;      /* B has entered its wait */
static volatile LONG   g_b_woke;         /* B came back out of its wait */
static volatile ULONG64 g_b_stack_base, g_b_stack_limit;
static HANDLE          g_b_obj;          /* event or semaphore under test */

static int in_b_stack(ULONG64 a) { return a > g_b_stack_limit && a <= g_b_stack_base; }

static DWORD WINAPI thread_b_spin(LPVOID unused)
{
    (void)unused;
    g_b_stack_base  = __readgsqword(0x08);
    g_b_stack_limit = __readgsqword(0x10);
    while (g_b_go) g_b_spin++;
    return 0;
}

static DWORD WINAPI thread_b_wait(LPVOID unused)
{
    (void)unused;
    g_b_stack_base  = __readgsqword(0x08);
    g_b_stack_limit = __readgsqword(0x10);
    InterlockedIncrement(&g_b_waiting);
    if (WaitForSingleObject(g_b_obj, 30000) == WAIT_OBJECT_0)
        InterlockedIncrement(&g_b_woke);
    return 0;
}

/* Samples `t' SAMPLES times. Returns 0 on success, else the exit code.
 * *varied is set when any two consecutive samples differed. */
static int sample_thread(HANDLE t, int *varied, ULONG64 *last_rip, ULONG64 *last_rsp)
{
    CONTEXT ctx;
    ULONG64 prev_rip = 0, prev_rsp = 0;
    int i;

    *varied = 0;
    for (i = 0; i < SAMPLES; i++)
    {
        if (SuspendThread(t) == (DWORD)-1) return 72;
        ctx.ContextFlags = CONTEXT_FULL;
        if (!GetThreadContext(t, &ctx)) { ResumeThread(t); return 73; }
        if (ResumeThread(t) == (DWORD)-1) return 72;

        if (!in_b_stack(ctx.Rsp))
        {
            put_kv("MADEIRA-CTX stw sample=", (unsigned)i, 0);
            put_kv("MADEIRA-CTX stw rsp=",    ctx.Rsp,     1);
            put_kv("MADEIRA-CTX stw rip=",    ctx.Rip,     1);
            return 74;
        }
        if (i && (ctx.Rip != prev_rip || ctx.Rsp != prev_rsp)) *varied = 1;
        prev_rip = ctx.Rip;
        prev_rsp = ctx.Rsp;
        Sleep(1);
    }
    *last_rip = prev_rip;
    *last_rsp = prev_rsp;
    return 0;
}

static int run_stw_spin_test(void)
{
    HANDLE t;
    DWORD tid = 0;
    ULONG64 rip = 0, rsp = 0;
    LONG64 before, after;
    int rc, varied = 0, spins;

    put_str("MADEIRA-CTX stw-spin start\n");
    g_b_spin = 0; g_b_go = 1; g_b_stack_base = 0;

    t = CreateThread(NULL, 0, thread_b_spin, NULL, 0, &tid);
    if (!t) return fail("CreateThread (sampled spinner)", 70, GetLastError());
    for (spins = 0; spins < 20000; spins++)
    {
        if (g_b_stack_base && g_b_spin > 100) break;
        Sleep(0);
    }
    if (!g_b_stack_base || g_b_spin <= 100)
        return fail("sampled thread never started", 71, (ULONG64)g_b_spin);

    before = g_b_spin;
    rc = sample_thread(t, &varied, &rip, &rsp);
    if (rc) return fail("sampling a spinning thread", rc, rsp ? rsp : rip);
    after = g_b_spin;

    put_kv("MADEIRA-CTX stw varied=",  (unsigned)varied, 0);
    put_kv("MADEIRA-CTX stw last_rip=", rip, 1);
    put_kv("MADEIRA-CTX stw last_rsp=", rsp, 1);
    put_kv("MADEIRA-CTX stw advanced=", (ULONG64)(after - before), 0);

    /* The stale-context signature: every sample identical AND the thread
     * demonstrably running the whole time. Either one alone is explainable
     * (a very tight loop can genuinely report one Rip; a thread can be
     * descheduled); together they can only mean the reply was cached. */
    if (!varied && after == before)
        return fail("every sample identical while the thread was running "
                    "(cached context)", 75, rip);
    if (!in_image(rip))
        return fail("Rip is not inside the exe image", 74, rip);

    g_b_go = 0;
    for (spins = 0; spins < 20000; spins++)
    {
        if (g_b_spin != after) break;
        Sleep(0);
    }
    if (WaitForSingleObject(t, 10000) != WAIT_OBJECT_0)
        return fail("spinner did not resume and exit after sampling", 76, (ULONG64)g_b_spin);
    CloseHandle(t);

    put_str("MADEIRA-CTX stw-spin PASS\n");
    return 0;
}

/* semaphore = 0 -> event, 1 -> semaphore. Same body: the two differ only in
 * which primitive parks the thread, and the whole point is that the answer must
 * not depend on that. */
static int run_stw_blocked_test(int semaphore)
{
    HANDLE t;
    DWORD tid = 0;
    ULONG64 rip = 0, rsp = 0;
    int rc, varied = 0, spins;

    put_str(semaphore ? "MADEIRA-CTX stw-semaphore start\n"
                      : "MADEIRA-CTX stw-event start\n");

    g_b_waiting = 0; g_b_woke = 0; g_b_stack_base = 0;
    g_b_obj = semaphore ? CreateSemaphoreW(NULL, 0, 1, NULL)
                        : CreateEventW(NULL, FALSE, FALSE, NULL);
    if (!g_b_obj) return fail("CreateEvent/CreateSemaphore", 77, GetLastError());

    t = CreateThread(NULL, 0, thread_b_wait, NULL, 0, &tid);
    if (!t) { CloseHandle(g_b_obj); return fail("CreateThread (blocked)", 70, GetLastError()); }

    for (spins = 0; spins < 20000; spins++)
    {
        if (g_b_waiting) break;
        Sleep(0);
    }
    if (!g_b_waiting) { CloseHandle(g_b_obj); return fail("blocked thread never reached its wait", 78, 0); }
    Sleep(50);   /* let it get all the way into the wait, not just past the flag */

    rc = sample_thread(t, &varied, &rip, &rsp);
    if (rc)
    {
        CloseHandle(g_b_obj);
        return fail(semaphore ? "sampling a semaphore-blocked thread"
                              : "sampling an event-blocked thread", rc, rsp ? rsp : rip);
    }

    put_kv("MADEIRA-CTX stw blocked varied=",  (unsigned)varied, 0);
    put_kv("MADEIRA-CTX stw blocked rip=",     rip, 1);
    put_kv("MADEIRA-CTX stw blocked rsp=",     rsp, 1);

    /* A blocked thread may legitimately report the same pair every time. What
     * it may not do is fail to wake up once it is released. */
    if (semaphore) ReleaseSemaphore(g_b_obj, 1, NULL);
    else           SetEvent(g_b_obj);

    if (WaitForSingleObject(t, 15000) != WAIT_OBJECT_0 || !g_b_woke)
    {
        CloseHandle(g_b_obj);
        return fail(semaphore ? "semaphore-blocked thread never woke after resume"
                              : "event-blocked thread never woke after resume",
                    79, (ULONG64)g_b_woke);
    }
    CloseHandle(t);
    CloseHandle(g_b_obj);
    g_b_obj = NULL;

    put_str(semaphore ? "MADEIRA-CTX stw-semaphore PASS\n"
                      : "MADEIRA-CTX stw-event PASS\n");
    return 0;
}

/* --- driver ------------------------------------------------------------- */

#define ITERATIONS 200

static int fail(const char *what, int code, ULONG64 v)
{
    put_str("MADEIRA-CTX FAIL: ");
    put_str(what);
    put_kv(" value=", v, 1);
    put_kv("MADEIRA-CTX exit=", (unsigned)code, 0);
    return code;
}

int main(void)
{
    HANDLE a;
    DWORD tid = 0;
    CONTEXT ctx, saved;
    LONG64 seen;
    int i, spins, warm;

    g_out = GetStdHandle(STD_OUTPUT_HANDLE);
    put_str("MADEIRA-CTX start\n");

    if (!image_bounds()) return fail("cannot read own PE headers", 56, 0);
    put_kv("MADEIRA-CTX image_base=", g_image_base, 1);
    put_kv("MADEIRA-CTX image_end=",  g_image_end,  1);

    a = CreateThread(NULL, 0, thread_a, NULL, 0, &tid);
    if (!a) return fail("CreateThread", 51, GetLastError());

    /* Wait for A to publish its stack and start advancing the counter. */
    for (spins = 0; spins < 20000; spins++)
    {
        if (g_stack_base && g_spin > 100) break;
        Sleep(0);
    }
    if (!g_stack_base || g_spin <= 100) return fail("thread A never span", 52, (ULONG64)g_spin);
    put_kv("MADEIRA-CTX a_stack_base=",  g_stack_base,  1);
    put_kv("MADEIRA-CTX a_stack_limit=", g_stack_limit, 1);

    /* Warm-up: tolerate a few captures that land outside the loop (A may still
     * be finishing thread startup inside ntdll). Inside the counted iterations
     * an out-of-image Rip is a hard failure — that is the thing being tested. */
    for (warm = 0; warm < 32; warm++)
    {
        if (SuspendThread(a) == (DWORD)-1) return fail("SuspendThread (warmup)", 53, 0);
        ctx.ContextFlags = CONTEXT_FULL;
        if (!GetThreadContext(a, &ctx)) { ResumeThread(a); return fail("GetThreadContext (warmup)", 54, GetLastError()); }
        ResumeThread(a);
        if (in_image(ctx.Rip) && in_a_stack(ctx.Rsp)) break;
        Sleep(1);
    }

    for (i = 0; i < ITERATIONS; i++)
    {
        if (SuspendThread(a) == (DWORD)-1) return fail("SuspendThread", 53, (ULONG64)i);

        ctx.ContextFlags = CONTEXT_FULL;
        if (!GetThreadContext(a, &ctx))
        {
            ResumeThread(a);
            return fail("GetThreadContext", 54, GetLastError());
        }

        if (!in_a_stack(ctx.Rsp))
        {
            ResumeThread(a);
            put_kv("MADEIRA-CTX iter=", (unsigned)i, 0);
            return fail("Rsp is not inside thread A's stack", 55, ctx.Rsp);
        }
        if (!in_image(ctx.Rip))
        {
            ResumeThread(a);
            put_kv("MADEIRA-CTX iter=", (unsigned)i, 0);
            return fail("Rip is not inside the exe image", 56, ctx.Rip);
        }

        saved = ctx;

        /* Redirect A to `landing` on a fresh slice of its own stack. x64 entry
         * convention: Rsp ≡ 8 (mod 16) at the first instruction of a function. */
        ctx.Rip = (DWORD64)(ULONG_PTR)&landing;
        ctx.Rsp = ((saved.Rsp - 1024) & ~(DWORD64)15) - 8;
        ctx.ContextFlags = CONTEXT_FULL;
        if (!SetThreadContext(a, &ctx))
        {
            ResumeThread(a);
            return fail("SetThreadContext (redirect)", 57, GetLastError());
        }
        if (ResumeThread(a) == (DWORD)-1) return fail("ResumeThread (redirect)", 58, (ULONG64)i);

        for (spins = 0; spins < 20000; spins++)
        {
            if (g_landed == i + 1) break;
            Sleep(0);
        }
        if (g_landed != i + 1)
        {
            put_kv("MADEIRA-CTX iter=", (unsigned)i, 0);
            return fail("thread A never reached landing()", 59, (ULONG64)g_landed);
        }

        /* Put the original context back and make sure A resumes its loop. */
        if (SuspendThread(a) == (DWORD)-1) return fail("SuspendThread (restore)", 53, (ULONG64)i);
        saved.ContextFlags = CONTEXT_FULL;
        if (!SetThreadContext(a, &saved))
        {
            ResumeThread(a);
            return fail("SetThreadContext (restore)", 57, GetLastError());
        }
        if (ResumeThread(a) == (DWORD)-1) return fail("ResumeThread (restore)", 58, (ULONG64)i);

        seen = g_spin;
        for (spins = 0; spins < 20000; spins++)
        {
            if (g_spin != seen) break;
            Sleep(0);
        }
        if (g_spin == seen)
        {
            put_kv("MADEIRA-CTX iter=", (unsigned)i, 0);
            return fail("thread A did not resume spinning", 60, (ULONG64)g_spin);
        }
    }

    g_go = 0;
    put_kv("MADEIRA-CTX iterations=", (unsigned)ITERATIONS, 0);
    put_kv("MADEIRA-CTX landings=",   (unsigned)g_landed,   0);

    /* ml1020: part 2 — the faulting thread's own handler rewrites Rip and
     * returns EXCEPTION_CONTINUE_EXECUTION. Runs after part 1 so image bounds
     * are already established (veh_continue uses in_image). */
    {
        int rc = run_veh_continue_test();
        if (rc) return rc;
    }

    /* ml1030: part 3 — Suspend/Get/Resume with no Set at all, which is the
     * shape a stop-the-world actually has and the only one that can detect a
     * cached context. Runs last so a failure here cannot be confused with a
     * failure of the round trip parts 1 and 2 cover. */
    {
        int rc = run_stw_spin_test();
        if (rc) return rc;
        rc = run_stw_blocked_test(0);
        if (rc) return rc;
        rc = run_stw_blocked_test(1);
        if (rc) return rc;
    }

    put_str("MADEIRA-CTX PASS\n");
    put_str("MADEIRA-CTX exit=50\n");
    /* A is parked in `landing` or in its loop; nothing to join. */
    return 50;
}
