/* MADEIRA-TEMP: the self-test for DirectInput — the host gamepad reaching a
 * 32-bit Windows program through IDirectInput8, not through XInput.
 *
 * WHAT IT IS ACTUALLY TESTING
 * ---------------------------
 * xinput-x86.exe already proves the transport from the phone's controller to
 * a Windows process:
 *
 *   app/Madeira/HardwareInput.swift   samples GCExtendedGamepad at 250 Hz
 *   app/Madeira/Winios/Winios.m       winios_gamepad_set_state -> a shared slot
 *   build/win32u-unix/driver_ios.c    ios_gamepad_query reads that slot
 *   wine/dlls/win32u/sysparams.c      NtUserCallTwoParam_GetGamepadState
 *   wine/dlls/wow64win/user.c         the 32-bit pointer translation
 *
 * This test covers the layer ABOVE that one, which xinput-x86.exe cannot see:
 *
 *   wine/dlls/dinput/joystick_ios.c   the same slot, as a DirectInput joystick
 *   wine/dlls/dinput/dinput.c         offered ahead of the HID enumeration
 *
 * That distinction is the whole reason this file exists. A game that reads its
 * pad through DirectInput — most games older than about 2010, and plenty of
 * newer ones for their menus — never calls XInputGetState at all. It calls
 * IDirectInput8::EnumDevices(DI8DEVCLASS_GAMECTRL), and on this port that used
 * to enumerate NOTHING: dinput's only joystick backend walks the HID device
 * interfaces that winebus.sys creates, and there is no winebus.sys here. So
 * xinput-x86.exe could pass while every DirectInput title in the same prefix
 * saw no controller.
 *
 * WHAT IT DOES
 * ------------
 * 1. DirectInput8Create, then EnumDevices(DI8DEVCLASS_GAMECTRL). It prints
 *    every device the enumeration offers, so a run that finds the WRONG number
 *    of devices is as legible as one that finds none.
 * 2. CreateDevice on the first one, SetDataFormat(&c_dfDIJoystick2) — the
 *    generic format a game uses, not a private one, so the format-translation
 *    path in dinput's core is exercised — SetCooperativeLevel(BACKGROUND |
 *    NONEXCLUSIVE) and Acquire.
 * 3. Prints the state at rest and runs a REST CHECK on it (see rest_check):
 *    with DirectInput's default 0..65535 range every axis must read ~32767 and
 *    the POV must read -1. That is the exact property whose absence made a
 *    2008 title's camera spin: the first version of joystick_ios.c described
 *    the trigger axes as if 0 were their centre, so a RELEASED trigger read as
 *    a fully deflected axis.
 * 4. Polls at 120 Hz for ten seconds. Every time the state CHANGES it prints
 *    one line:
 *
 *      MADEIRA-DINPUT: x=..... y=..... z=..... rx=..... ry=..... pov=.....
 *                      buttons=0x........
 *
 *    and exits on the first one. X/Y are the left stick, Rx/Ry the right
 *    stick, and Z the COMBINED triggers (left - right, centred when both are
 *    released) — the Xbox 360 DirectInput layout, so there is no Rz. pov is
 *    hundredths of a degree or -1 for centred, and buttons is a bitmask of the
 *    first 32.
 *
 * HOW TO RUN IT: launch it, then move a stick or press a button on the paired
 * controller. It exits as soon as it sees one change.
 *
 * Deliberate restrictions, the same ones the other tests in this directory
 * work under: no CRT (this file supplies `start' and is linked -nostdlib, so
 * its imports are dinput8, ole32, user32 and kernel32 and nothing else), no
 * 64-bit division, no int-to-double conversion.
 *
 * Exit status (the runtime reports it as "MADEIRA-EXIT: ... status=<n>"):
 *   58  a device enumerated AND its state changed at least once — it works
 *   64  DirectInput8Create failed
 *   65  CreateDevice / SetDataFormat / SetCooperativeLevel failed
 *   66  Acquire failed
 *   68  the enumeration produced no game controller at all
 *   69  a device enumerated but its state never changed in ten seconds
 */
#include <stddef.h>
#include <windows.h>

#define DIRECTINPUT_VERSION 0x0800
#include <dinput.h>

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

/* Signed, because a POV reads -1 when centred and printing that unsigned
 * would turn "no direction" into 4294967295. */
static void write_int(int v)
{
    if (v < 0) { write_log("-", 1); write_uint((unsigned int)(-v)); }
    else write_uint((unsigned int)v);
}

static void write_hex32(unsigned int v)
{
    static const char digits[] = "0123456789abcdef";
    char buf[10];
    int i;

    buf[0] = '0';
    buf[1] = 'x';
    for (i = 0; i < 8; i++) buf[2 + i] = digits[(v >> ((7 - i) * 4)) & 0xf];
    write_log(buf, 10);
}

/* The instance name is a WCHAR string and there is no CRT to widen or narrow
 * it; the ASCII subset is all these names ever are. */
