/* MADEIRA-TEMP: acceptance test PE for Madeira's WoW64 (i386) Direct3D 11
 * path.  See WOW64_DESIGN.md section 6 (2026-09-19) and section 7.
 *
 * Until now the i386 farm shipped WINE's d3d11.dll / dxgi.dll / d3d10core.dll,
 * which are wined3d frontends.  wined3d has no backend at all in this port --
 * there is no OpenGL and the tree is configured --without-vulkan -- so
 * D3D11CreateDevice and CreateDXGIFactory could only ever hand back failure,
 * and a 32-bit title that got as far as loading them died in its own code on
 * the NULL it was given.  Those three modules are now DXMT's, built i386 by
 * build/dxmt-ios/build-pe.sh against the same i386 winemetal.dll the D3D9 path
 * uses, and they reach Metal through the winemetal WoW64 unix-call table.
 *
 * This is the smallest program that still exercises every part of that
 * boundary:
 *
 *   - a 32-bit process loading an i386 dxgi.dll + d3d11.dll and reaching
 *     their unix side through the WoW64 unix-call table,
 *   - D3D11CreateDeviceAndSwapChain with D3D_DRIVER_TYPE_HARDWARE, which is
 *     the exact call the 32-bit title makes,
 *   - a swapchain bound to a real HWND, so presentation has to find its way
 *     out to the app's Metal layer,
 *   - a DYNAMIC vertex buffer the guest Map()s with WRITE_DISCARD and writes
 *     through a 32-bit pointer.  That is the interesting case (WOW64_DESIGN.md
 *     section 7.5): the pointer Map() hands back must name memory the 32-bit
 *     process can actually reach, because this code stores it in a 32-bit
 *     register and dereferences it.  A pointer into Metal's own heap has no
 *     32-bit address at all; a truncated one lands on something unrelated.
 *     The test does not just deref and hope -- it asks VirtualQuery whether
 *     the span is committed and writable, then writes a pattern and reads it
 *     back before Unmap.
 *   - a STAGING texture Map(READ) readback of the presented image, which is
 *     the same mapped-memory rule in the opposite direction and is the only
 *     way to assert that what reached the GPU is what was asked for.
 *
 * DXGI output and mode enumeration, ResizeTarget and SetFullscreenState are
 * exercised and LOGGED but never asserted: they have to agree with the
 * virtual monitor, and a mismatch is far more useful as a printed line next
 * to a passing render than as an exit code that hides it.
 *
 * Deliberate restrictions (same as the D3D9 test):
 *   - No CRT.  This file supplies its own PE entry point (`start`, which the
 *     i386 Windows C ABI mangles to `_start`) and its own memset/memcpy, and
 *     is linked -nostdlib, so the only imports are kernel32, user32, d3d11
 *     and dxgi.  Verified with objdump -p in the build script.
 *   - No dxguid.  The one interface id the test needs (ID3D11Texture2D, for
 *     IDXGISwapChain::GetBuffer) is spelled out below rather than linked in.
 *   - No draw call, and therefore no shader and no d3dcompiler.  The point is
 *     the device, the swapchain, the mapped buffer and the readback; a draw
 *     would add a shader compile (airconv SM50, a different slot range) and
 *     with it a second reason for the test to fail.
 *
 * Exit status (reported by the runtime as "MADEIRA-EXIT: ... status=<n>"):
 *   66  success
 *   67  device/swapchain creation failed (the HRESULT is printed)
 *   68  Map() returned a pointer outside the 32-bit process's reach, or one
 *       whose memory is not committed+writable, or one whose contents did not
 *       read back as written
 *   69  the readback pixel did not match the clear colour
 *   60  window creation failed
 *   61  GetBuffer / CreateRenderTargetView failed
 *   62  CreateBuffer (dynamic vertex buffer) failed
 *   63  Map(WRITE_DISCARD) itself failed
 *   64  CreateTexture2D (staging) failed
 *   65  Map(READ) on the staging texture failed
 */
