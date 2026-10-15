#!/usr/bin/env python3
"""FidelityFX frame-generation experiments: cs-split, fi-setup-zero, fi-field-check.

Horizon Forbidden West's FSR 3 generated frames carry black 16x16 squares on an
8-pixel lattice: one NaN texel of FSR's optical-flow motion-vector field
(R32_UINT, priority bits | a half-float vector) blacks out its 2x2 bilinear
footprint. cs-split ends a compute encoder after every dispatch, fi-setup-zero
zero-fills the R32 UAV textures of FSR's Setup pass before it runs, and
fi-field-check reads those fields back around FSR's dispatches and logs texels
whose low half is a NaN/Inf half-float.

Checks: all three keys default to 0 and carry a catalog comment; the replay
hooks run only for direct dispatches, the "before" hook ahead of exec_rp_note
and the "after" hook past the switch, so the strings other checks pin stay as
they are; Present polls the copies; every encoder boundary the experiments add
syncs in every fence-chain mode; a Setup-like dispatch is a 'CS' entry with
four or more same-size R32 UAV textures. The NaN-half census and the Setup-like
rule are compiled and run against stubs.
"""
from pathlib import Path
import shutil
import subprocess
import tempfile

root = Path(__file__).resolve().parents[2]
pe = (root / 'madeira-d3d12/src/pe/madeira_d3d12.c').read_text()
ok = True


def check(what, cond):
    global ok
    print(('ok   ' if cond else 'FAIL ') + what)
    ok &= bool(cond)


def body(sig):
    """A function's text, braces matched outside strings, characters and comments."""
    start = pe.index(sig)
    while pe.index(';', start) < pe.index('{', start):
        start = pe.index(sig, start + 1)
    i, depth, quote = pe.index('{', start), 0, None
    while i < len(pe):
        ch = pe[i]
        if quote:
            if ch == '\\':
                i += 2
                continue
            if ch == quote:
                quote = None
        elif pe.startswith('/*', i):
            i = pe.index('*/', i) + 2
            continue
        elif pe.startswith('//', i):
            i = pe.index('\n', i)
            continue
        elif ch in '"\'':
            quote = ch
        elif ch == '{':
            depth += 1
        elif ch == '}':
            depth -= 1
            if depth == 0:
                return pe[start:i + 1]
        i += 1
    raise ValueError(sig)


load = body('static void mad_ffx_load(void)')
check('cs-split reads 0 by default, 1 and 2 only, with a fix comment',
      'v = mad_cfg_int_pe("cs-split", 0);   /* fix: ' in load and 'g_cs_split = (v == 1 || v == 2) ? (int)v : 0;' in load)
check('fi-setup-zero reads 0 by default, with a fix comment',
      'g_fsz = mad_cfg_int_pe("fi-setup-zero", 0) ? 1 : 0;   /* fix: ' in load)
check('fi-field-check reads 0 by default (1 = every 60 presents), with a diagnostic comment',
      'v = mad_cfg_int_pe("fi-field-check", 0);   /* diagnostic: ' in load and
      'g_ffc = v <= 0 ? 0 : v == 1 ? 60 : v > 100000 ? 100000 : (int)v;' in load)
check('the replay asks only once whether any is on (g_ffx_exp written last)',
      load.rstrip().endswith('MemoryBarrier();\n    g_ffx_exp = (g_cs_split || g_fsz || g_ffc) ? 1 : 0;\n}') and
      'static int g_ffx_exp = -1;' in pe)

ex = body('static void mad_exec_list(struct mad_queue *q, struct mad_list *l, obj_handle_t cb)')
before = 'if (g_ffx_exp > 0 && c->kind == MC_DISPATCH) mad_ffx_before(&e, c);'
after = 'if (g_ffx_exp > 0 && c->kind == MC_DISPATCH) mad_ffx_after(&e, c);'
check('the switches are read when a replay starts',
      'if (g_ffx_exp < 0) mad_ffx_load();' in ex and ex.index('if (g_ffx_exp < 0) mad_ffx_load();') < ex.index('for (i = 0; i < l->ncmds; i++) {'))
check('the before hook runs for direct dispatches ahead of exec_rp_note, which keeps its line before the switch',
      before in ex and ex.index(before) < ex.index('exec_rp_note(&e, c);   /* madeira-bcd clear-defer, rp-discard */\n        switch (c->kind) {'))
check('the after hook runs for direct dispatches once the switch has replayed the command, before the replay-split timer',
      after in ex and ex.index('case MC_DISCARD: break;') < ex.index(after) < ex.index('if (rs) {   /* madeira-bcd: replay split, summed per list */'))
