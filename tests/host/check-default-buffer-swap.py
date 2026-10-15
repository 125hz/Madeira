#!/usr/bin/env python3
"""default-buffer-swap (opt-in, default 0) in madeira_d3d12.c: source checks plus
a host build of the switch reader.

Horizon Forbidden West keeps 1.3-1.6 GB of committed DEFAULT buffers (256 MB,
flags 0) on GPU-private Metal memory, which phys_footprint charges in full.
With the switch on, such buffers get storage the runtime allocates (a fresh
guest commit the file tier backs), handed to Metal as a shared no-copy buffer,
as upload-swap (ml1154) does for UPLOAD buffers. Checks:
  - off by default; 64 MB floor by default, never below 8 MB; 2 adds UAV buffers;
  - only committed DEFAULT buffers that nothing placed, never render-target or
    depth ones, UAV ones only with 2; the upload-swap condition is untouched;
  - storage is kept only when Metal accepted it; otherwise the buffer is
    GPU-private as before;
  - the application still sees a GPU-only resource (no CPU pointer);
  - typed views over such a buffer are made Shared, like the buffer;
  - the release path returns the bytes to both counters;
  - Settings lists both keys with their defaults.
"""
from pathlib import Path
import os, shutil, subprocess, sys, tempfile

root = Path(__file__).resolve().parents[2]
src = (root / "madeira-d3d12/src/pe/madeira_d3d12.c").read_text()
catalog = (root / "app/Madeira/ConfigCatalog.generated.swift").read_text()
ok = True


def check(what, cond):
    global ok
    print(("ok   " if cond else "FAIL ") + what)
    ok &= bool(cond)


def block(start, end="\n}\n"):
    i = src.index(start)
    return src[i:src.index(end, i) + len(end)]


mode = block("static int mad_defswap_mode(void) {")
check("off by default, 64 MB floor by default",
      'mad_cfg_int_pe("default-buffer-swap", 0)' in mode and 'mad_cfg_int_pe("default-buffer-swap-mb", 64)' in mode)

create = block("static HRESULT mad_create_resource_at(struct mad_device *d, D3D12_HEAP_TYPE heap_type,\n"
               "                                      const D3D12_RESOURCE_DESC *desc, REFIID riid, void **out,\n"
               "                                      struct mad_memheap *ph, UINT64 poff) {")
up = ('if (!r->buffer && heap_type != D3D12_HEAP_TYPE_DEFAULT && info.length >= (8u << 20) && mad_upload_swap_on() &&\n'
      '            (heap_type != D3D12_HEAP_TYPE_READBACK || mad_readback_swap_on())) {')
cond = ('if (!r->buffer && !ph && heap_type == D3D12_HEAP_TYPE_DEFAULT && mad_defswap_mode() && info.length >= g_defswap_min &&\n'
        '            !(desc->Flags & (D3D12_RESOURCE_FLAG_ALLOW_RENDER_TARGET | D3D12_RESOURCE_FLAG_ALLOW_DEPTH_STENCIL)) &&\n'
        '            (mad_defswap_mode() >= 2 || !(desc->Flags & D3D12_RESOURCE_FLAG_ALLOW_UNORDERED_ACCESS))) {')
check("upload-swap's condition is unchanged", up in create)
check("committed DEFAULT buffers only, at least the floor; never RT/DS; UAV only with 2", cond in create)
ds = create[create.index(cond):]
ds = ds[:ds.index("if (!r->buffer) r->buffer = MTLDevice_newBuffer(d->mtl_device, &info);")]
check("after upload-swap, before the Metal-owned fallback",
      create.index(up) < create.index(cond) < create.index("if (!r->buffer) r->buffer = MTLDevice_newBuffer(d->mtl_device, &info);"))
check("our own commit, 64 KB rounded, handed to Metal as a Shared no-copy buffer",
      "SIZE_T len = (SIZE_T)((info.length + 0xffff) & ~(UINT64)0xffff);" in ds and
      "VirtualAlloc(NULL, len, MEM_COMMIT | MEM_RESERVE, PAGE_READWRITE);" in ds and
      "info.length = len; info.memory.ptr = mem; info.options = WMTResourceStorageModeShared;" in ds)
acc = ds[ds.index("if (r->buffer) {"):ds.index("} else {")]
check("storage kept and counted (ml1154 count and its own) only when Metal accepted it",
      "r->own_mem = mem;" in acc and
      "InterlockedExchangeAdd64(&g_upload_swap_bytes, (LONG64)len); InterlockedIncrement(&g_upload_swap_n);" in acc and
      "InterlockedExchangeAdd64(&g_defswap_bytes, (LONG64)len); InterlockedIncrement(&g_defswap_n);" in acc)
check("refused: memory freed, GPU-private as before",
      "VirtualFree(mem, 0, MEM_RELEASE);\n                    info.length = want; info.memory.ptr = NULL; info.gpu_address = 0; "
      "info.options = WMTResourceStorageModePrivate;" in ds)
