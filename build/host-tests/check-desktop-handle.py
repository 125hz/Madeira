#!/usr/bin/env python3
"""Check native desktop lookup/ancestor/rectangle code with a mock handle table.

This runs no Wine process, game, or emulator. The server-only desktop entry has
the caller's process id and a NULL client object, as in forced desktop creation.
"""
from pathlib import Path
import subprocess
import tempfile

root = Path(__file__).resolve().parents[2]
source = (root / 'wine/dlls/win32u/window.c').read_text()


def function(signature):
    start = source.index(signature)
    return source[start:source.index('\n}', start) + 2]


code = r'''
#include <assert.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#define WINE_IOS 1
#define TRUE 1
#define FALSE 0
#define WINAPI
#define NTUSER_OBJ_WINDOW 1
#define ERROR_INVALID_WINDOW_HANDLE 1400
#define GA_PARENT 1
#define GA_ROOT 2
#define GA_ROOTOWNER 3
typedef int BOOL;
typedef unsigned int UINT;
typedef uint32_t user_handle_t;
typedef void *HWND;
typedef struct { HWND parent; } WND;
typedef struct { int left,top,right,bottom; } RECT;
enum coords_relative { COORDS_SCREEN };
struct window_rects { RECT window, client, visible; };
#define WND_OTHER_PROCESS ((WND *)1)
#define WND_DESKTOP ((WND *)2)
#define H(n) ((HWND)(uintptr_t)(n))
static WND local[40];
static int locks, stale, foreign, real_desktop;
static BOOL is_desktop_window(HWND h) { return h == H(1) || h == H(2); }
static BOOL is_valid_entry(HWND h, int type) { (void)type; return h && !stale; }
static WND *get_user_handle_ptr(HWND h, int type)
{
    (void)type;
    if (stale || !h) return NULL;
    if (foreign) return WND_OTHER_PROCESS;
    if (is_desktop_window(h) && !real_desktop) return NULL;
    if ((uintptr_t)h >= 40) return NULL;
    ++locks;
    return &local[(uintptr_t)h];
}
static void release_win_ptr(WND *w) { assert(w >= local && w < local+40); --locks; }
static HWND get_full_window_handle(HWND h) { return h; }
static HWND get_parent(HWND h) { return local[(uintptr_t)h].parent; }
static void RtlSetLastWin32Error(int e) { (void)e; }
static HWND get_hwnd_message_parent(void) { return H(2); }
static UINT get_dpi_for_window(HWND h) { (void)h; return 96; }
static RECT map_dpi_rect(RECT r, UINT from, UINT to) { (void)from; (void)to; return r; }
static RECT get_primary_monitor_rect(UINT dpi) { (void)dpi; return (RECT){0,0,1280,720}; }
struct request { user_handle_t handle, parent; int count; };
#define SERVER_START_REQ(name) do { struct request r={0}, p={0}; struct request *req=&r, *reply=&p;
#define SERVER_END_REQ } while (0)
#define wine_server_user_handle(h) ((user_handle_t)(uintptr_t)(h))
#define wine_server_ptr_handle(h) H(h)
static void wine_server_set_reply(struct request *r, void *p, size_t n) { (void)r; (void)p; (void)n; }
static int wine_server_call(struct request *r) { (void)r; assert(!"unexpected server fallback"); return 1; }
#define wine_server_call_err wine_server_call
'''
for signature in ['WND *get_win_ptr(', 'static HWND *list_window_parents(',
                  'HWND WINAPI NtUserGetAncestor(']:
    code += '\n' + function(signature) + '\n'

# The desktop-specific branches of the production rectangle query, before its
# unrelated local/cross-process rectangle handling.
rect = function('BOOL get_window_rects(')
code += rect[:rect.index('    if (win != WND_OTHER_PROCESS)')]
code += '\n    (void)relative; (void)ret; return FALSE;\n}\n'
code += r'''
int main(void)
{
    local[3].parent=H(1);  /* top-level dialog */
    for (int n=4; n<40; ++n) local[n].parent=H(n-1);  /* deeply nested controls */
    for (int enabled=0; enabled<=1; ++enabled)
    {
        setenv("MADEIRA_DESKTOP_HANDLE_FIX", enabled ? "1" : "0", 1);
        assert(get_win_ptr(H(1)) == (enabled ? WND_DESKTOP : NULL));
        for (int n=3; n<40; ++n)
            assert(NtUserGetAncestor(H(n),GA_ROOT) == (enabled ? H(3) : NULL));
        struct window_rects r={0};
        assert(get_window_rects(H(1),COORDS_SCREEN,&r,96) == enabled);
        if (enabled)
        {
            assert(r.window.right==1280 && r.window.bottom==720);
            assert(r.client.right==1280 && r.client.bottom==720);
            assert(r.visible.right==1280 && r.visible.bottom==720);
            /* A centered 382x659 dialog and all its buttons fit on screen. */
            assert((r.client.right-382)/2==449 && (r.client.bottom-659)/2==30);
        }
        assert(locks==0);
    }
    unsetenv("MADEIRA_DESKTOP_HANDLE_FIX");
    assert(get_win_ptr(H(1))==WND_DESKTOP);
    assert(get_win_ptr(H(2))==WND_DESKTOP);
    struct window_rects r={0};
    assert(get_window_rects(H(2),COORDS_SCREEN,&r,96) && r.client.right==100);
    assert(NtUserGetAncestor(H(4),GA_PARENT)==H(3));
    assert(!NtUserGetAncestor(H(1),GA_PARENT));
    assert(!get_win_ptr(NULL) && !get_win_ptr(H(99)));
    stale=1; assert(!get_win_ptr(H(1))); stale=0;
    foreign=1; assert(get_win_ptr(H(1))==WND_DESKTOP);
    assert(get_win_ptr(H(3))==WND_OTHER_PROCESS); foreign=0;
    real_desktop=1; WND *w=get_win_ptr(H(1));
    assert(w==&local[1] && locks==1); release_win_ptr(w);
    assert(locks==0);
    puts("PASS: server-only desktop, ancestors, screen bounds, rollback, stale/foreign/local handles, and lock balance");
}
'''
with tempfile.TemporaryDirectory(prefix='madeira-desktop-check-') as directory:
    path = Path(directory)
    (path / 'check.c').write_text(code)
    subprocess.run(['cc', '-std=gnu11', '-Wall', '-Wextra', '-Werror',
                    '-fsanitize=address,undefined', '-o', str(path / 'check'),
                    str(path / 'check.c')], check=True)
    subprocess.run([str(path / 'check')], check=True)
