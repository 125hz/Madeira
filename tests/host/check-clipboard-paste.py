#!/usr/bin/env python3
"""Compile the production paste planner, bounded queue and Unicode driver on a host."""
from pathlib import Path
import os
import subprocess
import tempfile

root = Path(__file__).resolve().parents[2]
app = root / 'app/Madeira'
hardware = (app / 'HardwareInput.swift').read_text()
pure = hardware.split('// MARK: - Pure input mapping', 1)[1].split('// MARK: - Device glue', 1)[0]
swift = r'''
func strokes(_ text: String) -> [PasteStroke] {
    var paste = PasteText(text), result: [PasteStroke] = []
    while let next = paste.next { result.append(next); paste.advance() }
    return result
}
let text = strokes("aA0!_+\\\"\r\n中文😀e\u{301}\r\t\0\u{8}\u{1b}\u{7f}")
assert(text.map(\.scalar) == [97,65,48,33,95,43,92,34,10,0x4e2d,0x6587,0x1f600,101,0x301,10,9])
assert(text.prefix(9).map(\.vk) == [0x41,0x41,0x30,0x31,0xbd,0xbb,0xdc,0xde,0x0d])
assert(text.prefix(8).map(\.shift) == [false,true,false,true,true,true,false,true])
assert(text[9].vk == 0 && text[10].vk == 0 && text[11].vk == 0 && text[13].vk == 0)
assert(PasteText.key(for: "ß") == nil)
assert(strokes("").isEmpty && strokes("\0\u{8}\u{1b}").isEmpty)
assert(strokes(String(repeating: "中A!", count: 10000)).count == 30000)
for cmd: Int32 in [0x5b, 0x5c] {
    assert(PasteText.isCommandV(0x56, held: [cmd,0x56]))
    assert(!PasteText.isCommandV(0x56, held: [cmd,0x56,0xa0])) // Cmd-Shift-V stays a guest chord
}
assert(!PasteText.isCommandV(0x56, held: [0xa2,0x56])) // Ctrl-V remains Windows paste
assert(!PasteText.isCommandV(0x56, held: [0x56]))
assert(!PasteText.isCommandV(0x41, held: [0x5b,0x41]))
var held = FocusGate<Int32>()
for key: Int32 in [0x5b,0x56] { held.press(key, focused: true) }
for key in held.physical { held.block(key) }
assert(held.wanted(focused: true).isEmpty)
held.release(0x56); held.release(0x5b)
held.press(0x41, focused: true)
assert(held.wanted(focused: true) == [0x41])
print("PASS: paste text, ASCII symbols/case, CRLF, Chinese, combining marks, emoji, long text, chord and held keys")
'''
bridge = (app / 'Winios/Winios.m').read_text()
queue = bridge[bridge.index('#define WINIOS_RING_SIZE'):bridge.index('static void winios_game_cursor_touch(int x, int y);')]
driver = (root / 'build/win32u-unix/driver_ios.c').read_text()
text_driver = driver[driver.index('static void winios_text_key('):driver.index('/* [winios-tree]')]
c = r'''
#include <assert.h>
#include <pthread.h>
#include <stdatomic.h>
#include <stdio.h>
#include <stddef.h>
#define INPUT_KEYBOARD 1
#define KEYEVENTF_KEYUP 0x0002
#define KEYEVENTF_UNICODE 4
#define VK_SHIFT 0x10
#define VK_CAPITAL 0x14
#define MAPVK_VK_TO_VSC_EX 4
typedef struct { unsigned short wVk, wScan; unsigned int dwFlags, time; unsigned long dwExtraInfo; } KEYBDINPUT;
typedef struct { unsigned int type; KEYBDINPUT ki; } INPUT;
static INPUT sent[32];
static int n, caps;
static int NtUserGetKeyState(int vk) { return caps; }
static int NtUserGetKeyboardLayout(int unused) { return 0; }
static unsigned int NtUserMapVirtualKeyEx(int vk, int mode, int layout) { return vk + 1; }
static void ios_foreground_if_none(const char *reason) {}
static int send_hardware_message(void *window, int flags, const INPUT *input, int unused) {
    assert(n < 32); sent[n++] = *input; return 0;
}
'''+text_driver+queue+r'''
static void drain(void) {
    while (g_input_q.tail != g_input_q.head) {
        winios_input_event_t e = g_input_q.buf[g_input_q.tail];
        g_input_q.tail = (g_input_q.tail + 1) % WINIOS_RING_SIZE;
        winios_drain_text(&e);
    }
}
static void expect_unit(int at, unsigned int unit) {
    assert(sent[at].ki.wVk == 0 && sent[at].ki.wScan == unit && sent[at].ki.dwFlags == 4);
    assert(sent[at+1].ki.wVk == 0 && sent[at+1].ki.wScan == unit && sent[at+1].ki.dwFlags == 6);
}
int main(void) {
    assert(winios_try_post_text(0x4e2d, 0, 0)); drain();
    assert(n == 2); expect_unit(0, 0x4e2d);
    n = 0; assert(winios_try_post_text(0x1f600, 0, 0)); drain();
    assert(n == 4); expect_unit(0, 0xd83d); expect_unit(2, 0xde00);
    n = 0; winios_drv_post_text(0xd800, 0, 0); winios_drv_post_text(0x110000, 0, 0); assert(!n);
    assert(winios_try_post_text('A', 'A', 1)); drain();
    assert(n == 4 && sent[0].ki.wVk == VK_SHIFT && sent[0].ki.dwFlags == 0);
    assert(sent[1].ki.wVk == 'A' && sent[1].ki.wScan == 'A'+1 && sent[1].ki.dwFlags == 0);
    assert(sent[2].ki.dwFlags == 2 && sent[3].ki.wVk == VK_SHIFT && sent[3].ki.dwFlags == 2);
    caps = 1; n = 0; winios_drv_post_text('A', 'A', 1); assert(n == 2);
    n = 0; winios_drv_post_text('a', 'A', 0); assert(n == 4); caps = 0;
    n = 0; assert(winios_try_post_text('a', 'A', 0)); winios_cancel_text(); drain(); assert(n == 0);
    for (int i = 0; i < WINIOS_RING_SIZE - 16; i++) assert(winios_try_post_text('a', 'A', 0));
    unsigned int before = g_input_q.head;
    assert(!winios_try_post_text('b', 'B', 0) && g_input_q.head == before);
    winios_q_push_ev(WINIOS_EV_KEY, 0x5b, 0, KEYEVENTF_KEYUP, 0);
    assert(g_input_q.head != before); // queue pressure never steals the reserved release slots
    winios_cancel_text(); drain(); assert(!n);
    assert(winios_try_post_text('b', 'B', 0)); drain(); assert(n == 2 && sent[0].ki.wVk == 'B');
    puts("PASS: bounded retry, reserved key-up slots, cancellation, Unicode BMP/surrogates, ASCII and Caps Lock");
}
'''
with tempfile.TemporaryDirectory(prefix='madeira-paste-') as temp:
    temp = Path(temp)
    (temp / 'main.swift').write_text('import Foundation\n'+pure+swift)
    subprocess.run([os.environ.get('SWIFTC', 'swiftc'), str(temp/'main.swift'), '-o', str(temp/'swift-test')], check=True)
    subprocess.run([str(temp/'swift-test')], check=True)
    (temp/'test.c').write_text(c)
    subprocess.run([os.environ.get('CC', 'cc'), '-std=c11', '-pthread', str(temp/'test.c'), '-o', str(temp/'c-test')], check=True)
    subprocess.run([str(temp/'c-test')], check=True)

assert 'if (winios_drain_text(&e))' in bridge
assert 'if pressed { cancelPaste() }' in hardware
assert 'if !keyboard { keys.focusLost(); deferredCommands.removeAll(); cancelPaste() }' in hardware
assert '!(fr is LibraryKeyInput)' in hardware
assert 'guard canPaste, let text = UIPasteboard.general.string' in hardware
library = (app/'Library.swift').read_text()
assert 'PasteButton(payloadType: String.self)' in library
assert 'if HardwareInput.shared.handlesTyping { return }' in library.split('final class LibraryKeyInput:', 1)[1]
print('PASS: focus cancellation, explicit clipboard read, native-field isolation and both text input bridges wired')
