/* MADEIRA-TEMP: the self-test for the virtual monitor's mode table and for
 * ChangeDisplaySettings actually changing the monitor
 * (build/win32u-unix/sysparams_ios.c: ios_standard_modes, ios_mode_at_index,
 * ios_virtual_change_display_settings, ios_publish_screen_size).
 *
 * WHY THIS TEST EXISTS
 * --------------------
 * The port used to report ONE fixed virtual monitor -- 1024x768 for every
 * direct launch, whatever the device looked like -- and to answer
 * ChangeDisplaySettings with "accepted" while changing nothing.  Both halves
 * are generic defects, not one program's problem:
 *
 *  - A monitor whose mode list is "640x480, 800x600, and whatever you are
 *    already running" gives a game no way to ask for a resolution.  The
 *    documented sequence every engine uses (EnumDisplayDevices ->
 *    EnumDisplaySettings -> ChangeDisplaySettingsEx) then has nothing to pick
 *    from, so the game keeps whatever it defaulted to.
 *  - Accept-and-ignore is worse than a clean failure.  The game believes it is
 *    running at the mode it asked for, sizes its swapchain and its projection
 *    for that mode, and renders it into a screen of a different SHAPE.  The
 *    visible result is a small, wrongly-proportioned image; no amount of
 *    scaling at present time can undo it, because the aspect was decided
 *    inside the guest.
 *
 * WHAT IT CHECKS
 * --------------
 *  1. MODE TABLE.  EnumDisplaySettings enumerates at least 6 modes, index 0
 *     is the current mode, every mode is 32 bpp / 60 Hz, and 800x600 is among
 *     them.  A table of two entries passes nothing a game would call a choice.
 *  2. CURRENT == REGISTRY == index 0.  A current mode missing from, or
 *     disagreeing with, the list reads to an application as a monitor that
 *     cannot do what it is doing.
 *  3. THE SWITCH.  ChangeDisplaySettingsEx(800x600, CDS_FULLSCREEN) returns
 *     DISP_CHANGE_SUCCESSFUL, and afterwards GetSystemMetrics(SM_CXSCREEN /
 *     SM_CYSCREEN), GetMonitorInfo's rcMonitor and
 *     EnumDisplaySettings(ENUM_CURRENT_SETTINGS) ALL say 800x600.  Each of
 *     those reaches the virtual monitor by a different route, and the old
 *     accept-and-ignore path passed none of them.
 *  4. WM_DISPLAYCHANGE.  It arrives at a window this program created, carrying
 *     the new size in lParam -- that message is how a game learns to re-create
 *     its swapchain, so a mode change nobody is told about is still broken.
 *  5. RESTORE.  ChangeDisplaySettings(NULL, 0) puts the session default back
 *     and the screen metrics follow.  A test that left the monitor at 800x600
 *     would corrupt whatever runs next.
 *
 * Deliberate restrictions, the same ones the other tests in this directory
 * work under: no CRT (this file supplies `start' and is linked -nostdlib, so
 * its only imports are kernel32 and user32), no 64-bit division, no
 * int-to-double conversion.
 *
 * Exit status (the runtime reports it as "MADEIRA-EXIT: ... status=<n>"):
 *   51  every check passed
 *   52  EnumDisplaySettings(ENUM_CURRENT_SETTINGS) failed
 *   53  fewer than 6 modes enumerated
 *   54  800x600 is not in the mode list
 *   55  index 0 is not the current mode, or a mode is not 32bpp/60Hz
 *   56  RegisterClass/CreateWindowEx failed -- nothing was tested
 *   57  ChangeDisplaySettingsEx(800x600, CDS_FULLSCREEN) did not succeed
 *   58  SM_CXSCREEN/SM_CYSCREEN did not follow the switch
 *   59  GetMonitorInfo's rcMonitor did not follow the switch
 *   60  ENUM_CURRENT_SETTINGS did not follow the switch
 *   61  no WM_DISPLAYCHANGE, or it carried the wrong size
 *   62  ChangeDisplaySettings(NULL, 0) did not succeed
 *   63  the original mode did not come back
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

static int g_displaychange_w = -1;
static int g_displaychange_h = -1;

static void write_log(const char *msg, DWORD len)
{
    HANDLE h = GetStdHandle(STD_ERROR_HANDLE);
    DWORD written = 0;
    WriteFile(h, msg, len, &written, NULL);
}

/* no CRT (no strlen, no printf), so the prefix length is always passed in and
 * the numbers are formatted by hand */
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