#define COBJMACROS
#define CINTERFACE
#include <stddef.h>
#include <windows.h>
#include <d3d11.h>
#include <dxgi.h>

#define WIN_W   640
#define WIN_H   480
#define FRAMES  30

/* The clear colour, chosen so every channel is an exact 8-bit value and no
 * two channels share one: 64/255, 128/255, 192/255.  The backbuffer is
 * B8G8R8A8_UNORM (linear, no sRGB conversion), so the bytes in memory come
 * out B=192 G=128 R=64 A=255. */
#define CLEAR_R 64
#define CLEAR_G 128
#define CLEAR_B 192
#define PIXEL_TOLERANCE 2

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

/* IID_ID3D11Texture2D.  Spelled out so the link stays -nostdlib clean and
 * pulls in no dxguid.a; the only place it is used is GetBuffer(). */
static const GUID MADEIRA_IID_ID3D11Texture2D =
    { 0x6f15aaf2, 0xd208, 0x4e89, { 0x9a, 0xb4, 0x48, 0x95, 0x35, 0xd3, 0x4f, 0x9c } };

/* IID_IDXGIFactory, for the direct CreateDXGIFactory probe below. */
static const GUID MADEIRA_IID_IDXGIFactory =
    { 0x7b7166ec, 0x21c7, 0x44ae, { 0xb2, 0x1a, 0xc9, 0xae, 0x32, 0x1a, 0xe3, 0x69 } };

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

#define LOG_PREFIX "MADEIRA-D3D11: "

static void log_msg( const char *what )
{
    char buf[256];
    char *p = put_str( buf, LOG_PREFIX );
    p = put_str( p, what );
    *p++ = '\n'; *p = 0;
    out_str( buf );
}

static void log_hr( const char *what, unsigned int hr )
{
    char buf[256];
    char *p = put_str( buf, LOG_PREFIX );
    p = put_str( p, what );
    p = put_str( p, " hr=" );
    p = put_hex( p, hr );
    *p++ = '\n'; *p = 0;
    out_str( buf );
}

static void log_u( const char *what, unsigned int v )
{
    char buf[256];
    char *p = put_str( buf, LOG_PREFIX );
    p = put_str( p, what );
    *p++ = '=';
    p = put_uint( p, v );
    *p++ = '\n'; *p = 0;
    out_str( buf );
}

static void log_ptr( const char *what, const void *v )
{
    char buf[256];
    char *p = put_str( buf, LOG_PREFIX );
    p = put_str( p, what );
    *p++ = '=';
    p = put_hex( p, (unsigned int)(ULONG_PTR)v );
    *p++ = '\n'; *p = 0;
    out_str( buf );
}

/* ------------------------------------------------------- mapped-memory check
 *
 * WOW64_DESIGN.md section 7.5.  Inside a 32-bit pseudo-process every pointer
 * is 32 bits wide, so "outside the 4 GB window" cannot show up as a large
 * value here -- it shows up as a pointer that names nothing, because the
 * host address was truncated on the way out.  VirtualQuery is the only way to
 * tell that apart from a good pointer WITHOUT taking the fault: it reports
 * the guest's own view of its address space, so a truncated host address
 * lands on MEM_FREE or on an unrelated reservation.
 *
 * Returns 0 and logs why if the span is not committed, readable/writable
 * (PAGE_GUARD counts as not), or not entirely inside one region. */
