/* MADEIRA-TEMP: the 32-bit D3D9 BLOCK-COMPRESSED TEXTURE self-test.
 *
 * WHY THIS TEST EXISTS
 * --------------------
 * Most GPUs this port runs on report supportsBCTextureCompression = NO. On
 * those, a DXTn texture is created with an UNCOMPRESSED Metal storage format of
 * the same texel extent and the frontend has to decode the application's blocks
 * on the CPU before they are uploaded (research/dxmt/src/d3d9/d3d9_device.cpp,
 * MTLD3D9Device::stageTextureUpload). Everything about that is invisible from
 * the application side by design: the D3DFORMAT, the LockRect pitch and the
 * caps all keep saying DXT. So the ONLY way to tell a working decode from a
 * broken one is to put known blocks in and read known pixels out.
 *
 * A screenshot cannot do that. "The menu text is noise" is equally consistent
 * with a wrong decode, a dropped upload, a wrong swizzle, a wrong pitch and a
 * sampler problem, and on a device there is nothing to step through. This test
 * separates them: it writes ONE block whose correct output can be computed by
 * hand from the D3D BC specification, samples it with a point filter into an
 * offscreen A8R8G8B8 render target, reads that back, and compares.
 *
 * The blocks chosen are the ones that go wrong in different ways:
 *   1. DXT1 with c0 > c1  -- the four-colour mode. Checks the 565 expansion
 *      and the 1/3 and 2/3 interpolants.
 *   2. DXT1 with c0 <= c1 -- the three-colour punch-through mode, where index
 *      2 is a HALF blend (not 1/3) and index 3 is TRANSPARENT BLACK. This is
 *      the single most commonly mis-implemented BC1 rule and it is what cut-out
 *      foliage and UI masks are made of.
 *   3. DXT3 -- explicit 4-bit alpha, which must expand by REPLICATION
 *      (0xA -> 0xAA), over a colour block that must NOT punch through even
 *      though its c0 <= c1.
 *   4. DXT5 -- interpolated alpha in the eight-value mode.
 * Each is a 4x4 texture, so exactly one block, and every texel of the render
 * target is one texel of the source with a point filter and a 1:1 mapping.
 *
 * It also asserts that CheckDeviceFormat still ADVERTISES DXT1/2/3/4/5. A
 * title that cannot find them does not fall back -- it refuses to start.
 *
 * WHAT A FAILURE MEANS
 * --------------------
 * Every case prints its expected and actual ARGB, so a failing run says which
 * rule broke. A uniform wrong colour across a case is a decode or swizzle
 * error; garbage that differs per texel is an upload that carried BC bytes
 * into an uncompressed texture; all-zero is an upload that was dropped.
 *
 * Deliberate restrictions: same as the other tests here. No CRT (own `start`,
 * own memset/memcpy, -nostdlib), imports limited to kernel32/user32/d3d9.
 *
 * Exit status (reported as "MADEIRA-EXIT: ... status=<n>"):
 *   57  every REQUIRED check passed
 *   20  Direct3DCreate9 returned NULL
 *   21  CreateDevice failed
 *   25  window creation failed
 *   58  a DXT format is not advertised by CheckDeviceFormat
 *   59  a resource create / lock failed (setup problem, not a decode result)
 *   60  at least one decoded texel did not match
 *
 * Run it from the Custom path popup as
 *   C:\windows\syswow64\d3d9dxt-x86.exe
 */
#include <stddef.h>
#include <windows.h>
#include <d3d9.h>

#define TEX_W 4
#define TEX_H 4
/* The render target is FOUR times the texture in each axis, and each texel is
 * read from the middle of its 4x4 cell, on purpose.
 *
 * A 1:1 target would make the result depend on D3D9's half-pixel convention
 * being translated exactly right, and a one-pixel offset there would fail every
 * case in this file while saying nothing whatsoever about BC decoding. Reading
 * the cell centre leaves a pixel of slack on every side, so the only thing that
 * can move a texel out of its cell is a genuinely wrong image. */
