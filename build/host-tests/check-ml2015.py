#!/usr/bin/env python3
"""ml2015 host checks (device logs 108-110); never runs Wine, Steam or iOS.

* Log 108: the install batch's `dockhost.exe --start-services` exited normally before the
  installers ran; the app took that for the Dock's exit, ended the start and deleted the
  one-use sign-in transfer, so the real host failed with 37. Only the host's own exit counts
  now. The skip logic is compiled from WineProcessBridge.m and exercised here.
* Log 108: an MSI custom action "returned" 5 (DuplicateHandle across processes failed with
  STATUS_PROCESS_IS_TERMINATING, because iOS cannot signal a busy thread). The wineserver
  queues such a process-wide system APC on a live thread instead.
* Log 109: a game's main window was first shown minimized; the census posts SC_RESTORE once.
* Log 110: Valve's client refused a launch with 35 (another session playing); the app knows
  the Dock's new session-wait fields.
* Owner request: the starting screen's controls are one row of glyph buttons.
"""
from pathlib import Path
import os, re, shutil, subprocess, tempfile

root = Path(__file__).resolve().parents[2]
app = root / 'app/Madeira'
lib = (app / 'Library.swift').read_text(encoding='utf-8')
dock = (app / 'MadeiraDock.swift').read_text(encoding='utf-8')
bridge = (app / 'WineProcessBridge.m').read_text(encoding='utf-8')
winios = (app / 'Winios/Winios.m').read_text(encoding='utf-8')
header = (app / 'Winios/Winios.h').read_text(encoding='utf-8')
server = (root / 'wine/server/thread.c').read_text(encoding='utf-8')

# 1. Dock exit skip: extract the three bridge functions and run them.
start = bridge.index('// ml2015: dockhost.exe exits to skip')
end = bridge.index('static char *g_prefix_path')
chunk = bridge[start:end]
prelude = bridge[bridge.index('static uint64_t g_dock_exit = 0;'):start]
harness = r'''
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <strings.h>
#include <assert.h>
''' + prelude + chunk + r'''
int main(void) {
    int status = -1;
    wine_dock_exit_reset();
    wine_dock_exit_skip_next();
    wine_process_did_exit("dockhost.exe", 0);           /* the --start-services step */
    assert(!wine_dock_exit_status(&status));
    wine_process_did_exit("msiexec.exe", 1603);         /* an installer: never the Dock */
    assert(!wine_dock_exit_status(&status));
    wine_process_did_exit("DOCKHOST.EXE", 45);          /* the host's own exit */
    assert(wine_dock_exit_status(&status) && status == 45);
    wine_dock_exit_reset();                             /* no batch: the first exit counts */
    wine_process_did_exit("dockhost.exe", 37);
    assert(wine_dock_exit_status(&status) && status == 37);
    wine_dock_exit_reset();                             /* reset also clears a pending skip */
    wine_dock_exit_skip_next(); wine_dock_exit_reset();
    wine_process_did_exit("dockhost.exe", 0);
    assert(wine_dock_exit_status(&status) && status == 0);
    puts("PASS: the batch's service-manager exit is skipped once; the host's own exit is reported");
    return 0;
}
'''
cc = os.environ.get('CC') or shutil.which('clang') or os.path.expanduser('~/.local/share/swiftly/bin/clang')
with tempfile.TemporaryDirectory(prefix='madeira-ml2015-') as tmp:
    src = Path(tmp) / 'skip.c'
    src.write_text(harness)
    subprocess.run([cc, '-std=gnu11', '-fsanitize=address,undefined', '-Wall', '-Werror', '-Wno-unused-function',
                    str(src), '-o', str(Path(tmp) / 'skip')], check=True)
    subprocess.run([str(Path(tmp) / 'skip')], check=True)

assert 'MadeiraDock.installerServicesStep = report && services != .off' in lib
assert 'LibraryFlags.enabled("MADEIRA_DOCK_SERVICES_EXIT_SKIP")' in lib and 'wine_dock_exit_skip_next()' in lib
assert lib.index('wine_dock_exit_reset()') < lib.index('wine_dock_exit_skip_next()'), 'skip armed after the reset'

# 2. wineserver: the fallback only runs when no waiting or signalable thread was found.
body = server[server.index('static int queue_apc( struct process *process'):]
body = body[:body.index('\n}\n')]
assert re.search(r'#ifdef WINE_IOS\s+if \(!thread\) thread = ios_process_apc_fallback\( process, apc \);\s+#endif\s+'
                 r'if \(!thread\) return 0;', body), 'fallback sits between the signal loop and the failure'