static int span_accessible( const void *p, SIZE_T len, int want_write )
{
    MEMORY_BASIC_INFORMATION mbi;
    const DWORD rw = PAGE_READWRITE | PAGE_WRITECOPY | PAGE_EXECUTE_READWRITE | PAGE_EXECUTE_WRITECOPY;
    const DWORD ro = rw | PAGE_READONLY | PAGE_EXECUTE_READ;

    if (!p)
    {
        log_msg( "map returned NULL" );
        return 0;
    }
    memset( &mbi, 0, sizeof(mbi) );
    if (VirtualQuery( p, &mbi, sizeof(mbi) ) != sizeof(mbi))
    {
        log_ptr( "VirtualQuery failed for", p );
        return 0;
    }
    log_ptr( "  region base", mbi.BaseAddress );
    log_u( "  region size", (unsigned int)mbi.RegionSize );
    log_hr( "  region state", mbi.State );
    log_hr( "  region protect", mbi.Protect );
    if (mbi.State != MEM_COMMIT)
    {
        log_msg( "mapped span is not committed memory" );
        return 0;
    }
    if (mbi.Protect & PAGE_GUARD)
    {
        log_msg( "mapped span is guarded" );
        return 0;
    }
    if (!(mbi.Protect & (want_write ? rw : ro)))
    {
        log_msg( "mapped span has the wrong protection" );
        return 0;
    }
    if ((const BYTE *)p + len > (const BYTE *)mbi.BaseAddress + mbi.RegionSize)
    {
        log_msg( "mapped span runs past the end of its region" );
        return 0;
    }
    return 1;
}

/* ------------------------------------------------------------------ window */

static LRESULT CALLBACK wndproc( HWND hwnd, UINT msg, WPARAM wp, LPARAM lp )
{
    if (msg == WM_CLOSE) return 0;   /* the test decides when it is over */
    return DefWindowProcA( hwnd, msg, wp, lp );
}

static void pump( void )
{
    MSG msg;
    while (PeekMessageA( &msg, NULL, 0, 0, PM_REMOVE ))
    {
        TranslateMessage( &msg );
        DispatchMessageA( &msg );
    }
}

/* --------------------------------------------- DXGI output / mode reporting
 *
 * Logged, never asserted.  On i386 DXMT's wsi layer is the user32 one
 * (src/util/wsi_monitor_win32.cpp), so these answers come from the port's
 * virtual monitor by way of EnumDisplayMonitors / EnumDisplaySettings, and a
 * disagreement with the swapchain's own idea of the mode is exactly what a
 * fullscreen title trips over. */
static void report_outputs( IDXGISwapChain *swapchain )
{
    IDXGIDevice *dxgi_device = NULL;
    IDXGIAdapter *adapter = NULL;
    IDXGIOutput *output = NULL;
    DXGI_OUTPUT_DESC odesc;
    DXGI_MODE_DESC modes[64];
    UINT num_modes = 0;
    UINT i;
    HRESULT hr;

    hr = IDXGISwapChain_GetContainingOutput( swapchain, &output );
    log_hr( "GetContainingOutput", hr );
    if (FAILED(hr) || !output) goto done;

    memset( &odesc, 0, sizeof(odesc) );
    hr = IDXGIOutput_GetDesc( output, &odesc );
    log_hr( "  IDXGIOutput::GetDesc", hr );
    if (SUCCEEDED(hr))
    {
        log_u( "  output left",   (unsigned int)odesc.DesktopCoordinates.left );
        log_u( "  output top",    (unsigned int)odesc.DesktopCoordinates.top );
        log_u( "  output right",  (unsigned int)odesc.DesktopCoordinates.right );
        log_u( "  output bottom", (unsigned int)odesc.DesktopCoordinates.bottom );
        log_ptr( "  output monitor", odesc.Monitor );
        log_u( "  output attached", (unsigned int)odesc.AttachedToDesktop );
    }

    num_modes = 0;
    hr = IDXGIOutput_GetDisplayModeList( output, DXGI_FORMAT_B8G8R8A8_UNORM, 0, &num_modes, NULL );
    log_hr( "  GetDisplayModeList(count)", hr );
    log_u( "  mode count", num_modes );
    if (SUCCEEDED(hr) && num_modes)
    {
        if (num_modes > 64) num_modes = 64;
        hr = IDXGIOutput_GetDisplayModeList( output, DXGI_FORMAT_B8G8R8A8_UNORM, 0, &num_modes, modes );
        log_hr( "  GetDisplayModeList(fill)", hr );
        if (SUCCEEDED(hr))
        {
            for (i = 0; i < num_modes && i < 8; i++)
            {
                char buf[128];
                char *p = put_str( buf, LOG_PREFIX "  mode " );
                p = put_uint( p, i );
                *p++ = ' ';
                p = put_uint( p, modes[i].Width );
                *p++ = 'x';
                p = put_uint( p, modes[i].Height );
                *p++ = ' ';
                p = put_uint( p, modes[i].RefreshRate.Numerator );
                *p++ = '/';
                p = put_uint( p, modes[i].RefreshRate.Denominator );
                *p++ = '\n'; *p = 0;
                out_str( buf );
            }
        }
    }

done:
    if (output) IDXGIOutput_Release( output );
    if (adapter) IDXGIAdapter_Release( adapter );
    if (dxgi_device) IDXGIDevice_Release( dxgi_device );
}

