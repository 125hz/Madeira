/* MADEIRA-TEMP: milestone-4 acceptance test PE for Madeira's WoW64 (i386)
 * Direct3D 9 path.  See WOW64_DESIGN.md section 7 ("D3D9 path (M4)").
 *
 * A 32-bit PE that spins a solid colour cube through a real D3D9 device and
 * exits with a known status.  It is deliberately the smallest program that
 * still exercises every part of the 32-bit graphics boundary we care about:
 *
 *   - a 32-bit process loading an i386 d3d9.dll and reaching its unix side
 *     through the WoW64 unix-call table,
 *   - a swapchain bound to a real HWND, so presentation has to find its way
 *     out to the app's Metal layer,
 *   - a DYNAMIC vertex buffer in D3DPOOL_DEFAULT that the guest Lock()s and
 *     writes through a 32-bit pointer every frame.  That last one is the
 *     interesting case: the pointer Lock() hands back must be INSIDE the
 *     pseudo-process's guest window, because this code stores it in a 32-bit
 *     register and dereferences it.  A host pointer would fault immediately.
 *
 * Deliberate restrictions:
 *   - No CRT.  This file supplies its own PE entry point (`start`, which the
 *     i386 Windows C ABI mangles to `_start`) and its own memset/memcpy, and
 *     is linked -nostdlib, so the only imports are kernel32, user32 and
 *     d3d9 -- all Wine-supplied.  Verified with objdump -p in the build
 *     script.  Nothing here depends on ucrtbase/msvcrt plumbing.
 *   - No libm.  The two rotations are advanced by repeatedly multiplying a
 *     unit rotor by a constant-angle rotor, so there is no runtime sin/cos
 *     and no float-library dependency at all.
 *   - FVF XYZRHW|DIFFUSE with software vertex processing: vertices are
 *     already in screen space when they reach the device, so the test needs
 *     no transform, lighting or texture state, and no fixed-function vertex
 *     pipeline beyond the bare minimum.
 *   - No depth buffer.  A cube is convex, so back-face rejection alone gives
 *     a correct image.  The rejection is done here on the CPU (sign of the
 *     screen-space signed area) rather than via D3DRS_CULLMODE, so the image
 *     does not depend on the layer's winding convention.
 *
 * Exit status (reported by the runtime as "MADEIRA-EXIT: ... status=<n>"):
 *   43  success -- MADEIRA_D3D9_FRAMES frames presented, or the window was
 *       closed after at least one frame was presented
 *   20  Direct3DCreate9 returned NULL
 *   21  CreateDevice failed
 *   22  CreateVertexBuffer failed
 *   23  Lock failed
 *   24  Present failed and the device never came back
 *   25  window creation failed
 *   26  the window was closed before any frame was presented
 */
#include <stddef.h>
#include <windows.h>
#include <d3d9.h>

#define MADEIRA_D3D9_FRAMES   240
#define WIN_W                 640
#define WIN_H                 480

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

static void log_step( const char *what, unsigned int hr )
{
    char buf[128];
    char *p = buf;
    const char *s = "MADEIRA-D3D9: ";
    while (*s) *p++ = *s++;
    while (*what) *p++ = *what++;
    *p++ = ' ';
    p = put_hex( p, hr );
    *p++ = '\n';
    *p = 0;
    out_str( buf );
}

/* One line per presented frame for the first few frames: the frame number and
 * the HRESULT Present actually returned.  `frame N` below is only printed once
 * Present has already succeeded, so it cannot show a Present that returned a
 * failure code or one that never returned at all. */
static void log_present( unsigned int frame, unsigned int hr )
{
    char buf[96];
    char *p = buf;
    const char *s = "MADEIRA-D3D9: present ";
    while (*s) *p++ = *s++;
    p = put_uint( p, frame );
    *p++ = ' '; *p++ = 'h'; *p++ = 'r'; *p++ = '=';
    p = put_hex( p, hr );
    *p++ = '\n';
    *p = 0;
    out_str( buf );
}