#define CELL  4
#define RT_W  (TEX_W * CELL)
#define RT_H  (TEX_H * CELL)

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

static char *put_hex8( char *p, unsigned int v )
{
    static const char digits[] = "0123456789abcdef";
    int i;
    *p++ = '0'; *p++ = 'x';
    for (i = 28; i >= 0; i -= 4) *p++ = digits[(v >> i) & 0xf];
    return p;
}

static char *put_str( char *p, const char *s )
{
    while (*s) *p++ = *s++;
    return p;
}

static unsigned int g_failures;
static unsigned int g_checks;

static void log_line( const char *s )
{
    char buf[256];
    char *p = put_str( buf, "MADEIRA-D3D9DXT: " );
    p = put_str( p, s );
    *p++ = '\n';
    *p = 0;
    out_str( buf );
}

static void log_hr( const char *what, HRESULT hr )
{
    char buf[256];
    char *p = put_str( buf, "MADEIRA-D3D9DXT: " );
    p = put_str( p, what );
    p = put_str( p, " hr=" );
    p = put_hex8( p, (unsigned int)hr );
    *p++ = '\n';
    *p = 0;
    out_str( buf );
}

/* One texel comparison. `mask` selects the channels that matter: a case that
 * does not exercise alpha must not fail on whatever the blend chain left in
 * it, and saying so here keeps that decision visible instead of hidden in the
 * expected value.
 *
 * Each selected channel is compared with a tolerance of +/-1. The decoder
 * itself is exact, but the value travels 8-bit -> normalised float -> sampler
 * -> render target -> 8-bit, and a single ulp of rounding anywhere on that
 * path would turn a correct decode into a confusing failure. Every defect this
 * test is built to catch is off by tens, not by one: a wrong interpolant, a
 * missing punch-through, a swapped channel and an undecoded block are all
 * gross errors. */
static void check_texel( const char *what, unsigned int x, unsigned int y,
                         unsigned int got, unsigned int want, unsigned int mask )
{
    char buf[256];
    char *p;
    int shift, bad = 0;
    ++g_checks;
    for (shift = 0; shift < 32; shift += 8)
    {
        int g, w, d;
        if (((mask >> shift) & 0xff) == 0) continue;
        g = (int)((got >> shift) & 0xff);
        w = (int)((want >> shift) & 0xff);
        d = g - w;
        if (d < -1 || d > 1) bad = 1;
    }
    if (!bad) return;
    ++g_failures;
    p = put_str( buf, "MADEIRA-D3D9DXT: [FAIL] " );
    p = put_str( p, what );
    p = put_str( p, " at (" );
    p = put_uint( p, x );
    *p++ = ',';
    p = put_uint( p, y );
    p = put_str( p, ") got=" );
    p = put_hex8( p, got );
    p = put_str( p, " want=" );
    p = put_hex8( p, want );
    p = put_str( p, " mask=" );
    p = put_hex8( p, mask );
    *p++ = '\n';
    *p = 0;
    out_str( buf );
}

/* --------------------------------------------------------- block building */

/* Expand a 565 colour the way the BC specification's unquantise does: the high
 * bits are replicated into the low ones, NOT shifted in with zeros. */
static unsigned int expand565( unsigned int c )
{
    unsigned int r = (c >> 11) & 0x1f, g = (c >> 5) & 0x3f, b = c & 0x1f;
    r = (r << 3) | (r >> 2);
    g = (g << 2) | (g >> 4);
    b = (b << 3) | (b >> 2);
    return (r << 16) | (g << 8) | b;      /* 0x00RRGGBB */
}

static unsigned int chan( unsigned int argb, int shift )
{
    return (argb >> shift) & 0xff;
}

