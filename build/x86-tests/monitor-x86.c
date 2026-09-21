/* MADEIRA-TEMP: the self-test for the PRIMARY MONITOR RECTANGLE and everything
 * a program places a window with (build/win32u-unix/sysparams_ios.c:
 * lock_display_devices, monitor_get_rect, monitor_get_info, get_monitor_info,
 * monitor_from_rect, get_primary_monitor_rect, SPI_GETWORKAREA).
 *
 * WHY THIS TEST EXISTS
 * --------------------
 * A direct launch placed a 255x86 dialog at {-127,-43,128,43}, which is
 * exactly ((0 + 0 - 255)/2, (0 + 0 - 86)/2): centred on an EMPTY rectangle.
 * The same program in a desktop session centred the same dialog correctly.
 * Nothing in either log said which of the several rectangles a centring
 * helper can ask for was the empty one, because none of them is logged and a
 * failed GetMonitorInfo leaves the caller's MONITORINFO untouched -- zero, on
 * a fresh stack, which is indistinguishable from a monitor of size zero.
 *
 * There are five separate routes to "how big is the screen", they are
 * computed by four different functions on this port, and they had at least
 * two independent ways of answering zero:
 *
 *   - the monitor list is built lazily, and the builder's early-out could
 *     return "up to date" while the list was still EMPTY (every consumer then
 *     answers {0,0,0,0} and MonitorFromWindow returns NULL);
 *   - SPI_GETWORKAREA caches its answer in a static and used to latch even a
 *     never-computed one -- for the whole session, since one win32u serves
 *     every process here.
 *
 * So this test asks all five, prints every answer, and fails with a distinct
 * status for each -- a log line naming the route is the point, not the pass.
 *
 * WHAT IT CHECKS
 * --------------
 *  1. GetSystemMetrics(SM_CXSCREEN/SM_CYSCREEN) is non-zero.
 *  2. GetSystemMetrics(SM_CXVIRTUALSCREEN/SM_CYVIRTUALSCREEN) is non-zero and
 *     at least as large as the primary (it comes from a different function --
 *     the union of the monitor list -- and is the one that reads an empty
 *     list as a zero-sized desktop).
 *  3. MonitorFromWindow(NULL, MONITOR_DEFAULTTOPRIMARY) returns a handle at
 *     all, and GetMonitorInfoW succeeds on it.
 *  4. Its rcMonitor is non-empty and agrees with SM_C{X,Y}SCREEN, and its
 *     rcWork is non-empty and inside rcMonitor.
 *  5. SystemParametersInfoW(SPI_GETWORKAREA) is non-empty and agrees with
 *     rcWork.  This is the cached one.
 *  6. EnumDisplayMonitors reports at least one monitor with a non-empty rect.
 *  7. GetWindowRect(GetDesktopWindow()) is non-empty and agrees with the
 *     virtual screen.
 *  8. A DS_CENTER dialog, created with no owner and no active window -- the
 *     exact shape of the failure -- lands INSIDE the primary monitor.
 *
 * It also dumps the EnumDisplaySettings mode list, because a program that
 * cannot find a mode of its own shape is the other half of the same story and
 * the two are read from the same log.
 *
 * Deliberate restrictions, the same ones the other tests in this directory
 * work under: no CRT (this file supplies `start' and is linked -nostdlib, so
 * its only imports are kernel32 and user32), no 64-bit division, no
 * int-to-double conversion.
 *
 * Exit status (the runtime reports it as "MADEIRA-EXIT: ... status=<n>"):
 *   71  every check passed
 *   72  SM_CXSCREEN or SM_CYSCREEN is zero
 *   73  SM_CXVIRTUALSCREEN/SM_CYVIRTUALSCREEN is zero or smaller than primary
 *   74  MonitorFromWindow(NULL, MONITOR_DEFAULTTOPRIMARY) returned NULL
 *   75  GetMonitorInfoW failed on that handle
 *   76  rcMonitor is empty, or disagrees with SM_C{X,Y}SCREEN
 *   77  rcWork is empty, or is not inside rcMonitor
 *   78  SPI_GETWORKAREA failed, is empty, or disagrees with rcWork
 *   79  EnumDisplayMonitors reported no monitor, or an empty one
 *   80  GetWindowRect(GetDesktopWindow()) is empty or disagrees with the
 *       virtual screen
 *   81  the DS_CENTER dialog could not be created -- nothing was tested
 *   82  the DS_CENTER dialog landed outside the primary monitor
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

static void write_log(const char *msg, DWORD len)
{
    HANDLE h = GetStdHandle(STD_ERROR_HANDLE);
    DWORD written = 0;
    WriteFile(h, msg, len, &written, NULL);
}

#define WRITE_LINE(lit) write_log( (lit), (DWORD)(sizeof(lit) - 1) )

/* no CRT (no strlen, no printf), so the numbers are formatted by hand.
 * Signed, because every rectangle in this test can legitimately be negative
 * and the whole bug is a pair of negative coordinates. */