check('the dispatch case and the indirect loop are untouched (no hook inside an ExecuteIndirect)',
      'case MC_DISPATCH: exec_dispatch(&e, c); if (g_vt_on > 0) { InterlockedIncrement(&g_vt_disp); InterlockedIncrement(&g_vt_disp_q[q->type & 3]); } break;' in ex and
      'mad_ffx' not in ex[ex.index('case MC_DRAW_INDIRECT: case MC_DRAW_INDEXED_INDIRECT: case MC_DISPATCH_INDIRECT: {'):ex.index('case MC_COPY_BB: case MC_COPY_B2T:')])

pr = body('static void mad_present_run(struct mad_swapchain *s, UINT idx)')
check('Present polls the copies after the frame\'s batches are committed',
      'mad_ffc_poll();' in pr and pr.index('mad_device_flush_all(s->queue->device);') < pr.index('mad_ffc_poll();'))

sync = body('static void mad_ffx_sync(struct mad_exec *e)')
check('an added encoder boundary syncs in every fence-chain mode (mode 6 and modes 2/3)',
      'e->f6_sync_needed = 1;' in sync and 'e->fence_needed = 1;' in sync)
bf = body('static void mad_ffx_before(struct mad_exec *e, const struct mad_cmd *c)')
check('before: FidelityFX dispatches only, and only Setup-like ones',
      'strcmp(e->cpso->vs_name, "CS")' in bf and 'if (!mad_ffx_setup_like(t, n)) return;' in bf)
check('before: the s00 copy (every 4-byte target of Setup) is taken before the zero fill, both between syncs',
      'na = mad_ffx_uavs(e, all, MAD_FFC_WATCH, 0);' in bf and
      bf.index('if (exec_begin_blit(e)) mad_ffc_copy_locked(e, c, all, na);') < bf.index('exec_copy(e, &fc);') and
      bf.count('mad_ffx_sync(e);') == 4)
check('before: the fill is a zero MC_FILL_TEX of mip 0, every slice, 4-byte texels',
      'obj_handle_t pat = mad_fill_pattern(e->q->device, 0);' in bf and 'fc.kind = MC_FILL_TEX;' in bf and
      'fc.u.filltex.level = 0; fc.u.filltex.sl0 = 0; fc.u.filltex.nsl = ~0u;' in bf and 'fc.u.filltex.bpp = 4; fc.u.filltex.pattern = pat;' in bf)
watch = body('static void mad_ffc_watch_locked(struct mad_resource *const *t, unsigned n)')
check('before: a window starts at a Setup pass (R32 fields), watches its textures and closes at the next Setup',
      'n = mad_ffx_uavs(e, t, MAD_FFC_WATCH, 1);' in bf and 'mad_ffc_watch_locked(all, na);' in bf and
      'else if (g_ffc_budget && g_ffc_setups++) g_ffc_budget = 0;' in bf and 'mad_ffc_release(rel, nrel);' in bf and
      bf.index('ReleaseSRWLockExclusive(&g_ffc_lock);') < bf.index('mad_ffc_release(rel, nrel);'))
check('watch: referenced while watched, at most MAD_FFC_WATCH, each named once with its memory (own or heap range and overlaps)',
      'ID3D12Resource_AddRef((ID3D12Resource *)t[i]);' in watch and 'g_ffc_nwatch >= MAD_FFC_WATCH' in watch and
      'mad_alias_desc(t[i], al, sizeof al);' in watch)
af = body('static void mad_ffx_after(struct mad_exec *e, const struct mad_cmd *c)')
check('after: the copies follow the dispatch in a blit encoder that ends its compute encoder',
      af.index('mad_ffx_sync(e);') < af.index('if (exec_begin_blit(e)) mad_ffc_copy_locked(e, c, t, n);'))
check('after: cs-split syncs, then ends the open compute encoder; 2 = FidelityFX only',
      'if (g_cs_split && e->cenc && (g_cs_split == 1 || ffx)) {' in af and
      af.index('mad_ffx_sync(e);   /* the next encoder waits for this one') < af.index('exec_end(e);'))
uav = body('static unsigned mad_ffx_uavs(const struct mad_exec *e, struct mad_resource **out, unsigned max, int r32)')
check('the UAV walk: descriptor-table UAV ranges, texture views only, 2D, mip 0, distinct; R32 uint/sint or any 4-byte colour format',
      'if (rg->range_type != MADEIRA_IR_RANGE_UAV) continue;' in uav and
      'if (!de->texture_view_id || de->gpu_va || (de->metadata >> 63)) continue;' in uav and
      'if (r32 ? r->tex_pf != WMTPixelFormatR32Uint && r->tex_pf != WMTPixelFormatR32Sint : !mad_ffx_pf4((UINT)r->tex_pf)) continue;' in uav and
      '|| u.level) continue;' in uav and 'if (j == n && n < max) out[n++] = r;' in uav)