static void write_size_line(const char *prefix, DWORD prefix_len,
                            unsigned int w, unsigned int h)
{
    char buf[32];
    DWORD i;

    write_log(prefix, prefix_len);
    i = format_uint(buf, sizeof(buf), w);
    write_log(buf + i, sizeof(buf) - i);
    write_log("x", 1);
    i = format_uint(buf, sizeof(buf), h);
    write_log(buf + i, sizeof(buf) - i);
    write_log("\n", 1);
}

#define WRITE_SIZE_LINE(lit, w, h) \
    write_size_line( (lit), (DWORD)(sizeof(lit) - 1), (unsigned int)(w), (unsigned int)(h) )

static void write_line(const char *msg, DWORD len) { write_log(msg, len); }
#define WRITE_LINE(lit) write_line( (lit), (DWORD)(sizeof(lit) - 1) )

static LRESULT CALLBACK WndProc(HWND hwnd, UINT msg, WPARAM wParam, LPARAM lParam)
{
    if (msg == WM_DISPLAYCHANGE)
    {
        g_displaychange_w = (int)(short)LOWORD(lParam);
        g_displaychange_h = (int)(short)HIWORD(lParam);
        WRITE_SIZE_LINE("MADEIRA-DISPMODE: WM_DISPLAYCHANGE ", g_displaychange_w, g_displaychange_h);
        return 0;
    }
    return DefWindowProcW(hwnd, msg, wParam, lParam);
}

/* WM_DISPLAYCHANGE is SENT, so on the thread that called
 * ChangeDisplaySettings it usually lands inside the call itself; pump anyway,
 * because the broadcast can also arrive posted. */
static void pump(void)
{
    MSG msg;
    int i;
    for (i = 0; i < 64; i++)
    {
        if (!PeekMessageW(&msg, NULL, 0, 0, PM_REMOVE)) break;
        TranslateMessage(&msg);
        DispatchMessageW(&msg);
    }
}

static BOOL enum_mode(DWORD index, DEVMODEW *dm)
{
    DEVMODEW zero = {0};
    *dm = zero;
    dm->dmSize = sizeof(*dm);
    return EnumDisplaySettingsW(NULL, index, dm);
}

static void fail(int status)
{
    WRITE_LINE("MADEIRA-DISPMODE: FAILED\n");
    ExitProcess((UINT)status);
}

