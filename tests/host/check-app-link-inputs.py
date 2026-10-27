#!/usr/bin/env python3
"""Check the source membership and native exports required by the iOS app link."""
from pathlib import Path
import collections
import plistlib
import re
import subprocess
import tempfile

root = Path(__file__).resolve().parents[2]


def function(source, head):
    start = source.index(head)
    end = source.index('{', start) + 1
    depth = 1
    while depth:
        depth += (source[end] == '{') - (source[end] == '}')
        end += 1
    return source[start:end]


project = root / 'app/Madeira.xcodeproj/project.pbxproj'
ids = re.findall(r'^\s*([A-F0-9]+) /\*.*?\*/ = \{', project.read_text(), re.M)
duplicates = [key for key, count in collections.Counter(ids).items() if count > 1]
assert not duplicates, duplicates
objects = plistlib.loads(subprocess.check_output(['plutil', '-convert', 'xml1', '-o', '-', str(project)]))['objects']
sources = objects['A3000002']['files']
paths = [objects[objects[key]['fileRef']]['path'] for key in sources]
for name in ['PhonePointer.m', 'GestureZones.swift']:
    assert paths.count(name) == 1, (name, paths.count(name))
print('PASS unique project IDs and both pointer/gesture sources included once')

virtual = (root / 'build/ntdll-unix/virtual_ios.c').read_text()
adapter = (root / 'build/win32u-unix/vulkan_ios.c').read_text()
bridge = (root / 'app/Madeira/WineProcessBridge.m').read_text()
assert 'madeira_vulkan_symbol' not in bridge, 'optional backend must not be an app link dependency'
with tempfile.TemporaryDirectory(prefix='madeira-app-link-') as folder:
    folder = Path(folder)

    def run_probe(name, source, flags=()):
        path = folder / name
        path.write_text(source)
        exe = folder / 'probe'
        subprocess.run(['xcrun', 'clang', '-Wall', '-Werror', str(path), '-o', str(exe), *flags], check=True)
        subprocess.run([str(exe)], check=True)

    run_probe('protection.c', '''
#include <assert.h>
#include <stdint.h>
#include <mach/mach.h>
#include <mach/mach_vm.h>
#include <sys/mman.h>
#include <unistd.h>
''' + function(virtual, 'static int ios_query_host_region(') + '\n' +
        function(virtual, 'int ios_addr_max_prot(') + '''
int main(void)
{
    size_t page = (size_t)sysconf(_SC_PAGESIZE);
    char *map = mmap(NULL, page * 3, PROT_READ | PROT_WRITE, MAP_PRIVATE | MAP_ANON, -1, 0);
    assert(map != MAP_FAILED);
    int current = -1, maximum = ios_addr_max_prot(map, &current);
    assert(current == (VM_PROT_READ | VM_PROT_WRITE));
    assert(maximum >= 0 && (maximum & current) == current);
    assert(ios_addr_max_prot(map + page - 1, NULL) == maximum);
    assert(mprotect(map, page, PROT_READ) == 0);
    assert(ios_addr_max_prot(map, &current) == maximum && current == VM_PROT_READ);
    assert(munmap(map + page, page) == 0);
    current = 123;
    assert(ios_addr_max_prot(map + page, &current) == -1 && current == 123);
    assert(ios_addr_max_prot(map + page * 2 - 1, &current) == -1 && current == 123);
    assert(ios_addr_max_prot(map + page * 2, &current) >= 0);
    current = 456;
    assert(ios_addr_max_prot((void *)UINTPTR_MAX, &current) == -1 && current == 456);
    assert(munmap(map, page) == 0 && munmap(map + page * 2, page) == 0);
}
''')
    print('PASS real Mach protection query, read-only pages, region holes and failed queries')

    vulkan = '''
#import <Foundation/Foundation.h>
#include <assert.h>
#include <dlfcn.h>
#include <stdio.h>
#include <string.h>
#include <unistd.h>
static const char *setting;
static BOOL wants_d3d;
static int madeira_cfg_get(const char *key, char *value, size_t size)
{
    assert(!strcmp(key, "vulkan"));
    if (!setting) return 0;
    snprintf(value, size, "%s", setting);
    return 1;
}
static BOOL madeira_d3d12_vkd3d_wanted(void) { return wants_d3d; }
static BOOL madeira_d3d11_dxvk_wanted(void) { return wants_d3d; }
#if MADEIRA_MOLTENVK
void *madeira_vulkan_symbol(const char *name) { assert(!strcmp(name, "probe")); return (void *)42; }
#endif
static char ios_vulkan_token;
''' + '\n'.join(function(adapter, head) for head in [
        'int madeira_vulkan_static_available(', 'static void *ios_vulkan_open(',
        'static void *ios_vulkan_sym(', 'static int ios_vulkan_close(',
    ]) + '\n' + function(bridge, 'static NSString *madeira_vulkan_library(') + '''
int main(void)
{
    @autoreleasepool {
        NSString *bundle = @"/bundle";
        assert(madeira_vulkan_library(bundle) == nil);
        for (setting = "static"; setting; setting = !strcmp(setting, "static") ? "1" : NULL) {
            NSString *library = madeira_vulkan_library(bundle);
#if MADEIRA_MOLTENVK
            assert([library isEqualToString:@"madeira-static-moltenvk"]);
            void *handle = ios_vulkan_open("madeira-static-moltenvk", RTLD_NOW);
            assert(handle && ios_vulkan_sym(handle, "probe") == (void *)42);
#else
            assert(!library && !ios_vulkan_open("madeira-static-moltenvk", RTLD_NOW));
            assert(!ios_vulkan_sym(&ios_vulkan_token, "probe"));
#endif
            assert(ios_vulkan_close(&ios_vulkan_token) == 0);
        }
        wants_d3d = YES;
        assert([madeira_vulkan_library(bundle) isEqualToString:@"/bundle/gl/libMoltenVK.dylib"]);
        setting = "off";
        assert(!madeira_vulkan_library(bundle));
        setting = "moltenvk";
        assert([madeira_vulkan_library(bundle) isEqualToString:@"/bundle/gl/libMoltenVK.dylib"]);
        setting = "kosmickrisp";
        assert([madeira_vulkan_library(bundle) isEqualToString:@"/bundle/gl/libvulkan_kosmickrisp.dylib"]);
        setting = "gl/custom.dylib";
        assert([madeira_vulkan_library(bundle) isEqualToString:@"/bundle/gl/custom.dylib"]);
        setting = "/custom.dylib";
        assert([madeira_vulkan_library(bundle) isEqualToString:@"/custom.dylib"]);
    }
}
'''
    for flags in [[], ['-DMADEIRA_MOLTENVK=0'], ['-DMADEIRA_MOLTENVK=1']]:
        run_probe('vulkan.m', vulkan, [*flags, '-fobjc-arc', '-framework', 'Foundation'])
    print('PASS real Vulkan bridge/native linkage with absent, zero and enabled static-backend flags')

    sdk = subprocess.check_output(['xcrun', '--sdk', 'iphoneos', '--show-sdk-path'], text=True).strip()
    obj = folder / 'PhonePointer.o'
    subprocess.run(['xcrun', 'clang', '-target', 'arm64-apple-ios18.0', '-isysroot', sdk,
                    '-fobjc-arc', '-c', str(root / 'app/Madeira/PhonePointer.m'), '-o', str(obj)], check=True)
    symbols = subprocess.check_output(['xcrun', 'nm', '-gU', str(obj)], text=True)
    for name in ['madeira_phone_pointer_setup', 'madeira_phone_pointer_status']:
        assert re.search(r'\bT _' + name + r'$', symbols, re.M), name
    print('PASS PhonePointer compiles for iOS and exports both app entry points')