fb = server[server.index('static struct thread *ios_process_apc_fallback'):]
fb = fb[:fb.index('\n}\n')]
assert 'MADEIRA_PROCESS_APC_QUEUE' in fb and 'candidate->state == TERMINATED' in fb and 'malloc' not in fb
print('PASS: process-wide system APCs fall back to a live thread (MADEIRA_PROCESS_APC_QUEUE=0 fails them)')

# 3. Born-minimized restore: once, only for a window never shown, only while the census runs.
assert 'unsigned char shown_once;' in header and 'unsigned char restore_sent;' in header and 'reserved[2]' not in header
note = winios[winios.index('static void winios_census_note_frame'):]
note = note[:note.index('\n}\n')]
assert "!atomic_load_explicit(&g_census_on" in note, 'only while the census runs'
assert '!e->shown_once && !e->restore_sent' in note and 'e->restore_sent = 1;' in note
assert note.index('pthread_mutex_unlock(&g_census_lock);') < note.index('NtUserPostMessage('), 'posted outside the lock'
assert 'WINIOS_SC_RESTORE    0xF120u' in winios and 'WINIOS_WM_SYSCOMMAND 0x0112u' in winios
print('PASS: a window first shown minimized gets one SC_RESTORE (MADEIRA_RESTORE_BORN_MINIMIZED=0 off)')

# 4. Session wait (error 35) fields, round and words.
assert '"launch-session-wait", "launch-session-gave-up"' in dock and '"ml2011", "ml2015"]' in dock
assert 'case 35:' in dock and 'fields["launch-session-wait"] != nil' in dock
assert 'report.fields["launch-client-error"] == "35"' in lib
print('PASS: the app reads the Dock session wait (error 35)')

# 5. Glyph row.
row = lib[lib.index('ml2015 (owner request): one row of glyph-only buttons'):]
row = row[:row.index('if model.steamHolding {\n                    // ml1990')]
assert 'HStack(spacing: 14)' in row
for label in ['"Close session", "stop.circle"', '"Hide live log" : "Show live log", "text.alignleft"',
              '"Show desktop" : "Show Steam", "macwindow"']:
    assert label in row, label
assert 'Button("Close session"' not in lib and '.accessibilityLabel(label)' in lib
print('PASS: close / live log / desktop are one row of glyph buttons with VoiceOver labels')

# 6. Logs 111/112 follow-ups.
views = (app / 'SteamStoreViews.swift').read_text(encoding='utf-8')
content = (app / 'ContentView.swift').read_text(encoding='utf-8')
madsync = (root / 'build/madsync/madsync.c').read_text(encoding='utf-8')
driver = (root / 'build/win32u-unix/driver_ios.c').read_text(encoding='utf-8')
dock_main = (root.parent / 'madeira-dock/src/main.c').read_text(encoding='utf-8')
assert 'var steamInstallersNext: Bool?' in lib and 'Picker("One-time installs"' in views
assert 'Text("Run at next start").tag(true)' in views and 'Text("Skip").tag(false)' in views
assert 'entry.steamInstallersNext == false && !pending.isEmpty' in lib and 'stored.steamInstallersNext = false' in lib
assert 'func skipDockInstallers()' in lib and 'model.skipDockInstallers()' in lib
print('PASS: game details › One-time installs (fresh install runs once, then Skip) and a Dock skip button')
assert 'let forceFast = madsync && !pending.isEmpty' in lib and 'MadeiraDock.installerSessionFastsync = forceFast' in lib
assert 'setenv("MADEIRA_MADSYNC_SESSION", "0", 1)' in content and 'unsetenv("MADEIRA_MADSYNC_SESSION")' in content
assert 'getenv( "MADEIRA_MADSYNC_SESSION" )' in madsync
assert 'SH_INSTALL_SCM_STEP_MS' in dock_main and 'printf("services timeout\\n")' in dock_main
print('PASS: a start with one-time installs runs on fastsync; the service step is bounded (20 s)')
assert 'int winios_drv_foreground_if_owner( HWND hwnd )' in driver and 'GetCurrentThreadId()' in driver
assert 'atomic_store(&g_restore_foreground, (uintptr_t)hwnd);' in winios and 'winios_drv_foreground_if_owner((HWND)fg)' in winios
print('PASS: a restored born-minimized window is brought to the front by its own thread')
assert 'Add complete application folders' not in lib
for who in ['name: "Will Faust", handle: "willfaust"', 'name: "Nick", handle: "125hz"', 'name: "Jfishin", handle: "Jfishin"']:
    assert who in lib, who
assert lib.index('header: { Text("Credits") }') > lib.index('header: { Text("Interface") }'), 'credits last'
print('PASS: Settings: the drive_c note is gone and Credits is the last section')