/* (w0*a + w1*b + round) / div, per channel, assembled back into 0x00RRGGBB. */
static unsigned int blend_rgb( unsigned int a, unsigned int b,
                               unsigned int w0, unsigned int w1, unsigned int div )
{
    unsigned int round = div / 2;
    unsigned int r = (w0 * chan( a, 16 ) + w1 * chan( b, 16 ) + round) / div;
    unsigned int g = (w0 * chan( a,  8 ) + w1 * chan( b,  8 ) + round) / div;
    unsigned int bl = (w0 * chan( a,  0 ) + w1 * chan( b,  0 ) + round) / div;
    return (r << 16) | (g << 8) | bl;
}

static void put16le( unsigned char *p, unsigned int v )
{
    p[0] = (unsigned char)(v & 0xff);
    p[1] = (unsigned char)((v >> 8) & 0xff);
}

/* Build the 8-byte BC1 colour half. `idx` is the packed 32-bit index word:
 * two bits per texel, texel 0 in the low bits, row-major. */
static void build_bc1( unsigned char *blk, unsigned int c0, unsigned int c1, unsigned int idx )
{
    put16le( blk + 0, c0 );
    put16le( blk + 2, c1 );
    blk[4] = (unsigned char)(idx & 0xff);
    blk[5] = (unsigned char)((idx >> 8) & 0xff);
    blk[6] = (unsigned char)((idx >> 16) & 0xff);
    blk[7] = (unsigned char)((idx >> 24) & 0xff);
}

/* Index word giving texel 0 index 0, texel 1 index 1, texel 2 index 2,
 * texel 3 index 3, and every remaining texel index 0. One block therefore
 * shows all four palette entries in its first row. */
#define IDX_0123  (0u | (1u << 2) | (2u << 4) | (3u << 6))

/* ------------------------------------------------------- render + readback */

struct vertex                     /* D3DFVF_XYZRHW | D3DFVF_TEX1 */
{
    float x, y, z, rhw;
    float u, v;
};

/* Draw the 4x4 texture magnified over the render target and read back one
 * pixel from the centre of each texel's cell. Returns FALSE only on a setup
 * failure; a wrong IMAGE is reported by the caller's comparisons, not here.
 * `out` receives TEX_W*TEX_H D3DFMT_A8R8G8B8 texels in row-major order. */