check("still GPU-only to the application (no CPU pointer)",
      "r->cpu = info.memory.ptr;" in create and
      "if (r->own_mem && heap_type == D3D12_HEAP_TYPE_DEFAULT) r->cpu = NULL;" in create and
      create.index("r->cpu = info.memory.ptr;") < create.index("if (r->own_mem && heap_type == D3D12_HEAP_TYPE_DEFAULT) r->cpu = NULL;")
      < create.index("mad_track(d, r);"))
check("typed views over our storage are Shared, like the buffer",
      "ti.options = (r->cpu || r->own_mem) ? WMTResourceStorageModeShared : WMTResourceStorageModePrivate;" in src and
      "ti.options = r->cpu ? WMTResourceStorageModeShared : WMTResourceStorageModePrivate;" not in src)
rel = block("static ULONG STDMETHODCALLTYPE res_Release(ID3D12Resource *This) {")
own = rel[rel.index("if (r->own_mem) {"):]
check("release returns the bytes to both counters and frees after the GPU (ml1154 path)",
      "InterlockedDecrement(&g_upload_swap_n);" in own and
      "if (r->heap == D3D12_HEAP_TYPE_DEFAULT) {" in own and
      "InterlockedExchangeAdd64(&g_defswap_bytes, -(LONG64)((r->size + 0xffff) & ~(UINT64)0xffff)); InterlockedDecrement(&g_defswap_n);" in own and
      "md->mhret[md->nmhret].mem = r->own_mem;" in own)
check("census line next to ml1154's",
      src.index('ml1154 CPU-visible buffers on file-backed storage: %ld, %lld MB') <
      src.index('default-buffer-swap: %ld DEFAULT buffers on file-backed storage'))
for key, dflt in (("default-buffer-swap", "0"), ("default-buffer-swap-mb", "64")):
    check("settings catalog: %s (default %s)" % (key, dflt),
          'ConfigOption(key: "%s", title: "", kind: .int, defaultValue: "%s", category: "Direct3D 12"' % (key, dflt) in catalog)

# The switch reader, built on the host with stand-ins.
harness = r'''
#include <stdio.h>
#include <string.h>
#include <stdarg.h>
typedef unsigned long long UINT64;
#define MemoryBarrier() __sync_synchronize()
static long long g_m, g_mb; static int g_m_set, g_mb_set, g_logs;
static long long mad_cfg_int_pe(const char *key, long long dflt) {
    if (!strcmp(key, "default-buffer-swap")) return g_m_set ? g_m : dflt;
    if (!strcmp(key, "default-buffer-swap-mb")) return g_mb_set ? g_mb : dflt;
    return dflt;
}
static void d3d12_log(const char *fmt, ...) { va_list ap; va_start(ap, fmt); g_logs++; vprintf(fmt, ap); va_end(ap); }
%s
int main(int argc, char **argv) {
    int m;
    if (argc > 1) { g_m_set = 1; g_m = atoll_(argv[1]); }
    if (argc > 2) { g_mb_set = 1; g_mb = atoll_(argv[2]); }
    m = mad_defswap_mode();
    if (mad_defswap_mode() != m) return 3;   /* read once */
    printf("RESULT mode=%%d min=%%llu logs=%%d\n", m, g_defswap_min >> 20, g_logs);
    return 0;
}
'''
reader = src[src.index("static UINT64 g_defswap_min = 64ull << 20;"):]
reader = reader[:reader.index("\n}\n", reader.index("static int mad_defswap_mode(void) {")) + 3]
cc = shutil.which("cc") or shutil.which("clang") or shutil.which("gcc")
if not cc:
    print("note: no host C compiler; the switch reader was not built")
else:
    with tempfile.TemporaryDirectory() as tmp:
        c = os.path.join(tmp, "t.c"); exe = os.path.join(tmp, "t")
        with open(c, "w") as f:
            f.write("#include <stdlib.h>\nstatic long long atoll_(const char *s) { return atoll(s); }\n" + harness % reader)
        r = subprocess.run([cc, "-std=c99", "-Wall", "-Werror", "-o", exe, c], capture_output=True, text=True)
        check("switch reader builds on the host", r.returncode == 0)
        if r.returncode:
            print(r.stderr)
        else:
            def run(*args):
                out = subprocess.run([exe] + [str(a) for a in args], capture_output=True, text=True)
                line = [l for l in out.stdout.splitlines() if l.startswith("RESULT")]
                return out.returncode, (line[0] if line else out.stdout)
            check("unset: off, 64 MB, silent", run() == (0, "RESULT mode=0 min=64 logs=0"))
            check("0: off, silent", run(0) == (0, "RESULT mode=0 min=64 logs=0"))
            check("1: on (no UAV), one line", run(1) == (0, "RESULT mode=1 min=64 logs=1"))
            check("2: UAV buffers too", run(2) == (0, "RESULT mode=2 min=64 logs=1"))
            check("7: treated as 2", run(7) == (0, "RESULT mode=2 min=64 logs=1"))
            check("-1: off", run(-1) == (0, "RESULT mode=0 min=64 logs=0"))
            check("floor 128 MB", run(1, 128) == (0, "RESULT mode=1 min=128 logs=1"))
            check("floor never below 8 MB", run(1, 1) == (0, "RESULT mode=1 min=8 logs=1"))
sys.exit(0 if ok else 1)
