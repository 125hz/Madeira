/* MADEIRA-TEMP: the self-test for DirectDraw on a host with NO 3D backend.
 *
 * WHY THIS TEST EXISTS
 * --------------------
 * There is no OpenGL and no Vulkan on this port, so wined3d's GL adapter
 * cannot be created at all: wined3d_caps_gl_ctx_create fails with "Failed to
 * find a suitable pixel format" and wined3d_create used to return NULL to
 * everyone. ddraw has always retried with WINED3D_NO3D, and wined3d now falls
 * back to the no3d adapter itself (wine/dlls/wined3d/directx.c wined3d_init),
 * so DirectDraw is expected to work here as a 2D interface -- which is all a
 * 2D DirectDraw application ever wanted.
 *
 * "Expected to work" was the whole problem: a device log showed ddraw7_Initialize
 * being reached and nothing after it, which is equally consistent with a
 * healthy 2D DirectDraw and with a DirectDraw that answers every capability
 * query with zeroes. This test settles that, and in particular settles the
 * three answers a period title acts on:
 *
 *  - GetDeviceIdentifier has to name a GPU. Under no3d the identity comes from
 *    the adapter's driver_info, which upstream fills with vendor 0 / device 0
 *    and "WineD3D DirectDraw Emulation". A vendor id of 0 is what a title's
 *    GPU table reads as "no adapter", and worse, it disagreed with what D3D9
 *    reports for the same machine. Both now report the same pair, and this
 *    test asserts it is non-zero and prints it so a D3D9 run and a ddraw run
 *    can be compared line for line.
 *  - EnumDisplayModes has to produce a real mode list. It runs entirely
 *    through wined3d_output_get_mode, which has no 3D dependency, so a short
 *    or empty list means the virtual monitor underneath is wrong rather than
 *    the no3d path.
 *  - A flipping primary chain has to be buildable. That is FRONTBUFFER,
 *    BACKBUFFER and COMPLEX in DDCAPS, which upstream's empty
 *    adapter_no3d_get_wined3d_caps left unset, so a title checked DDCAPS and
 *    took a windowed-blit fallback on a host where the chain works.
 *
 * WHAT IT CHECKS
 * --------------
 *  1. DirectDrawCreateEx(IID_IDirectDraw7) succeeds with a NULL GUID, and
 *     SetCooperativeLevel(NULL window, NORMAL) succeeds. No window is created:
 *     a title probes all of this before it opens one, and the NORMAL
 *     cooperative level is exactly the windowless case.
 *  2. GetDeviceIdentifier: non-zero vendor and device id, and a non-empty
 *     driver name and description. Printed either way.
 *  3. EnumDisplayModes returns at least 6 modes, each non-degenerate, and
 *     the list contains 640x480. Printed.
 *  4. GetCaps: the DDCAPS the 2D path needs -- BLT, and the surface caps for a
 *     flipping primary (PRIMARYSURFACE, FLIP, COMPLEX, FRONTBUFFER,
 *     BACKBUFFER, OFFSCREENPLAIN). The 3D bits are printed and NOT required:
 *     their absence is the correct answer here and is what makes ddraw set
 *     its own DDRAW_NO3D.
 *  5. EXCLUSIVE | FULLSCREEN cooperative level, SetDisplayMode(640, 480, 16),
 *     a flipping primary with one back buffer, a Blt colour fill into the back
 *     buffer, a Flip, and a Lock/Unlock roundtrip on the primary to prove the
 *     surface memory is real. Then RestoreDisplayMode and back to NORMAL.
 *     This needs a window (EXCLUSIVE requires one), so one is created here and
 *     only here.
 *
 * Deliberate restrictions, the same ones the other tests in this directory
 * work under: no CRT (this file supplies `start' and is linked -nostdlib, so
 * its only imports are kernel32, user32 and ddraw), no 64-bit division, no
 * int-to-double conversion. COM is reached through the C vtable macros, so no
 * ole32 import either -- DirectDrawCreateEx is a plain export.
 *
 * Exit status (the runtime reports it as "MADEIRA-EXIT: ... status=<n>"):
 *   57  every check passed
 *   80  DirectDrawCreateEx failed
 *   81  SetCooperativeLevel(NORMAL) failed
 *   82  GetDeviceIdentifier failed, or returned a zero vendor/device id or an
 *       empty driver/description string
 *   83  EnumDisplayModes failed, or produced fewer than 6 usable modes
 *   84  640x480 is missing from the mode list
 *   85  GetCaps failed, or a 2D capability a DirectDraw title needs is absent
 *   86  RegisterClass/CreateWindowEx failed -- the fullscreen half was not run
 *   87  SetCooperativeLevel(EXCLUSIVE|FULLSCREEN) failed
 *   88  SetDisplayMode(640, 480, 16) failed
 *   89  CreateSurface for the flipping primary failed
 *   90  GetAttachedSurface for the back buffer failed
 *   91  Blt colour fill failed
 *   92  Flip failed
 *   93  Lock/Unlock on the primary failed
 *   94  RestoreDisplayMode failed
 */