static void write_wstr(const WCHAR *s)
{
    char buf[64];
    int i = 0;
    while (s[i] && i < (int)sizeof(buf) - 1) { buf[i] = (char)(s[i] & 0x7f); i++; }
    write_log(buf, i);
}

struct enum_ctx
{
    GUID  guid;
    DWORD count;
};

static BOOL CALLBACK enum_cb(const DIDEVICEINSTANCEW *instance, void *context)
{
    struct enum_ctx *ctx = context;

    WRITE_LINE("MADEIRA-DINPUT: device ");
    write_uint(ctx->count);
    WRITE_LINE(" type=");
    write_hex32(instance->dwDevType);
    WRITE_LINE(" instance=\"");
    write_wstr(instance->tszInstanceName);
    WRITE_LINE("\" product=\"");
    write_wstr(instance->tszProductName);
    WRITE_LINE("\"\n");

    if (!ctx->count) ctx->guid = instance->guidInstance;
    ctx->count++;
    /* keep going: the point of listing them all is that "two devices" is a
     * different bug from "no devices", and only the log can say which. */
    return DIENUM_CONTINUE;
}

static void report(const DIJOYSTATE2 *js)
{
    DWORD buttons = 0;
    int i;

    for (i = 0; i < 32; i++) if (js->rgbButtons[i] & 0x80) buttons |= 1u << i;

    WRITE_LINE("MADEIRA-DINPUT: x=");
    write_int(js->lX);
    WRITE_LINE(" y=");
    write_int(js->lY);
    WRITE_LINE(" z=");
    write_int(js->lZ);
    WRITE_LINE(" rx=");
    write_int(js->lRx);
    WRITE_LINE(" ry=");
    write_int(js->lRy);
    WRITE_LINE(" pov=");
    write_int((int)js->rgdwPOV[0]);
    WRITE_LINE(" buttons=");
    write_hex32(buttons);
    WRITE_LINE("\n");
}

/* THE REST CHECK — the property the first version of joystick_ios.c did not
 * have, and the one that made a 2008 title's camera spin.
 *
 * DirectInput's default axis range is 0..65535, so an axis nobody is touching
 * must read its CENTRE, 32767 (the device's integer scaling lands one LSB
 * above it, hence the tolerance), and an untouched POV must read -1
 * (0xffffffff), not 0 — 0 is "up". An axis that rests at an END of the range
 * is a stick held permanently hard over as far as the game is concerned, and
 * a game that maps it to camera yaw turns forever and cannot be out-voted by
 * the mouse.
 *
 * Reported as a line rather than an exit code on purpose: if the player is
 * holding a stick or a trigger when this runs, a failure here is theirs, not
 * the driver's. The line is what the device log is grepped for. */
#define REST_CENTRE   32767
#define REST_TOLERANCE  512

static int near_centre(LONG v)
{
    LONG d = v - REST_CENTRE;
    if (d < 0) d = -d;
    return d <= REST_TOLERANCE;
}

static void rest_check(const DIJOYSTATE2 *js)
{
    int ok = 1;

    if (!near_centre(js->lX))  { WRITE_LINE("MADEIRA-DINPUT: REST-CHECK x not centred\n");  ok = 0; }
    if (!near_centre(js->lY))  { WRITE_LINE("MADEIRA-DINPUT: REST-CHECK y not centred\n");  ok = 0; }
    if (!near_centre(js->lZ))  { WRITE_LINE("MADEIRA-DINPUT: REST-CHECK z not centred "
                                            "(z is the COMBINED triggers; released = centre)\n"); ok = 0; }
    if (!near_centre(js->lRx)) { WRITE_LINE("MADEIRA-DINPUT: REST-CHECK rx not centred\n"); ok = 0; }
    if (!near_centre(js->lRy)) { WRITE_LINE("MADEIRA-DINPUT: REST-CHECK ry not centred\n"); ok = 0; }
    if (js->rgdwPOV[0] != 0xffffffff)
    {
        WRITE_LINE("MADEIRA-DINPUT: REST-CHECK pov is not -1 (idle must be 0xffffffff, not 0 = up)\n");
        ok = 0;
    }

    if (ok) WRITE_LINE("MADEIRA-DINPUT: REST-CHECK pass (every axis centred, pov -1)\n");
    else    WRITE_LINE("MADEIRA-DINPUT: REST-CHECK FAIL - an axis rests off-centre. If nobody was "
                       "touching the pad this is the bug that spins a camera forever; see "
                       "joystick_ios.c ios_init_object_properties.\n");
}

/* Two states differ if anything a game would react to differs. Comparing the
 * whole DIJOYSTATE2 would also catch the unused slider/POV padding, which is
 * constant here but would make this test depend on that staying true. */
