/* MADEIRA-TEMP: the self-test for A BAD USER BUFFER HANDED TO A SYSTEM CALL
 * (build/ntdll-unix/signal_arm64_ios.c: ios_handle_unix_fault / bus_handler /
 * segv_handler, and build/ntdll-unix/virtual_ios.c:
 * virtual_check_buffer_for_read / virtual_check_buffer_for_write).
 *
 * WHY THIS TEST EXISTS
 * --------------------
 * When a program passes an unreadable or unwritable pointer to a system call,
 * the unix side of Wine PROBES the buffer before touching it.  The probe is
 * allowed to fault: upstream, the fault lands in the SIGSEGV handler,
 * handle_syscall_fault() sees that the thread is inside a syscall and either
 * longjmps back into the probe (which then returns FALSE) or unwinds the
 * syscall so it RETURNS the exception code.  WriteFile fails with
 * ERROR_NOACCESS and the program carries on, exactly as it does on Windows.
 *
 * On this port a reserved-but-uncommitted page is a PROT_NONE mapping, so the
 * abort is a PROTECTION failure, which Darwin delivers as SIGBUS rather than
 * SIGSEGV -- and the SIGBUS handler had no equivalent of that path.  The
 * probe's fault was therefore converted to an access violation and DISPATCHED
 * AS A GUEST EXCEPTION with a host pc and a host (kernel-stack) sp; the guest
 * SEH walk rejected the frame ("Exception frame is not in stack limits") and
 * the whole process was terminated with c0000005 -- for a bad pointer that
 * Windows answers with a failed WriteFile.
 *
 * WHAT IT CHECKS
 * --------------
 *  1. WriteFile FROM reserved-but-uncommitted memory.
 *  2. ReadFile INTO reserved-but-uncommitted memory.
 *  3. WriteFile from a buffer that STRADDLES committed -> uncommitted (the
 *     shape the device log showed: the buffer starts in one state and runs
 *     into the other, so only a probe of the WHOLE range can catch it).
 *  4. ReadFile INTO a committed but READ-ONLY page (the write probe, not the
 *     read probe).
 *  5. GetFileSizeEx with its out-pointer in uncommitted memory.
 *  6. QueryPerformanceCounter with its out-pointer in uncommitted memory.
 *     5 and 6 are NOT the same animal as 1-4 -- one is a file system call
 *     that probes, the other is resolved in user mode and simply faults --
 *     and the expectations below are the ones REAL WINDOWS produced, not
 *     what the documentation implies.
 *  7. ReadFile INTO a PAGE_GUARD buffer.
 *  8. A plain guest-side access violation, which must STILL be delivered to
 *     the program's own vectored handler.  This is the regression guard: the
 *     fix must not send an ordinary application fault down the syscall-unwind
 *     path.
 *
 * Every case prints what it observed AND what was expected, so a device log
 * says which one diverged without a second run.
 *
 * Deliberate restrictions, the same ones the other tests in this directory
 * work under: no CRT (this file supplies `start' and is linked -nostdlib, so
 * its only import is kernel32), no 64-bit division, no int-to-double
 * conversion.  Faults are caught with a VECTORED handler rather than __try,
 * because clang has no SEH for i386.
 *
 * Exit status (the runtime reports it as "MADEIRA-EXIT: ... status=<n>"):
 *   90  every check passed
 *   91  could not create the scratch file
 *   92  VirtualAlloc(MEM_RESERVE) failed
 *   93  VirtualAlloc(MEM_COMMIT) / VirtualProtect for a committed case failed
 *   94  case 1 (WriteFile from uncommitted) diverged
 *   95  case 2 (ReadFile into uncommitted) diverged
 *   96  case 3 (WriteFile from a straddling buffer) diverged
 *   97  case 4 (ReadFile into a read-only page) diverged
 *   98  case 5 (GetFileSizeEx out-pointer) diverged
 *   99  case 6 (QueryPerformanceCounter out-pointer) diverged
 *  100  case 7 (ReadFile into a PAGE_GUARD buffer) diverged
 *  101  case 8: the guest-side access violation never reached the program's
 *       own handler
 */
#include <stddef.h>
#include <windows.h>

#ifndef STATUS_GUARD_PAGE_VIOLATION
#define STATUS_GUARD_PAGE_VIOLATION ((DWORD)0x80000001)
#endif
#ifndef ERROR_NOACCESS
#define ERROR_NOACCESS 998
#endif