static DWORD format_int(char *buf, DWORD size, int value)
{
    unsigned int v = (value < 0) ? (unsigned int)(-value) : (unsigned int)value;
    DWORD i = size;

    if (!v) buf[--i] = '0';
    else while (v && i > 0)
    {
        buf[--i] = (char)('0' + (v % 10));
        v /= 10;
    }
    if (value < 0 && i > 0) buf[--i] = '-';
    return i;
}

static void write_int(int value)
{
    char buf[16];
    DWORD i = format_int(buf, sizeof(buf), value);
    write_log(buf + i, sizeof(buf) - i);
}

static void write_rect_line(const char *prefix, DWORD prefix_len, const RECT *r)
{
    write_log(prefix, prefix_len);
    WRITE_LINE("{");
    write_int((int)r->left);  WRITE_LINE(",");
    write_int((int)r->top);   WRITE_LINE(",");
    write_int((int)r->right); WRITE_LINE(",");
    write_int((int)r->bottom);
    WRITE_LINE("} (");
    write_int((int)(r->right - r->left)); WRITE_LINE("x");
    write_int((int)(r->bottom - r->top));
    WRITE_LINE(")\n");
}

#define WRITE_RECT(lit, r) write_rect_line( (lit), (DWORD)(sizeof(lit) - 1), (r) )

static void write_size_line(const char *prefix, DWORD prefix_len, int w, int h)
{
    write_log(prefix, prefix_len);
    write_int(w);
    WRITE_LINE("x");
    write_int(h);
    WRITE_LINE("\n");
}

#define WRITE_SIZE(lit, w, h) write_size_line( (lit), (DWORD)(sizeof(lit) - 1), (int)(w), (int)(h) )

static BOOL rect_empty(const RECT *r)
{
    return r->right <= r->left || r->bottom <= r->top;
}

static void fail(int status)
{
    WRITE_LINE("MADEIRA-MONITOR: FAILED status=");
    write_int(status);
    WRITE_LINE("\n");
    ExitProcess((UINT)status);
}

/* --- 6: EnumDisplayMonitors ------------------------------------------- */

static int g_enum_count;
static int g_enum_empty;
static RECT g_enum_first;

static BOOL CALLBACK monitor_enum_proc(HMONITOR mon, HDC hdc, LPRECT rect, LPARAM lparam)
{
    MONITORINFO mi;

    (void)hdc;
    (void)lparam;

    if (!g_enum_count) g_enum_first = *rect;
    if (rect_empty(rect)) g_enum_empty++;

    WRITE_LINE("MADEIRA-MONITOR: EnumDisplayMonitors #");
    write_int(g_enum_count);
    WRITE_RECT(" rect=", rect);

    mi.cbSize = sizeof(mi);
    if (GetMonitorInfoW(mon, &mi))
    {
        WRITE_RECT("MADEIRA-MONITOR:   rcMonitor=", &mi.rcMonitor);
        WRITE_RECT("MADEIRA-MONITOR:   rcWork   =", &mi.rcWork);
    }
    else WRITE_LINE("MADEIRA-MONITOR:   GetMonitorInfoW FAILED\n");

    g_enum_count++;
    return TRUE;
}

/* --- 8: the DS_CENTER dialog ------------------------------------------ */

static INT_PTR CALLBACK dlg_proc(HWND hwnd, UINT msg, WPARAM wparam, LPARAM lparam)
{
    (void)hwnd;
    (void)wparam;
    (void)lparam;
    if (msg == WM_INITDIALOG) return FALSE;   /* do not move focus */
    return FALSE;
}