static int state_changed(const DIJOYSTATE2 *a, const DIJOYSTATE2 *b)
{
    int i;

    if (a->lX != b->lX || a->lY != b->lY || a->lZ != b->lZ) return 1;
    if (a->lRx != b->lRx || a->lRy != b->lRy) return 1;
    if (a->rgdwPOV[0] != b->rgdwPOV[0]) return 1;
    for (i = 0; i < 32; i++) if (a->rgbButtons[i] != b->rgbButtons[i]) return 1;
    return 0;
}

void start(void)
{
    /* 10 s at 120 Hz, matching xinput-x86.exe's cadence: a game polls its pad
     * at least once a frame, and a path that only survives a leisurely poll is
     * not one. */
    static const int poll_ms = 8;
    static const int total_polls = 10 * 1000 / 8;

    IDirectInputDevice8W *device = NULL;
    IDirectInput8W *dinput = NULL;
    DIJOYSTATE2 state, last;
    struct enum_ctx ctx;
    HRESULT hr;
    int i;

    WRITE_LINE("MADEIRA-DINPUT: start (10s; move a stick or press a button)\n");

    CoInitializeEx(NULL, COINIT_APARTMENTTHREADED);

    hr = DirectInput8Create(GetModuleHandleW(NULL), DIRECTINPUT_VERSION,
                            &IID_IDirectInput8W, (void **)&dinput, NULL);
    if (FAILED(hr) || !dinput)
    {
        WRITE_LINE("MADEIRA-DINPUT: DirectInput8Create failed hr=");
        write_hex32((unsigned int)hr);
        WRITE_LINE("\n");
        ExitProcess(64);
    }

    memset(&ctx, 0, sizeof(ctx));
    hr = IDirectInput8_EnumDevices(dinput, DI8DEVCLASS_GAMECTRL, enum_cb, &ctx, DIEDFL_ATTACHEDONLY);
    WRITE_LINE("MADEIRA-DINPUT: EnumDevices hr=");
    write_hex32((unsigned int)hr);
    WRITE_LINE(" devices=");
    write_uint(ctx.count);
    WRITE_LINE("\n");

    if (!ctx.count)
    {
        WRITE_LINE("MADEIRA-DINPUT: NO GAME CONTROLLER - EnumDevices("
                   "DI8DEVCLASS_GAMECTRL) returned nothing. Either no pad is "
                   "paired (check for [winios] gamepad slot 0 connected in the "
                   "log, and run xinput-x86.exe first), or dinput.dll in the "
                   "i386 farm predates joystick_ios.c.\n");
        ExitProcess(68);
    }

    hr = IDirectInput8_CreateDevice(dinput, &ctx.guid, &device, NULL);
    if (SUCCEEDED(hr)) hr = IDirectInputDevice8_SetDataFormat(device, &c_dfDIJoystick2);
    if (SUCCEEDED(hr)) hr = IDirectInputDevice8_SetCooperativeLevel(device, NULL,
                                                                    DISCL_BACKGROUND | DISCL_NONEXCLUSIVE);
    if (FAILED(hr))
    {
        WRITE_LINE("MADEIRA-DINPUT: device setup failed hr=");
        write_hex32((unsigned int)hr);
        WRITE_LINE("\n");
        ExitProcess(65);
    }

    hr = IDirectInputDevice8_Acquire(device);
    if (FAILED(hr))
    {
        WRITE_LINE("MADEIRA-DINPUT: Acquire failed hr=");
        write_hex32((unsigned int)hr);
        WRITE_LINE("\n");
        ExitProcess(66);
    }

    memset(&last, 0, sizeof(last));
    IDirectInputDevice8_Poll(device);
    if (SUCCEEDED(IDirectInputDevice8_GetDeviceState(device, sizeof(last), &last)))
    {
        WRITE_LINE("MADEIRA-DINPUT: acquired, initial state:\n");
        report(&last);
        rest_check(&last);
    }

    for (i = 0; i < total_polls; i++)
    {
        IDirectInputDevice8_Poll(device);
        memset(&state, 0, sizeof(state));
        hr = IDirectInputDevice8_GetDeviceState(device, sizeof(state), &state);
        if (hr == DIERR_INPUTLOST)
        {
            /* the pad went away; re-Acquire is what a game does here */
            IDirectInputDevice8_Acquire(device);
            Sleep(poll_ms);
            continue;
        }
        if (FAILED(hr))
        {
            WRITE_LINE("MADEIRA-DINPUT: GetDeviceState hr=");
            write_hex32((unsigned int)hr);
            WRITE_LINE("\n");
            Sleep(poll_ms);
            continue;
        }

        if (state_changed(&state, &last))
        {
            report(&state);
            WRITE_LINE("MADEIRA-DINPUT: state changed - DirectInput path works\n");
            ExitProcess(58);
        }

        Sleep(poll_ms);
    }

    WRITE_LINE("MADEIRA-DINPUT: TIMEOUT - the device enumerated and acquired, "
               "but its state never changed in 10s. The enumeration half works "
               "and the polling half does not: look at joystick_ios.c "
               "ios_joystick_sample, and check xinput-x86.exe still passes.\n");
    ExitProcess(69);
}
