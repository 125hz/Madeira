/* MADEIRA-TEMP: the self-test for XInput — a controller paired to the phone,
 * reaching a 32-bit Windows program as XInput user 0.
 *
 * WHAT IT IS ACTUALLY TESTING
 * ---------------------------
 * The whole transport, end to end, and nothing else:
 *
 *   app/Madeira/HardwareInput.swift   samples GCExtendedGamepad at 250 Hz
 *   app/Madeira/Winios/Winios.m       winios_gamepad_set_state -> a shared slot
 *   build/win32u-unix/driver_ios.c    ios_gamepad_query reads that slot
 *   wine/dlls/win32u/sysparams.c      NtUserCallTwoParam_GetGamepadState
 *   wine/dlls/wow64win/user.c         the 32-bit pointer translation
 *   wine/dlls/xinput1_3/main.c        XInputGetState over the syscall
 *
 * Every one of those is a place the sample can be lost, and only the last one
 * is visible from inside a Windows program — which is exactly why the test
 * lives here and not in the app. A 32-bit build specifically, because the
 * wow64 thunk in that list is on the 32-bit path ONLY: a 64-bit program would
 * pass this test with the thunk missing entirely.
 *
 * WHAT IT DOES
 * ------------
 * Loads xinput1_3.dll by name (so its only import is kernel32 — see the build
 * script), then polls XInputGetState(0) at 120 Hz for fifteen seconds. Every
 * time the packet number CHANGES it prints one line:
 *
 *   MADEIRA-XINPUT: packet=N buttons=0x.... lx=.... ly=.... lt=... rt=...
 *
 * The packet number is the point. XInput's contract is that it only moves when
 * the pad's state actually changed, so a stream of identical packets means the
 * pad is connected and nobody is touching it, while a packet that never moves
 * AT ALL under an actively-waggled stick means the transport is dead somewhere
 * in the list above. Those are different failures and the log distinguishes
 * them: a connected pad with no change exits 63 saying so, and a pad that
 * never connected exits 63 saying THAT.
 *
 * HOW TO RUN IT: launch it, then move a stick or press a button on the paired
 * controller. It exits as soon as it sees one change.
 *
 * Deliberate restrictions, the same ones the other tests in this directory
 * work under: no CRT (this file supplies `start' and is linked -nostdlib, so
 * its only import is kernel32), no 64-bit division, no int-to-double
 * conversion.
 *
 * Exit status (the runtime reports it as "MADEIRA-EXIT: ... status=<n>"):
 *   53  at least one packet change was observed — the transport works
 *   61  xinput1_3.dll did not load
 *   62  xinput1_3.dll has no XInputGetState export
 *   63  fifteen seconds with no packet change (the line above says why)
 */
#include <stddef.h>
#include <windows.h>

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

/* xinput.h is not included: the mingw copy drags in a CRT-dependent header
 * chain, and these two structs are the entire ABI this test depends on. They
 * are byte-for-byte XINPUT_GAMEPAD and XINPUT_STATE, which is also why they
 * can be read the same way in a 32-bit and a 64-bit program. */
typedef struct
{
    WORD  wButtons;
    BYTE  bLeftTrigger;
    BYTE  bRightTrigger;
    SHORT sThumbLX;
    SHORT sThumbLY;
    SHORT sThumbRX;
    SHORT sThumbRY;
} MD_XINPUT_GAMEPAD;

typedef struct
{
    DWORD dwPacketNumber;
    MD_XINPUT_GAMEPAD Gamepad;
} MD_XINPUT_STATE;

typedef DWORD (WINAPI *xinput_get_state_t)(DWORD, MD_XINPUT_STATE *);

#define MD_ERROR_DEVICE_NOT_CONNECTED 1167

static void write_log(const char *msg, DWORD len)
{
    HANDLE h = GetStdHandle(STD_ERROR_HANDLE);
    DWORD written = 0;
    WriteFile(h, msg, len, &written, NULL);
}

static void write_line(const char *msg, DWORD len) { write_log(msg, len); }
#define WRITE_LINE(lit) write_line( (lit), (DWORD)(sizeof(lit) - 1) )

/* no CRT (no strlen, no printf), so every number is formatted by hand */
static DWORD format_uint(char *buf, DWORD size, unsigned int value)
{
    DWORD i = size;
    if (!value) buf[--i] = '0';
    else while (value && i > 0)
    {
        buf[--i] = (char)('0' + (value % 10));
        value /= 10;
    }
    return i;
}

static void write_uint(unsigned int v)
{
    char buf[16];
    DWORD i = format_uint(buf, sizeof(buf), v);
    write_log(buf + i, sizeof(buf) - i);
}

