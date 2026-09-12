/* MADEIRA-TEMP: milestone-2 windowed smoke test PE for Madeira's WoW64 (i386)
 * path. See WOW64_DESIGN.md section 5, milestone 2: a minimal windowed
 * 32-bit PE exercising user32/gdi32/win32u (message loop, WM_PAINT, a timer)
 * instead of just kernel32 (hello-x86.exe, milestone 1).
 *
 * No CRT: this file supplies its own PE entry point (`start`, which the
 * i386 Windows C ABI mangles to the symbol `_start`) and is linked with
 * -nostdlib, so the only DLLs this exe imports are kernel32.dll, user32.dll
 * and gdi32.dll -- verified with `i686-w64-mingw32-objdump -p window-x86.exe`
 * (see build.sh).
 *
 * The paint check is deliberately two-sided, because the two ways a window
 * gets a WM_PAINT exercise different plumbing:
 *   - QUEUED: the window's update region lives in the wineserver, which sets
 *     the queue's QS_PAINT bit and synthesizes WM_PAINT from get_message().
 *     This is what a normal show/expose produces and what the twelfth device
 *     run never delivered.
 *   - SYNCHRONOUS: UpdateWindow() -> NtUserRedrawWindow( RDW_UPDATENOW ),
 *     which sends WM_PAINT directly to the window procedure, bypassing the
 *     queue entirely.
 * Logging which one arrived tells us whether the queue path or the whole
 * invalidate/paint path is broken.
 */
#include <windows.h>

static int g_painted = 0;
static int g_ticks = 0;
static int g_in_loop = 0;     /* set just before the GetMessage loop */

static void write_log(const char *msg, DWORD len)
{
    HANDLE h = GetStdHandle(STD_ERROR_HANDLE);
    DWORD written = 0;
    WriteFile(h, msg, len, &written, NULL);
}

/* no CRT (no strlen either), so the prefix length is always passed in and the
 * one number we print is formatted by hand */
static void write_uint_line(const char *prefix, DWORD prefix_len, unsigned int value)
{
    char buf[16];
    int i = (int)(sizeof(buf));

    buf[--i] = '\n';
    if (!value) buf[--i] = '0';
    else while (value && i > 0)
    {
        buf[--i] = (char)('0' + (value % 10));
        value /= 10;
    }
    write_log(prefix, prefix_len);
    write_log(buf + i, (DWORD)(sizeof(buf) - i));
}

#define WRITE_UINT_LINE(lit, value) \
    write_uint_line( (lit), (DWORD)(sizeof(lit) - 1), (unsigned int)(value) )

static LRESULT CALLBACK WndProc(HWND hwnd, UINT msg, WPARAM wParam, LPARAM lParam)
{
    switch (msg)
    {
    case WM_PAINT:
    {
        PAINTSTRUCT ps;
        HDC hdc = BeginPaint(hwnd, &ps);
        static const WCHAR text[] = L"Madeira 32-bit window test";
        TextOutW(hdc, 10, 10, text, (sizeof(text) / sizeof(WCHAR)) - 1);
        EndPaint(hwnd, &ps);

        if (!g_painted)
        {
            g_painted = 1;
            static const char paintedMsg[] = "MADEIRA-X86-32-WINDOW: painted\n";
            static const char queueMsg[] = "MADEIRA-X86-32-WINDOW: painted-via-queue\n";
            static const char syncMsg[] = "MADEIRA-X86-32-WINDOW: painted-via-updatewindow\n";
            write_log(paintedMsg, sizeof(paintedMsg) - 1);
            if (g_in_loop)
                write_log(queueMsg, sizeof(queueMsg) - 1);
            else
                write_log(syncMsg, sizeof(syncMsg) - 1);
        }
        return 0;
    }
    case WM_TIMER:
        g_ticks++;
        if (g_ticks >= 20)
            DestroyWindow(hwnd);
        return 0;
    case WM_DESTROY:
        PostQuitMessage(43);
        return 0;
    default:
        return DefWindowProcW(hwnd, msg, wParam, lParam);
    }
}

void start(void)
{
    HINSTANCE hInstance = GetModuleHandleW(NULL);
    static const WCHAR className[] = L"MadeiraX86WindowTest";
    WNDCLASSW wc;
    HWND hwnd;
    MSG msg;
    BOOL invalidated, updated;
    static const char createdMsg[] = "MADEIRA-X86-32-WINDOW: created hwnd\n";

    wc.style = 0;
    wc.lpfnWndProc = WndProc;
    wc.cbClsExtra = 0;
    wc.cbWndExtra = 0;
    wc.hInstance = hInstance;
    wc.hIcon = NULL;
    wc.hCursor = LoadCursorW(NULL, (LPCWSTR)IDC_ARROW);
    wc.hbrBackground = (HBRUSH)(COLOR_WINDOW + 1);
    wc.lpszMenuName = NULL;
    wc.lpszClassName = className;

    RegisterClassW(&wc);

    hwnd = CreateWindowExW(0, className, className,
                            WS_OVERLAPPEDWINDOW | WS_VISIBLE,
                            CW_USEDEFAULT, CW_USEDEFAULT, 320, 240,
                            NULL, NULL, hInstance, NULL);

    SetTimer(hwnd, 1, 100, NULL);

    write_log(createdMsg, sizeof(createdMsg) - 1);

    /* Force the queue-independent path as well: InvalidateRect puts an update
     * region on the window (server-side), UpdateWindow then sends WM_PAINT
     * synchronously via NtUserRedrawWindow( RDW_UPDATENOW ). If "painted"
     * appears with "painted-via-updatewindow" but never with
     * "painted-via-queue", invalidation works and the queue's QS_PAINT /
     * get_message synthesis is at fault; if neither appears, the
     * invalidate/update-region path itself is broken. */
    invalidated = InvalidateRect(hwnd, NULL, TRUE);
    updated = UpdateWindow(hwnd);
    WRITE_UINT_LINE("MADEIRA-X86-32-WINDOW: invalidate-rect returned ", invalidated);
    WRITE_UINT_LINE("MADEIRA-X86-32-WINDOW: update-window returned ", updated);

    g_in_loop = 1;
    while (GetMessageW(&msg, NULL, 0, 0))
    {
        TranslateMessage(&msg);
        DispatchMessageW(&msg);
    }

    ExitProcess((UINT)msg.wParam);
}