static void log_frame( unsigned int frame )
{
    char buf[64];
    char *p = buf;
    const char *s = "MADEIRA-D3D9: frame ";
    while (*s) *p++ = *s++;
    p = put_uint( p, frame );
    *p++ = '\n';
    *p = 0;
    out_str( buf );
}

/* ------------------------------------------------------------- cube model */

struct vertex           /* D3DFVF_XYZRHW | D3DFVF_DIFFUSE */
{
    float    x, y, z, rhw;
    D3DCOLOR color;
};

#define FVF_CUBE (D3DFVF_XYZRHW | D3DFVF_DIFFUSE)

/* Unit cube corners, and the six faces as CCW quads seen from outside. */
static const float corner[8][3] =
{
    { -1, -1, -1 }, {  1, -1, -1 }, {  1,  1, -1 }, { -1,  1, -1 },
    { -1, -1,  1 }, {  1, -1,  1 }, {  1,  1,  1 }, { -1,  1,  1 },
};

static const int face[6][4] =
{
    { 0, 1, 2, 3 },   /* -Z */
    { 5, 4, 7, 6 },   /* +Z */
    { 4, 0, 3, 7 },   /* -X */
    { 1, 5, 6, 2 },   /* +X */
    { 4, 5, 1, 0 },   /* -Y */
    { 3, 2, 6, 7 },   /* +Y */
};

static const D3DCOLOR face_color[6] =
{
    0xffe04040, 0xff40e040, 0xff4040e0,
    0xffe0e040, 0xff40e0e0, 0xffe040e0,
};

/* Rotors advanced by a constant-angle multiply each frame: no runtime trig.
 * step_a = 2*pi/180, step_b = 2*pi/300. */
#define COS_STEP_A  0.99939083f
#define SIN_STEP_A  0.03489950f
#define COS_STEP_B  0.99978066f
#define SIN_STEP_B  0.02094242f

/* Fill `out` with the visible triangles for this frame; returns the triangle
 * count (<= 12).  Vertices come out already in screen space, which is what
 * XYZRHW means. */
static unsigned int build_frame( struct vertex *out,
                                 float ca, float sa, float cb, float sb,
                                 float width, float height )
{
    float sx[8], sy[8], sw[8];
    int visible[8];
    unsigned int tris = 0;
    const float cam_z = 4.5f;            /* camera distance along +Z   */
    const float focal = 0.9f * height;   /* pixels per unit at z = 1   */
    const float cx = width * 0.5f;
    const float cy = height * 0.5f;
    int i, f;

    for (i = 0; i < 8; i++)
    {
        float x = corner[i][0], y = corner[i][1], z = corner[i][2];
        float x1, y1, z1, z2, inv;

        /* yaw about Y, then pitch about X */
        x1 =  x * ca + z * sa;
        z1 = -x * sa + z * ca;
        y1 =  y * cb - z1 * sb;
        z2 =  y * sb + z1 * cb;

        z2 += cam_z;
        if (z2 < 0.1f) { visible[i] = 0; sx[i] = sy[i] = sw[i] = 0.0f; continue; }
        visible[i] = 1;
        inv = 1.0f / z2;
        sx[i] = cx + focal * x1 * inv;
        sy[i] = cy - focal * y1 * inv;
        sw[i] = inv;
    }

    for (f = 0; f < 6; f++)
    {
        const int *q = face[f];
        float ax, ay, bx, by, area;

        if (!visible[q[0]] || !visible[q[1]] || !visible[q[2]] || !visible[q[3]])
            continue;

        /* Screen-space signed area of the first triangle.  For a convex
         * solid this is exactly the back-face test, so no depth buffer and
         * no reliance on the layer's D3DRS_CULLMODE convention. */
        ax = sx[q[1]] - sx[q[0]];
        ay = sy[q[1]] - sy[q[0]];
        bx = sx[q[2]] - sx[q[0]];
        by = sy[q[2]] - sy[q[0]];
        area = ax * by - ay * bx;
        if (area <= 0.0f) continue;

        {
            static const int tri[6] = { 0, 1, 2, 0, 2, 3 };
            int k;
            for (k = 0; k < 6; k++)
            {
                int c = q[tri[k]];
                out->x     = sx[c];
                out->y     = sy[c];
                out->z     = 0.5f;          /* no depth test in use */
                out->rhw   = sw[c];
                out->color = face_color[f];
                out++;
            }
            tris += 2;
        }
    }
    return tris;
}