static BOOL render_and_read( IDirect3DDevice9 *dev, IDirect3DSurface9 *rt,
                             IDirect3DSurface9 *sysmem, IDirect3DBaseTexture9 *tex,
                             unsigned int *out )
{
    struct vertex quad[4];
    HRESULT hr;
    D3DLOCKED_RECT lr;
    unsigned int y, x;

    /* Screen-space quad covering the whole target. The -0.5 offset is D3D9's
     * half-pixel rule; with the cell-centre readback below the test survives
     * getting it wrong, but there is no reason to author it wrong. */
    quad[0].x = -0.5f;              quad[0].y = -0.5f;              quad[0].u = 0.0f; quad[0].v = 0.0f;
    quad[1].x = (float)RT_W - 0.5f; quad[1].y = -0.5f;              quad[1].u = 1.0f; quad[1].v = 0.0f;
    quad[2].x = -0.5f;              quad[2].y = (float)RT_H - 0.5f; quad[2].u = 0.0f; quad[2].v = 1.0f;
    quad[3].x = (float)RT_W - 0.5f; quad[3].y = (float)RT_H - 0.5f; quad[3].u = 1.0f; quad[3].v = 1.0f;
    for (x = 0; x < 4; x++) { quad[x].z = 0.0f; quad[x].rhw = 1.0f; }

    hr = IDirect3DDevice9_SetRenderTarget( dev, 0, rt );
    if (FAILED(hr)) { log_hr( "SetRenderTarget", hr ); return FALSE; }

    /* Magenta, so an untouched target is obvious in the dump rather than
     * looking like a plausible black. */
    IDirect3DDevice9_Clear( dev, 0, NULL, D3DCLEAR_TARGET, 0xFFFF00FF, 1.0f, 0 );

    IDirect3DDevice9_SetTexture( dev, 0, tex );
    IDirect3DDevice9_SetFVF( dev, D3DFVF_XYZRHW | D3DFVF_TEX1 );
    IDirect3DDevice9_BeginScene( dev );
    hr = IDirect3DDevice9_DrawPrimitiveUP( dev, D3DPT_TRIANGLESTRIP, 2, quad, sizeof(quad[0]) );
    IDirect3DDevice9_EndScene( dev );
    if (FAILED(hr)) { log_hr( "DrawPrimitiveUP", hr ); return FALSE; }

    hr = IDirect3DDevice9_GetRenderTargetData( dev, rt, sysmem );
    if (FAILED(hr)) { log_hr( "GetRenderTargetData", hr ); return FALSE; }

    memset( &lr, 0, sizeof(lr) );
    hr = IDirect3DSurface9_LockRect( sysmem, &lr, NULL, D3DLOCK_READONLY );
    if (FAILED(hr) || !lr.pBits) { log_hr( "readback LockRect", hr ); return FALSE; }
    for (y = 0; y < TEX_H; y++)
    {
        const unsigned char *base = (const unsigned char *)lr.pBits;
        const unsigned int *row = (const unsigned int *)(base + (int)(y * CELL + CELL / 2) * lr.Pitch);
        for (x = 0; x < TEX_W; x++) out[y * TEX_W + x] = row[x * CELL + CELL / 2];
    }
    IDirect3DSurface9_UnlockRect( sysmem );
    return TRUE;
}

/* Fill mip 0 of a 4x4 compressed texture with one block. `block_bytes` is 8
 * for DXT1 and 16 for DXT3/DXT5. Also asserts the pitch contract D3D9 promises
 * for a block format: one row of BLOCKS, not one row of texels. */
static BOOL upload_block( IDirect3DTexture9 *tex, const unsigned char *block, unsigned int block_bytes )
{
    D3DLOCKED_RECT lr;
    HRESULT hr;

    memset( &lr, 0, sizeof(lr) );
    hr = IDirect3DTexture9_LockRect( tex, 0, &lr, NULL, 0 );
    if (FAILED(hr) || !lr.pBits) { log_hr( "texture LockRect", hr ); return FALSE; }
    if ((unsigned int)lr.Pitch < block_bytes)
    {
        char buf[160];
        char *p = put_str( buf, "MADEIRA-D3D9DXT: [FAIL] block pitch too small, Pitch=" );
        p = put_uint( p, (unsigned int)lr.Pitch );
        p = put_str( p, " expected at least " );
        p = put_uint( p, block_bytes );
        *p++ = '\n'; *p = 0;
        out_str( buf );
        ++g_failures;
        ++g_checks;
    }
    memcpy( lr.pBits, block, block_bytes );
    hr = IDirect3DTexture9_UnlockRect( tex, 0 );
    if (FAILED(hr)) { log_hr( "texture UnlockRect", hr ); return FALSE; }
    return TRUE;
}

