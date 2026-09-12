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
 */
#include <windows.h>

static int g_painted = 0;
static int g_ticks = 0;

static void write_log(const char *msg, DWORD len)
{
    HANDLE h = GetStdHandle(STD_ERROR_HANDLE);
    DWORD written = 0;
    WriteFile(h, msg, len, &written, NULL);
}

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
            write_log(paintedMsg, sizeof(paintedMsg) - 1);
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

    while (GetMessageW(&msg, NULL, 0, 0))
    {
        TranslateMessage(&msg);
        DispatchMessageW(&msg);
    }

    ExitProcess((UINT)msg.wParam);
}