/* ------------------------------------------------- the direct dxgi.dll probe
 *
 * CreateDXGIFactory is the other half of what the 32-bit title does before it
 * dies: it asks dxgi.dll for a factory and walks the adapters.  Calling it
 * here is what puts dxgi.dll in this exe's OWN import table rather than only
 * behind d3d11's, so a dxgi.dll that fails to load is a loader error on this
 * binary instead of a mystery inside D3D11CreateDeviceAndSwapChain.
 *
 * Logged, not asserted: device creation (exit 67) is the real gate. */
static void probe_dxgi_factory( void )
{
    IDXGIFactory *factory = NULL;
    IDXGIAdapter *adapter = NULL;
    DXGI_ADAPTER_DESC adesc;
    UINT index;
    HRESULT hr;

    hr = CreateDXGIFactory( &MADEIRA_IID_IDXGIFactory, (void **)&factory );
    log_hr( "CreateDXGIFactory", hr );
    if (FAILED(hr) || !factory) return;

    for (index = 0; index < 4; index++)
    {
        hr = IDXGIFactory_EnumAdapters( factory, index, &adapter );
        if (FAILED(hr) || !adapter) break;
        memset( &adesc, 0, sizeof(adesc) );
        hr = IDXGIAdapter_GetDesc( adapter, &adesc );
        if (SUCCEEDED(hr))
        {
            char buf[256];
            char *p = put_str( buf, LOG_PREFIX "  adapter " );
            int i;
            p = put_uint( p, index );
            p = put_str( p, " vendor=" );
            p = put_hex( p, adesc.VendorId );
            p = put_str( p, " device=" );
            p = put_hex( p, adesc.DeviceId );
            p = put_str( p, " vram_mb=" );
            p = put_uint( p, (unsigned int)(adesc.DedicatedVideoMemory >> 20) );
            p = put_str( p, " name=" );
            for (i = 0; i < 96 && adesc.Description[i]; i++)
                *p++ = (adesc.Description[i] < 128) ? (char)adesc.Description[i] : '?';
            *p++ = '\n'; *p = 0;
            out_str( buf );
        }
        IDXGIAdapter_Release( adapter );
        adapter = NULL;
    }
    IDXGIFactory_Release( factory );
}

/* ------------------------------------------------------------------- start */