#include <stddef.h>
#include <windows.h>

#define COBJMACROS
#define CINTERFACE
#include <ddraw.h>

/* -nostdlib: clang may still lower a struct initialisation to a memset or
 * memcpy call, so provide them rather than hoping it does not. */
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

/* ---------------------------------------------------------------- logging */

static void out_str( const char *s )
{
    DWORD written = 0;
    const char *e = s;
    while (*e) e++;
    WriteFile( GetStdHandle( STD_ERROR_HANDLE ), s, (DWORD)(e - s), &written, NULL );
}

static char *put_str( char *p, const char *s )
{
    while (*s) *p++ = *s++;
    return p;
}

static char *put_uint( char *p, unsigned int v )
{
    char tmp[16];
    int n = 0;
    if (!v) { *p++ = '0'; return p; }
    while (v) { tmp[n++] = (char)('0' + v % 10); v /= 10; }
    while (n--) *p++ = tmp[n];
    return p;
}

static char *put_hex( char *p, unsigned int v )
{
    static const char digits[] = "0123456789abcdef";
    int i;
    *p++ = '0'; *p++ = 'x';
    for (i = 28; i >= 0; i -= 4) *p++ = digits[(v >> i) & 0xf];
    return p;
}

#define TAG "MADEIRA-DDRAW: "

static void log_line( const char *s )
{
    char buf[256], *p = buf;
    p = put_str( p, TAG );
    p = put_str( p, s );
    *p++ = '\n';
    *p = 0;
    out_str( buf );
}

static void log_val( const char *label, unsigned int v )
{
    char buf[256], *p = buf;
    p = put_str( p, TAG );
    p = put_str( p, label );
    *p++ = '=';
    p = put_uint( p, v );
    *p++ = '\n';
    *p = 0;
    out_str( buf );
}

static void log_valx( const char *label, unsigned int v )
{
    char buf[256], *p = buf;
    p = put_str( p, TAG );
    p = put_str( p, label );
    *p++ = '=';
    p = put_hex( p, v );
    *p++ = '\n';
    *p = 0;
    out_str( buf );
}

static void log_hr( const char *label, HRESULT hr )
{
    char buf[256], *p = buf;
    p = put_str( p, TAG );
    p = put_str( p, label );
    p = put_str( p, " hr=" );
    p = put_hex( p, (unsigned int)hr );
    *p++ = '\n';
    *p = 0;
    out_str( buf );
}

static void log_bit( const char *label, DWORD have, DWORD bit, int required, int *failed )
{
    char buf[256], *p = buf;
    int ok = (have & bit) != 0;
    p = put_str( p, TAG );
    p = put_str( p, required ? (ok ? "[ok  ] " : "[FAIL] ") : (ok ? "[info] present " : "[info] absent  ") );
    p = put_str( p, label );
    *p++ = '\n';
    *p = 0;
    out_str( buf );
    if (required && !ok) *failed = 1;
}

/* ------------------------------------------------------- mode enumeration */

struct mode_scan
{
    unsigned int count;
    unsigned int bad;
    unsigned int have_640x480;
    unsigned int printed;
};

static HRESULT WINAPI enum_modes_cb( DDSURFACEDESC2 *desc, void *ctx )
{
    struct mode_scan *scan = ctx;

    if (!desc || !(desc->dwFlags & DDSD_WIDTH) || !(desc->dwFlags & DDSD_HEIGHT) ||
        !desc->dwWidth || !desc->dwHeight)
    {
        scan->bad++;
        return DDENUMRET_OK;
    }

    scan->count++;
    if (desc->dwWidth == 640 && desc->dwHeight == 480) scan->have_640x480 = 1;

    /* The first eight are enough to tell a real table from a stub, and short
     * enough not to flood a log that is already large. */
    if (scan->printed < 8)
    {
        char buf[160], *p = buf;
        scan->printed++;
        p = put_str( p, TAG "mode " );
        p = put_uint( p, desc->dwWidth );
        *p++ = 'x';
        p = put_uint( p, desc->dwHeight );
        p = put_str( p, " bpp=" );
        p = put_uint( p, (desc->dwFlags & DDSD_PIXELFORMAT) ? desc->ddpfPixelFormat.dwRGBBitCount : 0 );
        p = put_str( p, " hz=" );
        p = put_uint( p, (desc->dwFlags & DDSD_REFRESHRATE) ? desc->dwRefreshRate : 0 );
        *p++ = '\n';
        *p = 0;
        out_str( buf );
    }
    return DDENUMRET_OK;
}