/* -nostdlib: clang may still lower a struct initialisation or a struct
 * assignment to memset/memcpy. */
void *memset( void *dst, int c, size_t n )
{
    unsigned char *p = dst;
    while (n--) *p++ = (unsigned char)c;
    return dst;
}

void *memcpy( void *dst, const void *src, size_t n )
{
    unsigned char *d = dst;
    const unsigned char *s = src;
    while (n--) *d++ = *s++;
    return dst;
}

static void write_log(const char *msg, DWORD len)
{
    HANDLE h = GetStdHandle(STD_ERROR_HANDLE);
    DWORD written = 0;
    WriteFile(h, msg, len, &written, NULL);
}

#define WRITE_LINE(lit) write_log( (lit), (DWORD)(sizeof(lit) - 1) )

/* no CRT (no strlen, no printf), so the numbers are formatted by hand. */
static DWORD format_uint(char *buf, DWORD size, unsigned int v, unsigned int base)
{
    static const char digits[] = "0123456789abcdef";
    DWORD i = size;

    if (!v) buf[--i] = '0';
    else while (v && i > 0)
    {
        buf[--i] = digits[v % base];
        v /= base;
    }
    return i;
}

static void write_uint(unsigned int value)
{
    char buf[16];
    DWORD i = format_uint(buf, sizeof(buf), value, 10);
    write_log(buf + i, sizeof(buf) - i);
}

static void write_hex(unsigned int value)
{
    char buf[16];
    DWORD i = format_uint(buf, sizeof(buf), value, 16);
    WRITE_LINE("0x");
    write_log(buf + i, sizeof(buf) - i);
}

/* ------------------------------------------------------------------ *
 * The observation record.  Every case is reduced to the same four
 * numbers so the expected values can be written down as data and a
 * device log can be diffed against a real-Windows log line by line.
 * ------------------------------------------------------------------ */
struct observation
{
    BOOL  ret;          /* what the API returned */
    DWORD err;          /* GetLastError() after it */
    DWORD faults;       /* exceptions the program's own handler saw */
    DWORD fault_code;   /* the last such exception code */
};

/* ------------------------------------------------------------------ *
 * The vectored handler.  It serves two purposes: it RECORDS whether an
 * exception reached user mode at all (which is the whole question for
 * cases 5-7), and for case 8 it is the program's own handler that must
 * still work.  In both roles it makes the faulting access succeed on
 * retry -- committing the page for an access violation, or simply
 * resuming for a guard-page hit, whose guard bit the fault already
 * cleared -- so the test never has to unwind.
 * ------------------------------------------------------------------ */
/* volatile: these are written from an asynchronous handler.  Without it, -O1
 * folds `g_fault_count` across a stretch with no opaque call in it -- case 8
 * is exactly that shape and reported faults=0 while the handler had run. */
static volatile DWORD g_fault_count;
static volatile DWORD g_fault_code;
static volatile DWORD g_fault_addr;
static volatile BOOL  g_fault_armed;

static LONG CALLBACK veh_handler(EXCEPTION_POINTERS *ep)
{
    DWORD code = ep->ExceptionRecord->ExceptionCode;
    void *addr;

    if (!g_fault_armed) return EXCEPTION_CONTINUE_SEARCH;
    if (code != EXCEPTION_ACCESS_VIOLATION && code != STATUS_GUARD_PAGE_VIOLATION)
        return EXCEPTION_CONTINUE_SEARCH;

    g_fault_count++;
    g_fault_code = code;
    g_fault_addr = 0;
    if (ep->ExceptionRecord->NumberParameters >= 2)
        g_fault_addr = (DWORD)ep->ExceptionRecord->ExceptionInformation[1];

    if (code == EXCEPTION_ACCESS_VIOLATION)
    {
        /* Commit the page so the retried instruction succeeds.  If it was
         * already committed (a protection problem rather than a reservation
         * one) this fails harmlessly and the retry re-faults, which the
         * count below would show as a runaway. */
        addr = (void *)(g_fault_addr & ~0xfffu);
        if (g_fault_count > 64) return EXCEPTION_CONTINUE_SEARCH;
        VirtualAlloc(addr, 0x1000, MEM_COMMIT, PAGE_READWRITE);
    }
    return EXCEPTION_CONTINUE_EXECUTION;
}