/* A DLGTEMPLATE built by hand: no resources, because a -nostdlib test has no
 * resource section and the template is the whole point -- DS_CENTER is the
 * one style bit under test. DWORD-aligned by construction (the header is 18
 * bytes, then three aligned WORD arrays). */
static HWND create_centered_dialog(HINSTANCE instance)
{
    static WORD tmpl[64];
    DLGTEMPLATE *dt = (DLGTEMPLATE *)tmpl;
    WORD *p;

    memset(tmpl, 0, sizeof(tmpl));
    dt->style = WS_POPUP | WS_CAPTION | WS_SYSMENU | DS_MODALFRAME | DS_CENTER;
    dt->dwExtendedStyle = 0;
    dt->cdit = 0;
    dt->x = 0;
    dt->y = 0;
    dt->cx = 160;
    dt->cy = 40;

    p = (WORD *)(dt + 1);
    *p++ = 0;        /* menu:  none */
    *p++ = 0;        /* class: none (standard dialog class) */
    /* title */
    *p++ = 'M'; *p++ = 'o'; *p++ = 'n'; *p++ = 0;

    return CreateDialogIndirectParamW(instance, dt, NULL, dlg_proc, 0);
}

void start(void)
{
    HINSTANCE instance = GetModuleHandleW(NULL);
    RECT mon_rc, work_rc, spi_rc, desk_rc, dlg_rc, virt_rc;
    int cx, cy, vx, vy, vleft, vtop;
    MONITORINFO mi;
    HMONITOR hmon;
    DEVMODEW dm;
    HWND dlg;
    DWORD i;

    WRITE_LINE("MADEIRA-MONITOR: start\n");

    /* --- 1: SM_CXSCREEN ------------------------------------------------ */

    cx = GetSystemMetrics(SM_CXSCREEN);
    cy = GetSystemMetrics(SM_CYSCREEN);
    WRITE_SIZE("MADEIRA-MONITOR: SM_C{X,Y}SCREEN ", cx, cy);
    if (cx <= 0 || cy <= 0) fail(72);

    /* --- 2: SM_CXVIRTUALSCREEN ----------------------------------------- */

    vx = GetSystemMetrics(SM_CXVIRTUALSCREEN);
    vy = GetSystemMetrics(SM_CYVIRTUALSCREEN);
    vleft = GetSystemMetrics(SM_XVIRTUALSCREEN);
    vtop = GetSystemMetrics(SM_YVIRTUALSCREEN);
    WRITE_SIZE("MADEIRA-MONITOR: SM_C{X,Y}VIRTUALSCREEN ", vx, vy);
    WRITE_SIZE("MADEIRA-MONITOR: SM_{X,Y}VIRTUALSCREEN ", vleft, vtop);
    if (vx <= 0 || vy <= 0 || vx < cx || vy < cy) fail(73);
    virt_rc.left = vleft;
    virt_rc.top = vtop;
    virt_rc.right = vleft + vx;
    virt_rc.bottom = vtop + vy;

    /* --- 3: MonitorFromWindow(NULL) + GetMonitorInfoW ------------------- */

    /* NULL, deliberately: this is what user32's DS_CENTER path passes when
     * the dialog has no owner and there is no active window. */
    hmon = MonitorFromWindow(NULL, MONITOR_DEFAULTTOPRIMARY);
    if (!hmon)
    {
        WRITE_LINE("MADEIRA-MONITOR: MonitorFromWindow(NULL, DEFAULTTOPRIMARY) = NULL\n");
        fail(74);
    }

    mi.cbSize = sizeof(mi);
    if (!GetMonitorInfoW(hmon, (MONITORINFO *)&mi))
    {
        WRITE_LINE("MADEIRA-MONITOR: GetMonitorInfoW FAILED\n");
        fail(75);
    }
    mon_rc = mi.rcMonitor;
    work_rc = mi.rcWork;
    WRITE_RECT("MADEIRA-MONITOR: rcMonitor ", &mon_rc);
    WRITE_RECT("MADEIRA-MONITOR: rcWork    ", &work_rc);

    /* --- 4: rcMonitor / rcWork ----------------------------------------- */

    if (rect_empty(&mon_rc)) fail(76);
    if (mon_rc.right - mon_rc.left != cx || mon_rc.bottom - mon_rc.top != cy) fail(76);
    if (rect_empty(&work_rc)) fail(77);
    if (work_rc.left < mon_rc.left || work_rc.top < mon_rc.top ||
        work_rc.right > mon_rc.right || work_rc.bottom > mon_rc.bottom) fail(77);

    /* --- 5: SPI_GETWORKAREA (the cached one) --------------------------- */

    memset(&spi_rc, 0, sizeof(spi_rc));
    if (!SystemParametersInfoW(SPI_GETWORKAREA, 0, &spi_rc, 0))
    {
        WRITE_LINE("MADEIRA-MONITOR: SPI_GETWORKAREA FAILED\n");
        fail(78);
    }
    WRITE_RECT("MADEIRA-MONITOR: SPI_GETWORKAREA ", &spi_rc);
    if (rect_empty(&spi_rc)) fail(78);
    if (spi_rc.left != work_rc.left || spi_rc.top != work_rc.top ||
        spi_rc.right != work_rc.right || spi_rc.bottom != work_rc.bottom) fail(78);

    /* --- 6: EnumDisplayMonitors ---------------------------------------- */

    EnumDisplayMonitors(NULL, NULL, monitor_enum_proc, 0);
    if (!g_enum_count || g_enum_empty) fail(79);

    /* --- 7: the desktop window ----------------------------------------- */

    memset(&desk_rc, 0, sizeof(desk_rc));
    GetWindowRect(GetDesktopWindow(), &desk_rc);
    WRITE_RECT("MADEIRA-MONITOR: GetWindowRect(GetDesktopWindow()) ", &desk_rc);
    if (rect_empty(&desk_rc)) fail(80);
    if (desk_rc.right - desk_rc.left != virt_rc.right - virt_rc.left ||
        desk_rc.bottom - desk_rc.top != virt_rc.bottom - virt_rc.top) fail(80);

    /* --- the mode list, for the log ------------------------------------ */

    memset(&dm, 0, sizeof(dm));
    dm.dmSize = sizeof(dm);
    if (EnumDisplaySettingsW(NULL, ENUM_CURRENT_SETTINGS, &dm))
        WRITE_SIZE("MADEIRA-MONITOR: ENUM_CURRENT_SETTINGS ", dm.dmPelsWidth, dm.dmPelsHeight);

    for (i = 0; i < 256; i++)
    {
        memset(&dm, 0, sizeof(dm));
        dm.dmSize = sizeof(dm);
        if (!EnumDisplaySettingsW(NULL, i, &dm)) break;
        WRITE_LINE("MADEIRA-MONITOR: mode #");
        write_int((int)i);
        WRITE_LINE(" ");
        write_int((int)dm.dmPelsWidth);
        WRITE_LINE("x");
        write_int((int)dm.dmPelsHeight);
        WRITE_LINE(" ");
        write_int((int)dm.dmBitsPerPel);
        WRITE_LINE("bpp ");
        write_int((int)dm.dmDisplayFrequency);
        WRITE_LINE("Hz\n");
    }
    WRITE_LINE("MADEIRA-MONITOR: mode count ");
    write_int((int)i);
    WRITE_LINE("\n");

    /* --- 8: the DS_CENTER dialog --------------------------------------- */

    dlg = create_centered_dialog(instance);
    if (!dlg)
    {
        WRITE_LINE("MADEIRA-MONITOR: CreateDialogIndirectParamW FAILED err=");
        write_int((int)GetLastError());
        WRITE_LINE("\n");
        fail(81);
    }

    memset(&dlg_rc, 0, sizeof(dlg_rc));
    GetWindowRect(dlg, &dlg_rc);
    WRITE_RECT("MADEIRA-MONITOR: DS_CENTER dialog ", &dlg_rc);
    DestroyWindow(dlg);

    /* Inside the primary monitor: the failure this test was written for puts
     * it at ((0 - cx)/2, (0 - cy)/2), which is outside on both axes. */
    if (dlg_rc.left < mon_rc.left || dlg_rc.top < mon_rc.top ||
        dlg_rc.right > mon_rc.right || dlg_rc.bottom > mon_rc.bottom) fail(82);

    WRITE_LINE("MADEIRA-MONITOR: all checks passed\n");
    ExitProcess(71);
}