/* ------------------------------------------------------------------ window */

static volatile int window_closed;

static LRESULT CALLBACK wnd_proc( HWND hwnd, UINT msg, WPARAM wp, LPARAM lp )
{
    switch (msg)
    {
    case WM_CLOSE:
    case WM_DESTROY:
        window_closed = 1;
        return 0;
    }
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

/* -------------------------------------------------------------------- main */

void start( void )
{
    WNDCLASSEXA wc;
    D3DPRESENT_PARAMETERS pp;
    HWND hwnd;
    HINSTANCE inst = GetModuleHandleA( NULL );
    IDirect3D9 *d3d;
    IDirect3DDevice9 *dev = NULL;
    IDirect3DVertexBuffer9 *vb = NULL;
    unsigned int frame, presented = 0;
    float ca = 1.0f, sa = 0.0f, cb = 1.0f, sb = 0.0f;
    HRESULT hr;

    out_str( "MADEIRA-D3D9: 32-bit D3D9 cube starting\n" );

    memset( &wc, 0, sizeof(wc) );
    wc.cbSize        = sizeof(wc);
    wc.lpfnWndProc   = wnd_proc;
    wc.hInstance     = inst;
    wc.hCursor       = NULL;
    wc.lpszClassName = "MadeiraD3D9CubeX86";
    if (!RegisterClassExA( &wc ))
    {
        log_step( "RegisterClassExA failed, err", GetLastError() );
        ExitProcess( 25 );
    }

    hwnd = CreateWindowExA( 0, wc.lpszClassName, "Madeira D3D9 cube (32-bit)",
                            WS_OVERLAPPEDWINDOW | WS_VISIBLE,
                            0, 0, WIN_W, WIN_H, NULL, NULL, inst, NULL );
    if (!hwnd)
    {
        log_step( "CreateWindowExA failed, err", GetLastError() );
        ExitProcess( 25 );
    }
    log_step( "hwnd", (unsigned int)(ULONG_PTR)hwnd );

    d3d = Direct3DCreate9( D3D_SDK_VERSION );
    if (!d3d)
    {
        out_str( "MADEIRA-D3D9: Direct3DCreate9 returned NULL\n" );
        ExitProcess( 20 );
    }
    out_str( "MADEIRA-D3D9: Direct3DCreate9 ok\n" );

    memset( &pp, 0, sizeof(pp) );
    pp.Windowed               = TRUE;
    pp.SwapEffect             = D3DSWAPEFFECT_DISCARD;
    pp.BackBufferFormat       = D3DFMT_UNKNOWN;
    pp.BackBufferWidth        = WIN_W;
    pp.BackBufferHeight       = WIN_H;
    pp.hDeviceWindow          = hwnd;
    pp.EnableAutoDepthStencil = FALSE;
    pp.PresentationInterval   = D3DPRESENT_INTERVAL_IMMEDIATE;

    hr = IDirect3D9_CreateDevice( d3d, D3DADAPTER_DEFAULT, D3DDEVTYPE_HAL, hwnd,
                                  D3DCREATE_SOFTWARE_VERTEXPROCESSING, &pp, &dev );
    if (FAILED(hr) || !dev)
    {
        log_step( "CreateDevice failed, hr", (unsigned int)hr );
        ExitProcess( 21 );
    }
    out_str( "MADEIRA-D3D9: device created (software vertex processing)\n" );

    hr = IDirect3DDevice9_CreateVertexBuffer( dev, 12 * 3 * sizeof(struct vertex),
                                              D3DUSAGE_DYNAMIC | D3DUSAGE_WRITEONLY,
                                              FVF_CUBE, D3DPOOL_DEFAULT, &vb, NULL );
    if (FAILED(hr) || !vb)
    {
        log_step( "CreateVertexBuffer failed, hr", (unsigned int)hr );
        ExitProcess( 22 );
    }
    out_str( "MADEIRA-D3D9: dynamic vertex buffer created\n" );

    IDirect3DDevice9_SetRenderState( dev, D3DRS_LIGHTING, FALSE );
    IDirect3DDevice9_SetRenderState( dev, D3DRS_ZENABLE, D3DZB_FALSE );
    IDirect3DDevice9_SetRenderState( dev, D3DRS_CULLMODE, D3DCULL_NONE );
    IDirect3DDevice9_SetFVF( dev, FVF_CUBE );

    for (frame = 0; frame < MADEIRA_D3D9_FRAMES; frame++)
    {
        void *locked = NULL;
        unsigned int tris;
        float nca, ncb;

        pump();
        if (window_closed) break;

        hr = IDirect3DVertexBuffer9_Lock( vb, 0, 0, &locked, D3DLOCK_DISCARD );
        if (FAILED(hr) || !locked)
        {
            log_step( "Lock failed, hr", (unsigned int)hr );
            ExitProcess( 23 );
        }
        if (!frame) log_step( "first locked vertex pointer", (unsigned int)(ULONG_PTR)locked );

        tris = build_frame( locked, ca, sa, cb, sb, (float)WIN_W, (float)WIN_H );
        IDirect3DVertexBuffer9_Unlock( vb );

        IDirect3DDevice9_Clear( dev, 0, NULL, D3DCLEAR_TARGET,
                                D3DCOLOR_XRGB( 24, 28, 40 ), 1.0f, 0 );
        if (SUCCEEDED(IDirect3DDevice9_BeginScene( dev )))
        {
            if (tris)
            {
                IDirect3DDevice9_SetStreamSource( dev, 0, vb, 0, sizeof(struct vertex) );
                hr = IDirect3DDevice9_DrawPrimitive( dev, D3DPT_TRIANGLELIST, 0, tris );
                if (!frame) log_step( "first DrawPrimitive returned hr", (unsigned int)hr );
            }
            IDirect3DDevice9_EndScene( dev );
        }

        hr = IDirect3DDevice9_Present( dev, NULL, NULL, NULL, NULL );
        if (frame < 3) log_present( frame + 1, (unsigned int)hr );
        if (FAILED(hr))
        {
            log_step( "Present failed, hr", (unsigned int)hr );
            if (hr == D3DERR_DEVICELOST || hr == D3DERR_DEVICENOTRESET)
            {
                Sleep( 50 );
                continue;
            }
            ExitProcess( 24 );
        }
        presented++;
        if (frame == 0 || frame == 1 || ((frame + 1) % 60) == 0) log_frame( frame + 1 );

        /* advance both rotors */
        nca = ca * COS_STEP_A - sa * SIN_STEP_A;
        sa  = sa * COS_STEP_A + ca * SIN_STEP_A;
        ca  = nca;
        ncb = cb * COS_STEP_B - sb * SIN_STEP_B;
        sb  = sb * COS_STEP_B + cb * SIN_STEP_B;
        cb  = ncb;
    }

    if (vb)  IDirect3DVertexBuffer9_Release( vb );
    if (dev) IDirect3DDevice9_Release( dev );
    IDirect3D9_Release( d3d );
    DestroyWindow( hwnd );

    if (!presented)
    {
        out_str( "MADEIRA-D3D9: closed before any frame was presented\n" );
        ExitProcess( 26 );
    }

    {
        char buf[80];
        char *p = buf;
        const char *s = "MADEIRA-D3D9: done, frames presented = ";
        while (*s) *p++ = *s++;
        p = put_uint( p, presented );
        *p++ = '\n';
        *p = 0;
        out_str( buf );
    }
    ExitProcess( 43 );
}