/* Signed, because a stick reads negative for left and down and printing it
 * unsigned would turn "full left" into 4294934528. */
static void write_int(int v)
{
    if (v < 0) { write_log("-", 1); write_uint((unsigned int)(-v)); }
    else write_uint((unsigned int)v);
}

static void write_hex16(unsigned int v)
{
    static const char digits[] = "0123456789abcdef";
    char buf[6];
    int i;

    buf[0] = '0';
    buf[1] = 'x';
    for (i = 0; i < 4; i++) buf[2 + i] = digits[(v >> ((3 - i) * 4)) & 0xf];
    write_log(buf, 6);
}

static void report(const MD_XINPUT_STATE *s)
{
    WRITE_LINE("MADEIRA-XINPUT: packet=");
    write_uint(s->dwPacketNumber);
    WRITE_LINE(" buttons=");
    write_hex16(s->Gamepad.wButtons);
    WRITE_LINE(" lx=");
    write_int(s->Gamepad.sThumbLX);
    WRITE_LINE(" ly=");
    write_int(s->Gamepad.sThumbLY);
    WRITE_LINE(" lt=");
    write_uint(s->Gamepad.bLeftTrigger);
    WRITE_LINE(" rt=");
    write_uint(s->Gamepad.bRightTrigger);
    WRITE_LINE("\n");
}

void start(void)
{
    /* 15 s at 120 Hz. The poll rate is deliberately faster than the app's
     * 250 Hz sampler is slow: a game polls XInput once per frame at least, and
     * a transport that only survives a leisurely poll is not one. */
    static const int poll_ms = 8;
    static const int total_polls = 15 * 1000 / 8;

    xinput_get_state_t pXInputGetState;
    MD_XINPUT_STATE state, last;
    DWORD ret, last_packet = 0;
    HMODULE mod;
    int i, seen_connected = 0, have_last = 0;

    WRITE_LINE("MADEIRA-XINPUT: start (15s; move a stick or press a button)\n");

    mod = LoadLibraryA("xinput1_3.dll");
    if (!mod)
    {
        WRITE_LINE("MADEIRA-XINPUT: LoadLibrary(xinput1_3.dll) failed, error=");
        write_uint(GetLastError());
        WRITE_LINE("\n");
        ExitProcess(61);
    }

    pXInputGetState = (xinput_get_state_t)GetProcAddress(mod, "XInputGetState");
    if (!pXInputGetState)
    {
        WRITE_LINE("MADEIRA-XINPUT: no XInputGetState export\n");
        ExitProcess(62);
    }

    memset(&last, 0, sizeof(last));

    for (i = 0; i < total_polls; i++)
    {
        memset(&state, 0, sizeof(state));
        ret = pXInputGetState(0, &state);

        if (ret == MD_ERROR_DEVICE_NOT_CONNECTED)
        {
            /* Not an error yet: the pad may be paired halfway through the
             * window, and saying so once is more useful than saying nothing. */
            if (seen_connected)
            {
                WRITE_LINE("MADEIRA-XINPUT: pad 0 went away\n");
                seen_connected = 0;
            }
            Sleep(poll_ms);
            continue;
        }
        if (ret != 0)
        {
            WRITE_LINE("MADEIRA-XINPUT: XInputGetState returned ");
            write_uint(ret);
            WRITE_LINE("\n");
            Sleep(poll_ms);
            continue;
        }

        if (!seen_connected)
        {
            seen_connected = 1;
            WRITE_LINE("MADEIRA-XINPUT: pad 0 connected\n");
            report(&state);
            last = state;
            last_packet = state.dwPacketNumber;
            have_last = 1;
            Sleep(poll_ms);
            continue;
        }

        if (have_last && state.dwPacketNumber != last_packet)
        {
            report(&state);
            last = state;
            last_packet = state.dwPacketNumber;
            WRITE_LINE("MADEIRA-XINPUT: packet changed - transport works\n");
            ExitProcess(53);
        }

        Sleep(poll_ms);
    }

    if (!seen_connected)
        WRITE_LINE("MADEIRA-XINPUT: TIMEOUT - no pad in slot 0 for 15s "
                   "(XInputGetState kept returning ERROR_DEVICE_NOT_CONNECTED). "
                   "Pair a controller and look for [xinput] pad0 connected in the log.\n");
    else
        WRITE_LINE("MADEIRA-XINPUT: TIMEOUT - pad 0 is connected but its packet "
                   "number never moved in 15s. The app's sampler or the win32u "
                   "slot is stuck; look for the 10s [xinput] pad0 packets= line.\n");
    (void)last;
    ExitProcess(63);
}