/* ------------------------------------------------------------------ window */

static LRESULT CALLBACK wnd_proc( HWND hwnd, UINT msg, WPARAM wp, LPARAM lp )
{
    if (msg == WM_CLOSE) return 0;   /* the test owns its own lifetime */
    return DefWindowProcA( hwnd, msg, wp, lp );
}

/* --------------------------------------------------------------- the test */

void start( void )
{
    IDirectDraw7 *dd = NULL;
    IDirectDrawSurface7 *primary = NULL, *back = NULL;
    DDDEVICEIDENTIFIER2 ident;
    DDCAPS hal, hel;
    DDSURFACEDESC2 desc;
    DDSCAPS2 scaps;
    DDBLTFX fx;
    struct mode_scan scan;
    WNDCLASSEXA wc;
    HWND hwnd;
    HINSTANCE inst = GetModuleHandleA( NULL );
    HRESULT hr;
    int caps_failed = 0;

    log_line( "start" );

    /* --- 1: the interface ------------------------------------------------- */

    hr = DirectDrawCreateEx( NULL, (void **)&dd, &IID_IDirectDraw7, NULL );
    if (FAILED(hr) || !dd)
    {
        log_hr( "DirectDrawCreateEx", hr );
        ExitProcess( 80 );
    }
    log_line( "[ok  ] DirectDrawCreateEx(IID_IDirectDraw7)" );

    hr = IDirectDraw7_SetCooperativeLevel( dd, NULL, DDSCL_NORMAL );
    if (FAILED(hr))
    {
        log_hr( "SetCooperativeLevel(NORMAL)", hr );
        ExitProcess( 81 );
    }
    log_line( "[ok  ] SetCooperativeLevel(NULL, NORMAL)" );

    /* --- 2: the adapter's identity ---------------------------------------- */

    memset( &ident, 0, sizeof(ident) );
    hr = IDirectDraw7_GetDeviceIdentifier( dd, &ident, 0 );
    if (FAILED(hr))
    {
        log_hr( "GetDeviceIdentifier", hr );
        ExitProcess( 82 );
    }
    log_valx( "dwVendorId", (unsigned int)ident.dwVendorId );
    log_valx( "dwDeviceId", (unsigned int)ident.dwDeviceId );
    log_valx( "dwSubSysId", (unsigned int)ident.dwSubSysId );
    log_valx( "dwRevision", (unsigned int)ident.dwRevision );
    {
        char buf[512], *p = buf;
        p = put_str( p, TAG "szDriver=\"" );
        p = put_str( p, ident.szDriver );
        p = put_str( p, "\" szDescription=\"" );
        p = put_str( p, ident.szDescription );
        p = put_str( p, "\"\n" );
        *p = 0;
        out_str( buf );
    }
    /* This must match what d3d9caps-x86.exe prints for VendorId / DeviceId.
     * A title that asks both interfaces and compares them is the reason the
     * two were made to agree. */
    if (!ident.dwVendorId || !ident.dwDeviceId || !ident.szDriver[0] || !ident.szDescription[0])
    {
        log_line( "[FAIL] device identifier has a zero id or an empty string" );
        ExitProcess( 82 );
    }
    log_line( "[ok  ] device identifier is non-degenerate" );

    /* --- 3: the mode list --------------------------------------------------- */

    memset( &scan, 0, sizeof(scan) );
    hr = IDirectDraw7_EnumDisplayModes( dd, 0, NULL, &scan, enum_modes_cb );
    if (FAILED(hr))
    {
        log_hr( "EnumDisplayModes", hr );
        ExitProcess( 83 );
    }
    log_val( "modes", scan.count );
    log_val( "degenerate modes", scan.bad );
    if (scan.count < 6 || scan.bad)
    {
        log_line( "[FAIL] fewer than 6 usable modes, or a degenerate entry" );
        ExitProcess( 83 );
    }
    log_line( "[ok  ] mode list" );
    if (!scan.have_640x480)
    {
        log_line( "[FAIL] 640x480 is not in the mode list" );
        ExitProcess( 84 );
    }
    log_line( "[ok  ] 640x480 present" );

    /* --- 4: DDCAPS ---------------------------------------------------------- */

    memset( &hal, 0, sizeof(hal) );
    memset( &hel, 0, sizeof(hel) );
    hal.dwSize = sizeof(hal);
    hel.dwSize = sizeof(hel);
    hr = IDirectDraw7_GetCaps( dd, &hal, &hel );
    if (FAILED(hr))
    {
        log_hr( "GetCaps", hr );
        ExitProcess( 85 );
    }
    log_valx( "hal.dwCaps", (unsigned int)hal.dwCaps );
    log_valx( "hal.dwCaps2", (unsigned int)hal.dwCaps2 );
    log_valx( "hal.ddsCaps.dwCaps", (unsigned int)hal.ddsCaps.dwCaps );
    log_valx( "hal.dwSVBCaps", (unsigned int)hal.dwSVBCaps );
    log_valx( "hal.dwCKeyCaps", (unsigned int)hal.dwCKeyCaps );
    log_valx( "hal.dwFXCaps", (unsigned int)hal.dwFXCaps );
    log_valx( "hal.dwVidMemTotal", (unsigned int)hal.dwVidMemTotal );

    log_bit( "DDCAPS_BLT", hal.dwCaps, DDCAPS_BLT, 1, &caps_failed );
    log_bit( "DDCAPS_BLTCOLORFILL", hal.dwCaps, DDCAPS_BLTCOLORFILL, 1, &caps_failed );
    log_bit( "DDSCAPS_PRIMARYSURFACE", hal.ddsCaps.dwCaps, DDSCAPS_PRIMARYSURFACE, 1, &caps_failed );
    log_bit( "DDSCAPS_OFFSCREENPLAIN", hal.ddsCaps.dwCaps, DDSCAPS_OFFSCREENPLAIN, 1, &caps_failed );
    log_bit( "DDSCAPS_FLIP", hal.ddsCaps.dwCaps, DDSCAPS_FLIP, 1, &caps_failed );
    log_bit( "DDSCAPS_COMPLEX", hal.ddsCaps.dwCaps, DDSCAPS_COMPLEX, 1, &caps_failed );
    log_bit( "DDSCAPS_FRONTBUFFER", hal.ddsCaps.dwCaps, DDSCAPS_FRONTBUFFER, 1, &caps_failed );
    log_bit( "DDSCAPS_BACKBUFFER", hal.ddsCaps.dwCaps, DDSCAPS_BACKBUFFER, 1, &caps_failed );
    log_bit( "DDSCAPS_VIDEOMEMORY", hal.ddsCaps.dwCaps, DDSCAPS_VIDEOMEMORY, 1, &caps_failed );
    /* The 3D bits: absent is the CORRECT answer on this port, and is what
     * makes ddraw set DDRAW_NO3D. Printed so a run where a 3D backend did
     * come up is distinguishable from one where it did not. */
    log_bit( "DDCAPS_3D (expected absent here)", hal.dwCaps, DDCAPS_3D, 0, &caps_failed );
    log_bit( "DDSCAPS_3DDEVICE (expected absent here)", hal.ddsCaps.dwCaps, DDSCAPS_3DDEVICE, 0, &caps_failed );
    log_bit( "DDSCAPS_ZBUFFER", hal.ddsCaps.dwCaps, DDSCAPS_ZBUFFER, 0, &caps_failed );

    if (caps_failed)
    {
        log_line( "[FAIL] a 2D capability a DirectDraw title needs is absent" );
        ExitProcess( 85 );
    }
    log_line( "[ok  ] DDCAPS 2D set" );

    /* --- 5: the fullscreen surface roundtrip -------------------------------- */

    memset( &wc, 0, sizeof(wc) );
    wc.cbSize        = sizeof(wc);
    wc.lpfnWndProc   = wnd_proc;
    wc.hInstance     = inst;
    wc.lpszClassName = "MadeiraDDrawTest";
    if (!RegisterClassExA( &wc ))
    {
        log_val( "RegisterClassExA failed, err", GetLastError() );
        ExitProcess( 86 );
    }
    hwnd = CreateWindowExA( 0, wc.lpszClassName, "Madeira DirectDraw (32-bit)",
                            WS_OVERLAPPEDWINDOW | WS_VISIBLE, 0, 0, 640, 480,
                            NULL, NULL, inst, NULL );
    if (!hwnd)
    {
        log_val( "CreateWindowExA failed, err", GetLastError() );
        ExitProcess( 86 );
    }

    hr = IDirectDraw7_SetCooperativeLevel( dd, hwnd, DDSCL_EXCLUSIVE | DDSCL_FULLSCREEN );
    if (FAILED(hr))
    {
        log_hr( "SetCooperativeLevel(EXCLUSIVE|FULLSCREEN)", hr );
        ExitProcess( 87 );
    }
    log_line( "[ok  ] SetCooperativeLevel(EXCLUSIVE|FULLSCREEN)" );

    /* 640x480x16 is the mode every 2D DirectDraw title of the era opens with.
     * The virtual monitor ignores dmBitsPerPel, so this also proves a 16-bit
     * request is not refused on a display that only has one real depth. */
    hr = IDirectDraw7_SetDisplayMode( dd, 640, 480, 16, 0, 0 );
    if (FAILED(hr))
    {
        log_hr( "SetDisplayMode(640,480,16)", hr );
        ExitProcess( 88 );
    }
    log_line( "[ok  ] SetDisplayMode(640, 480, 16)" );

    memset( &desc, 0, sizeof(desc) );
    desc.dwSize            = sizeof(desc);
    desc.dwFlags           = DDSD_CAPS | DDSD_BACKBUFFERCOUNT;
    desc.ddsCaps.dwCaps    = DDSCAPS_PRIMARYSURFACE | DDSCAPS_FLIP | DDSCAPS_COMPLEX;
    desc.dwBackBufferCount = 1;
    hr = IDirectDraw7_CreateSurface( dd, &desc, &primary, NULL );
    if (FAILED(hr) || !primary)
    {
        log_hr( "CreateSurface(flipping primary)", hr );
        ExitProcess( 89 );
    }
    log_line( "[ok  ] flipping primary with 1 back buffer" );

    memset( &scaps, 0, sizeof(scaps) );
    scaps.dwCaps = DDSCAPS_BACKBUFFER;
    hr = IDirectDrawSurface7_GetAttachedSurface( primary, &scaps, &back );
    if (FAILED(hr) || !back)
    {
        log_hr( "GetAttachedSurface(BACKBUFFER)", hr );
        ExitProcess( 90 );
    }
    log_line( "[ok  ] GetAttachedSurface(BACKBUFFER)" );

    memset( &fx, 0, sizeof(fx) );
    fx.dwSize      = sizeof(fx);
    fx.dwFillColor = 0x1f;     /* blue in 5-6-5, blue-ish in 8-8-8 */
    hr = IDirectDrawSurface7_Blt( back, NULL, NULL, NULL, DDBLT_COLORFILL | DDBLT_WAIT, &fx );
    if (FAILED(hr))
    {
        log_hr( "Blt(COLORFILL)", hr );
        ExitProcess( 91 );
    }
    log_line( "[ok  ] Blt colour fill into the back buffer" );

    hr = IDirectDrawSurface7_Flip( primary, NULL, DDFLIP_WAIT );
    if (FAILED(hr))
    {
        log_hr( "Flip", hr );
        ExitProcess( 92 );
    }
    log_line( "[ok  ] Flip" );

    /* Lock/Unlock proves the surface memory is real rather than a handle to
     * nothing: a no3d surface is a system-memory allocation, and a title that
     * draws by hand writes straight into it. */
    memset( &desc, 0, sizeof(desc) );
    desc.dwSize = sizeof(desc);
    hr = IDirectDrawSurface7_Lock( primary, NULL, &desc, DDLOCK_WAIT | DDLOCK_SURFACEMEMORYPTR, NULL );
    if (FAILED(hr) || !desc.lpSurface)
    {
        log_hr( "Lock(primary)", hr );
        ExitProcess( 93 );
    }
    log_val( "primary lock pitch", (unsigned int)desc.lPitch );
    log_val( "primary lock width", desc.dwWidth );
    log_val( "primary lock height", desc.dwHeight );
    hr = IDirectDrawSurface7_Unlock( primary, NULL );
    if (FAILED(hr))
    {
        log_hr( "Unlock(primary)", hr );
        ExitProcess( 93 );
    }
    log_line( "[ok  ] Lock/Unlock roundtrip on the primary" );

    /* --- leave the screen the way it was ------------------------------------ */

    IDirectDrawSurface7_Release( back );
    IDirectDrawSurface7_Release( primary );

    hr = IDirectDraw7_RestoreDisplayMode( dd );
    if (FAILED(hr))
    {
        log_hr( "RestoreDisplayMode", hr );
        ExitProcess( 94 );
    }
    IDirectDraw7_SetCooperativeLevel( dd, hwnd, DDSCL_NORMAL );
    IDirectDraw7_Release( dd );
    DestroyWindow( hwnd );

    log_line( "PASS" );
    ExitProcess( 57 );
}
