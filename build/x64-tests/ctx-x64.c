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
    put_str("MADEIRA-CTX PASS\n");
    put_str("MADEIRA-CTX exit=50\n");
    /* A is parked in `landing` or in its loop; nothing to join. */
    return 50;
}