static void arm_handler(void)
{
    g_fault_count = 0;
    g_fault_code = 0;
    g_fault_addr = 0;
    g_fault_armed = TRUE;
}

static void disarm_handler(struct observation *obs)
{
    g_fault_armed = FALSE;
    obs->faults = g_fault_count;
    obs->fault_code = g_fault_code;
}

static void report(const char *name, DWORD name_len, const struct observation *got,
                   const struct observation *want)
{
    write_log("MADEIRA-BADBUF: ", 16);
    write_log(name, name_len);
    WRITE_LINE(" ret=");
    write_uint((unsigned int)got->ret);
    WRITE_LINE(" err=");
    write_uint((unsigned int)got->err);
    WRITE_LINE(" faults=");
    write_uint((unsigned int)got->faults);
    WRITE_LINE(" code=");
    write_hex((unsigned int)got->fault_code);
    WRITE_LINE("  [windows: ret=");
    write_uint((unsigned int)want->ret);
    WRITE_LINE(" err=");
    write_uint((unsigned int)want->err);
    WRITE_LINE(" faults=");
    write_uint((unsigned int)want->faults);
    WRITE_LINE(" code=");
    write_hex((unsigned int)want->fault_code);
    WRITE_LINE("]\n");
}

#define REPORT(lit, got, want) report( (lit), (DWORD)(sizeof(lit) - 1), (got), (want) )

static BOOL same(const struct observation *a, const struct observation *b)
{
    return a->ret == b->ret && a->err == b->err &&
           a->faults == b->faults && a->fault_code == b->fault_code;
}

static void fail(int status)
{
    WRITE_LINE("MADEIRA-BADBUF: FAILED status=");
    write_uint((unsigned int)status);
    WRITE_LINE("\n");
    ExitProcess((UINT)status);
}

/* ------------------------------------------------------------------ *
 * THE EXPECTED VALUES.
 *
 * Recorded by running this exact binary on real Windows 11 (build
 * 26200, x64 host, the test running as a 32-bit process under WOW64)
 * before it was ever trusted here.  They are DATA, not a prediction:
 * where a call raised in user mode instead of failing, that is what is
 * written down, because that is what a program will see.  Two of them
 * are worth saying out loud, because both contradict the obvious guess:
 *
 *   - the WRITE direction fails with ERROR_INVALID_USER_BUFFER (1784),
 *     not ERROR_NOACCESS.  Reading the caller's buffer and writing into
 *     it are two different failures and Windows reports them as such.
 *   - the PAGE_GUARD case returns FALSE with the RAW NTSTATUS
 *     0x80000001 as the last error, because STATUS_GUARD_PAGE_VIOLATION
 *     has no DOS mapping.  Wine's probe cannot distinguish a guard hit
 *     from any other failed write probe and collapses it to
 *     ERROR_NOACCESS, so BOTH are accepted: what matters, and what the
 *     port used to get wrong, is that the call FAILS and the process
 *     lives.
 *
 *   - GetFileSizeEx and QueryPerformanceCounter do NOT probe.  Both
 *     store their result through the caller's pointer in USER mode, so
 *     the bad pointer is an ordinary application access violation and
 *     the program's own handler sees it.  They are in this test to prove
 *     the fix did not swallow a guest fault into the syscall path.
 * ------------------------------------------------------------------ */
#define RESERVE_SIZE  0x100000   /* 1 MB reserved, nothing committed */

#ifndef ERROR_INVALID_USER_BUFFER
#define ERROR_INVALID_USER_BUFFER 1784
#endif

static const struct observation want_write_uncommitted = { FALSE, ERROR_INVALID_USER_BUFFER, 0, 0 };
static const struct observation want_read_uncommitted  = { FALSE, ERROR_NOACCESS, 0, 0 };
static const struct observation want_write_straddle    = { FALSE, ERROR_INVALID_USER_BUFFER, 0, 0 };
static const struct observation want_read_readonly     = { FALSE, ERROR_NOACCESS, 0, 0 };
static const struct observation want_getfilesizeex     = { TRUE,  0, 1, EXCEPTION_ACCESS_VIOLATION };
static const struct observation want_qpc               = { TRUE,  0, 1, EXCEPTION_ACCESS_VIOLATION };
static const struct observation want_read_guard        = { FALSE, STATUS_GUARD_PAGE_VIOLATION, 0, 0 };
static const struct observation want_read_guard_alt    = { FALSE, ERROR_NOACCESS, 0, 0 };