static LRESULT CALLBACK wnd_proc( HWND h, UINT msg, WPARAM wp, LPARAM lp )
{
    return DefWindowProcA( h, msg, wp, lp );
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
    IDirect3DSurface9 *rt = NULL, *sysmem = NULL;
    IDirect3DTexture9 *tex = NULL;
    unsigned char block[16];
    unsigned int px[TEX_W * TEX_H];  /* one sample per texel, cell centres */
    unsigned int c0, c1, e0, e1;
    HRESULT hr;
    unsigned int i;

    static const D3DFORMAT dxt_formats[5] = { D3DFMT_DXT1, D3DFMT_DXT2, D3DFMT_DXT3,
                                              D3DFMT_DXT4, D3DFMT_DXT5 };
    static const char *const dxt_names[5] = { "DXT1", "DXT2", "DXT3", "DXT4", "DXT5" };

    log_line( "32-bit D3D9 DXT decode self-test starting" );

    memset( &wc, 0, sizeof(wc) );
    wc.cbSize        = sizeof(wc);
    wc.lpfnWndProc   = wnd_proc;
    wc.hInstance     = inst;
    wc.lpszClassName = "MadeiraD3D9DxtX86";
    if (!RegisterClassExA( &wc )) { log_hr( "RegisterClassExA", (HRESULT)GetLastError() ); ExitProcess( 25 ); }
    hwnd = CreateWindowExA( 0, wc.lpszClassName, "Madeira D3D9 DXT test (32-bit)",
                            WS_OVERLAPPEDWINDOW | WS_VISIBLE, 0, 0, 320, 240, NULL, NULL, inst, NULL );
    if (!hwnd) { log_hr( "CreateWindowExA", (HRESULT)GetLastError() ); ExitProcess( 25 ); }

    d3d = Direct3DCreate9( D3D_SDK_VERSION );
    if (!d3d) { log_line( "Direct3DCreate9 returned NULL" ); ExitProcess( 20 ); }

    /* 1. The caps a title gates on. A DXT format that is not advertised is
     *    not a degraded image -- it is a title that refuses to start, so this
     *    is REQUIRED even though this test could decode without it. */
    for (i = 0; i < 5; i++)
    {
        hr = IDirect3D9_CheckDeviceFormat( d3d, D3DADAPTER_DEFAULT, D3DDEVTYPE_HAL,
                                           D3DFMT_X8R8G8B8, 0, D3DRTYPE_TEXTURE, dxt_formats[i] );
        log_hr( dxt_names[i], hr );
        if (FAILED(hr))
        {
            log_line( "[FAIL] a DXT format is not advertised; titles refuse to run without these" );
            IDirect3D9_Release( d3d );
            ExitProcess( 58 );
        }
    }
    log_line( "CheckDeviceFormat advertises DXT1..DXT5" );

    memset( &pp, 0, sizeof(pp) );
    pp.Windowed             = TRUE;
    pp.SwapEffect           = D3DSWAPEFFECT_DISCARD;
    pp.BackBufferFormat     = D3DFMT_UNKNOWN;
    pp.BackBufferWidth      = 320;
    pp.BackBufferHeight     = 240;
    pp.hDeviceWindow        = hwnd;
    pp.PresentationInterval = D3DPRESENT_INTERVAL_IMMEDIATE;
    hr = IDirect3D9_CreateDevice( d3d, D3DADAPTER_DEFAULT, D3DDEVTYPE_HAL, hwnd,
                                  D3DCREATE_SOFTWARE_VERTEXPROCESSING, &pp, &dev );
    if (FAILED(hr) || !dev) { log_hr( "CreateDevice", hr ); ExitProcess( 21 ); }

    /* Point sampling and a pass-through blend chain: the render target must
     * receive the texture's own texels, not a filtered or modulated version
     * of them, or the comparison is measuring the sampler instead. */
    IDirect3DDevice9_SetSamplerState( dev, 0, D3DSAMP_MAGFILTER, D3DTEXF_POINT );
    IDirect3DDevice9_SetSamplerState( dev, 0, D3DSAMP_MINFILTER, D3DTEXF_POINT );
    IDirect3DDevice9_SetSamplerState( dev, 0, D3DSAMP_MIPFILTER, D3DTEXF_NONE );
    IDirect3DDevice9_SetSamplerState( dev, 0, D3DSAMP_ADDRESSU, D3DTADDRESS_CLAMP );
    IDirect3DDevice9_SetSamplerState( dev, 0, D3DSAMP_ADDRESSV, D3DTADDRESS_CLAMP );
    IDirect3DDevice9_SetSamplerState( dev, 0, D3DSAMP_SRGBTEXTURE, FALSE );
    IDirect3DDevice9_SetTextureStageState( dev, 0, D3DTSS_COLOROP, D3DTOP_SELECTARG1 );
    IDirect3DDevice9_SetTextureStageState( dev, 0, D3DTSS_COLORARG1, D3DTA_TEXTURE );
    IDirect3DDevice9_SetTextureStageState( dev, 0, D3DTSS_ALPHAOP, D3DTOP_SELECTARG1 );
    IDirect3DDevice9_SetTextureStageState( dev, 0, D3DTSS_ALPHAARG1, D3DTA_TEXTURE );
    IDirect3DDevice9_SetTextureStageState( dev, 1, D3DTSS_COLOROP, D3DTOP_DISABLE );
    IDirect3DDevice9_SetRenderState( dev, D3DRS_LIGHTING, FALSE );
    IDirect3DDevice9_SetRenderState( dev, D3DRS_ZENABLE, D3DZB_FALSE );
    IDirect3DDevice9_SetRenderState( dev, D3DRS_CULLMODE, D3DCULL_NONE );
    IDirect3DDevice9_SetRenderState( dev, D3DRS_ALPHABLENDENABLE, FALSE );
    IDirect3DDevice9_SetRenderState( dev, D3DRS_ALPHATESTENABLE, FALSE );
    IDirect3DDevice9_SetRenderState( dev, D3DRS_SRGBWRITEENABLE, FALSE );

    hr = IDirect3DDevice9_CreateRenderTarget( dev, RT_W, RT_H, D3DFMT_A8R8G8B8,
                                              D3DMULTISAMPLE_NONE, 0, FALSE, &rt, NULL );
    if (FAILED(hr) || !rt) { log_hr( "CreateRenderTarget", hr ); ExitProcess( 59 ); }
    hr = IDirect3DDevice9_CreateOffscreenPlainSurface( dev, RT_W, RT_H, D3DFMT_A8R8G8B8,
                                                       D3DPOOL_SYSTEMMEM, &sysmem, NULL );
    if (FAILED(hr) || !sysmem) { log_hr( "CreateOffscreenPlainSurface", hr ); ExitProcess( 59 ); }

    /* ---------------- case 1: DXT1, four-colour mode (c0 > c1) ------------ */
    c0 = 0xF800;                          /* pure red  */
    c1 = 0x001F;                          /* pure blue */
    e0 = expand565( c0 );
    e1 = expand565( c1 );
    build_bc1( block, c0, c1, IDX_0123 );
    hr = IDirect3DDevice9_CreateTexture( dev, TEX_W, TEX_H, 1, 0, D3DFMT_DXT1,
                                         D3DPOOL_MANAGED, &tex, NULL );
    if (FAILED(hr) || !tex) { log_hr( "CreateTexture DXT1", hr ); ExitProcess( 59 ); }
    if (!upload_block( tex, block, 8 )) ExitProcess( 59 );
    if (!render_and_read( dev, rt, sysmem, (IDirect3DBaseTexture9 *)tex, px )) ExitProcess( 59 );
    check_texel( "dxt1.4c index0 = c0", 0, 0, px[0], e0, 0x00FFFFFF );
    check_texel( "dxt1.4c index1 = c1", 1, 0, px[1], e1, 0x00FFFFFF );
    check_texel( "dxt1.4c index2 = (2c0+c1)/3", 2, 0, px[2], blend_rgb( e0, e1, 2, 1, 3 ), 0x00FFFFFF );
    check_texel( "dxt1.4c index3 = (c0+2c1)/3", 3, 0, px[3], blend_rgb( e0, e1, 1, 2, 3 ), 0x00FFFFFF );
    check_texel( "dxt1.4c row1 index0 = c0", 0, 1, px[TEX_W], e0, 0x00FFFFFF );
    IDirect3DTexture9_Release( tex ); tex = NULL;
    log_line( "case 1 done: DXT1 four-colour" );

    /* ------------- case 2: DXT1, three-colour punch-through (c0 <= c1) ---- */
    c0 = 0x001F;                          /* blue, the SMALLER value */
    c1 = 0xF800;                          /* red                      */
    e0 = expand565( c0 );
    e1 = expand565( c1 );
    build_bc1( block, c0, c1, IDX_0123 );
    hr = IDirect3DDevice9_CreateTexture( dev, TEX_W, TEX_H, 1, 0, D3DFMT_DXT1,
                                         D3DPOOL_MANAGED, &tex, NULL );
    if (FAILED(hr) || !tex) { log_hr( "CreateTexture DXT1 pt", hr ); ExitProcess( 59 ); }
    if (!upload_block( tex, block, 8 )) ExitProcess( 59 );
    if (!render_and_read( dev, rt, sysmem, (IDirect3DBaseTexture9 *)tex, px )) ExitProcess( 59 );
    check_texel( "dxt1.pt index0 = c0", 0, 0, px[0], e0, 0x00FFFFFF );
    check_texel( "dxt1.pt index1 = c1", 1, 0, px[1], e1, 0x00FFFFFF );
    check_texel( "dxt1.pt index2 = HALF blend", 2, 0, px[2], blend_rgb( e0, e1, 1, 1, 2 ), 0x00FFFFFF );
    /* Index 3 is transparent BLACK: colour zero and alpha zero. The colour is
     * what a wrong implementation gets wrong (it writes the 1/3 blend), and the
     * blend chain above passes texture alpha straight through, so both halves
     * of the rule are observable in the render target. */
    check_texel( "dxt1.pt index3 = transparent black", 3, 0, px[3], 0x00000000, 0xFFFFFFFF );
    check_texel( "dxt1.pt index0 alpha opaque", 0, 0, px[0] & 0xFF000000u, 0xFF000000u, 0xFF000000u );
    IDirect3DTexture9_Release( tex ); tex = NULL;
    log_line( "case 2 done: DXT1 punch-through" );

    /* ------------------ case 3: DXT3, explicit 4-bit alpha ---------------- */
    /* alpha nibbles, low nibble first: texel0=0x0 texel1=0xF texel2=0x8
     * texel3=0xA. Expansion is by replication, so 0x8 -> 0x88, 0xA -> 0xAA. */
    memset( block, 0, sizeof(block) );
    block[0] = (unsigned char)(0x0 | (0xF << 4));
    block[1] = (unsigned char)(0x8 | (0xA << 4));
    /* Colour half with c0 <= c1 on purpose: DXT3 must NOT punch through. */
    c0 = 0x001F;
    c1 = 0xF800;
    e0 = expand565( c0 );
    e1 = expand565( c1 );
    build_bc1( block + 8, c0, c1, IDX_0123 );
    hr = IDirect3DDevice9_CreateTexture( dev, TEX_W, TEX_H, 1, 0, D3DFMT_DXT3,
                                         D3DPOOL_MANAGED, &tex, NULL );
    if (FAILED(hr) || !tex) { log_hr( "CreateTexture DXT3", hr ); ExitProcess( 59 ); }
    if (!upload_block( tex, block, 16 )) ExitProcess( 59 );
    if (!render_and_read( dev, rt, sysmem, (IDirect3DBaseTexture9 *)tex, px )) ExitProcess( 59 );
    check_texel( "dxt3 alpha 0x0 -> 0x00", 0, 0, px[0] & 0xFF000000u, 0x00000000u, 0xFF000000u );
    check_texel( "dxt3 alpha 0xF -> 0xFF", 1, 0, px[1] & 0xFF000000u, 0xFF000000u, 0xFF000000u );
    check_texel( "dxt3 alpha 0x8 -> 0x88", 2, 0, px[2] & 0xFF000000u, 0x88000000u, 0xFF000000u );
    check_texel( "dxt3 alpha 0xA -> 0xAA", 3, 0, px[3] & 0xFF000000u, 0xAA000000u, 0xFF000000u );
    check_texel( "dxt3 colour index3 is 1/3 blend, not black", 3, 0, px[3] & 0x00FFFFFFu,
                 blend_rgb( e0, e1, 1, 2, 3 ), 0x00FFFFFF );
    IDirect3DTexture9_Release( tex ); tex = NULL;
    log_line( "case 3 done: DXT3 explicit alpha" );

    /* --------------- case 4: DXT5, interpolated alpha (a0 > a1) ----------- */
    memset( block, 0, sizeof(block) );
    block[0] = 255;                       /* a0 */
    block[1] = 0;                         /* a1 -- a0 > a1 selects 8 values  */
    /* three-bit alpha indices: texel0=0, texel1=1, texel2=2, texel3=7 */
    {
        unsigned int lo = 0u | (1u << 3) | (2u << 6) | (7u << 9);
        block[2] = (unsigned char)(lo & 0xff);
        block[3] = (unsigned char)((lo >> 8) & 0xff);
        block[4] = (unsigned char)((lo >> 16) & 0xff);
    }
    c0 = 0xFFFF;                          /* white */
    c1 = 0x0000;                          /* black */
    build_bc1( block + 8, c0, c1, 0 );    /* every texel index 0 = white */
    hr = IDirect3DDevice9_CreateTexture( dev, TEX_W, TEX_H, 1, 0, D3DFMT_DXT5,
                                         D3DPOOL_MANAGED, &tex, NULL );
    if (FAILED(hr) || !tex) { log_hr( "CreateTexture DXT5", hr ); ExitProcess( 59 ); }
    if (!upload_block( tex, block, 16 )) ExitProcess( 59 );
    if (!render_and_read( dev, rt, sysmem, (IDirect3DBaseTexture9 *)tex, px )) ExitProcess( 59 );
    check_texel( "dxt5 alpha index0 = a0 = 255", 0, 0, px[0] & 0xFF000000u, 0xFF000000u, 0xFF000000u );
    check_texel( "dxt5 alpha index1 = a1 = 0",   1, 0, px[1] & 0xFF000000u, 0x00000000u, 0xFF000000u );
    /* index 2 = (6*a0 + 1*a1 + 3)/7 = (6*255+3)/7 = 1533/7 = 219 = 0xDB */
    check_texel( "dxt5 alpha index2 = 6/7 of a0", 2, 0, px[2] & 0xFF000000u, 0xDB000000u, 0xFF000000u );
    /* index 7 = (1*a0 + 6*a1 + 3)/7 = (255+3)/7 = 36 = 0x24 */
    check_texel( "dxt5 alpha index7 = 1/7 of a0", 3, 0, px[3] & 0xFF000000u, 0x24000000u, 0xFF000000u );
    check_texel( "dxt5 colour index0 = white", 0, 0, px[0] & 0x00FFFFFFu, 0x00FFFFFFu, 0x00FFFFFF );
    IDirect3DTexture9_Release( tex ); tex = NULL;
    log_line( "case 4 done: DXT5 interpolated alpha" );

    IDirect3DSurface9_Release( sysmem );
    IDirect3DSurface9_Release( rt );
    IDirect3DDevice9_Release( dev );
    IDirect3D9_Release( d3d );
    DestroyWindow( hwnd );

    {
        char buf[160];
        char *p = put_str( buf, "MADEIRA-D3D9DXT: " );
        p = put_uint( p, g_checks );
        p = put_str( p, " checks, " );
        p = put_uint( p, g_failures );
        p = put_str( p, " failures -- " );
        p = put_str( p, g_failures ? "FAIL" : "PASS" );
        *p++ = '\n'; *p = 0;
        out_str( buf );
    }
    ExitProcess( g_failures ? 60 : 57 );
}