af_watch = body('static void mad_ffx_after(struct mad_exec *e, const struct mad_cmd *c)')
check('after: the dispatch\'s 4-byte targets join the watch before the copies',
      af_watch.index('n = mad_ffx_uavs(e, t, MAD_FFC_WATCH, 0);') < af_watch.index('mad_ffc_watch_locked(t, n);') <
      af_watch.index('if (exec_begin_blit(e)) mad_ffc_copy_locked(e, c, t, n);'))
poll = body('static void mad_ffc_poll(void)')
check('poll: in order, only completed command buffers, every copy freed, the watch released unlocked',
      'if (st < WMTCommandBufferStatusCompleted) break;' in poll and 'mad_capbuf_free(&t);' in poll and
      'NSObject_release(q->cb);' in poll and poll.index('ReleaseSRWLockExclusive(&g_ffc_lock);') < poll.index('mad_ffc_release(rel, nrel);'))

harness = r'''
#include <stdio.h>
#include <string.h>
#include <stdint.h>
typedef uint32_t UINT32; typedef unsigned UINT; typedef uint64_t UINT64;
struct mad_resource { UINT width, height; };
@COUNT@
@SETUP@
static int fails;
#define T(c) do { if (!(c)) { printf("FAIL line %d: %s\n", __LINE__, #c); fails++; } } while (0)
int main(void) {
    UINT32 px[4 * 3]; struct mad_ffc_counts k; UINT64 s0;
    struct mad_resource a = { 824, 376 }, b = { 824, 376 }, c = { 824, 376 }, d = { 824, 376 }, e = { 176, 81 };
    struct mad_resource *t4[4] = { &a, &b, &c, &d }, *t5[5] = { &a, &b, &c, &d, &e };
    memset(px, 0, sizeof px);
    mad_ffc_count(px, 4, 3, &k); s0 = k.sum;
    T(k.nz == 0 && k.nan == 0 && k.inf == 0 && k.nex == 0 && k.ex[0] == 0);
    px[1 * 4 + 2] = 0x80007e01u;   /* a primary entry whose vector component is NaN */
    px[2 * 4 + 3] = 0xffffffffu;   /* -NaN in the low half */
    px[0 * 4 + 1] = 0x80007c00u;   /* +Inf */
    px[0 * 4 + 0] = 0x7fff3c00u;   /* 1.0 under priority bits: valid */
    px[2 * 4 + 0] = 0x7c000000u;   /* the pattern in the HIGH half only: valid */
    mad_ffc_count(px, 4, 3, &k);
    T(k.nz == 5 && k.nan == 2 && k.inf == 1);
    T(k.bx0 == 2 && k.by0 == 1 && k.bx1 == 3 && k.by1 == 2);
    T(k.nex == 2 && strstr(k.ex, "(2,1)=80007e01") && strstr(k.ex, "(3,2)=ffffffff"));
    T(k.sum != s0);
    T(mad_ffx_setup_like(t4, 4) == 1);
    T(mad_ffx_setup_like(t4, 3) == 0);
    T(mad_ffx_setup_like(t5, 5) == 0);
    printf(fails ? "harness FAILED\n" : "harness ok\n");
    return fails != 0;
}
'''


def cut(start, end):
    i = pe.index(start)
    return pe[i:pe.index(end, i) + len(end)]


count_src = cut('struct mad_ffc_counts {', '};') + '\n' + body('static void mad_ffc_count(const UINT32 *px, UINT w, UINT h, struct mad_ffc_counts *o)')
setup_src = body('static int mad_ffx_setup_like(struct mad_resource *const *t, unsigned n)')
cc = shutil.which('cc') or shutil.which('gcc') or shutil.which('clang')
if not cc:
    print('note: no C compiler; the harness did not run')
else:
    with tempfile.TemporaryDirectory(prefix='madeira-ffx-') as tmp:
        src = Path(tmp) / 'ffx.c'
        exe = Path(tmp) / 'ffx'
        src.write_text(harness.replace('@COUNT@', count_src).replace('@SETUP@', setup_src))
        b = subprocess.run([cc, '-std=gnu11', '-Wall', '-Wno-unused-function', str(src), '-o', str(exe)],
                           capture_output=True, text=True)
        check('harness compiles', b.returncode == 0)
        if b.returncode != 0:
            print(b.stderr[-2000:])
        else:
            run = subprocess.run([str(exe)], capture_output=True, text=True)
            print(run.stdout.rstrip())
            check('the NaN-half census and the Setup-like rule behave', run.returncode == 0)

print('PASS' if ok else 'FAILED')
raise SystemExit(0 if ok else 1)
