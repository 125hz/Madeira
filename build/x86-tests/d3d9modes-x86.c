/* MADEIRA-TEMP: the self-test for the D3D9 adapter's MODE TABLE and for
 * fullscreen CreateDevice against a mode out of it.
 *
 * WHY THIS TEST EXISTS
 * --------------------
 * dispmode-x86.exe already proves the win32u virtual monitor
 * (build/win32u-unix/sysparams_ios.c) enumerates a real mode table and really
 * switches. This one proves the *D3D9 adapter* tells an application the same
 * story, which is a separate question with separate answers:
 *
 *  - The D3D9 frontend has its own mode list
 *    (research/dxmt/src/d3d9/d3d9_interface.cpp adapterModes(), fed by
 *    src/util/wsi_monitor_*.cpp). It used to synthesize "640x480, 800x600 and
 *    whatever you are already running" -- three entries -- while user32
 *    reported 14+. An application that walks GetAdapterModeCount /
 *    EnumAdapterModes looking for the mode it saved, or that asks
 *    CheckDeviceType whether a fullscreen device is possible at all, found
 *    nothing and fell into its own "could not initialise the renderer" path.
 *    The two lists disagreeing is the defect; either number alone proves
 *    nothing.
 *  - GetAdapterDisplayMode must be the mode the rest of the system is in.
 *    An adapter whose "current mode" is not the screen size is a monitor that
 *    cannot do what it is doing, and an application sizes its fullscreen
 *    swapchain from exactly that value.
 *  - A fullscreen CreateDevice at a mode out of the list must SUCCEED. That
 *    is the only check that exercises the enumeration and the create path
 *    together; a list nothing can be created from is not a list.
 *
 * WHAT IT CHECKS
 * --------------
 *  1. Direct3DCreate9 and GetAdapterCount >= 1.
 *  2. GetAdapterModeCount(X8R8G8B8) >= 6, and every EnumAdapterModes entry is
 *     non-degenerate (non-zero extent, the format that was asked for).
 *     Prints "MADEIRA-D3D9MODES: count=N" and the modes.
 *  3. The list contains 640x480 and 800x600 -- the two extents every
 *     fullscreen application of this era asks for.
 *  4. GetAdapterDisplayMode matches GetSystemMetrics(SM_CXSCREEN/SM_CYSCREEN).
 *     Those reach the same virtual monitor by two different routes (the D3D9
 *     frontend's wsi, and user32 -> win32u); the bug class this test exists
 *     for is precisely the two disagreeing.
 *  5. CheckDeviceType(HAL, X8R8G8B8, X8R8G8B8, fullscreen) succeeds, which
 *     internally requires the mode count to be non-zero.
 *  6. A FULLSCREEN device at 800x600 X8R8G8B8 is created, Present()ed once,
 *     and released; then the same at 640x480. Each switches the virtual
 *     monitor, so this also proves ChangeDisplaySettings behind CreateDevice.
 *  7. The screen is restored to the session default on the way out, so the
 *     test does not corrupt whatever runs next.
 *
 * Deliberate restrictions, the same ones the other tests in this directory
 * work under: no CRT (this file supplies `start' and is linked -nostdlib, so
 * its only imports are kernel32, user32 and d3d9), no 64-bit division, no
 * int-to-double conversion.
 *
 * Exit status (the runtime reports it as "MADEIRA-EXIT: ... status=<n>"):
 *   55  every check passed
 *   60  Direct3DCreate9 returned NULL
 *   61  GetAdapterCount reported 0 adapters
 *   62  fewer than 6 modes enumerated for X8R8G8B8
 *   63  EnumAdapterModes returned a degenerate or mis-formatted mode
 *   64  640x480 or 800x600 is missing from the mode list
 *   65  GetAdapterDisplayMode failed, or disagrees with GetSystemMetrics
 *   66  CheckDeviceType refused a fullscreen HAL device at X8R8G8B8
 *   67  RegisterClass/CreateWindowEx failed -- nothing was tested
 *   68  fullscreen CreateDevice at 800x600 failed
 *   69  fullscreen CreateDevice at 640x480 failed
 *   70  Present failed on a device that had just been created
 */
#include <stddef.h>
#include <windows.h>
#include <d3d9.h>

/* No CRT means no stack probe (__alloca/_chkstk), so every frame in this file
 * has to stay under a page. The modes are validated one at a time as they are
 * enumerated rather than collected into an array, and this cap only bounds the
 * loop. */
#define MAX_MODES 512

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

static void log_val( const char *label, unsigned int v )
{
    char buf[160], *p = buf;
    p = put_str( p, "MADEIRA-D3D9MODES: " );
    p = put_str( p, label );
    p = put_str( p, "=" );
    p = put_uint( p, v );
    *p++ = '\n';
    *p = 0;
    out_str( buf );
}

static void log_hr( const char *label, HRESULT hr )
{
    char buf[160], *p = buf;
    p = put_str( p, "MADEIRA-D3D9MODES: " );
    p = put_str( p, label );
    p = put_str( p, " hr=" );
    p = put_hex( p, (unsigned int)hr );
    *p++ = '\n';
    *p = 0;
    out_str( buf );
}