void start(void)
{
    static const WCHAR name[] = { 'b','a','d','b','u','f','-','x','8','6','.','t','m','p',0 };
    static char seed[0x2000];   /* static: an 8 KB stack array pulls in __alloca */
    WCHAR path[MAX_PATH + 32];
    struct observation obs;
    HANDLE file;
    BYTE *reserved, *straddle, *readonly_page, *guard_page;
    DWORD done, n, old_prot;
    volatile BYTE *p;
    int i, first_fail = 0;   /* every case runs, so one log says which diverged */

    if (!AddVectoredExceptionHandler(1, veh_handler))
    {
        WRITE_LINE("MADEIRA-BADBUF: AddVectoredExceptionHandler FAILED\n");
        fail(91);
    }

    /* --- the scratch file ------------------------------------------- */
    n = GetTempPathW(MAX_PATH, path);
    if (!n || n > MAX_PATH) { WRITE_LINE("MADEIRA-BADBUF: GetTempPathW FAILED\n"); fail(91); }
    for (i = 0; name[i]; i++) path[n + i] = name[i];
    path[n + i] = 0;

    file = CreateFileW(path, GENERIC_READ | GENERIC_WRITE, 0, NULL, CREATE_ALWAYS,
                       FILE_ATTRIBUTE_TEMPORARY, NULL);
    if (file == INVALID_HANDLE_VALUE)
    {
        WRITE_LINE("MADEIRA-BADBUF: CreateFileW FAILED err=");
        write_uint((unsigned int)GetLastError());
        WRITE_LINE("\n");
        fail(91);
    }
    memset(seed, 'A', sizeof(seed));
    if (!WriteFile(file, seed, sizeof(seed), &done, NULL) || done != sizeof(seed)) fail(91);

    /* --- the memory ------------------------------------------------- */
    reserved = VirtualAlloc(NULL, RESERVE_SIZE, MEM_RESERVE, PAGE_READWRITE);
    straddle = VirtualAlloc(NULL, RESERVE_SIZE, MEM_RESERVE, PAGE_READWRITE);
    if (!reserved || !straddle) fail(92);

    WRITE_LINE("MADEIRA-BADBUF: reserved=");
    write_hex((unsigned int)(ULONG_PTR)reserved);
    WRITE_LINE(" straddle=");
    write_hex((unsigned int)(ULONG_PTR)straddle);
    WRITE_LINE("\n");

    /* --- 1: WriteFile FROM reserved-but-uncommitted ----------------- */
    SetFilePointer(file, 0, NULL, FILE_BEGIN);
    arm_handler();
    SetLastError(0);
    obs.ret = WriteFile(file, reserved, 0x1000, &done, NULL);
    obs.err = GetLastError();
    disarm_handler(&obs);
    REPORT("1 write-from-uncommitted", &obs, &want_write_uncommitted);
    if (!same(&obs, &want_write_uncommitted) && !first_fail) first_fail = 94;

    /* --- 2: ReadFile INTO reserved-but-uncommitted ------------------ */
    SetFilePointer(file, 0, NULL, FILE_BEGIN);
    arm_handler();
    SetLastError(0);
    obs.ret = ReadFile(file, reserved, 0x1000, &done, NULL);
    obs.err = GetLastError();
    disarm_handler(&obs);
    REPORT("2 read-into-uncommitted ", &obs, &want_read_uncommitted);
    if (!same(&obs, &want_read_uncommitted) && !first_fail) first_fail = 95;

    /* --- 3: WriteFile from a buffer that straddles the boundary ----- */
    if (!VirtualAlloc(straddle, 0x1000, MEM_COMMIT, PAGE_READWRITE)) fail(93);
    memset(straddle, 'S', 0x1000);
    SetFilePointer(file, 0, NULL, FILE_BEGIN);
    arm_handler();
    SetLastError(0);
    obs.ret = WriteFile(file, straddle, 0x2000, &done, NULL);
    obs.err = GetLastError();
    disarm_handler(&obs);
    REPORT("3 write-straddling      ", &obs, &want_write_straddle);
    if (!same(&obs, &want_write_straddle) && !first_fail) first_fail = 96;

    /* --- 4: ReadFile INTO a committed but READ-ONLY page ------------ */
    readonly_page = VirtualAlloc(NULL, 0x1000, MEM_COMMIT | MEM_RESERVE, PAGE_READWRITE);
    if (!readonly_page) fail(93);
    memset(readonly_page, 0, 0x1000);
    if (!VirtualProtect(readonly_page, 0x1000, PAGE_READONLY, &old_prot)) fail(93);
    SetFilePointer(file, 0, NULL, FILE_BEGIN);
    arm_handler();
    SetLastError(0);
    obs.ret = ReadFile(file, readonly_page, 0x1000, &done, NULL);
    obs.err = GetLastError();
    disarm_handler(&obs);
    REPORT("4 read-into-readonly    ", &obs, &want_read_readonly);
    if (!same(&obs, &want_read_readonly) && !first_fail) first_fail = 97;

    /* --- 5: GetFileSizeEx with the out-pointer in uncommitted memory - */
    arm_handler();
    SetLastError(0);
    obs.ret = GetFileSizeEx(file, (LARGE_INTEGER *)(reserved + 0x8000));
    obs.err = GetLastError();
    disarm_handler(&obs);
    REPORT("5 getfilesizeex-badout  ", &obs, &want_getfilesizeex);
    if (!same(&obs, &want_getfilesizeex) && !first_fail) first_fail = 98;

    /* --- 6: QueryPerformanceCounter with the out-pointer likewise ---- */
    arm_handler();
    SetLastError(0);
    obs.ret = QueryPerformanceCounter((LARGE_INTEGER *)(reserved + 0xc000));
    obs.err = GetLastError();
    disarm_handler(&obs);
    REPORT("6 qpc-badout            ", &obs, &want_qpc);
    if (!same(&obs, &want_qpc) && !first_fail) first_fail = 99;

    /* --- 7: ReadFile INTO a PAGE_GUARD buffer ----------------------- */
    guard_page = VirtualAlloc(NULL, 0x1000, MEM_COMMIT | MEM_RESERVE, PAGE_READWRITE);
    if (!guard_page) fail(93);
    memset(guard_page, 0, 0x1000);
    if (!VirtualProtect(guard_page, 0x1000, PAGE_READWRITE | PAGE_GUARD, &old_prot)) fail(93);
    SetFilePointer(file, 0, NULL, FILE_BEGIN);
    arm_handler();
    SetLastError(0);
    obs.ret = ReadFile(file, guard_page, 0x1000, &done, NULL);
    obs.err = GetLastError();
    disarm_handler(&obs);
    REPORT("7 read-into-guard       ", &obs, &want_read_guard);
    if (!same(&obs, &want_read_guard) && !same(&obs, &want_read_guard_alt)
        && !first_fail) first_fail = 100;

    /* --- 8: a plain guest-side access violation --------------------- */
    /* The regression guard.  This fault happens on the PROGRAM's stack in
     * the PROGRAM's code, so it must still be dispatched to the program's
     * own handler -- never unwound as if it belonged to a system call. */
    arm_handler();
    p = (volatile BYTE *)(reserved + 0x40000);
    *p = 0x5a;                         /* faults: uncommitted, VEH commits it */
    obs.ret = (*p == 0x5a);            /* and the retried store really landed */
    obs.err = 0;
    disarm_handler(&obs);
    WRITE_LINE("MADEIRA-BADBUF: 8 guest-av-to-own-handler faults=");
    write_uint((unsigned int)obs.faults);
    WRITE_LINE(" code=");
    write_hex((unsigned int)obs.fault_code);
    WRITE_LINE(" store-landed=");
    write_uint((unsigned int)obs.ret);
    WRITE_LINE("  [windows: faults=1 code=0xc0000005 store-landed=1]\n");
    if ((obs.faults != 1 || obs.fault_code != EXCEPTION_ACCESS_VIOLATION || !obs.ret)
        && !first_fail) first_fail = 101;

    /* --- done ------------------------------------------------------- */
    CloseHandle(file);
    DeleteFileW(path);
    if (first_fail) fail(first_fail);

    WRITE_LINE("MADEIRA-BADBUF: all checks passed\n");
    ExitProcess(90);
}