void start(void)
{
    static const WCHAR className[] = L"MadeiraDispModeTest";
    DEVMODEW current, registry, mode, want;
    HINSTANCE instance = GetModuleHandleW(NULL);
    MONITORINFO mi;
    WNDCLASSW wc;
    HWND hwnd;
    HMONITOR hmon;
    DWORD i, count = 0;
    BOOL found_800x600 = FALSE;
    LONG ret;
    int orig_w, orig_h;

    WRITE_LINE("MADEIRA-DISPMODE: start\n");

    /* --- 1/2: the mode table ------------------------------------------- */

    if (!enum_mode(ENUM_CURRENT_SETTINGS, &current)) fail(52);
    orig_w = (int)current.dmPelsWidth;
    orig_h = (int)current.dmPelsHeight;
    WRITE_SIZE_LINE("MADEIRA-DISPMODE: current ", orig_w, orig_h);

    if (!enum_mode(ENUM_REGISTRY_SETTINGS, &registry)) fail(52);
    if ((int)registry.dmPelsWidth != orig_w || (int)registry.dmPelsHeight != orig_h) fail(55);

    for (i = 0; enum_mode(i, &mode); i++)
    {
        count++;
        WRITE_SIZE_LINE("MADEIRA-DISPMODE: mode ", mode.dmPelsWidth, mode.dmPelsHeight);
        if (mode.dmBitsPerPel != 32 || mode.dmDisplayFrequency != 60) fail(55);
        if (!i && ((int)mode.dmPelsWidth != orig_w || (int)mode.dmPelsHeight != orig_h)) fail(55);
        if (mode.dmPelsWidth == 800 && mode.dmPelsHeight == 600) found_800x600 = TRUE;
        if (count > 128) break;   /* a runaway enumeration is a bug of its own */
    }
    WRITE_SIZE_LINE("MADEIRA-DISPMODE: mode count/minimum ", count, 6);
    if (count < 6) fail(53);
    if (!found_800x600) fail(54);

    /* --- a window to receive WM_DISPLAYCHANGE --------------------------- */

    wc.style = 0;
    wc.lpfnWndProc = WndProc;
    wc.cbClsExtra = 0;
    wc.cbWndExtra = 0;
    wc.hInstance = instance;
    wc.hIcon = NULL;
    wc.hCursor = LoadCursorW(NULL, (LPCWSTR)IDC_ARROW);
    wc.hbrBackground = (HBRUSH)(COLOR_WINDOW + 1);
    wc.lpszMenuName = NULL;
    wc.lpszClassName = className;
    if (!RegisterClassW(&wc)) fail(56);

    hwnd = CreateWindowExW(0, className, className, WS_OVERLAPPEDWINDOW,
                           0, 0, 320, 240, NULL, NULL, instance, NULL);
    if (!hwnd) fail(56);
    ShowWindow(hwnd, SW_SHOW);
    pump();

    /* --- 3/4: switch to 800x600 ----------------------------------------- */

    {
        DEVMODEW zero = {0};
        want = zero;
    }
    want.dmSize = sizeof(want);
    want.dmFields = DM_PELSWIDTH | DM_PELSHEIGHT | DM_BITSPERPEL | DM_DISPLAYFREQUENCY;
    want.dmPelsWidth = 800;
    want.dmPelsHeight = 600;
    want.dmBitsPerPel = 32;
    want.dmDisplayFrequency = 60;

    ret = ChangeDisplaySettingsExW(NULL, &want, NULL, CDS_FULLSCREEN, NULL);
    if (ret != DISP_CHANGE_SUCCESSFUL)
    {
        WRITE_SIZE_LINE("MADEIRA-DISPMODE: switch returned/expected ",
                        (unsigned int)ret, (unsigned int)DISP_CHANGE_SUCCESSFUL);
        fail(57);
    }
    pump();

    WRITE_SIZE_LINE("MADEIRA-DISPMODE: after switch SM_CXSCREEN/SM_CYSCREEN ",
                    GetSystemMetrics(SM_CXSCREEN), GetSystemMetrics(SM_CYSCREEN));
    if (GetSystemMetrics(SM_CXSCREEN) != 800 || GetSystemMetrics(SM_CYSCREEN) != 600) fail(58);

    hmon = MonitorFromWindow(hwnd, MONITOR_DEFAULTTOPRIMARY);
    mi.cbSize = sizeof(mi);
    if (!GetMonitorInfoW(hmon, &mi)) fail(59);
    WRITE_SIZE_LINE("MADEIRA-DISPMODE: after switch rcMonitor ",
                    mi.rcMonitor.right - mi.rcMonitor.left,
                    mi.rcMonitor.bottom - mi.rcMonitor.top);
    if (mi.rcMonitor.right - mi.rcMonitor.left != 800 ||
        mi.rcMonitor.bottom - mi.rcMonitor.top != 600) fail(59);

    if (!enum_mode(ENUM_CURRENT_SETTINGS, &mode)) fail(60);
    if (mode.dmPelsWidth != 800 || mode.dmPelsHeight != 600) fail(60);

    if (g_displaychange_w != 800 || g_displaychange_h != 600)
    {
        WRITE_SIZE_LINE("MADEIRA-DISPMODE: WM_DISPLAYCHANGE said ",
                        (unsigned int)g_displaychange_w, (unsigned int)g_displaychange_h);
        fail(61);
    }

    /* --- 5: restore ------------------------------------------------------ */

    ret = ChangeDisplaySettingsW(NULL, 0);
    if (ret != DISP_CHANGE_SUCCESSFUL) fail(62);
    pump();

    WRITE_SIZE_LINE("MADEIRA-DISPMODE: after restore SM_CXSCREEN/SM_CYSCREEN ",
                    GetSystemMetrics(SM_CXSCREEN), GetSystemMetrics(SM_CYSCREEN));
    if (GetSystemMetrics(SM_CXSCREEN) != orig_w || GetSystemMetrics(SM_CYSCREEN) != orig_h) fail(63);
    if (!enum_mode(ENUM_CURRENT_SETTINGS, &mode)) fail(63);
    if ((int)mode.dmPelsWidth != orig_w || (int)mode.dmPelsHeight != orig_h) fail(63);

    DestroyWindow(hwnd);
    WRITE_LINE("MADEIRA-DISPMODE: all checks passed\n");
    ExitProcess(51);
}