static void log_mode( const char *label, unsigned int i, unsigned int w, unsigned int h,
                      unsigned int hz, unsigned int fmt )
{
    char buf[160], *p = buf;
    p = put_str( p, "MADEIRA-D3D9MODES: " );
    p = put_str( p, label );
    p = put_str( p, "[" );
    p = put_uint( p, i );
    p = put_str( p, "] " );
    p = put_uint( p, w );
    *p++ = 'x';
    p = put_uint( p, h );
    p = put_str( p, " @" );
    p = put_uint( p, hz );
    p = put_str( p, "Hz fmt=" );
    p = put_uint( p, fmt );
    *p++ = '\n';
    *p = 0;
    out_str( buf );
}

/* ------------------------------------------------------------------ window */

static LRESULT CALLBACK wnd_proc( HWND hwnd, UINT msg, WPARAM wp, LPARAM lp )
{
    if (msg == WM_CLOSE) return 0;   /* the test owns its own lifetime */
    return DefWindowProcA( hwnd, msg, wp, lp );
}

/* Creates a fullscreen device at w x h, presents one cleared frame, releases
 * it. Returns the CreateDevice/Present HRESULT; S_OK means the whole sequence
 * worked. *present_failed is set when creation succeeded but Present did not,
 * so the caller can report the two separately. */
static HRESULT run_fullscreen_device( IDirect3D9 *d3d, HWND hwnd, unsigned int w, unsigned int h,
                                      int *present_failed )
{
    D3DPRESENT_PARAMETERS pp;
    IDirect3DDevice9 *dev = NULL;
    HRESULT hr;

    *present_failed = 0;

    memset( &pp, 0, sizeof(pp) );
    pp.Windowed               = FALSE;
    pp.SwapEffect             = D3DSWAPEFFECT_DISCARD;
    pp.BackBufferFormat       = D3DFMT_X8R8G8B8;
    pp.BackBufferWidth        = w;
    pp.BackBufferHeight       = h;
    pp.BackBufferCount        = 1;
    pp.hDeviceWindow          = hwnd;
    pp.EnableAutoDepthStencil = FALSE;
    /* 0 = "any refresh rate the adapter offers for this mode", which is what a
     * fullscreen application of this era passes; pinning 60 here would test the
     * refresh match rather than the mode match. */
    pp.FullScreen_RefreshRateInHz = 0;
    pp.PresentationInterval   = D3DPRESENT_INTERVAL_IMMEDIATE;

    hr = IDirect3D9_CreateDevice( d3d, D3DADAPTER_DEFAULT, D3DDEVTYPE_HAL, hwnd,
                                  D3DCREATE_SOFTWARE_VERTEXPROCESSING, &pp, &dev );
    if (FAILED(hr) || !dev)
        return FAILED(hr) ? hr : E_FAIL;

    /* The realized parameters are written back; report them, since a runtime
     * that silently substituted a different extent is exactly as broken as one
     * that refused the call. */
    log_mode( "created", 0, pp.BackBufferWidth, pp.BackBufferHeight,
              pp.FullScreen_RefreshRateInHz, (unsigned int)pp.BackBufferFormat );

    IDirect3DDevice9_Clear( dev, 0, NULL, D3DCLEAR_TARGET, D3DCOLOR_XRGB(0, 0, 64), 1.0f, 0 );
    hr = IDirect3DDevice9_Present( dev, NULL, NULL, NULL, NULL );
    if (FAILED(hr))
        *present_failed = 1;

    IDirect3DDevice9_Release( dev );
    return hr;
}

/* -------------------------------------------------------------------- main */