void start( void )
{
    WNDCLASSEXA wc;
    RECT rc;
    HWND hwnd;
    DXGI_SWAP_CHAIN_DESC scd;
    D3D_FEATURE_LEVEL levels[3];
    D3D_FEATURE_LEVEL got_level = (D3D_FEATURE_LEVEL)0;
    IDXGISwapChain *swapchain = NULL;
    ID3D11Device *device = NULL;
    ID3D11DeviceContext *ctx = NULL;
    ID3D11Texture2D *backbuffer = NULL;
    ID3D11RenderTargetView *rtv = NULL;
    ID3D11Buffer *vb = NULL;
    ID3D11Texture2D *staging = NULL;
    D3D11_BUFFER_DESC bd;
    D3D11_TEXTURE2D_DESC td;
    D3D11_MAPPED_SUBRESOURCE mapped;
    DXGI_MODE_DESC target_mode;
    const float clear[4] = { (float)CLEAR_R / 255.0f, (float)CLEAR_G / 255.0f,
                             (float)CLEAR_B / 255.0f, 1.0f };
    const UINT vb_bytes = 1024;
    unsigned int frame;
    unsigned char *bytes;
    const unsigned char *row;
    unsigned int i;
    int b, g, r, a;
    HRESULT hr;

    log_msg( "start" );

    memset( &wc, 0, sizeof(wc) );
    wc.cbSize = sizeof(wc);
    wc.lpfnWndProc = wndproc;
    wc.hInstance = GetModuleHandleA( NULL );
    wc.hCursor = LoadCursorA( NULL, (LPCSTR)IDC_ARROW );
    wc.lpszClassName = "MadeiraD3D11Test";
    RegisterClassExA( &wc );

    rc.left = 0; rc.top = 0; rc.right = WIN_W; rc.bottom = WIN_H;
    AdjustWindowRect( &rc, WS_OVERLAPPEDWINDOW, FALSE );
    hwnd = CreateWindowExA( 0, "MadeiraD3D11Test", "Madeira D3D11 (i386)",
                            WS_OVERLAPPEDWINDOW, CW_USEDEFAULT, CW_USEDEFAULT,
                            rc.right - rc.left, rc.bottom - rc.top,
                            NULL, NULL, wc.hInstance, NULL );
    if (!hwnd)
    {
        log_hr( "CreateWindowEx failed, last error", GetLastError() );
        ExitProcess( 60 );
    }
    ShowWindow( hwnd, SW_SHOW );
    UpdateWindow( hwnd );
    pump();
    log_msg( "window created 640x480" );

    probe_dxgi_factory();

    memset( &scd, 0, sizeof(scd) );
    scd.BufferDesc.Width = WIN_W;
    scd.BufferDesc.Height = WIN_H;
    scd.BufferDesc.RefreshRate.Numerator = 60;
    scd.BufferDesc.RefreshRate.Denominator = 1;
    scd.BufferDesc.Format = DXGI_FORMAT_B8G8R8A8_UNORM;
    scd.SampleDesc.Count = 1;
    scd.SampleDesc.Quality = 0;
    scd.BufferUsage = DXGI_USAGE_RENDER_TARGET_OUTPUT;
    scd.BufferCount = 1;
    scd.OutputWindow = hwnd;
    scd.Windowed = TRUE;
    scd.SwapEffect = DXGI_SWAP_EFFECT_DISCARD;
    scd.Flags = DXGI_SWAP_CHAIN_FLAG_ALLOW_MODE_SWITCH;

    levels[0] = D3D_FEATURE_LEVEL_11_0;
    levels[1] = D3D_FEATURE_LEVEL_10_1;
    levels[2] = D3D_FEATURE_LEVEL_10_0;

    hr = D3D11CreateDeviceAndSwapChain( NULL, D3D_DRIVER_TYPE_HARDWARE, NULL, 0,
                                        levels, 3, D3D11_SDK_VERSION,
                                        &scd, &swapchain, &device, &got_level, &ctx );
    log_hr( "D3D11CreateDeviceAndSwapChain", hr );
    if (FAILED(hr) || !device || !ctx || !swapchain)
    {
        log_msg( "device creation failed -- the i386 d3d11.dll/dxgi.dll in "
                 "syswow64 must be DXMT's, not wined3d's" );
        ExitProcess( 67 );
    }
    log_hr( "feature level", (unsigned int)got_level );
    /* The spec asks for 11_0 and accepts anything at or above 10_0. */
    if ((unsigned int)got_level < (unsigned int)D3D_FEATURE_LEVEL_10_0)
    {
        log_msg( "feature level below 10_0" );
        ExitProcess( 67 );
    }

    report_outputs( swapchain );

    /* ResizeTarget with the mode the swapchain already has must succeed: a
     * fullscreen title calls it before SetFullscreenState and treats a
     * failure as "this adapter cannot do my resolution".  Logged only. */
    memset( &target_mode, 0, sizeof(target_mode) );
    target_mode.Width = WIN_W;
    target_mode.Height = WIN_H;
    target_mode.RefreshRate.Numerator = 0;
    target_mode.RefreshRate.Denominator = 0;
    target_mode.Format = DXGI_FORMAT_UNKNOWN;
    target_mode.ScanlineOrdering = DXGI_MODE_SCANLINE_ORDER_UNSPECIFIED;
    target_mode.Scaling = DXGI_MODE_SCALING_UNSPECIFIED;
    hr = IDXGISwapChain_ResizeTarget( swapchain, &target_mode );
    log_hr( "ResizeTarget(640x480)", hr );
    pump();

    hr = IDXGISwapChain_SetFullscreenState( swapchain, TRUE, NULL );
    log_hr( "SetFullscreenState(TRUE)", hr );
    pump();
    hr = IDXGISwapChain_SetFullscreenState( swapchain, FALSE, NULL );
    log_hr( "SetFullscreenState(FALSE)", hr );
    pump();

    hr = IDXGISwapChain_GetBuffer( swapchain, 0, &MADEIRA_IID_ID3D11Texture2D, (void **)&backbuffer );
    log_hr( "GetBuffer(0)", hr );
    if (FAILED(hr) || !backbuffer) ExitProcess( 61 );

    hr = ID3D11Device_CreateRenderTargetView( device, (ID3D11Resource *)backbuffer, NULL, &rtv );
    log_hr( "CreateRenderTargetView", hr );
    if (FAILED(hr) || !rtv) ExitProcess( 61 );

    /* ---- the dynamic vertex buffer (the mapped-memory rule) ---- */
    memset( &bd, 0, sizeof(bd) );
    bd.ByteWidth = vb_bytes;
    bd.Usage = D3D11_USAGE_DYNAMIC;
    bd.BindFlags = D3D11_BIND_VERTEX_BUFFER;
    bd.CPUAccessFlags = D3D11_CPU_ACCESS_WRITE;
    hr = ID3D11Device_CreateBuffer( device, &bd, NULL, &vb );
    log_hr( "CreateBuffer(DYNAMIC, 1024, VERTEX)", hr );
    if (FAILED(hr) || !vb) ExitProcess( 62 );

    memset( &mapped, 0, sizeof(mapped) );
    hr = ID3D11DeviceContext_Map( ctx, (ID3D11Resource *)vb, 0,
                                  D3D11_MAP_WRITE_DISCARD, 0, &mapped );
    log_hr( "Map(WRITE_DISCARD)", hr );
    if (FAILED(hr)) ExitProcess( 63 );
    log_ptr( "mapped pData", mapped.pData );
    if (!span_accessible( mapped.pData, vb_bytes, 1 ))
    {
        ID3D11DeviceContext_Unmap( ctx, (ID3D11Resource *)vb, 0 );
        ExitProcess( 68 );
    }
    bytes = (unsigned char *)mapped.pData;
    for (i = 0; i < vb_bytes; i++) bytes[i] = (unsigned char)(i * 7 + 3);
    for (i = 0; i < vb_bytes; i++)
    {
        if (bytes[i] != (unsigned char)(i * 7 + 3))
        {
            log_u( "mapped buffer did not read back at byte", i );
            ID3D11DeviceContext_Unmap( ctx, (ID3D11Resource *)vb, 0 );
            ExitProcess( 68 );
        }
    }
    ID3D11DeviceContext_Unmap( ctx, (ID3D11Resource *)vb, 0 );
    log_msg( "dynamic buffer map/write/readback/unmap OK" );

    /* ---- the staging texture the readback comes through ---- */
    memset( &td, 0, sizeof(td) );
    td.Width = WIN_W;
    td.Height = WIN_H;
    td.MipLevels = 1;
    td.ArraySize = 1;
    td.Format = DXGI_FORMAT_B8G8R8A8_UNORM;
    td.SampleDesc.Count = 1;
    td.SampleDesc.Quality = 0;
    td.Usage = D3D11_USAGE_STAGING;
    td.BindFlags = 0;
    td.CPUAccessFlags = D3D11_CPU_ACCESS_READ;
    td.MiscFlags = 0;
    hr = ID3D11Device_CreateTexture2D( device, &td, NULL, &staging );
    log_hr( "CreateTexture2D(STAGING, READ)", hr );
    if (FAILED(hr) || !staging) ExitProcess( 64 );

    /* ---- clear + present, and copy the last cleared image out ---- */
    for (frame = 0; frame < FRAMES; frame++)
    {
        pump();
        ID3D11DeviceContext_OMSetRenderTargets( ctx, 1, &rtv, NULL );
        ID3D11DeviceContext_ClearRenderTargetView( ctx, rtv, clear );
        if (frame + 1 == FRAMES)
            ID3D11DeviceContext_CopyResource( ctx, (ID3D11Resource *)staging,
                                              (ID3D11Resource *)backbuffer );
        hr = IDXGISwapChain_Present( swapchain, 0, 0 );
        if (frame < 3 || frame + 1 == FRAMES)
        {
            char buf[96];
            char *p = put_str( buf, LOG_PREFIX "present " );
            p = put_uint( p, frame );
            p = put_str( p, " hr=" );
            p = put_hex( p, (unsigned int)hr );
            *p++ = '\n'; *p = 0;
            out_str( buf );
        }
    }
    log_u( "frames presented", FRAMES );

    memset( &mapped, 0, sizeof(mapped) );
    hr = ID3D11DeviceContext_Map( ctx, (ID3D11Resource *)staging, 0, D3D11_MAP_READ, 0, &mapped );
    log_hr( "Map(READ) on staging", hr );
    if (FAILED(hr)) ExitProcess( 65 );
    log_ptr( "staging pData", mapped.pData );
    log_u( "staging RowPitch", mapped.RowPitch );
    if (!span_accessible( mapped.pData, (SIZE_T)mapped.RowPitch, 0 ))
    {
        ID3D11DeviceContext_Unmap( ctx, (ID3D11Resource *)staging, 0 );
        ExitProcess( 68 );
    }

    row = (const unsigned char *)mapped.pData + (SIZE_T)mapped.RowPitch * (WIN_H / 2);
    b = row[(WIN_W / 2) * 4 + 0];
    g = row[(WIN_W / 2) * 4 + 1];
    r = row[(WIN_W / 2) * 4 + 2];
    a = row[(WIN_W / 2) * 4 + 3];
    log_u( "pixel B", (unsigned int)b );
    log_u( "pixel G", (unsigned int)g );
    log_u( "pixel R", (unsigned int)r );
    log_u( "pixel A", (unsigned int)a );
    ID3D11DeviceContext_Unmap( ctx, (ID3D11Resource *)staging, 0 );

#define NEAR_ENOUGH(v, want) ((v) >= (want) - PIXEL_TOLERANCE && (v) <= (want) + PIXEL_TOLERANCE)
    if (!NEAR_ENOUGH( b, CLEAR_B ) || !NEAR_ENOUGH( g, CLEAR_G ) || !NEAR_ENOUGH( r, CLEAR_R ))
    {
        log_msg( "readback mismatch -- expected B=192 G=128 R=64" );
        ExitProcess( 69 );
    }

    log_msg( "PASS" );

    if (staging) ID3D11Texture2D_Release( staging );
    if (vb) ID3D11Buffer_Release( vb );
    if (rtv) ID3D11RenderTargetView_Release( rtv );
    if (backbuffer) ID3D11Texture2D_Release( backbuffer );
    if (ctx) ID3D11DeviceContext_Release( ctx );
    if (swapchain) IDXGISwapChain_Release( swapchain );
    if (device) ID3D11Device_Release( device );
    DestroyWindow( hwnd );

    ExitProcess( 66 );
}