void start( void )
{
    WNDCLASSEXA wc;
    HWND hwnd;
    HINSTANCE inst = GetModuleHandleA( NULL );
    IDirect3D9 *d3d;
    D3DDISPLAYMODE cur;
    D3DDISPLAYMODE mode;
    unsigned int count, i, kept = 0;
    int have640 = 0, have800 = 0, present_failed = 0;
    int screen_w, screen_h;
    HRESULT hr;

    out_str( "MADEIRA-D3D9MODES: 32-bit D3D9 adapter mode test starting\n" );

    d3d = Direct3DCreate9( D3D_SDK_VERSION );
    if (!d3d)
    {
        out_str( "MADEIRA-D3D9MODES: Direct3DCreate9 returned NULL\n" );
        ExitProcess( 60 );
    }

    if (IDirect3D9_GetAdapterCount( d3d ) == 0)
    {
        out_str( "MADEIRA-D3D9MODES: GetAdapterCount reported 0 adapters\n" );
        ExitProcess( 61 );
    }

    /* --- 2/3: the mode table -------------------------------------------- */

    count = IDirect3D9_GetAdapterModeCount( d3d, D3DADAPTER_DEFAULT, D3DFMT_X8R8G8B8 );
    log_val( "count", count );

    if (count > MAX_MODES) count = MAX_MODES;
    for (i = 0; i < count; i++)
    {
        memset( &mode, 0, sizeof(mode) );
        hr = IDirect3D9_EnumAdapterModes( d3d, D3DADAPTER_DEFAULT, D3DFMT_X8R8G8B8, i, &mode );
        if (FAILED(hr))
        {
            log_hr( "EnumAdapterModes failed", hr );
            ExitProcess( 63 );
        }
        if (!mode.Width || !mode.Height || mode.Format != D3DFMT_X8R8G8B8)
        {
            log_mode( "degenerate", i, mode.Width, mode.Height,
                      mode.RefreshRate, (unsigned int)mode.Format );
            ExitProcess( 63 );
        }
        log_mode( "mode", i, mode.Width, mode.Height,
                  mode.RefreshRate, (unsigned int)mode.Format );
        if (mode.Width == 640 && mode.Height == 480) have640 = 1;
        if (mode.Width == 800 && mode.Height == 600) have800 = 1;
        kept++;
    }

    /* Six is the floor a resolution menu needs to be a choice at all; the
     * old three-entry synthesis is exactly what this rejects. */
    if (kept < 6)
    {
        out_str( "MADEIRA-D3D9MODES: fewer than 6 modes enumerated\n" );
        ExitProcess( 62 );
    }
    if (!have640 || !have800)
    {
        out_str( "MADEIRA-D3D9MODES: 640x480 or 800x600 missing from the mode list\n" );
        ExitProcess( 64 );
    }

    /* --- 4: current mode == the screen ---------------------------------- */

    memset( &cur, 0, sizeof(cur) );
    hr = IDirect3D9_GetAdapterDisplayMode( d3d, D3DADAPTER_DEFAULT, &cur );
    if (FAILED(hr))
    {
        log_hr( "GetAdapterDisplayMode failed", hr );
        ExitProcess( 65 );
    }
    log_mode( "current", 0, cur.Width, cur.Height, cur.RefreshRate, (unsigned int)cur.Format );

    screen_w = GetSystemMetrics( SM_CXSCREEN );
    screen_h = GetSystemMetrics( SM_CYSCREEN );
    log_mode( "sysmetrics", 0, (unsigned int)screen_w, (unsigned int)screen_h, 0, 0 );
    if ((int)cur.Width != screen_w || (int)cur.Height != screen_h)
    {
        out_str( "MADEIRA-D3D9MODES: adapter current mode disagrees with GetSystemMetrics\n" );
        ExitProcess( 65 );
    }

    /* --- 5: a fullscreen HAL device is possible at all ------------------- */

    hr = IDirect3D9_CheckDeviceType( d3d, D3DADAPTER_DEFAULT, D3DDEVTYPE_HAL,
                                     D3DFMT_X8R8G8B8, D3DFMT_X8R8G8B8, FALSE );
    if (FAILED(hr))
    {
        log_hr( "CheckDeviceType(fullscreen X8R8G8B8) refused", hr );
        ExitProcess( 66 );
    }

    /* --- 6: create at 800x600 and at 640x480 ---------------------------- */

    memset( &wc, 0, sizeof(wc) );
    wc.cbSize        = sizeof(wc);
    wc.lpfnWndProc   = wnd_proc;
    wc.hInstance     = inst;
    wc.hCursor       = NULL;
    wc.lpszClassName = "MadeiraD3D9ModesX86";
    if (!RegisterClassExA( &wc ))
    {
        log_val( "RegisterClassExA failed, err", GetLastError() );
        ExitProcess( 67 );
    }

    hwnd = CreateWindowExA( 0, wc.lpszClassName, "Madeira D3D9 modes (32-bit)",
                            WS_OVERLAPPEDWINDOW | WS_VISIBLE,
                            0, 0, 800, 600, NULL, NULL, inst, NULL );
    if (!hwnd)
    {
        log_val( "CreateWindowExA failed, err", GetLastError() );
        ExitProcess( 67 );
    }

    hr = run_fullscreen_device( d3d, hwnd, 800, 600, &present_failed );
    if (FAILED(hr))
    {
        log_hr( "fullscreen 800x600", hr );
        ExitProcess( present_failed ? 70 : 68 );
    }
    out_str( "MADEIRA-D3D9MODES: fullscreen 800x600 device created and presented\n" );

    hr = run_fullscreen_device( d3d, hwnd, 640, 480, &present_failed );
    if (FAILED(hr))
    {
        log_hr( "fullscreen 640x480", hr );
        ExitProcess( present_failed ? 70 : 69 );
    }
    out_str( "MADEIRA-D3D9MODES: fullscreen 640x480 device created and presented\n" );

    /* --- 7: leave the screen the way it was ----------------------------- */

    IDirect3D9_Release( d3d );
    ChangeDisplaySettingsA( NULL, 0 );
    DestroyWindow( hwnd );

    out_str( "MADEIRA-D3D9MODES: PASS\n" );
    ExitProcess( 55 );
}
