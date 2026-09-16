/*  madeira-d3d12: M2 native D3D12 ABI slice.
 *
 *  The minimum set of objects the design's M2 gate names: a device that can
 *  create a queue, an allocator, a command list and a fence; a list that can be
 *  recorded, closed and reset; a queue that can execute it and signal; and a
 *  fence that reports completion and wakes a Win32 event waiter.
 *
 *  There is deliberately no Metal here yet. M2 is about the COM ABI, object
 *  lifetime and synchronisation being right, and mixing GPU work into that would
 *  make a failure ambiguous between the two. The buffer-copy/readback test comes
 *  next and gives the fence something real to be synchronising.
 *
 *  Every vtable is fully populated from generated stubs first, then implemented
 *  methods are assigned over them. So the supported surface is exactly the list
 *  of assignments below, and anything else returns E_NOTIMPL and names itself.
 */

#define INITGUID
#define COBJMACROS
#include <initguid.h>
#include <windows.h>
#include <d3d12.h>
#include <dxgi1_5.h>
#include <stdarg.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <math.h>

/* The existing winemetal bridge, already used by d3d11.dll. Reusing it means
 * the D3D12 path inherits the working local/remote split rather than growing a
 * second transport, which the design asks for explicitly. */
#include "winemetal.h"

#include "madeira_d3d12_stubs.h"
#include "madeira_ir_abi.h"

#define MADEIRA_D3D12_BUILD "madeira-d3d12 M2 " __DATE__ " " __TIME__

/* ---- diagnostics ---------------------------------------------------------
 * Routed through OutputDebugStringA so it lands in the same log as everything
 * else on this port. */
/* ml931: keep a shader's bytecode on disk (C:\madeira-cs, i.e. the prefix's
 * drive_c) so a kernel identified at dispatch time by its pipeline pointer can
 * be disassembled offline. Files, not log lines: a 60 KB blob does not belong
 * in the log. */
static void mad_dump_blob(const char *name, const void *data, SIZE_T len) {
    char path[300]; HANDLE h; DWORD wr = 0;
    if (!data || !len || len > (1u << 20)) return;
    CreateDirectoryA("C:\\madeira-cs", NULL);
    snprintf(path, sizeof path, "C:\\madeira-cs\\%s", name);
    h = CreateFileA(path, GENERIC_WRITE, 0, NULL, CREATE_ALWAYS, FILE_ATTRIBUTE_NORMAL, NULL);
    if (h == INVALID_HANDLE_VALUE) return;
    WriteFile(h, data, (DWORD)len, &wr, NULL);
    CloseHandle(h);
}
static void d3d12_log(const char *fmt, ...) {
    /* ml909: every record handed to __wine_dbg_output MUST end in a newline
     * and be shorter than ntdll's 1020-byte line buffer. A record truncated
     * by vsnprintf lost its newline, ntdll kept accumulating the fragments
     * of successive calls into one "line", and when that overflowed it
     * raised STATUS_BUFFER_OVERFLOW (0x80000005) on the calling thread --
     * the engine's submission thread, in the middle of the draw census.
     * That exception, not the media player, is what ended every run at
     * present ~1800 (ants49/50/52). */
    char buf[1000];
    size_t len;
    va_list ap;
    va_start(ap, fmt);
    vsnprintf(buf, sizeof buf, fmt, ap);
    va_end(ap);
    len = strlen(buf);
    if (!len || buf[len - 1] != '\n') {
        if (len >= sizeof buf - 1) { buf[sizeof buf - 2] = '\n'; buf[sizeof buf - 1] = 0; }
        else { buf[len] = '\n'; buf[len + 1] = 0; }
    }
    OutputDebugStringA(buf);
    /* Wine's own debug output: an unbuffered write on the log's file
     * descriptor from unix ntdll, which reaches the log from EVERY process.
     * The engine launched from the desktop is a child of its launcher and has
     * no standard handles, so stderr below goes nowhere for it (ml854 showed
     * a whole run with no runtime lines at all). */
    {
        typedef int (__cdecl *dbg_output_fn)(const char *);
        static dbg_output_fn dbg_output;
        static int looked;
        if (!looked) {
            HMODULE nt = GetModuleHandleA("ntdll.dll");
            if (nt) dbg_output = (dbg_output_fn)GetProcAddress(nt, "__wine_dbg_output");
            looked = 1;
        }
        if (dbg_output) dbg_output(buf);
    }
    /* Also stderr. OutputDebugStringA reaches the log as a debug-string
     * exception, and the host dumper caps those: the ml836 run recorded four
     * of them and dropped every line after, so the shader decisions that run
     * proved could not be read back. The guest's stderr is not capped, which
     * is why the test's own output survived in the same log. */
    fputs(buf, stderr);
    fflush(stderr);
}

void madeira_d3d12_note_unimplemented(const char *iface, const char *method) {
    /* Rate limiting is per call site rather than global: one chatty method must
     * not hide the first occurrence of every other one. */
    static const char *seen[64];
    static unsigned seen_n;
    for (unsigned i = 0; i < seen_n; i++)
        if (seen[i] == method) return;
    if (seen_n < 64) seen[seen_n++] = method;
    d3d12_log("[madeira-d3d12] unimplemented: %s::%s\n", iface, method);
}

/* ---- object model --------------------------------------------------------
 * One refcount and one interface id per object. QueryInterface accepts the
 * object's own iid plus the IUnknown/ID3D12Object/ID3D12DeviceChild ancestors
 * it genuinely is, and refuses everything else rather than handing back a
 * pointer whose vtable does not match what the caller will call through it. */
/* ml879 draw dump: the first executed lists are described draw by draw, with
 * the encoder index rmetald labels on its side, so a GPU fault report can be
 * matched to the draw that caused it. */
static char g_last_entry[64];
static struct mad_device *g_last_device;   /* ml887: GetDevice fallback for children without a back pointer */
static unsigned g_enc_seq, g_list_seq, g_dump_draws;
static int g_census_on;   /* ml899: one frame at presents 1500,1700,...,2800 */
struct mad_obj {
    void *vtbl;
    LONG refs;
    const IID *iid;
    const char *name;
};

/* Declared ahead of the objects that reference them. */
struct mad_device;
struct mad_resource;
struct mad_pso;
#define MAD_MAX_COPIES 64
struct mad_copy {
    struct mad_resource *dst; UINT64 dst_off;
    struct mad_resource *src; UINT64 src_off;
    UINT64 len;
};

struct mad_device {
    ID3D12Device10Vtbl *vtbl;   /* ml877: full Device10 slot table, Device1..8 answered */
    LONG refs;
    const IID *iid;
    const char *name;
    obj_handle_t mtl_device;
    obj_handle_t mtl_queue;
    obj_handle_t dsso;          /* depth: less-equal, writes enabled */
    LONG device_lost;
    /* GPU addresses are resolved back to the resource that owns them rather
     * than dereferenced. The design is explicit that a D3D GPU address, a
     * descriptor handle and a backend object id are separate namespaces. */
    struct mad_resource **live;
    unsigned nlive, live_cap;
    CRITICAL_SECTION live_lock;
    obj_handle_t *samplers;      /* held for the process's life; see CreateSampler */
    unsigned nsamplers, samplers_cap;
    /* Textures that have had a shader resource view created. A descriptor heap
     * stores resource IDs, not resource pointers, so the encoder cannot recover
     * from a bound table which textures it names. Declaring residency for all
     * of them is deliberately over-broad: over-declaring only keeps a resource
     * available, while under-declaring lets a draw sample nothing with every
     * call still reporting success. */
    struct mad_resource **srv_res;
    unsigned nsrv, nsrv_cap;
    struct mad_resource **uav_res;   /* written through descriptors; resident read+write */
    unsigned nuav, nuav_cap;
    /* ml880: one residency set on the queue holds every buffer and texture
     * ever created; committed before the next submission whenever it grew.
     * The 256-per-draw useResource lists stay as a belt for older systems. */
    obj_handle_t resset; LONG resset_dirty;
    /* Unset root descriptors used to hand the shader address 0 (+ offset),
     * which was a GPU page fault that killed the whole queue. They now point
     * at 64 KB of zeros instead. */
    obj_handle_t null_buffer; UINT64 null_gpu;
    struct mad_queue *queues[16]; unsigned nqueues;   /* ml884: every live queue, for flush-all */
    /* ml910: GPU-ordered capture of what a draw actually receives. Blits run
     * in the same command buffer right before the draw, so they see the
     * compute output the draw consumes; the shared buffer is read back after
     * the fence wait and printed then. */
    obj_handle_t cap_buf; unsigned char *cap_cpu; UINT cap_used;
    struct { char label[160]; UINT off, len; UINT kind; UINT nt; } cap[96]; unsigned ncap, cap_total;   /* ml924: nt>0 = sequential texels */
};
static void mad_resident(struct mad_device *d, obj_handle_t h) {
    if (!d || !h || !d->resset) return;
    MTLResidencySet_addAllocation(d->resset, h);
    InterlockedExchange(&d->resset_dirty, 1);
}

/* Growable arrays. The fixed tables of the cube era (16 samplers, 16 views,
 * 64 resources, 16 descriptors per heap) were sized for one demo; an engine
 * creates thousands of each during its first second, and the 16-descriptor
 * heap limit surfaced as an "out of video memory" dialog. */
static int mad_grow(void **arr, unsigned *cap, unsigned need, size_t elem) {
    unsigned ncap;
    void *n;
    if (need <= *cap) return 1;
    ncap = *cap ? *cap * 2 : 64;
    while (ncap < need) ncap *= 2;
    n = realloc(*arr, (size_t)ncap * elem);
    if (!n) return 0;
    *arr = n; *cap = ncap;
    return 1;
}

static void mad_note_sampler(struct mad_device *d, obj_handle_t smp) {
    if (!d || !smp) return;
    if (mad_grow((void **)&d->samplers, &d->samplers_cap, d->nsamplers + 1, sizeof *d->samplers))
        d->samplers[d->nsamplers++] = smp;
    else NSObject_release(smp);
}

/* ---- resources ----------------------------------------------------------
 * Buffers only for now. The CPU-visible heaps get storage allocated here and
 * handed to the backend as the buffer's memory, which is the same arrangement
 * DXMT's ring allocator uses and the one the remote shadow machinery already
 * understands. DEFAULT is GPU-private and deliberately not mappable. */
struct mad_resource {
    ID3D12Resource2Vtbl *vtbl;   /* ml886: Resource2-sized slot table */
    LONG refs;
    const IID *iid;
    const char *name;
    obj_handle_t buffer;
    void *cpu;                 /* NULL for GPU-private */
    UINT64 size;
    D3D12_HEAP_TYPE heap;
    UINT64 gpu_address;        /* reported by the backend at creation */
    LONG mapped;
    obj_handle_t texture;      /* set instead of `buffer` for TEXTURE2D */
    UINT64 gpu_resource_id;    /* what a descriptor entry stores for a texture */
    UINT32 width, height;
    int is_depth;
    int has_stencil;
    UINT samples;
    struct mad_device *owner;
    int borrowed;              /* texture belongs to a drawable; do not release */
    D3D12_RESOURCE_DESC desc;  /* as created; answered by GetDesc */
    /* ml905: typed-buffer views (Buffer<T> / RWBuffer<T>). The converter reads
     * a typed buffer as a texture buffer, so each distinct (format, offset,
     * count, access) needs a texture view over the buffer's memory. Cached per
     * resource; released with it. */
    struct { UINT fmt; UINT64 off, num; UINT8 uav; obj_handle_t tex; UINT64 id; } tview[16];
    unsigned ntview, tview_next;
    /* ml913: dimension-correct texture views. Metal binds a texture only to a
     * shader slot of the SAME type: a Texture2DArray SRV over a texture we
     * created as 2D (one layer) read back nothing (host shader validation:
     * "Invalid texture type MTLTextureType2D bound to shader, expected
     * MTLTextureType2DArray", 6520 reports in one run). Views are cached per
     * (type, levels, slices). */
    enum WMTTextureType tex_type; enum WMTPixelFormat tex_pf; UINT tex_mips, tex_layers; UINT tex_depth;   /* ml924: 3D depth */
    struct { UINT type, lvl0, nlvl, sl0, nsl, pf, swz; obj_handle_t tex; UINT64 id; } xview[8];
    unsigned nxview, xview_next;
};

DEFINE_GUID(IID_IMTLDXGIDevice, 0x6bfa1657, 0x9cb1, 0x471a, 0xa4, 0xfb, 0x7c, 0xac, 0xf8, 0xa8, 0x12, 0x07);

#define MAD_ROOT_PARAM_MAX 32
#define MAD_ROOT_RANGE_MAX 32
/* The parsed root signature, not the blob. The converter needs the layout at
 * pipeline creation, and re-parsing the blob there would mean keeping the
 * application's memory alive for the object's whole life. */
struct mad_rootsig {
    ID3D12RootSignatureVtbl *vtbl; LONG refs; const IID *iid; const char *name;
    struct madeira_ir_root_param params[MAD_ROOT_PARAM_MAX];
    struct madeira_ir_root_range ranges[MAD_ROOT_RANGE_MAX];
    UINT nparams, nranges;
    struct madeira_ir_static_sampler samplers[32];
    UINT nsamplers;
    /* ml923: the converter reserves one implicit descriptor-table slot at the
     * end of the top-level argument buffer for the static samplers; this is
     * the table it points at (nsamplers sampler descriptors, built once). */
    obj_handle_t stab; UINT64 stab_gpu;
};
struct mad_pso {
    ID3D12PipelineStateVtbl *vtbl; LONG refs; const IID *iid; const char *name;
    obj_handle_t rps;          /* Metal render pipeline state */
    obj_handle_t vs_lib, ps_lib, vs_fn, ps_fn;
    int uses_depth, uses_stencil;
    UINT8 dbg_denable, dbg_dfunc, dbg_dwrite, dbg_wmask[8], dbg_senable, dbg_sfunc, dbg_srmask, dbg_swmask;   /* ml903/ml904: census only */
    obj_handle_t dsso;                              /* per-pipeline depth-stencil state */
    struct wmtcmd_render_setrasterizerstate raster;  /* applied at every draw */
    UINT vb_stride[16]; UINT vb_mask;               /* the strides the vertex descriptor assumed */
    /* ml878: a D3D12 pipeline carries no vertex strides (they arrive with the
     * buffer view at draw time) but a Metal vertex descriptor must. The base
     * pipeline assumes the tightest stride; when a draw binds a different one
     * the pipeline is rebuilt with the real strides and cached here. */
    struct WMTRenderPipelineInfo rp; struct WMTVertexDescriptorInfo vd; int has_vd;
    struct { UINT strides[16]; obj_handle_t rps; } var[8]; unsigned nvar;
    CRITICAL_SECTION var_lock;
    obj_handle_t device_handle;
    char vs_name[64], ps_name[64];                  /* ml879: for the draw dump */
    UINT root_off[MAD_ROOT_PARAM_MAX]; int has_root_off; /* ml882: offsets from the converter's reflection */
    UINT static_off; int has_static_off;                  /* ml923: the implicit static-sampler table slot */
    int gs_emu;                                     /* ml927: a geometry-shader pipeline through the converter's mesh emulation */
    obj_handle_t si_lib, gs_lib;                    /* stage-in library, geometry (mesh) library */
    UINT gs_vertex_size, gs_max_prims;              /* IRRuntimeGeometryPipelineConfig */
    char gs_name[64];                               /* the converter's name for the mesh (geometry) function */
    int is_compute;
    obj_handle_t cps;                               /* Metal compute pipeline state */
    UINT tg[3];                                     /* threadgroup size the kernel was compiled with */
};

/* One shader-visible descriptor, in the converter's layout.
 *
 * Written out here rather than included: this file must not depend on the
 * converter's headers, and the three fields are the whole contract. Taken from
 * IRDescriptorTableEntry and its Set* helpers in the converter's runtime
 * header, which is also where the encodings below come from. */
struct mad_rtvp { UINT16 level, slice, layers, plane; };
struct mad_rtv { struct mad_resource *res; struct mad_rtvp p; };
struct mad_descriptor {
    UINT64 gpu_va;          /* sampler resource id, or a buffer address */
    UINT64 texture_view_id; /* texture resource id */
    UINT64 metadata;        /* min LOD clamp, or an encoded LOD bias */
};

static enum WMTCompareFunction mad_compare(D3D12_COMPARISON_FUNC f);
static void mad_sampler_info(struct WMTSamplerInfo *si, UINT filter, UINT au, UINT av, UINT aw, UINT aniso, UINT cmp, UINT border, float minlod, float maxlod);

/* RTV and DSV heaps hold resource pointers and never reach the GPU; the other
 * two hold real descriptors in a Metal buffer the shader reads. Both kinds hand
 * out CPU handles that are simply the address of the slot, so the application's
 * own `start + index * increment` arithmetic lands in the right place without
 * the runtime having to recover which heap a handle came from. */
struct mad_heap {
    ID3D12DescriptorHeapVtbl *vtbl; LONG refs; const IID *iid; const char *name;
    D3D12_DESCRIPTOR_HEAP_TYPE type;
    struct mad_rtv *slots;                      /* RTV/DSV: resource + sub-view per descriptor (ml925) */
    int shader_visible;
    obj_handle_t buffer;                        /* CBV_SRV_UAV/SAMPLER */
    struct mad_descriptor *cpu;
    UINT64 gpu_address;
    UINT count;
    struct mad_device *owner;
    D3D12_DESCRIPTOR_HEAP_DESC desc;           /* as created; answered by GetDesc */
};

/* An RTV or DSV handle addresses one slot in a heap's resource-pointer array. */
/* ml925: a render-target / depth-stencil view. The resource pointer comes
 * first so every reader of the old pointer-only slot still works. level =
 * mip, slice = first array slice (arrays, cubes), plane = first W slice (3D),
 * layers = how many slices the view spans: >1 means layered rendering and the
 * pass gets a renderTargetArrayLength, without which every layer the vertex
 * shader selects lands in (or is clipped from) slice 0. That is how UE's
 * 32-slice colour-grading LUT ended up with only slice 0 written. */
static unsigned mad_table_count(const struct mad_rootsig *rs, unsigned i, unsigned cap);   /* ml930 */
static struct mad_resource *mad_slot_resource(SIZE_T handle) {
    return handle ? *(struct mad_resource **)handle : NULL;
}
static void mad_view_all(struct mad_resource *r, struct mad_rtvp *p, UINT first, UINT count, int is3d);
static struct mad_rtvp mad_slot_view(SIZE_T handle) {
    struct mad_rtvp z = { 0, 0, 1, 0 };
    return handle ? ((struct mad_rtv *)handle)->p : z;
}

/* The increment the application uses for handle arithmetic. It has to be the
 * real stride or every descriptor after the first lands in the wrong place. */
static UINT mad_descriptor_stride(D3D12_DESCRIPTOR_HEAP_TYPE t) {
    return (t == D3D12_DESCRIPTOR_HEAP_TYPE_RTV || t == D3D12_DESCRIPTOR_HEAP_TYPE_DSV)
         ? (UINT)sizeof(struct mad_rtv)
         : (UINT)sizeof(struct mad_descriptor);
}

#ifndef DXGI_ERROR_DEVICE_REMOVED
#define DXGI_ERROR_DEVICE_REMOVED ((HRESULT)0x887A0005)
#endif

/* A dead transport used to surface as E_OUTOFMEMORY from every creation call,
 * because a failed backend call returns a null handle and "null handle" was read
 * as "allocation failed". That sent us looking for a memory problem when the
 * daemon had aborted. Probe the device and say which it is. */
static void mad_track(struct mad_device *d, struct mad_resource *r);
static void mad_untrack(struct mad_device *d, struct mad_resource *r);
static void mad_format_info(DXGI_FORMAT f, UINT *bytes, UINT *block);
static UINT64 mad_res_row_bytes(const struct mad_resource *r);
static int mad_map_texture_format(DXGI_FORMAT f, D3D12_RESOURCE_FLAGS flags, enum WMTPixelFormat *out, int *is_depth);
struct mad_rootsig;
static UINT mad_root_layout(const struct mad_rootsig *rs, UINT offsets[32]);

static HRESULT mad_creation_failure(struct mad_device *d, const char *what) {
    if (d && !d->device_lost && MTLDevice_recommendedMaxWorkingSetSize(d->mtl_device) == 0) {
        InterlockedExchange(&d->device_lost, 1);
        d3d12_log("[madeira-d3d12] %s failed AND the device no longer answers -- "
                  "treating this as device removal, not an allocation failure\n", what);
    }
    if (d && d->device_lost) return DXGI_ERROR_DEVICE_REMOVED;
    d3d12_log("[madeira-d3d12] %s failed while the device is still responding\n", what);
    return E_OUTOFMEMORY;
}

static HRESULT mad_qi(struct mad_obj *o, REFIID riid, void **out, int is_device_child) {
    if (!out) return E_POINTER;
    *out = NULL;
    if (IsEqualGUID(riid, &IID_IUnknown) || IsEqualGUID(riid, o->iid) ||
        IsEqualGUID(riid, &IID_ID3D12Object) ||
        (is_device_child && IsEqualGUID(riid, &IID_ID3D12DeviceChild))) {
        InterlockedIncrement(&o->refs);
        *out = o;
        return S_OK;
    }
    /* ml888: a refused interface on ANY object is named. The ID3D12Resource1
     * refusal that nulled the engine's RHI resource was invisible because only
     * the device logged its refusals. */
    {
        static unsigned said;
        if (riid && said++ < 24)
            d3d12_log("[madeira-d3d12] %s QueryInterface refused: {%08lx-%04x-%04x-%02x%02x-%02x%02x%02x%02x%02x%02x}\n",
                      o->name ? o->name : "?", (unsigned long)riid->Data1, riid->Data2, riid->Data3, riid->Data4[0], riid->Data4[1],
                      riid->Data4[2], riid->Data4[3], riid->Data4[4], riid->Data4[5], riid->Data4[6], riid->Data4[7]);
    }
    return E_NOINTERFACE;
}

static ULONG mad_addref(struct mad_obj *o) { return (ULONG)InterlockedIncrement(&o->refs); }

static ULONG mad_release(struct mad_obj *o) {
    LONG r = InterlockedDecrement(&o->refs);
    if (r == 0) {
        d3d12_log("[madeira-d3d12] destroyed %s\n", o->name);
        free(o);
    }
    return (ULONG)r;
}

/* ---- fence ---------------------------------------------------------------
 * A completed value plus a list of waiters. The design requires immediate
 * completion, multiple waiters and late registration all to work: registering
 * for a value already reached must signal at once rather than wait forever. */
#define MAD_FENCE_WAITERS 16
struct mad_fence {
    ID3D12FenceVtbl *vtbl;
    LONG refs;
    const IID *iid;
    const char *name;
    CRITICAL_SECTION lock;
    /* A null event means "block this thread until the value is reached", so the
     * fence needs a way to wait that RELEASES the lock -- otherwise the thread
     * that would advance the fence cannot get in, and the wait is a deadlock
     * rather than a wait. A condition variable over the same critical section
     * is exactly that. */
    CONDITION_VARIABLE cv;
    UINT64 value;
    struct { UINT64 value; HANDLE event; } waiters[MAD_FENCE_WAITERS];
    unsigned nwaiters;
};

static void fence_set_locked(struct mad_fence *f, UINT64 v) {
    f->value = v;
    WakeAllConditionVariable(&f->cv);
    unsigned w = 0;
    for (unsigned i = 0; i < f->nwaiters; i++) {
        if (f->waiters[i].value <= v) SetEvent(f->waiters[i].event);
        else f->waiters[w++] = f->waiters[i];
    }
    f->nwaiters = w;
}

static HRESULT STDMETHODCALLTYPE fence_QI(ID3D12Fence *This, REFIID riid, void **out) {
    return mad_qi((struct mad_obj *)This, riid, out, 1);
}
static ULONG STDMETHODCALLTYPE fence_AddRef(ID3D12Fence *This) { return mad_addref((struct mad_obj *)This); }
static ULONG STDMETHODCALLTYPE fence_Release(ID3D12Fence *This) {
    struct mad_fence *f = (struct mad_fence *)This;
    LONG r = InterlockedDecrement(&f->refs);
    if (r == 0) { DeleteCriticalSection(&f->lock); d3d12_log("[madeira-d3d12] destroyed %s\n", f->name); free(f); }
    return (ULONG)r;
}
static UINT64 STDMETHODCALLTYPE fence_GetCompletedValue(ID3D12Fence *This) {
    struct mad_fence *f = (struct mad_fence *)This;
    EnterCriticalSection(&f->lock);
    UINT64 v = f->value;
    LeaveCriticalSection(&f->lock);
    return v;
}
static HRESULT STDMETHODCALLTYPE fence_SetEventOnCompletion(ID3D12Fence *This, UINT64 value, HANDLE event) {
    struct mad_fence *f = (struct mad_fence *)This;
    HRESULT hr = S_OK;
    EnterCriticalSection(&f->lock);
    if (value <= f->value) {
        /* Already reached. Signalling now is the documented behaviour; queueing
         * it would hang a caller that waits on a value in the past. */
        if (event) SetEvent(event);
    } else if (!event) {
        /* Documented behaviour for a null event is to block until the value is
         * reached, not to reject the call. SleepConditionVariableCS drops the
         * lock while waiting and reacquires it on wake, so a signalling thread
         * can make progress. Re-checked in a loop because a condition variable
         * may wake spuriously and because an intervening signal may not have
         * reached our value yet. */
        while (f->value < value)
            SleepConditionVariableCS(&f->cv, &f->lock, INFINITE);
    } else if (f->nwaiters < MAD_FENCE_WAITERS) {
        f->waiters[f->nwaiters].value = value;
        f->waiters[f->nwaiters].event = event;
        f->nwaiters++;
    } else {
        hr = E_OUTOFMEMORY;
    }
    LeaveCriticalSection(&f->lock);
    return hr;
}
static HRESULT STDMETHODCALLTYPE fence_Signal(ID3D12Fence *This, UINT64 value) {
    struct mad_fence *f = (struct mad_fence *)This;
    EnterCriticalSection(&f->lock);
    fence_set_locked(f, value);
    LeaveCriticalSection(&f->lock);
    return S_OK;
}

/* ---- command allocator --------------------------------------------------- */
static int mad_list_type_ok(D3D12_COMMAND_LIST_TYPE t) {
    return t == D3D12_COMMAND_LIST_TYPE_DIRECT || t == D3D12_COMMAND_LIST_TYPE_COMPUTE ||
           t == D3D12_COMMAND_LIST_TYPE_COPY;
}

struct mad_alloc {
    ID3D12CommandAllocatorVtbl *vtbl;
    LONG refs;
    const IID *iid;
    const char *name;
    D3D12_COMMAND_LIST_TYPE type;
    LONG recording;    /* a list is currently recording into this allocator */
    LONG generation;   /* bumped by Reset; lists recorded against an older one
                        * are no longer executable, which is the rule that makes
                        * "reset then execute the same list" illegal */
};

static HRESULT STDMETHODCALLTYPE alloc_QI(ID3D12CommandAllocator *This, REFIID riid, void **out) {
    return mad_qi((struct mad_obj *)This, riid, out, 1);
}
static ULONG STDMETHODCALLTYPE alloc_AddRef(ID3D12CommandAllocator *This) { return mad_addref((struct mad_obj *)This); }
static ULONG STDMETHODCALLTYPE alloc_Release(ID3D12CommandAllocator *This) { return mad_release((struct mad_obj *)This); }
static HRESULT STDMETHODCALLTYPE alloc_Reset(ID3D12CommandAllocator *This) {
    struct mad_alloc *a = (struct mad_alloc *)This;
    /* Resetting storage a list is still recording into would pull the memory out
     * from under it. Refusing is what the API requires and what catches the bug
     * at the call site instead of later. */
    if (a->recording) return E_FAIL;
    /* Storage is reused from here, so everything previously recorded from this
     * allocator becomes stale. */
    InterlockedIncrement(&a->generation);
    return S_OK;
}

/* ---- graphics command list ----------------------------------------------- */
/* ---- command list: a recorded command stream ---------------------------
 * ml858. Until now a list held one render pass, one copy batch and one
 * readback, and refused anything beyond that at Close ("list overflowed").
 * An engine's first list has hundreds of copies, several passes and clears
 * that arrive in any order, so recording is now a growable stream of
 * commands replayed in order at execute time, where Metal encoders are
 * opened and closed as the stream demands. Recording never fails for lack
 * of room; what execution cannot do yet is named once in the log and
 * skipped, so a frame is never silently truncated at Close. */
enum mad_ck {
    MC_PSO, MC_ROOT, MC_HEAPS, MC_VP, MC_SCISSOR, MC_TOPO, MC_IB, MC_VB, MC_RTS,
    MC_CLEAR_RT, MC_CLEAR_DS, MC_DRAW, MC_DRAW_INDEXED,
    MC_DRAW_INDIRECT, MC_DRAW_INDEXED_INDIRECT, MC_DISPATCH_INDIRECT,   /* ml889: ExecuteIndirect */
    MC_FILL_BB, MC_BLEND_FACTOR,   /* ml892: UAV buffer clears, blend factor */
    MC_COPY_BB, MC_COPY_B2T, MC_COPY_T2B, MC_COPY_T2T, MC_DISPATCH,
    MC_ROOTSIG, MC_ROOT_CONST, MC_STENCIL_REF,
    MC_CROOTSIG, MC_CROOT, MC_CROOT_CONST,
};
struct mad_cmd {
    enum mad_ck kind;
    union {
        struct mad_pso *pso;
        struct { UINT index; UINT64 value; } root;
        struct mad_rootsig *rootsig;
        struct { UINT index, dst, n, data; } rconst;   /* data: offset into the list's constant words */
        UINT stencil_ref;
        struct { struct mad_heap *srv, *smp; } heaps;
        D3D12_VIEWPORT vp;
        D3D12_RECT scissor;
        D3D12_PRIMITIVE_TOPOLOGY topo;
        struct { struct mad_resource *res; UINT64 off; enum WMTIndexType type; } ib;
        struct { UINT slot; struct mad_resource *res; UINT64 off; UINT stride; } vb;
        struct { struct mad_resource *rt[8]; UINT n; struct mad_resource *depth; struct mad_rtvp v[8], dv; } rts;   /* ml925: + sub-views */
        struct { struct mad_resource *res; float rgba[4]; float depth; UINT8 stencil; UINT8 flags; struct mad_rtvp v; } clear;   /* ml904: flags = D3D12_CLEAR_FLAGS; ml925: v = the view cleared */
        struct { UINT vcount, icount, vstart, istart; } draw;
        struct { UINT icount, inst, start; INT base; UINT istart; } drawi;
        struct { struct mad_resource *dst, *src; UINT64 doff, soff, len; } bb;
        /* buffer<->texture: the buffer side is described by a footprint */
        struct { struct mad_resource *tex, *buf; UINT64 off; UINT row, rows; UINT w, h, d; UINT level, slice; UINT x, y, z; } bt;
        struct { struct mad_resource *dst, *src; UINT dlevel, dslice, slevel, sslice; UINT w, h, d; UINT dx, dy, dz, sx, sy, sz; } tt;
        struct { UINT x, y, z; } dispatch;
        struct { struct mad_resource *args; UINT64 off; UINT count; UINT stride; struct mad_resource *cnt; UINT64 cnt_off; } ind;
        struct { struct mad_resource *res; UINT64 off, len; UINT8 byte; } fill;
        struct { float rgba[4]; } blend;
    } u;
};

#define MAD_ARG_RING_BYTES  (64u * 1024u)
#define MAD_ARG_SLOT_BYTES  1088u  /* up to 64 dwords of root constants plus 32 root arguments, then ml912 draw params, then the ml927 vertex-buffer table */
#define MAD_ARG_DRAWPARAMS_OFF 512u /* IRRuntimeDrawParams (20 bytes) at kIRArgumentBufferDrawArgumentsBindPoint */
#define MAD_ARG_DRAWINFO_OFF   544u /* IRRuntimeDrawInfo (24 bytes; first uint16 = index type) at kIRArgumentBufferUniformsBindPoint */
#define MAD_ARG_VBTABLE_OFF    576u /* ml927: IRRuntimeVertexBuffers (31 x {addr, length, stride} = 496 bytes) at kIRVertexBufferBindPoint, object stage */

struct mad_list {
    ID3D12GraphicsCommandListVtbl *vtbl;
    LONG refs;
    const IID *iid;
    const char *name;
    D3D12_COMMAND_LIST_TYPE type;
    struct mad_alloc *alloc;
    int closed;
    LONG recorded_generation;  /* the allocator generation this list recorded against */
    struct mad_device *device;
    struct mad_cmd *cmds;
    unsigned ncmds, ccap;
    /* Resources reached by address through root descriptors; declared
     * resident at every draw because Metal cannot see them. */
    struct mad_resource **used;
    unsigned nused, ucap;
    /* Argument buffers: one slot of root values per draw, carved from shared
     * chunks. A draw's root arguments must survive until the GPU reads them,
     * so a single buffer rewritten per draw would race the previous draw. */
    obj_handle_t *rings; void **ring_cpu; unsigned nrings; unsigned ring_used;
    UINT32 *cdata; unsigned ncdata, cdcap;   /* root constant words, referenced by MC_ROOT_CONST */
};

static struct mad_cmd *mad_list_push(struct mad_list *l, enum mad_ck kind) {
    struct mad_cmd *c;
    if (l->closed) return NULL;
    if (!mad_grow((void **)&l->cmds, &l->ccap, l->ncmds + 1, sizeof *l->cmds)) return NULL;
    c = &l->cmds[l->ncmds++];
    memset(c, 0, sizeof *c);
    c->kind = kind;
    return c;
}
static void mad_list_note_used(struct mad_list *l, struct mad_resource *r) {
    unsigned i, from = l->nused > 64 ? l->nused - 64 : 0;
    if (!r) return;
    for (i = from; i < l->nused; i++) if (l->used[i] == r) return;
    if (mad_grow((void **)&l->used, &l->ucap, l->nused + 1, sizeof *l->used)) l->used[l->nused++] = r;
}

static HRESULT STDMETHODCALLTYPE list_QI(ID3D12GraphicsCommandList *This, REFIID riid, void **out) {
    struct mad_obj *o = (struct mad_obj *)This;
    if (out && (IsEqualGUID(riid, &IID_ID3D12CommandList))) {
        InterlockedIncrement(&o->refs);
        *out = o;
        return S_OK;
    }
    return mad_qi(o, riid, out, 1);
}
static ULONG STDMETHODCALLTYPE list_AddRef(ID3D12GraphicsCommandList *This) { return mad_addref((struct mad_obj *)This); }
static ULONG STDMETHODCALLTYPE list_Release(ID3D12GraphicsCommandList *This) {
    struct mad_list *l = (struct mad_list *)This;
    LONG r = InterlockedDecrement(&l->refs);
    if (r == 0) {
        if (l->alloc && !l->closed) InterlockedDecrement(&l->alloc->recording);
        if (l->alloc) ID3D12CommandAllocator_Release((ID3D12CommandAllocator *)l->alloc);
        for (unsigned k = 0; k < l->nrings; k++) NSObject_release(l->rings[k]);
        free(l->rings); free(l->ring_cpu); free(l->cmds); free(l->used); free(l->cdata);
        free(l);
    }
    return (ULONG)r;
}
static HRESULT STDMETHODCALLTYPE list_Close(ID3D12GraphicsCommandList *This) {
    struct mad_list *l = (struct mad_list *)This;
    if (l->closed) return E_FAIL;          /* double Close is a caller bug */
    l->closed = 1;
    l->recorded_generation = l->alloc ? l->alloc->generation : 0;
    if (l->alloc) InterlockedDecrement(&l->alloc->recording);
    return S_OK;
}
static HRESULT STDMETHODCALLTYPE list_Reset(ID3D12GraphicsCommandList *This,
                                            ID3D12CommandAllocator *allocator,
                                            ID3D12PipelineState *pso) {
    struct mad_list *l = (struct mad_list *)This;
    (void)pso;
    if (!l->closed) return E_FAIL;         /* reset while recording */
    if (!allocator) return E_INVALIDARG;
    if (l->alloc != (struct mad_alloc *)allocator) {
        if (l->alloc) ID3D12CommandAllocator_Release((ID3D12CommandAllocator *)l->alloc);
        l->alloc = (struct mad_alloc *)allocator;
        ID3D12CommandAllocator_AddRef(allocator);
    }
    InterlockedIncrement(&l->alloc->recording);
    l->recorded_generation = l->alloc->generation;
    l->closed = 0;
    l->ncmds = 0;
    l->nused = 0;
    l->ncdata = 0;
    l->ring_used = 0;   /* the chunks stay; the allocator's reset rule says the GPU is done with them */
    return S_OK;
}
static D3D12_COMMAND_LIST_TYPE STDMETHODCALLTYPE list_GetType(ID3D12GraphicsCommandList *This) {
    (void)This;
    return ((struct mad_list *)This)->type;
}

/* ---- command queue ------------------------------------------------------- */
struct mad_queue {
    ID3D12CommandQueueVtbl *vtbl;
    LONG refs;
    const IID *iid;
    const char *name;
    D3D12_COMMAND_LIST_TYPE type;
    UINT64 executed;
    UINT64 rejected;
    struct mad_device *device;
    /* Command buffers submitted but not yet known complete. A fence signal must
     * wait for these, otherwise it reports GPU work finished that has only been
     * submitted -- which is the difference between a fence and a counter. */
    obj_handle_t pending[16];
    unsigned npending;
    UINT64 untracked;   /* submissions the fence could not be made to cover */
    /* ml884: one Metal command buffer per BATCH of submissions, not per
     * ExecuteCommandLists. The engine submits ~31 lists per frame; each used
     * to be its own command buffer with its own round trips and its own
     * shadow-buffer flush (measured: 6.6 ms per submission = 5 FPS). The open
     * buffer is committed at Signal, Wait, Present or after open_cap lists. */
    obj_handle_t open_cb;
    unsigned open_lists;
    UINT64 batches;
};

static HRESULT mad_queue_dxgi_tearoff(struct mad_queue *q, void **out);
static HRESULT STDMETHODCALLTYPE queue_QI(ID3D12CommandQueue *This, REFIID riid, void **out) {
    HRESULT hr = mad_qi((struct mad_obj *)This, riid, out, 1);
    if (hr == E_NOINTERFACE && IsEqualGUID(riid, &IID_IMTLDXGIDevice))
        return mad_queue_dxgi_tearoff((struct mad_queue *)This, out);
    return hr;
}
static ULONG STDMETHODCALLTYPE queue_AddRef(ID3D12CommandQueue *This) { return mad_addref((struct mad_obj *)This); }
static void mad_queue_flush(struct mad_queue *q);
static ULONG STDMETHODCALLTYPE queue_Release(ID3D12CommandQueue *This) {
    struct mad_queue *q = (struct mad_queue *)This;
    LONG r = InterlockedDecrement(&q->refs);
    if (r == 0) {
        struct mad_device *d = q->device;
        unsigned i;
        mad_queue_flush(q);                          /* ml884: never free a queue holding an open batch */
        for (i = 0; i < q->npending; i++) NSObject_release(q->pending[i]);
        q->npending = 0;
        if (d) {
            EnterCriticalSection(&d->live_lock);
            for (i = 0; i < d->nqueues; i++) if (d->queues[i] == q) { d->queues[i] = d->queues[--d->nqueues]; break; }
            LeaveCriticalSection(&d->live_lock);
        }
        d3d12_log("[madeira-d3d12] destroyed %s\n", q->name);
        free(q);
    }
    return (ULONG)r;
}
/* ---- execution: replaying a list into Metal encoders -------------------- */
struct mad_exec {
    struct mad_queue *q;
    struct mad_list *l;
    obj_handle_t cb, renc, benc;
    struct mad_resource *rt[8]; UINT nrt; struct mad_resource *depth;          /* bound */
    struct mad_rtvp rtp[8], dp; struct mad_rtvp enc_rtp[8], enc_dp;            /* ml925: bound / encoded sub-views */
    struct mad_resource *enc_rt[8]; UINT enc_nrt; struct mad_resource *enc_depth; /* what the open encoder has */
    struct { struct mad_resource *res; float rgba[4]; float depth; UINT8 stencil; UINT8 flags; int is_depth; struct mad_rtvp v; } pend[16];
    unsigned npend;
    struct mad_pso *pso;
    struct mad_rootsig *rs;
    unsigned cap_after;   /* ml918: capture rt[0] texels after the current draw */
    struct mad_resource *cap_after_cs;   /* ml920: texture to capture after the current dispatch */
    struct { struct mad_resource *r; UINT64 off; char label[96]; } cap_after_buf[6]; unsigned ncap_after_buf;   /* ml922 */
    struct { struct mad_resource *r; UINT slice; char label[96]; } cap_after_tex[6]; unsigned ncap_after_tex;   /* ml924 */
    UINT64 root[MAD_ROOT_PARAM_MAX]; UINT nroot;
    UINT32 consts[MAD_ROOT_PARAM_MAX][64];
    UINT stencil_ref;
    float blend[4]; int has_blend;                  /* ml892 */
    struct mad_pso *cpso;
    struct mad_rootsig *crs;
    UINT64 croot[MAD_ROOT_PARAM_MAX];
    UINT32 cconsts[MAD_ROOT_PARAM_MAX][64];
    obj_handle_t cenc;
    struct mad_heap *srv, *smp;
    D3D12_VIEWPORT vp; int has_vp;
    D3D12_RECT sc; int has_sc;
    D3D12_PRIMITIVE_TOPOLOGY topo;
    struct mad_resource *ib; UINT64 ib_off; enum WMTIndexType ib_type;
    unsigned renc_seq;                          /* ml879: rmetald label index of the open render encoder */
    struct { struct mad_resource *res; UINT64 off; UINT stride; } vb[16];
    unsigned draws, skipped;
};

static void exec_end(struct mad_exec *e) {
    if (e->renc) { MTLCommandEncoder_endEncoding(e->renc); e->renc = 0; e->enc_nrt = 0; e->enc_depth = NULL; }
    if (e->benc) { MTLCommandEncoder_endEncoding(e->benc); e->benc = 0; }
    if (e->cenc) { MTLCommandEncoder_endEncoding(e->cenc); e->cenc = 0; }
}

static int mad_rtvp_eq(const struct mad_rtvp *a, const struct mad_rtvp *b) {
    return a->level == b->level && a->slice == b->slice && a->layers == b->layers && a->plane == b->plane;
}
static int exec_pending_index(struct mad_exec *e, struct mad_resource *r, const struct mad_rtvp *v) {
    unsigned i;
    for (i = 0; i < e->npend; i++) if (e->pend[i].res == r && mad_rtvp_eq(&e->pend[i].v, v)) return (int)i;
    return -1;
}
/* ml925: one attachment of a pass: mip level, array slice or 3D plane. */
static void mad_attach_view(struct WMTColorAttachmentInfo *a, const struct mad_resource *r, const struct mad_rtvp *v) {
    a->level = v->level;
    if (r->tex_type == WMTTextureType3D) { a->slice = 0; a->depth_plane = v->plane; }
    else { a->slice = v->slice; a->depth_plane = 0; }
}
static void exec_drop_pending(struct mad_exec *e, int i) {
    if (i < 0) return;
    e->pend[i] = e->pend[--e->npend];
}

/* A clear whose target is not part of the next pass still has to happen: it
 * gets a pass of its own with nothing drawn. */
static void exec_flush_clear(struct mad_exec *e, int i) {
    struct WMTRenderPassInfo rpi;
    obj_handle_t enc;
    if (i < 0 || !e->pend[i].res || !e->pend[i].res->texture) { exec_drop_pending(e, i); return; }
    exec_end(e);
    memset(&rpi, 0, sizeof rpi);
    if (e->pend[i].v.layers > 1) rpi.render_target_array_length = e->pend[i].v.layers;   /* ml925 */
    if (e->pend[i].is_depth) {
        UINT8 cf = e->pend[i].flags;   /* ml904 */
        rpi.depth.texture = e->pend[i].res->texture;
        rpi.depth.level = e->pend[i].v.level; rpi.depth.slice = e->pend[i].v.slice;
        rpi.stencil.level = e->pend[i].v.level; rpi.stencil.slice = e->pend[i].v.slice;
        rpi.depth.load_action = (cf & D3D12_CLEAR_FLAG_DEPTH) ? WMTLoadActionClear : WMTLoadActionLoad; rpi.depth.store_action = WMTStoreActionStore;
        rpi.depth.clear_depth = e->pend[i].depth;
        if (e->pend[i].res->has_stencil) {
            rpi.stencil.texture = e->pend[i].res->texture;
            rpi.stencil.load_action = (cf & D3D12_CLEAR_FLAG_STENCIL) ? WMTLoadActionClear : WMTLoadActionLoad; rpi.stencil.store_action = WMTStoreActionStore;
            rpi.stencil.clear_stencil = e->pend[i].stencil;
        }
    } else {
        rpi.colors[0].texture = e->pend[i].res->texture;
        mad_attach_view(&rpi.colors[0], e->pend[i].res, &e->pend[i].v);
        rpi.colors[0].load_action = WMTLoadActionClear; rpi.colors[0].store_action = WMTStoreActionStore;
        rpi.colors[0].clear_color.r = e->pend[i].rgba[0]; rpi.colors[0].clear_color.g = e->pend[i].rgba[1];
        rpi.colors[0].clear_color.b = e->pend[i].rgba[2]; rpi.colors[0].clear_color.a = e->pend[i].rgba[3];
    }
    rpi.render_target_width = e->pend[i].res->width >> e->pend[i].v.level;
    rpi.render_target_height = e->pend[i].res->height >> e->pend[i].v.level;
    if (!rpi.render_target_width) rpi.render_target_width = 1; if (!rpi.render_target_height) rpi.render_target_height = 1;
    rpi.default_raster_sample_count = e->pend[i].res->samples ? e->pend[i].res->samples : 1;
    enc = MTLCommandBuffer_renderCommandEncoder(e->cb, &rpi); if (enc) g_enc_seq++;
    if (enc) MTLCommandEncoder_endEncoding(enc);
    exec_drop_pending(e, i);
}

static void exec_add_clear(struct mad_exec *e, struct mad_resource *r, const struct mad_rtvp *v, const float *rgba, float depth, int is_depth, UINT8 stencil, UINT8 flags) {
    int i;
    if (!r) return;
    /* A clear ends the pass in progress so the next one can load it as a
     * clear; a clear mid-pass would otherwise be lost. */
    if (e->renc) exec_end(e);
    i = exec_pending_index(e, r, v);
    if (i >= 0 && is_depth && e->pend[i].is_depth && e->pend[i].flags) {
        /* ml904: a second clear of the other aspect merges; the values of the
         * aspects actually named are the ones that count. ml908: only an entry
         * that is STILL PENDING merges. The slot a dropped entry vacates keeps
         * its old bytes, so a fresh entry landing there used to inherit the
         * previous clear's flags -- a stencil-only clear after a consumed
         * depth+stencil clear became a depth clear too, which is exactly the
         * UE5 pre-pass -> stencil clear -> base pass shape (vfetch case 5c). */
        if (flags & D3D12_CLEAR_FLAG_DEPTH) e->pend[i].depth = depth;
        if (flags & D3D12_CLEAR_FLAG_STENCIL) e->pend[i].stencil = stencil;
        e->pend[i].flags |= flags;
        return;
    }
    if (i < 0) {
        if (e->npend == 16) exec_flush_clear(e, 0);
        i = (int)e->npend++;
    }
    e->pend[i].res = r; e->pend[i].v = *v; e->pend[i].is_depth = is_depth; e->pend[i].depth = depth; e->pend[i].stencil = stencil;
    e->pend[i].flags = is_depth ? flags : 0;
    if (rgba) memcpy(e->pend[i].rgba, rgba, sizeof e->pend[i].rgba); else memset(e->pend[i].rgba, 0, sizeof e->pend[i].rgba);
}

static int exec_same_targets(struct mad_exec *e) {
    UINT i;
    if (!e->renc || e->enc_nrt != e->nrt || e->enc_depth != e->depth) return 0;
    for (i = 0; i < e->nrt; i++) if (e->enc_rt[i] != e->rt[i] || !mad_rtvp_eq(&e->enc_rtp[i], &e->rtp[i])) return 0;
    if (e->depth && !mad_rtvp_eq(&e->enc_dp, &e->dp)) return 0;
    return 1;
}

static int exec_begin_render(struct mad_exec *e) {
    struct WMTRenderPassInfo rpi;
    UINT i, w = 0, h = 0;
    unsigned k;
    if (exec_same_targets(e)) return 1;
    exec_end(e);
    if (!e->nrt && !e->depth) return 0;
    /* Pending clears for targets outside this pass go first, on their own. */
    for (k = 0; k < e->npend; ) {
        int bound = (e->pend[k].res == e->depth && mad_rtvp_eq(&e->pend[k].v, &e->dp));
        for (i = 0; i < e->nrt && !bound; i++) if (e->rt[i] == e->pend[k].res && mad_rtvp_eq(&e->pend[k].v, &e->rtp[i])) bound = 1;
        if (!bound) exec_flush_clear(e, (int)k); else k++;
    }
    memset(&rpi, 0, sizeof rpi);
    for (i = 0; i < e->nrt; i++) {
        struct mad_resource *r = e->rt[i];
        int p;
        if (!r || !r->texture) continue;
        p = exec_pending_index(e, r, &e->rtp[i]);
        rpi.colors[i].texture = r->texture;
        mad_attach_view(&rpi.colors[i], r, &e->rtp[i]);   /* ml925 */
        if (e->rtp[i].layers > 1 && e->rtp[i].layers > rpi.render_target_array_length) rpi.render_target_array_length = e->rtp[i].layers;
        rpi.colors[i].load_action = p >= 0 ? WMTLoadActionClear : WMTLoadActionLoad;
        rpi.colors[i].store_action = WMTStoreActionStore;
        if (p >= 0) {
            rpi.colors[i].clear_color.r = e->pend[p].rgba[0]; rpi.colors[i].clear_color.g = e->pend[p].rgba[1];
            rpi.colors[i].clear_color.b = e->pend[p].rgba[2]; rpi.colors[i].clear_color.a = e->pend[p].rgba[3];
            exec_drop_pending(e, p);
        }
        if (!w) { w = r->width >> e->rtp[i].level; h = r->height >> e->rtp[i].level; }
    }
    if (e->depth && e->depth->texture) {
        int p = exec_pending_index(e, e->depth, &e->dp);
        UINT8 cf = p >= 0 ? e->pend[p].flags : 0;   /* ml904: which aspects the clear named */
        rpi.depth.texture = e->depth->texture;
        rpi.depth.level = e->dp.level; rpi.depth.slice = e->dp.slice;                /* ml925 */
        rpi.stencil.level = e->dp.level; rpi.stencil.slice = e->dp.slice;
        if (e->dp.layers > 1 && e->dp.layers > rpi.render_target_array_length) rpi.render_target_array_length = e->dp.layers;
        rpi.depth.load_action = (cf & D3D12_CLEAR_FLAG_DEPTH) ? WMTLoadActionClear : WMTLoadActionLoad;
        rpi.depth.store_action = WMTStoreActionStore;
        if (e->depth->has_stencil) {
            rpi.stencil.texture = e->depth->texture;
            rpi.stencil.load_action = (cf & D3D12_CLEAR_FLAG_STENCIL) ? WMTLoadActionClear : WMTLoadActionLoad;
            rpi.stencil.store_action = WMTStoreActionStore;
            if (p >= 0) rpi.stencil.clear_stencil = e->pend[p].stencil;
        }
        if (p >= 0) { rpi.depth.clear_depth = e->pend[p].depth; exec_drop_pending(e, p); }
        if (!w) { w = e->depth->width >> e->dp.level; h = e->depth->height >> e->dp.level; }
    }
    if (!w) w = 1; if (!h) h = 1;
    rpi.render_target_width = w; rpi.render_target_height = h;
    rpi.default_raster_sample_count = (e->nrt && e->rt[0] && e->rt[0]->samples) ? e->rt[0]->samples
                                    : (e->depth && e->depth->samples) ? e->depth->samples : 1;
    e->renc = MTLCommandBuffer_renderCommandEncoder(e->cb, &rpi); if (e->renc) e->renc_seq = ++g_enc_seq;
    if (!e->renc) { d3d12_log("[madeira-d3d12] no render encoder\n"); return 0; }
    e->enc_nrt = e->nrt; memcpy(e->enc_rt, e->rt, sizeof e->rt); e->enc_depth = e->depth;
    memcpy(e->enc_rtp, e->rtp, sizeof e->rtp); e->enc_dp = e->dp;   /* ml925 */
    return 1;
}

static int exec_begin_blit(struct mad_exec *e) {
    if (e->benc) return 1;
    exec_end(e);
    e->benc = MTLCommandBuffer_blitCommandEncoder(e->cb); if (e->benc) g_enc_seq++;
    if (!e->benc) d3d12_log("[madeira-d3d12] no blit encoder\n");
    return e->benc != 0;
}

/* One slot of root values for this draw, from the list's shared chunks. */
static int exec_arg_slot_for(struct mad_exec *e, const struct mad_rootsig *rs, const UINT64 *root,
                             const UINT32 (*consts)[64], obj_handle_t *buf, UINT64 *off, const UINT *ovr, const struct mad_pso *pso);
static int exec_arg_slot(struct mad_exec *e, obj_handle_t *buf, UINT64 *off) {
    return exec_arg_slot_for(e, e->rs, e->root, (const UINT32 (*)[64])e->consts, buf, off,
                             (e->pso && e->pso->has_root_off) ? e->pso->root_off : NULL, e->pso);
}
static int exec_arg_slot_for(struct mad_exec *e, const struct mad_rootsig *rs, const UINT64 *root,
                             const UINT32 (*consts)[64], obj_handle_t *buf, UINT64 *off, const UINT *ovr, const struct mad_pso *pso) {
    struct mad_list *l = e->l;
    unsigned chunk = l->ring_used / (MAD_ARG_RING_BYTES / MAD_ARG_SLOT_BYTES);
    unsigned slot = l->ring_used % (MAD_ARG_RING_BYTES / MAD_ARG_SLOT_BYTES);
    if (chunk >= l->nrings) {
        struct WMTBufferInfo bi;
        obj_handle_t nb;
        memset(&bi, 0, sizeof bi);
        bi.length = MAD_ARG_RING_BYTES;
        bi.options = WMTResourceStorageModeShared;
        nb = MTLDevice_newBuffer(e->q->device->mtl_device, &bi);
        if (!nb || !bi.memory.ptr) return 0;
        l->rings = realloc(l->rings, (l->nrings + 1) * sizeof *l->rings);
        l->ring_cpu = realloc(l->ring_cpu, (l->nrings + 1) * sizeof *l->ring_cpu);
        l->rings[l->nrings] = nb; l->ring_cpu[l->nrings] = bi.memory.ptr; l->nrings++;
    }
    {
        unsigned char *dst = (unsigned char *)l->ring_cpu[chunk] + slot * MAD_ARG_SLOT_BYTES;
        memset(dst, 0, MAD_ARG_SLOT_BYTES);
        if (rs) {
            UINT offsets[MAD_ROOT_PARAM_MAX], i;
            if (ovr) memcpy(offsets, ovr, sizeof offsets); else mad_root_layout(rs, offsets);
            for (i = 0; i < rs->nparams && i < MAD_ROOT_PARAM_MAX; i++) {
                if (rs->params[i].type == MADEIRA_IR_PARAM_CONSTANTS) {
                    UINT n = rs->params[i].num_constants;
                    if (n > 64) n = 64;
                    if (offsets[i] + n * 4 <= MAD_ARG_SLOT_BYTES) memcpy(dst + offsets[i], consts[i], n * 4);
                } else if (offsets[i] + 8 <= MAD_ARG_SLOT_BYTES) {
                    UINT64 v = root[i];
                    if (!v && e->q->device->null_gpu) {
                        static unsigned said_null;
                        v = e->q->device->null_gpu;
                        if (said_null++ < 24)
                            d3d12_log("[madeira-d3d12] root parameter %u (type %u) never set for '%s'; pointing it at zeros\n",
                                      i, (unsigned)rs->params[i].type,
                                      rs == e->crs ? (e->cpso ? e->cpso->vs_name : "?") : (e->pso ? e->pso->vs_name : "?"));
                    }
                    memcpy(dst + offsets[i], &v, 8);
                }
            }
            if (pso && pso->has_static_off && rs->stab_gpu && pso->static_off + 8 <= MAD_ARG_SLOT_BYTES)   /* ml923 */
                memcpy(dst + pso->static_off, &rs->stab_gpu, 8);
        } else {
            memcpy(dst, root, MAD_ROOT_PARAM_MAX * 8);   /* no signature bound: flat addresses */
        }
    }
    *buf = l->rings[chunk]; *off = (UINT64)slot * MAD_ARG_SLOT_BYTES;
    l->ring_used++;
    return 1;
}

/* ml927: the converter runtime's geometry-emulation draw contract, ported from
 * metal_irconverter_runtime.h (IRRuntimeCalculateDrawInfoForGSEmulation,
 * IRRuntimeCalculateObjectTgCountForTessellationAndGeometryEmulation,
 * IRRuntimeCalculateThreadgroupSizeForGeometry). The object stage runs the
 * vertex shader over `objVertexStride` vertices per threadgroup (+ the strip
 * overlap), the mesh stage runs the geometry shader over `maxPrims` input
 * primitives per threadgroup; both read IRRuntimeDrawInfo at bind point 5 and
 * IRRuntimeDrawParams at bind point 4. */
struct mad_gs_drawinfo {
    UINT16 index_type; UINT8 primitive_topology, threads_per_patch;
    UINT16 max_input_prims, obj_vertex_stride, mesh_prim_stride, gs_instance_count, patches_per_obj_tg, input_cps_per_patch;
    UINT64 index_buffer;
};
static UINT mad_gs_prim(D3D12_PRIMITIVE_TOPOLOGY t) {
    switch (t) {
    case D3D_PRIMITIVE_TOPOLOGY_POINTLIST: return 0;
    case D3D_PRIMITIVE_TOPOLOGY_LINELIST: return 1;
    case D3D_PRIMITIVE_TOPOLOGY_LINESTRIP: return 2;
    case D3D_PRIMITIVE_TOPOLOGY_TRIANGLESTRIP: return 4;
    case D3D_PRIMITIVE_TOPOLOGY_LINELIST_ADJ: return 5;
    case D3D_PRIMITIVE_TOPOLOGY_TRIANGLELIST_ADJ: return 6;
    case D3D_PRIMITIVE_TOPOLOGY_LINESTRIP_ADJ: return 7;
    default: return 3;
    }
}
static UINT mad_gs_vcount(UINT pt) { static const UINT n[8] = { 1, 2, 2, 3, 3, 4, 6, 4 }; return pt < 8 ? n[pt] : 3; }
static UINT mad_gs_overlap(UINT pt) { return pt == 2 ? 1 : pt == 4 ? 2 : pt == 7 ? 3 : 0; }
static void mad_gs_draw(UINT pt, UINT vertex_size, UINT max_prims, UINT instances, UINT count, UINT16 index_type, UINT64 index_buffer,
                        struct mad_gs_drawinfo *di, struct WMTSize *grid, struct WMTSize *obj_tg, struct WMTSize *mesh_tg) {
    UINT pvc = mad_gs_vcount(pt), align = pvc ? pvc : 1;
    UINT payload_vertex_bytes = 16384u - 32u;
    UINT max_v_by_payload = ((payload_vertex_bytes / (vertex_size ? vertex_size : 1)) / align) * align;
    UINT max_prims_by_amp = 1024u * max_prims;
    UINT max_prims_per_obj = max_v_by_payload / align; if (max_prims_per_obj > max_prims_by_amp) max_prims_per_obj = max_prims_by_amp;
    if (max_prims_per_obj > 256u / align) max_prims_per_obj = 256u / align;
    if (!max_prims_per_obj) max_prims_per_obj = 1;
    memset(di, 0, sizeof *di);
    di->index_type = index_type; di->primitive_topology = (UINT8)pt; di->threads_per_patch = (UINT8)pvc;
    di->max_input_prims = (UINT16)max_prims; di->obj_vertex_stride = (UINT16)(max_prims_per_obj * pvc);
    di->mesh_prim_stride = (UINT16)max_prims; di->gs_instance_count = (UINT16)instances;
    di->patches_per_obj_tg = (UINT16)max_prims_per_obj; di->input_cps_per_patch = (UINT16)pvc; di->index_buffer = index_buffer;
    {
        UINT stride = di->obj_vertex_stride ? di->obj_vertex_stride : 1, ov = mad_gs_overlap(pt);
        UINT n = count > ov ? count - ov : 0;
        grid->width = (n + stride - 1) / stride; grid->height = instances ? instances : 1; grid->depth = 1;
        obj_tg->width = stride + ov; obj_tg->height = 1; obj_tg->depth = 1;
        mesh_tg->width = max_prims ? max_prims : 1; mesh_tg->height = 1; mesh_tg->depth = 1;
    }
}

static enum WMTPrimitiveType mad_prim(D3D12_PRIMITIVE_TOPOLOGY t) {
    switch (t) {
    case D3D_PRIMITIVE_TOPOLOGY_POINTLIST: return WMTPrimitiveTypePoint;
    case D3D_PRIMITIVE_TOPOLOGY_LINELIST: return WMTPrimitiveTypeLine;
    case D3D_PRIMITIVE_TOPOLOGY_LINESTRIP: return WMTPrimitiveTypeLineStrip;
    case D3D_PRIMITIVE_TOPOLOGY_TRIANGLESTRIP: return WMTPrimitiveTypeTriangleStrip;
    default: return WMTPrimitiveTypeTriangle;
    }
}


/* ml878: pipeline variant for the strides a draw actually binds. */
static obj_handle_t mad_pso_for_strides(struct mad_pso *p, const UINT strides[16]) {
    unsigned k, i; obj_handle_t err = 0, rps;
    struct WMTVertexDescriptorInfo vd;
    static unsigned said;
    for (i = 0; i < 16; i++) if ((p->vb_mask & (1u << i)) && strides[i] != p->vb_stride[i]) break;
    if (i == 16) return p->rps;                      /* the base pipeline already matches */
    EnterCriticalSection(&p->var_lock);
    for (k = 0; k < p->nvar; k++) if (!memcmp(p->var[k].strides, strides, sizeof p->var[k].strides)) {
        rps = p->var[k].rps; LeaveCriticalSection(&p->var_lock); return rps;
    }
    vd = p->vd;
    for (i = 0; i < 16; i++) if (p->vb_mask & (1u << i)) {
        if (strides[i] == 0) {
            /* ml904: constant step -- one element for every vertex. Metal's
             * MTLVertexStepFunctionConstant (0) with step rate 0; the stride
             * is kept at the packed size so the element's own layout stands. */
            vd.layouts[6 + i].step_function = 0; vd.layouts[6 + i].step_rate = 0;
            vd.layouts[6 + i].stride = p->vb_stride[i];
        } else vd.layouts[6 + i].stride = strides[i];
    }
    rps = MTLDevice_newRenderPipelineStateVD(p->device_handle, &p->rp, &vd, &err);
    if (err) NSObject_release(err);
    if (!rps) {
        /* ml904: second try for the constant case with a zero stride, in case
         * this Metal wants the layout that way. */
        int retry = 0;
        for (i = 0; i < 16; i++) if ((p->vb_mask & (1u << i)) && strides[i] == 0) { vd.layouts[6 + i].stride = 0; retry = 1; }
        if (retry) { err = 0; rps = MTLDevice_newRenderPipelineStateVD(p->device_handle, &p->rp, &vd, &err); if (err) NSObject_release(err); }
    }
    if (!rps) {
        if (said++ < 8) d3d12_log("[madeira-d3d12] stride variant failed (slot0 stride %u vs assumed %u, slot1 stride %u); using the base pipeline\n",
                                  strides[0], p->vb_stride[0], strides[1]);
        LeaveCriticalSection(&p->var_lock); return p->rps;
    }
    if (p->nvar < 8) { memcpy(p->var[p->nvar].strides, strides, sizeof p->var[0].strides); p->var[p->nvar].rps = rps; p->nvar++; }
    else { NSObject_release(p->var[0].rps); memmove(&p->var[0], &p->var[1], sizeof p->var[0] * 7);
           memcpy(p->var[7].strides, strides, sizeof p->var[0].strides); p->var[7].rps = rps; }
    if (said < 8) { said++; d3d12_log("[madeira-d3d12] pipeline stride variant built (%u variants cached)\n", p->nvar); }
    LeaveCriticalSection(&p->var_lock);
    return rps;
}

static unsigned g_cap_kinds;   /* ml910: kinds captured since the last flush */
static unsigned g_k9_n;        /* ml929: K9 captures since the last flush */
static struct mad_resource *mad_resolve_address(struct mad_device *d, UINT64 addr, UINT64 *off);
/* ml913: name every table entry that is a buffer descriptor pointing at no
 * live resource (host shader validation reported 8132 "Invalid device load ...
 * out of bounds of user address space" from compute kernels). Census frames
 * only: the resolve walks the live list. */
static void exec_desc_check(struct mad_exec *e, const struct mad_rootsig *rs, const UINT64 *root, const char *who) {
    static unsigned said, checked;
    unsigned i, k;
    if (!rs || !e->srv || !e->srv->cpu || said >= 40 || checked++ > 20000) return;
    for (i = 0; i < rs->nparams && i < MAD_ROOT_PARAM_MAX; i++) {
        UINT64 va = root[i]; unsigned idx;
        if (rs->params[i].type != MADEIRA_IR_PARAM_TABLE || !va) continue;
        if (va < e->srv->gpu_address || va >= e->srv->gpu_address + (UINT64)e->srv->count * sizeof(struct mad_descriptor)) continue;
        idx = (unsigned)((va - e->srv->gpu_address) / sizeof(struct mad_descriptor));
        for (k = 0; k < 16 && idx + k < e->srv->count; k++) {
            const struct mad_descriptor *de = &e->srv->cpu[idx + k];
            UINT64 off = 0;
            if (de->texture_view_id || !de->gpu_va) continue;
            if (!mad_resolve_address(e->q->device, de->gpu_va, &off) && said++ < 40)
                d3d12_log("[desc-check] '%s' table p%u heap[%u]: buffer descriptor va=%llx size=%llu points at NO live resource%s\n",
                          who, i, idx + k, (unsigned long long)de->gpu_va, (unsigned long long)(de->metadata & 0xffffffffu),
                          (e->q->device->null_gpu && de->gpu_va >= e->q->device->null_gpu && de->gpu_va < e->q->device->null_gpu + 65536) ? " (= the runtime's null buffer)" : "");
        }
    }
}
/* ml910: copy `len` bytes of a GPU buffer into the capture ring, GPU-ordered
 * (a blit in this command buffer, before the draw that follows). */
static int exec_capture_bytes(struct mad_exec *e, const char *label, struct mad_resource *r, UINT64 off, UINT len, UINT kind) {
    struct mad_device *d = e->q->device;
    struct wmtcmd_blit_copy_from_buffer_to_buffer k;
    if (!r || !r->buffer || off + len > r->size || d->ncap >= 96) return 0;
    if (!d->cap_buf) {
        struct WMTBufferInfo bi; memset(&bi, 0, sizeof bi);
        bi.length = 65536; bi.options = WMTResourceStorageModeShared;
        d->cap_buf = MTLDevice_newBuffer(d->mtl_device, &bi);
        if (!d->cap_buf || !bi.memory.ptr) { d->cap_buf = 0; return 0; }
        d->cap_cpu = bi.memory.ptr;
    }
    if (d->cap_used + len > 65536) return 0;
    if (!exec_begin_blit(e)) return 0;
    memset(&k, 0, sizeof k);
    k.type = WMTBlitCommandCopyFromBufferToBuffer;
    k.src = r->buffer; k.src_offset = off; k.dst = d->cap_buf; k.dst_offset = d->cap_used; k.copy_length = len;
    MTLBlitCommandEncoder_encodeCommands(e->benc, (const struct wmtcmd_base *)&k);
    snprintf(d->cap[d->ncap].label, sizeof d->cap[d->ncap].label, "%s", label);
    d->cap[d->ncap].off = d->cap_used; d->cap[d->ncap].len = len; d->cap[d->ncap].kind = kind;
    d->ncap++; d->cap_used += (len + 15) & ~15u; d->cap_total++;
    return 1;
}

/* ml918: which resource (and which of its views) a texture descriptor names. */
static struct mad_resource *mad_texture_of_view(struct mad_device *d, UINT64 id, int *xv) {
    /* Textures are not in the live (GPU-address) list; every texture that has
     * ever had an SRV or UAV is in srv_res / uav_res, which is what a table
     * entry can name. */
    unsigned i, k, pass;
    *xv = -1;
    if (!id) return NULL;
    for (pass = 0; pass < 2; pass++) {
        struct mad_resource **list = pass ? d->uav_res : d->srv_res; unsigned n = pass ? d->nuav : d->nsrv;
        for (i = 0; i < n; i++) {
            struct mad_resource *r = list[i];
            if (!r || !r->texture) continue;
            if (r->gpu_resource_id == id) return r;
            for (k = 0; k < r->nxview; k++) if (r->xview[k].id == id) { *xv = (int)k; return r; }
        }
    }
    return NULL;
}
static UINT mad_pf_bytes(UINT pf) {
    switch (pf) {
    case 10: case 13: return 1;
    case 25: case 30: return 2;
    case 53: case 54: case 55: case 65: case 70: case 71: case 80: case 81: case 90: case 92: return 4;
    case 103: case 105: case 110: case 115: return 8;
    case 125: return 16;
    default: return 0;
    }
}
/* A 4x4 block at the centre of one subresource, GPU-ordered, into the ring. */
/* ml924: a rectangle of one subresource (array slice, or z-slice of a 3D
 * texture), GPU-ordered, into the ring. seq=1 records the texel count so the
 * printer lists every texel in order (small textures: histograms, grids). */
static int exec_capture_region(struct mad_exec *e, const char *label, struct mad_resource *r, UINT slice, UINT level,
                               UINT x0, UINT y0, UINT rw, UINT rh, int seq) {
    struct mad_device *d = e->q->device;
    struct wmtcmd_blit_copy_from_texture_to_buffer k;
    UINT bpp = mad_pf_bytes((UINT)r->tex_pf), w, h, len;
    if (!r->texture || !bpp || r->is_depth || r->samples > 1 || d->ncap >= 96) return 0;
    w = r->width >> level; h = r->height >> level; if (!w || !h) return 0;
    if (x0 >= w || y0 >= h) return 0;
    if (x0 + rw > w) rw = w - x0; if (y0 + rh > h) rh = h - y0;
    len = rw * rh * bpp;
    if (!d->cap_buf) {
        struct WMTBufferInfo bi; memset(&bi, 0, sizeof bi);
        bi.length = 65536; bi.options = WMTResourceStorageModeShared;
        d->cap_buf = MTLDevice_newBuffer(d->mtl_device, &bi);
        if (!d->cap_buf || !bi.memory.ptr) { d->cap_buf = 0; return 0; }
        d->cap_cpu = bi.memory.ptr;
    }
    if (d->cap_used + len > 65536) return 0;
    if (!exec_begin_blit(e)) return 0;
    memset(&k, 0, sizeof k);
    k.type = WMTBlitCommandCopyFromTextureToBuffer;
    k.src = r->texture; k.level = level;
    if (r->tex_type == WMTTextureType3D) { k.slice = 0; k.origin.z = slice < r->tex_depth ? slice : 0; }
    else { k.slice = slice; k.origin.z = 0; }
    k.origin.x = x0; k.origin.y = y0; k.size.width = rw; k.size.height = rh; k.size.depth = 1;
    k.bytes_per_row = rw * bpp; k.bytes_per_image = len;
    k.dst = d->cap_buf; k.offset = d->cap_used;
    MTLBlitCommandEncoder_encodeCommands(e->benc, (const struct wmtcmd_base *)&k);
    snprintf(d->cap[d->ncap].label, sizeof d->cap[0].label, "%s", label);
    d->cap[d->ncap].off = d->cap_used; d->cap[d->ncap].len = len; d->cap[d->ncap].kind = 100 + (UINT)r->tex_pf;
    d->cap[d->ncap].nt = seq ? rw * rh : 0;
    d->ncap++; d->cap_used += (len + 15) & ~15u; d->cap_total++;
    return 1;
}
/* A 4x4 block at the centre of one subresource; the whole level when it has
 * at most 256 texels (then every texel is listed in order). */
static int exec_capture_texels(struct mad_exec *e, const char *label, struct mad_resource *r, UINT slice, UINT level) {
    UINT w = r->width >> level, h = r->height >> level;
    if (!w || !h) return 0;
    if (w * h <= 256) return exec_capture_region(e, label, r, slice, level, 0, 0, w, h, 1);
    if (w < 4 || h < 4) return exec_capture_region(e, label, r, slice, level, 0, 0, 1, 1, 1);
    return exec_capture_region(e, label, r, slice, level, w / 2 - 2, h / 2 - 2, 4, 4, 0);
}

/* ml918: the post-process chain. For the first three 816-wide single-target
 * draws and the first ScreenPassVS draw into the 960x540 back buffer: every
 * texture descriptor in every table (resolved to its resource and view), a
 * 4x4 centre block of the first few inputs BEFORE the draw, the root CBVs,
 * and (from exec_draw) a 4x4 centre block of the output AFTER the draw. */
static void exec_capture_pp(struct mad_exec *e, unsigned kind) {
    struct mad_device *d = e->q->device;
    unsigned i, k, grabbed = 0; char lab[160];
    d3d12_log("[cap] K%u list#%u PP vs='%s' ps='%s' rt0=%ux%u pf%u (%s)\n", kind, g_list_seq, e->pso->vs_name, e->pso->ps_name,
              e->rt[0]->width, e->rt[0]->height, (unsigned)e->rt[0]->tex_pf, e->rt[0]->name);
    if (e->rs && e->srv && e->srv->cpu) for (i = 0; i < e->rs->nparams && i < MAD_ROOT_PARAM_MAX; i++) {
        UINT64 va = e->root[i]; unsigned idx; char line[900]; int n;
        if (e->rs->params[i].type != MADEIRA_IR_PARAM_TABLE || !va) continue;
        if (va < e->srv->gpu_address || va >= e->srv->gpu_address + (UINT64)e->srv->count * sizeof(struct mad_descriptor)) continue;
        idx = (unsigned)((va - e->srv->gpu_address) / sizeof(struct mad_descriptor));
        n = snprintf(line, sizeof line, "[cap] K%u table p%u heap[%u..] (%u):", kind, i, idx, mad_table_count(e->rs, i, 12));
        for (k = 0; k < mad_table_count(e->rs, i, 12) && idx + k < e->srv->count && n < (int)sizeof line - 120; k++) {
            const struct mad_descriptor *de = &e->srv->cpu[idx + k];
            if (de->texture_view_id) {
                int xv; struct mad_resource *r = mad_texture_of_view(d, de->texture_view_id, &xv);
                if (!r) n += snprintf(line + n, sizeof line - n, " [%u]tex%llx=?", k, (unsigned long long)de->texture_view_id);
                else if (xv < 0) n += snprintf(line + n, sizeof line - n, " [%u]%s %ux%u pf%u t%u", k, r->name, r->width, r->height, (unsigned)r->tex_pf, (unsigned)r->tex_type);
                else n += snprintf(line + n, sizeof line - n, " [%u]%s %ux%u pf%u t%u VIEW(t%u pf%u swz%x l%u+%u s%u+%u)", k, r->name, r->width, r->height,
                                   (unsigned)r->tex_pf, (unsigned)r->tex_type, r->xview[xv].type, r->xview[xv].pf, r->xview[xv].swz,
                                   r->xview[xv].lvl0, r->xview[xv].nlvl, r->xview[xv].sl0, r->xview[xv].nsl);
                if (r && grabbed < 12 && !r->is_depth && (de->metadata >> 63) == 0) {
                    UINT sl = xv >= 0 ? r->xview[xv].sl0 : 0, lv = xv >= 0 ? r->xview[xv].lvl0 : 0;
                    if (r->tex_type == WMTTextureType3D) {   /* ml924: the middle z-slice, and texel (0,0,0) */
                        sl = r->tex_depth / 2;
                        snprintf(lab, sizeof lab, "K%u IN p%u[%u] %s %ux%u pf%u origin z0", kind, i, k, r->name, r->width, r->height, (unsigned)r->tex_pf);
                        exec_capture_region(e, lab, r, 0, lv, 0, 0, 1, 1, 1);
                    }
                    snprintf(lab, sizeof lab, "K%u IN p%u[%u] %s %ux%u pf%u s%u l%u", kind, i, k, r->name, r->width, r->height, (unsigned)r->tex_pf, sl, lv);
                    if (exec_capture_texels(e, lab, r, sl, lv)) grabbed++;
                }
            } else if (de->gpu_va) {
                UINT64 off = 0; struct mad_resource *r = mad_resolve_address(d, de->gpu_va, &off);
                n += snprintf(line + n, sizeof line - n, " [%u]buf+%llu/%llu%s", k, (unsigned long long)off, (unsigned long long)(de->metadata & 0xffffffffu), r ? "" : "(NOT LIVE)");
                if (r && grabbed < 8) {   /* ml921: buffer inputs too (exposure lives in one) */
                    snprintf(lab, sizeof lab, "K%u IN p%u[%u] buffer %s+%llu (%llu B)", kind, i, k, r->cpu ? "upload" : "default", (unsigned long long)off, (unsigned long long)r->size);
                    if (exec_capture_bytes(e, lab, r, off, 64, 15)) grabbed++;
                }
            } else n += snprintf(line + n, sizeof line - n, " [%u]null", k);
        }
        d3d12_log("%s\n", line);
    }
    if (e->rs) for (i = 0; i < e->rs->nparams && i < MAD_ROOT_PARAM_MAX; i++) {
        UINT64 off = 0; struct mad_resource *r;
        if (e->rs->params[i].type != MADEIRA_IR_PARAM_CBV || !e->root[i]) continue;
        r = mad_resolve_address(d, e->root[i], &off);
        snprintf(lab, sizeof lab, "K%u rootCBV p%u -> %s+%llu", kind, i, r ? (r->cpu ? "upload" : "default") : "UNRESOLVED", (unsigned long long)off);
        if (r) exec_capture_bytes(e, lab, r, off, 96, 16);
    }
    e->cap_after = kind;
}

/* ml920: the compute producer of the black post-process input. In census
 * frames, the first dispatch whose tables name a texture of width 816 in
 * RG11B10F (the temporal upscaler's output): every table entry resolved, a
 * 4x4 centre block of that texture BEFORE the dispatch, the root CBVs, and
 * (from exec_dispatch) the same block AFTER it. */
/* ml930: how many descriptors a table parameter actually spans (the sum of
 * its ranges); scanning past that reads the NEXT table's descriptors and
 * attributed neighbours' resources to the wrong dispatch. Unbounded ranges
 * keep the old cap. */
static unsigned mad_table_count(const struct mad_rootsig *rs, unsigned i, unsigned cap) {
    unsigned n = 0, k;
    if (!rs || i >= rs->nparams) return cap;
    for (k = 0; k < rs->params[i].num_ranges; k++) {
        unsigned ri = rs->params[i].first_range + k, nd;
        if (ri >= rs->nranges) return cap;
        nd = rs->ranges[ri].num_descriptors;
        if (nd == 0xffffffffu || nd > 4096) return cap;
        if (rs->ranges[ri].table_offset != 0xffffffffu && rs->ranges[ri].table_offset + nd > n) n = rs->ranges[ri].table_offset + nd;
        else n += nd;
    }
    return n && n < cap ? n : cap;
}
static void exec_capture_cs(struct mad_exec *e, const struct mad_cmd *c) {
    struct mad_device *d = e->q->device;
    struct mad_resource *target = NULL; unsigned i, k; char lab[160];
    if (!e->crs || !e->srv || !e->srv->cpu || d->cap_total >= 2000) return;
    /* ml922/ml924: named kernels of the exposure chain, and the kernel that
     * writes the local-exposure grid. Every table entry resolved; textures and
     * buffers captured BEFORE and AFTER the dispatch, plus the root CBVs. */
    {
        unsigned kind = 0; const char *nm = e->cpso->vs_name;
        if (!strcmp(nm, "EyeAdaptationCS")) kind = 10;
        else if (!strcmp(nm, "HistogramConvertCS")) kind = 11;
        else if (!strcmp(nm, "MainAtomicCS")) kind = 12;
        else if (!(g_cap_kinds & (1u << 13))) {   /* the grid producer: any table naming a 3D RG32Float texture */
            for (i = 0; i < e->crs->nparams && i < MAD_ROOT_PARAM_MAX && !kind; i++) {
                UINT64 va = e->croot[i]; unsigned idx;
                if (e->crs->params[i].type != MADEIRA_IR_PARAM_TABLE || !va) continue;
                if (va < e->srv->gpu_address || va >= e->srv->gpu_address + (UINT64)e->srv->count * sizeof(struct mad_descriptor)) continue;
                idx = (unsigned)((va - e->srv->gpu_address) / sizeof(struct mad_descriptor));
                for (k = 0; k < 8 && idx + k < e->srv->count; k++) {
                    const struct mad_descriptor *de = &e->srv->cpu[idx + k]; int xv; struct mad_resource *r;
                    if (!de->texture_view_id || (de->metadata >> 63)) continue;
                    r = mad_texture_of_view(d, de->texture_view_id, &xv);
                    if (r && r->tex_type == WMTTextureType3D && r->tex_pf == 105) { kind = 13; break; }
                }
            }
        }
        if (kind && !(g_cap_kinds & (1u << kind))) {
            g_cap_kinds |= 1u << kind;
            d3d12_log("[cap] K%u list#%u CS '%s' %ux%ux%u\n", kind, g_list_seq, nm,
                      c->kind == MC_DISPATCH ? c->u.dispatch.x : 0, c->kind == MC_DISPATCH ? c->u.dispatch.y : 0, c->kind == MC_DISPATCH ? c->u.dispatch.z : 0);
            for (i = 0; i < e->crs->nparams && i < MAD_ROOT_PARAM_MAX; i++) {
                UINT64 va = e->croot[i]; unsigned idx; char line[900]; int n;
                if (e->crs->params[i].type == MADEIRA_IR_PARAM_CBV && va) {
                    UINT64 off = 0; struct mad_resource *r = mad_resolve_address(d, va, &off);
                    snprintf(lab, sizeof lab, "K%u rootCBV p%u -> %s+%llu", kind, i, r ? (r->cpu ? "upload" : "default") : "UNRESOLVED", (unsigned long long)off);
                    if (r) exec_capture_bytes(e, lab, r, off, 96, 16); else d3d12_log("[cap] %s\n", lab);
                    continue;
                }
                if (e->crs->params[i].type != MADEIRA_IR_PARAM_TABLE || !va) continue;
                if (va < e->srv->gpu_address || va >= e->srv->gpu_address + (UINT64)e->srv->count * sizeof(struct mad_descriptor)) continue;
                idx = (unsigned)((va - e->srv->gpu_address) / sizeof(struct mad_descriptor));
                n = snprintf(line, sizeof line, "[cap] K%u table p%u heap[%u..] (%u):", kind, i, idx, mad_table_count(e->crs, i, 8));
                for (k = 0; k < mad_table_count(e->crs, i, 8) && idx + k < e->srv->count && n < (int)sizeof line - 120; k++) {
                    const struct mad_descriptor *de = &e->srv->cpu[idx + k];
                    if (de->texture_view_id) {
                        int xv; struct mad_resource *r = mad_texture_of_view(d, de->texture_view_id, &xv);
                        if (!r) n += snprintf(line + n, sizeof line - n, " [%u]tex%llx=?%s", k, (unsigned long long)de->texture_view_id, (de->metadata >> 63) ? "(typedbuf)" : "");
                        else {
                            UINT sl = r->tex_type == WMTTextureType3D ? r->tex_depth / 2 : 0;
                            n += snprintf(line + n, sizeof line - n, " [%u]%s %ux%u pf%u t%u%s", k, r->name, r->width, r->height, (unsigned)r->tex_pf, (unsigned)r->tex_type, (de->metadata >> 63) ? "(typedbuf)" : "");
                            if (de->metadata >> 63) continue;
                            snprintf(lab, sizeof lab, "K%u IN p%u[%u] %s %ux%u pf%u z%u", kind, i, k, r->name, r->width, r->height, (unsigned)r->tex_pf, sl); exec_capture_texels(e, lab, r, sl, 0);
                            if (e->ncap_after_tex < 6 && r->width * r->height <= 256) { e->cap_after_tex[e->ncap_after_tex].r = r; e->cap_after_tex[e->ncap_after_tex].slice = sl;
                                snprintf(e->cap_after_tex[e->ncap_after_tex].label, 96, "K%u AFTER p%u[%u] %s %ux%u pf%u z%u", kind, i, k, r->name, r->width, r->height, (unsigned)r->tex_pf, sl); e->ncap_after_tex++; }
                        }
                    } else if (de->gpu_va) {
                        UINT64 off = 0; struct mad_resource *r = mad_resolve_address(d, de->gpu_va, &off);
                        n += snprintf(line + n, sizeof line - n, " [%u]buf+%llu/%llu%s", k, (unsigned long long)off, (unsigned long long)(de->metadata & 0xffffffffu), r ? "" : "(NOT LIVE)");
                        if (r) {
                            snprintf(lab, sizeof lab, "K%u BEFORE p%u[%u] buffer+%llu", kind, i, k, (unsigned long long)off); exec_capture_bytes(e, lab, r, off, 64, 15);
                            if (e->ncap_after_buf < 6) { e->cap_after_buf[e->ncap_after_buf].r = r; e->cap_after_buf[e->ncap_after_buf].off = off;
                                snprintf(e->cap_after_buf[e->ncap_after_buf].label, 96, "K%u AFTER p%u[%u] buffer+%llu", kind, i, k, (unsigned long long)off); e->ncap_after_buf++; }
                        }
                    } else n += snprintf(line + n, sizeof line - n, " [%u]null", k);
                }
                d3d12_log("%s\n", line);
            }
            /* ml930: fall through to the K9 scan; a dispatch can be both (the
             * 102x58 kernel with the grid AND the 816x460 output was hidden) */
        }
    }
    /* ml929: every dispatch in the census frame that names the 816-wide
     * RG11B10F texture (the upscaler's output), not just the first: the one
     * whose OUT differs from its IN is the writer. */
    if (g_k9_n >= 10) return;
    for (i = 0; i < e->crs->nparams && i < MAD_ROOT_PARAM_MAX && !target; i++) {
        UINT64 va = e->croot[i]; unsigned idx;
        if (e->crs->params[i].type != MADEIRA_IR_PARAM_TABLE || !va) continue;
        if (va < e->srv->gpu_address || va >= e->srv->gpu_address + (UINT64)e->srv->count * sizeof(struct mad_descriptor)) continue;
        idx = (unsigned)((va - e->srv->gpu_address) / sizeof(struct mad_descriptor));
        for (k = 0; k < 12 && idx + k < e->srv->count; k++) {
            const struct mad_descriptor *de = &e->srv->cpu[idx + k]; int xv; struct mad_resource *r;
            if (!de->texture_view_id || (de->metadata >> 63)) continue;
            r = mad_texture_of_view(d, de->texture_view_id, &xv);
            if (r && r->width == 816 && r->tex_pf == WMTPixelFormatRG11B10Float) { target = r; break; }
        }
    }
    if (!target) return;
    g_cap_kinds |= 1u << 9; g_k9_n++;
    { unsigned k9_big = 0;
    d3d12_log("[cap] K9 list#%u CS '%s' pso=%p %ux%ux%u names %s %ux%u pf%u\n", g_list_seq, e->cpso->vs_name, (void *)e->cpso,
              c->kind == MC_DISPATCH ? c->u.dispatch.x : 0, c->kind == MC_DISPATCH ? c->u.dispatch.y : 0, c->kind == MC_DISPATCH ? c->u.dispatch.z : 0,
              target->name, target->width, target->height, (unsigned)target->tex_pf);
    for (i = 0; i < e->crs->nparams && i < MAD_ROOT_PARAM_MAX; i++) {
        UINT64 va = e->croot[i]; unsigned idx; char line[900]; int n;
        if (e->crs->params[i].type == MADEIRA_IR_PARAM_CBV && va) {
            UINT64 off = 0; struct mad_resource *r = mad_resolve_address(d, va, &off);
            snprintf(lab, sizeof lab, "K9 rootCBV p%u -> %s+%llu", i, r ? (r->cpu ? "upload" : "default") : "UNRESOLVED", (unsigned long long)off);
            if (r) exec_capture_bytes(e, lab, r, off, 96, 16); else d3d12_log("[cap] %s\n", lab);
            continue;
        }
        if (e->crs->params[i].type != MADEIRA_IR_PARAM_TABLE || !va) continue;
        if (va < e->srv->gpu_address || va >= e->srv->gpu_address + (UINT64)e->srv->count * sizeof(struct mad_descriptor)) {
            d3d12_log("[cap] K9 table p%u va=%llx not in the SRV heap\n", i, (unsigned long long)va); continue; }
        idx = (unsigned)((va - e->srv->gpu_address) / sizeof(struct mad_descriptor));
        n = snprintf(line, sizeof line, "[cap] K9 table p%u heap[%u..] (%u):", i, idx, mad_table_count(e->crs, i, 12));
        for (k = 0; k < mad_table_count(e->crs, i, 12) && idx + k < e->srv->count && n < (int)sizeof line - 120; k++) {
            const struct mad_descriptor *de = &e->srv->cpu[idx + k];
            if (de->texture_view_id) {
                int xv; struct mad_resource *r = mad_texture_of_view(d, de->texture_view_id, &xv);
                if (!r) n += snprintf(line + n, sizeof line - n, " [%u]tex%llx=?%s", k, (unsigned long long)de->texture_view_id, (de->metadata >> 63) ? "(typedbuf)" : "");
                else {
                    n += snprintf(line + n, sizeof line - n, " [%u]%s %ux%u pf%u t%u%s", k, r->name, r->width, r->height, (unsigned)r->tex_pf, (unsigned)r->tex_type, xv >= 0 ? " VIEW" : "");
                    if (xv >= 0) n += snprintf(line + n, sizeof line - n, "(t%u pf%u l%u+%u s%u+%u)", r->xview[xv].type, r->xview[xv].pf, r->xview[xv].lvl0, r->xview[xv].nlvl, r->xview[xv].sl0, r->xview[xv].nsl);
                    if (r->width >= 400 && !r->is_depth && !(de->metadata >> 63) && r != target && k9_big < 6) {   /* ml930: the big inputs (history) too */
                        UINT sl = xv >= 0 ? r->xview[xv].sl0 : 0, lv = xv >= 0 ? r->xview[xv].lvl0 : 0;
                        snprintf(lab, sizeof lab, "K9 IN p%u[%u] %s %ux%u pf%u s%u l%u", i, k, r->name, r->width, r->height, (unsigned)r->tex_pf, sl, lv);
                        if (exec_capture_texels(e, lab, r, sl, lv)) k9_big++;
                        snprintf(lab, sizeof lab, "K9 IN p%u[%u] %s at (100,100)", i, k, r->name);
                        exec_capture_region(e, lab, r, sl, lv, 100, 100, 4, 4, 0);
                    }
                }
            } else if (de->gpu_va) {
                UINT64 off = 0; struct mad_resource *r = mad_resolve_address(d, de->gpu_va, &off);
                n += snprintf(line + n, sizeof line - n, " [%u]buf+%llu/%llu%s", k, (unsigned long long)off, (unsigned long long)(de->metadata & 0xffffffffu), r ? "" : "(NOT LIVE)");
            } else n += snprintf(line + n, sizeof line - n, " [%u]null", k);
        }
        d3d12_log("%s\n", line);
    }
    snprintf(lab, sizeof lab, "K9 IN before '%s' %s %ux%u pf%u", e->cpso->vs_name, target->name, target->width, target->height, (unsigned)target->tex_pf);
    exec_capture_texels(e, lab, target, 0, 0);
    snprintf(lab, sizeof lab, "K9 IN before '%s' %s at (100,100)", e->cpso->vs_name, target->name);
    exec_capture_region(e, lab, target, 0, 0, 100, 100, 4, 4, 0);
    e->cap_after_cs = target;
    }
}

/* Pick a few draws per census frame: an indirect scene-depth draw, an indirect
 * base-pass draw, a direct indexed base-pass draw, a direct scene-depth draw.
 * For each: the indirect args (or the first indices), the first vertices of
 * stream 0 and 1, and the first 64 bytes of every root CBV. */
static void exec_capture_draw(struct mad_exec *e, const struct mad_cmd *c) {
    struct mad_device *d = e->q->device;
    char lab[160]; unsigned i;
    int indirect = (c->kind == MC_DRAW_INDIRECT || c->kind == MC_DRAW_INDEXED_INDIRECT);
    int scene_depth = e->depth && e->depth->width == 736 && e->nrt == 0;
    int base_pass = e->nrt >= 5;
    unsigned kind = indirect ? (scene_depth ? 1 : base_pass ? 2 : 0) : (base_pass && c->kind == MC_DRAW_INDEXED ? 3 : scene_depth && c->kind == MC_DRAW_INDEXED ? 4 : 0);
    if (!kind && e->nrt == 1 && e->rt[0] && !e->depth) {   /* ml918: post-process chain */
        if (e->rt[0]->width == 816) kind = !(g_cap_kinds & (1u << 5)) ? 5 : !(g_cap_kinds & (1u << 6)) ? 6 : !(g_cap_kinds & (1u << 7)) ? 7 : 0;
        else if (e->rt[0]->width == 960 && e->rt[0]->height == 540 && !strcmp(e->pso->vs_name, "ScreenPassVS")) kind = 8;
    }
    if (!kind || d->cap_total >= 2000) return;
    if (g_cap_kinds & (1u << kind)) return;   /* each kind once per fence interval */
    g_cap_kinds |= 1u << kind;
    if (kind >= 5) { exec_capture_pp(e, kind); return; }
    if (indirect)
        snprintf(lab, sizeof lab, "K%u list#%u %s vs='%s' ps='%s' rt=%u ARGS@%llu", kind, g_list_seq,
                 c->kind == MC_DRAW_INDEXED_INDIRECT ? "dii" : "di", e->pso->vs_name, e->pso->ps_name, e->nrt, (unsigned long long)c->u.ind.off);
    else
        snprintf(lab, sizeof lab, "K%u list#%u dix vs='%s' ps='%s' rt=%u idx=%u start=%u base=%d inst=%u", kind, g_list_seq,
                 e->pso->vs_name, e->pso->ps_name, e->nrt, c->u.drawi.icount, c->u.drawi.start, (int)c->u.drawi.base, c->u.drawi.inst);
    d3d12_log("[cap] %s\n", lab);
    if (indirect) exec_capture_bytes(e, lab, c->u.ind.args, c->u.ind.off, 20, 10);
    if (e->ib && e->ib->buffer) {
        UINT isz = e->ib_type == WMTIndexTypeUInt32 ? 4 : 2;
        UINT64 o = e->ib_off + (c->kind == MC_DRAW_INDEXED ? (UINT64)c->u.drawi.start * isz : 0);
        snprintf(lab, sizeof lab, "K%u indices@%llu/%s", kind, (unsigned long long)o, isz == 4 ? "u32" : "u16");
        exec_capture_bytes(e, lab, e->ib, o, 48, isz == 4 ? 11 : 12);
    }
    for (i = 0; i < 3; i++) if (e->vb[i].res && e->vb[i].res->buffer) {
        snprintf(lab, sizeof lab, "K%u vb%u@%llu st%u", kind, i, (unsigned long long)e->vb[i].off, e->vb[i].stride);
        exec_capture_bytes(e, lab, e->vb[i].res, e->vb[i].off, 48, 13);
    }
    if (e->rs) for (i = 0; i < e->rs->nparams && i < MAD_ROOT_PARAM_MAX; i++) {
        UINT64 off = 0; struct mad_resource *r;
        if (e->rs->params[i].type != MADEIRA_IR_PARAM_CBV || !e->root[i]) continue;
        r = mad_resolve_address(d, e->root[i], &off);
        snprintf(lab, sizeof lab, "K%u rootCBV p%u va=%llx -> %s+%llu", kind, i, (unsigned long long)e->root[i], r ? (r->cpu ? "upload" : "default") : "UNRESOLVED", (unsigned long long)off);
        if (r) exec_capture_bytes(e, lab, r, off, 96, 16); else d3d12_log("[cap] %s\n", lab);
    }
    {
        char line[600]; int n = snprintf(line, sizeof line, "[cap] K%u root:", kind);
        for (i = 0; i < 12 && n < (int)sizeof line - 24; i++) n += snprintf(line + n, sizeof line - n, " %llx", (unsigned long long)e->root[i]);
        d3d12_log("%s\n", line);
    }
    /* ml911: the descriptor tables. Entries are CPU-authored (the heap is
     * shared memory the application wrote), so reading them here is exact;
     * the BUFFERS they point at are GPU-written (GPUScene), so those are
     * captured GPU-ordered like everything else. */
    if (e->rs && e->srv && e->srv->cpu) for (i = 0; i < e->rs->nparams && i < MAD_ROOT_PARAM_MAX; i++) {
        UINT64 va = e->root[i]; unsigned k, idx; char line[900]; int n;
        if (e->rs->params[i].type != MADEIRA_IR_PARAM_TABLE || !va) continue;
        if (va < e->srv->gpu_address || va >= e->srv->gpu_address + (UINT64)e->srv->count * sizeof(struct mad_descriptor)) {
            d3d12_log("[cap] K%u table p%u va=%llx is not in the bound SRV heap (%s)\n", kind, i, (unsigned long long)va,
                      (e->smp && va >= e->smp->gpu_address && va < e->smp->gpu_address + (UINT64)e->smp->count * sizeof(struct mad_descriptor)) ? "sampler heap" : "unknown");
            continue;
        }
        idx = (unsigned)((va - e->srv->gpu_address) / sizeof(struct mad_descriptor));
        n = snprintf(line, sizeof line, "[cap] K%u table p%u heap[%u..]:", kind, i, idx);
        for (k = 0; k < 10 && idx + k < e->srv->count && n < (int)sizeof line - 80; k++) {
            const struct mad_descriptor *de = &e->srv->cpu[idx + k];
            if (de->texture_view_id) n += snprintf(line + n, sizeof line - n, " [%u]tex%llx%s", k, (unsigned long long)de->texture_view_id, (de->metadata >> 63) ? "(typedbuf)" : "");
            else if (de->gpu_va) {
                UINT64 off = 0; struct mad_resource *r = mad_resolve_address(d, de->gpu_va, &off);
                n += snprintf(line + n, sizeof line - n, " [%u]buf%llx+%llu/%llu%s", k, (unsigned long long)de->gpu_va, (unsigned long long)off,
                              (unsigned long long)(de->metadata & 0xffffffffu), r ? (r->cpu ? "u" : "d") : "?");
                if (r && k < 6) { snprintf(lab, sizeof lab, "K%u p%u[%u] buf+%llu (%s, %llu B)", kind, i, k, (unsigned long long)off, r->cpu ? "upload" : "default", (unsigned long long)r->size);
                                  exec_capture_bytes(e, lab, r, off, 64, 15); }
            } else n += snprintf(line + n, sizeof line - n, " [%u]null", k);
        }
        d3d12_log("%s\n", line);
    }
}

static float mad_half(USHORT h) {
    UINT s = (h >> 15) & 1, e = (h >> 10) & 31, m = h & 1023; float f;
    if (e == 0) f = ldexpf((float)m, -24); else if (e == 31) f = m ? NAN : INFINITY; else f = ldexpf((float)(m | 1024), (int)e - 25);
    return s ? -f : f;
}
static float mad_f11(UINT v) { UINT e = (v >> 6) & 31, m = v & 63; if (e == 0) return ldexpf((float)m, -20); if (e == 31) return m ? NAN : INFINITY; return ldexpf((float)(m | 64), (int)e - 21); }
static float mad_f10(UINT v) { UINT e = (v >> 5) & 31, m = v & 31; if (e == 0) return ldexpf((float)m, -19); if (e == 31) return m ? NAN : INFINITY; return ldexpf((float)(m | 32), (int)e - 20); }

/* Print every capture whose command buffer has completed (called after the
 * fence wait, so all of them have). */
static void mad_capture_flush(struct mad_device *d) {
    unsigned i, j;
    g_cap_kinds = 0; g_k9_n = 0;
    if (!d->ncap) return;
    for (i = 0; i < d->ncap; i++) {
        const unsigned char *p = d->cap_cpu + d->cap[i].off;
        char line[900]; int n = snprintf(line, sizeof line, "[cap-data] %s:", d->cap[i].label);
        switch (d->cap[i].kind) {
        case 10: { const UINT *u = (const UINT *)p; n += snprintf(line + n, sizeof line - n, " args idx/vcount=%u inst=%u start=%u base=%d istart=%u", u[0], u[1], u[2], (int)u[3], u[4]); break; }
        case 11: { const UINT *u = (const UINT *)p; for (j = 0; j < 12; j++) n += snprintf(line + n, sizeof line - n, " %u", u[j]); break; }
        case 12: { const USHORT *u = (const USHORT *)p; for (j = 0; j < 24; j++) n += snprintf(line + n, sizeof line - n, " %u", u[j]); break; }
        case 13: { const float *f = (const float *)p; const UINT *u = (const UINT *)p;
                   for (j = 0; j < 12; j++) n += snprintf(line + n, sizeof line - n, " %g", f[j]);
                   n += snprintf(line + n, sizeof line - n, " | hex"); for (j = 0; j < 8; j++) n += snprintf(line + n, sizeof line - n, " %08x", u[j]); break; }
        case 14: { const float *f = (const float *)p; for (j = 0; j < 16; j++) n += snprintf(line + n, sizeof line - n, " %g", f[j]); break; }
        case 16: { const float *f = (const float *)p; for (j = 0; j < 24; j++) n += snprintf(line + n, sizeof line - n, " %g", f[j]); break; }   /* ml930: 96 bytes, covers offset 72 */
        default: if (d->cap[i].kind >= 100) {
            UINT pf = d->cap[i].kind - 100, bpp = mad_pf_bytes(pf), t, nt = d->cap[i].nt ? d->cap[i].nt : (d->cap[i].len >= 16 * bpp ? 4 : 1);
            for (t = 0; t < nt; t++) {
                const unsigned char *q = d->cap[i].nt ? p + t * bpp : p + (t * 4 + t) * bpp;   /* sequential, or texels (0,0) (1,1) (2,2) (3,3) */
                float c[4] = { 0, 0, 0, 0 };
                if (n > (int)sizeof line - 80) { d3d12_log("%s\n", line); n = snprintf(line, sizeof line, "[cap-data] %s +%u:", d->cap[i].label, t); }   /* ml924: continue on a new line */
                if (pf == 53 || pf == 54 || pf == 103) {   /* ml924: integer formats */
                    UINT u[2] = { 0, 0 }; memcpy(u, q, bpp);
                    if (bpp == 8) n += snprintf(line + n, sizeof line - n, " (%u %u)", u[0], u[1]); else n += snprintf(line + n, sizeof line - n, " %u", u[0]);
                    continue;
                }
                switch (pf) {
                case 115: { const USHORT *h = (const USHORT *)q; unsigned j; for (j = 0; j < 4; j++) c[j] = mad_half(h[j]); break; }
                case 65:  { const USHORT *h = (const USHORT *)q; c[0] = mad_half(h[0]); c[1] = mad_half(h[1]); break; }
                case 25:  { const USHORT *h = (const USHORT *)q; c[0] = mad_half(h[0]); break; }
                case 125: memcpy(c, q, 16); break;
                case 105: memcpy(c, q, 8); break;   /* ml924: RG32Float (the local-exposure grid) */
                case 55:  memcpy(c, q, 4); break;
                case 92:  { UINT v; memcpy(&v, q, 4); c[0] = mad_f11(v & 0x7ff); c[1] = mad_f11((v >> 11) & 0x7ff); c[2] = mad_f10(v >> 22); c[3] = 1; break; }
                case 90:  { UINT v; memcpy(&v, q, 4); c[0] = (v & 1023) / 1023.f; c[1] = ((v >> 10) & 1023) / 1023.f; c[2] = ((v >> 20) & 1023) / 1023.f; c[3] = (v >> 30) / 3.f; break; }
                case 70: case 71: c[0] = q[0] / 255.f; c[1] = q[1] / 255.f; c[2] = q[2] / 255.f; c[3] = q[3] / 255.f; break;
                case 80: case 81: c[0] = q[2] / 255.f; c[1] = q[1] / 255.f; c[2] = q[0] / 255.f; c[3] = q[3] / 255.f; break;
                case 110: { const USHORT *h = (const USHORT *)q; unsigned j; for (j = 0; j < 4; j++) c[j] = h[j] / 65535.f; break; }
                case 10: case 13: c[0] = q[0] / 255.f; break;
                default: break;
                }
                n += snprintf(line + n, sizeof line - n, " (%.4g %.4g %.4g %.4g)", c[0], c[1], c[2], c[3]);
            }
            break; }
        case 15: { const float *f = (const float *)p; const UINT *u = (const UINT *)p;
                   for (j = 0; j < 16; j++) n += snprintf(line + n, sizeof line - n, " %g", f[j]);
                   n += snprintf(line + n, sizeof line - n, " | hex"); for (j = 0; j < 8; j++) n += snprintf(line + n, sizeof line - n, " %08x", u[j]); break; }
        }
        d3d12_log("%s\n", line);
    }
    d->ncap = 0; d->cap_used = 0;
}

static void exec_draw(struct mad_exec *e, const struct mad_cmd *c) {
    struct wmtcmd_render_setpso c_pso;
    struct wmtcmd_render_draw_indirect c_di;
    struct wmtcmd_render_setblendcolor c_bl;
    struct wmtcmd_render_draw_indexed_indirect c_dii;
    struct wmtcmd_render_setviewport c_vp;
    struct wmtcmd_render_setscissorrect c_sc;
    struct wmtcmd_render_setbuffer sb[6 + 16 + 2];
    struct wmtcmd_render_useresource ur[256];
    struct wmtcmd_render_setdsso c_dss;
    struct wmtcmd_render_setrasterizerstate c_ras;
    struct wmtcmd_render_draw c_draw;
    struct wmtcmd_render_draw_indexed c_dix;
    struct wmtcmd_render_draw_meshthreadgroups c_mesh;   /* ml927 */
    struct mad_gs_drawinfo gdi; int gsemu;
    struct wmtcmd_base *tail;
    obj_handle_t argbuf = 0; UINT64 argoff = 0;
    unsigned nsb = 0, nur = 0, i;
    static unsigned said_nopso, said_trunc;
    struct mad_device *dev = e->q->device;

    if (!e->pso || !e->pso->rps) {
        if (!said_nopso++) d3d12_log("[madeira-d3d12] draw without a pipeline state; skipped\n");
        e->skipped++;
        return;
    }
    gsemu = e->pso->gs_emu;
    if (gsemu && (c->kind == MC_DRAW_INDIRECT || c->kind == MC_DRAW_INDEXED_INDIRECT)) {
        static unsigned said; if (said++ < 4) d3d12_log("[madeira-d3d12] indirect draw on a geometry-shader pipeline is not implemented; skipped\n");
        e->skipped++; return;
    }
    if (g_census_on) { exec_capture_draw(e, c); exec_desc_check(e, e->rs, e->root, e->pso->vs_name); }   /* ml910/ml913 */
    if (!exec_begin_render(e)) { e->skipped++; return; }
    if (!exec_arg_slot(e, &argbuf, &argoff)) { e->skipped++; return; }

    memset(&c_pso, 0, sizeof c_pso); c_pso.type = WMTRenderCommandSetPSO; c_pso.pso = e->pso->rps;
    if (e->pso->has_vd && !gsemu) {
        UINT strides[16];
        /* ml904: a BOUND stream with StrideInBytes 0 means "every vertex reads
         * the same element" (D3D semantics); it must not be promoted to the
         * packed stride, which made the base pass read successive elements of
         * a per-draw constant stream. Unbound slots keep the assumed stride. */
        for (i = 0; i < 16; i++) strides[i] = e->vb[i].res ? e->vb[i].stride : e->pso->vb_stride[i];
        c_pso.pso = mad_pso_for_strides(e->pso, strides);
    }
    tail = (struct wmtcmd_base *)&c_pso;
#define MAD_APPEND(node) do { tail->next.ptr = (node); tail = (struct wmtcmd_base *)(node); } while (0)
    if (e->has_vp) {
        memset(&c_vp, 0, sizeof c_vp); c_vp.type = WMTRenderCommandSetViewport;
        c_vp.viewport.originX = e->vp.TopLeftX; c_vp.viewport.originY = e->vp.TopLeftY;
        c_vp.viewport.width = e->vp.Width; c_vp.viewport.height = e->vp.Height;
        c_vp.viewport.znear = e->vp.MinDepth; c_vp.viewport.zfar = e->vp.MaxDepth;
        MAD_APPEND(&c_vp);
    }
    if (e->has_sc) {
        /* Metal refuses a scissor outside the attachment; clamp to it. */
        UINT tw = e->enc_nrt && e->enc_rt[0] ? e->enc_rt[0]->width : (e->enc_depth ? e->enc_depth->width : 0);
        UINT th = e->enc_nrt && e->enc_rt[0] ? e->enc_rt[0]->height : (e->enc_depth ? e->enc_depth->height : 0);
        LONG x0 = e->sc.left < 0 ? 0 : e->sc.left, y0 = e->sc.top < 0 ? 0 : e->sc.top;
        LONG x1 = e->sc.right, y1 = e->sc.bottom;
        if (tw && x1 > (LONG)tw) x1 = (LONG)tw;
        if (th && y1 > (LONG)th) y1 = (LONG)th;
        if (x1 > x0 && y1 > y0) {
            memset(&c_sc, 0, sizeof c_sc); c_sc.type = WMTRenderCommandSetScissorRect;
            c_sc.scissor_rect.x = (UINT64)x0; c_sc.scissor_rect.y = (UINT64)y0;
            c_sc.scissor_rect.width = (UINT64)(x1 - x0); c_sc.scissor_rect.height = (UINT64)(y1 - y0);
            MAD_APPEND(&c_sc);
        }
    }
    memset(sb, 0, sizeof sb);
#define MAD_SETBUF(stage, buf_, off_, idx_) do { sb[nsb].type = (stage); sb[nsb].buffer = (buf_); \
        sb[nsb].offset = (off_); sb[nsb].index = (idx_); MAD_APPEND(&sb[nsb]); nsb++; } while (0)
    /* kIRArgumentBufferBindPoint 2, descriptor heap 0, sampler heap 1. */
    /* ml927: on a geometry-emulation pipeline the vertex stage is the OBJECT
     * stage and the geometry shader the MESH stage; both take the same
     * bindings the vertex stage would. */
#define MAD_SETBUF_VS(buf_, off_, idx_) do { if (gsemu) { MAD_SETBUF(WMTRenderCommandSetObjectBuffer, buf_, off_, idx_); MAD_SETBUF(WMTRenderCommandSetMeshBuffer, buf_, off_, idx_); } \
                                             else MAD_SETBUF(WMTRenderCommandSetVertexBuffer, buf_, off_, idx_); } while (0)
    MAD_SETBUF_VS(argbuf, argoff, 2);
    MAD_SETBUF(WMTRenderCommandSetFragmentBuffer, argbuf, argoff, 2);
    if (e->srv && e->srv->buffer) {
        MAD_SETBUF_VS(e->srv->buffer, 0, 0);
        MAD_SETBUF(WMTRenderCommandSetFragmentBuffer, e->srv->buffer, 0, 0);
    }
    if (e->smp && e->smp->buffer) {
        MAD_SETBUF_VS(e->smp->buffer, 0, 1);
        MAD_SETBUF(WMTRenderCommandSetFragmentBuffer, e->smp->buffer, 0, 1);
    }
    /* Vertex buffers ride at kIRVertexBufferBindPoint (6) + slot. They only
     * matter once pipelines carry a vertex descriptor; binding them now costs
     * nothing and keeps the encoder state truthful. */
    if (!gsemu) {
        for (i = 0; i < 16; i++)
            if (e->vb[i].res && e->vb[i].res->buffer)
                MAD_SETBUF(WMTRenderCommandSetVertexBuffer, e->vb[i].res->buffer, e->vb[i].off, (uint8_t)(6 + i));
    }
    /* ml912: the converter's draw contract (metal_irconverter_runtime.h,
     * IRRuntimeDraw*): every vertex stage that reads SV_VertexID /
     * SV_InstanceID takes the draw's own arguments at bind point 4
     * (IRRuntimeDrawParams: the D3D12 argument block verbatim) and a uint16
     * "index type" at bind point 5 (0 = non-indexed, MTLIndexType+1 for
     * indexed). Nothing bound them before; the engine's instanced scene
     * shaders were computing their instance ids from an unbound buffer. For
     * indirect draws the argument buffer itself is bound, as Apple's helper
     * does, so the GPU reads the culling output the draw consumes. */
    {
        struct mad_list *l = e->l;
        unsigned per = MAD_ARG_RING_BYTES / MAD_ARG_SLOT_BYTES, used = l->ring_used - 1;
        unsigned char *cpu = (unsigned char *)l->ring_cpu[used / per] + (used % per) * MAD_ARG_SLOT_BYTES;
        UINT32 dp[5] = { 0, 0, 0, 0, 0 };
        UINT16 kind = 0;
        if (c->kind == MC_DRAW_INDEXED) {
            /* ml914: Apple's IRRuntimeDrawIndexedPrimitives stores the index
             * buffer BYTE offset it hands Metal in startIndexLocation, not the
             * D3D element count; match it exactly. */
            UINT isz = e->ib_type == WMTIndexTypeUInt32 ? 4 : 2;
            dp[0] = c->u.drawi.icount; dp[1] = c->u.drawi.inst ? c->u.drawi.inst : 1;
            dp[2] = (UINT32)(e->ib_off + (UINT64)c->u.drawi.start * isz);
            dp[3] = (UINT32)c->u.drawi.base; dp[4] = c->u.drawi.istart;
        } else if (c->kind == MC_DRAW) {
            dp[0] = c->u.draw.vcount; dp[1] = c->u.draw.icount ? c->u.draw.icount : 1; dp[2] = c->u.draw.vstart; dp[3] = c->u.draw.istart;
        }
        if (c->kind == MC_DRAW_INDEXED || c->kind == MC_DRAW_INDEXED_INDIRECT) kind = (UINT16)((e->ib_type == WMTIndexTypeUInt32 ? 1 : 0) + 1);
        memset(&gdi, 0, sizeof gdi);
        if (gsemu) {
            /* ml927: the emulation helpers take the ELEMENT start index and fold
             * the index-buffer byte offset into the buffer address. */
            UINT pt = mad_gs_prim(e->topo), count = c->kind == MC_DRAW_INDEXED ? c->u.drawi.icount : c->u.draw.vcount;
            UINT inst = dp[1]; UINT64 ibaddr = 0;
            struct WMTSize grid, otg, mtg;
            struct { UINT64 addr; UINT32 length, stride; } vbt[31];
            if (c->kind == MC_DRAW_INDEXED) { dp[2] = c->u.drawi.start; if (e->ib) ibaddr = e->ib->gpu_address + e->ib_off; }
            mad_gs_draw(pt, e->pso->gs_vertex_size, e->pso->gs_max_prims, inst, count, kind, ibaddr, &gdi, &grid, &otg, &mtg);
            memset(&c_mesh, 0, sizeof c_mesh); c_mesh.type = WMTRenderCommandDrawMeshThreadgroups;
            c_mesh.threadgroup_per_grid = grid; c_mesh.object_threadgroup_size = otg; c_mesh.mesh_threadgroup_size = mtg;
            memset(vbt, 0, sizeof vbt);
            for (i = 0; i < 16; i++) if (e->vb[i].res && e->vb[i].res->buffer) {
                vbt[i].addr = e->vb[i].res->gpu_address + e->vb[i].off;
                vbt[i].length = (UINT32)(e->vb[i].res->size > e->vb[i].off ? e->vb[i].res->size - e->vb[i].off : 0);
                vbt[i].stride = e->vb[i].stride;
            }
            memcpy(cpu + MAD_ARG_VBTABLE_OFF, vbt, sizeof vbt);
            MAD_SETBUF(WMTRenderCommandSetObjectBuffer, argbuf, argoff + MAD_ARG_VBTABLE_OFF, 6);
        } else gdi.index_type = kind;
        memcpy(cpu + MAD_ARG_DRAWPARAMS_OFF, dp, sizeof dp);
        memcpy(cpu + MAD_ARG_DRAWINFO_OFF, &gdi, sizeof gdi);
        if ((c->kind == MC_DRAW_INDIRECT || c->kind == MC_DRAW_INDEXED_INDIRECT) && c->u.ind.args && c->u.ind.args->buffer)
            MAD_SETBUF(WMTRenderCommandSetVertexBuffer, c->u.ind.args->buffer, c->u.ind.off, 4);
        else
            MAD_SETBUF_VS(argbuf, argoff + MAD_ARG_DRAWPARAMS_OFF, 4);
        MAD_SETBUF_VS(argbuf, argoff + MAD_ARG_DRAWINFO_OFF, 5);
    }
#undef MAD_SETBUF_VS
#undef MAD_SETBUF
    memset(ur, 0, sizeof ur);
#define MAD_USE(h) do { if ((h) && nur < 256) { ur[nur].type = WMTRenderCommandUseResource; ur[nur].resource = (h); \
        ur[nur].usage = WMTResourceUsageRead; ur[nur].stages = (enum WMTRenderStages)(gsemu ? (WMTRenderStageObject | WMTRenderStageMesh | WMTRenderStageFragment) : (WMTRenderStageVertex | WMTRenderStageFragment)); \
        MAD_APPEND(&ur[nur]); nur++; } } while (0)
    if (e->srv) MAD_USE(e->srv->buffer);
    if (e->smp) MAD_USE(e->smp->buffer);
    if (gsemu) {   /* ml927: the object stage reads vertices and indices through the tables, not encoder bindings */
        for (i = 0; i < 16; i++) if (e->vb[i].res) MAD_USE(e->vb[i].res->buffer);
        if (e->ib) MAD_USE(e->ib->buffer);
    }
    for (i = e->l->nused > 64 ? e->l->nused - 64 : 0; i < e->l->nused; i++) {
        struct mad_resource *r = e->l->used[i];
        if (r) MAD_USE(r->texture ? r->texture : r->buffer);
    }
    for (i = 0; i < dev->nsrv && nur < 256; i++) {
        struct mad_resource *r = dev->srv_res[i];
        if (r) MAD_USE(r->texture ? r->texture : r->buffer);
    }
    for (i = 0; i < dev->nuav && nur < 256; i++) {
        struct mad_resource *r = dev->uav_res[i];
        if (r) { MAD_USE(r->texture ? r->texture : r->buffer); ur[nur - 1].usage = (enum WMTResourceUsage)(WMTResourceUsageRead | WMTResourceUsageWrite); }
    }
    if (dev->nsrv > 190 && !said_trunc++)
        d3d12_log("[madeira-d3d12] residency list truncated at 256 per draw (%u views); a real residency set is owed\n", dev->nsrv);
#undef MAD_USE
    if (e->enc_depth && (e->pso->dsso || dev->dsso)) {
        memset(&c_dss, 0, sizeof c_dss); c_dss.type = WMTRenderCommandSetDSSO;
        c_dss.dsso = e->pso->dsso ? e->pso->dsso : dev->dsso;
        c_dss.stencil_ref = (uint8_t)e->stencil_ref;
        MAD_APPEND(&c_dss);
    }
    if (e->has_blend) {
        memset(&c_bl, 0, sizeof c_bl); c_bl.type = WMTRenderCommandSetBlendFactorAndStencilRef;
        c_bl.red = e->blend[0]; c_bl.green = e->blend[1]; c_bl.blue = e->blend[2]; c_bl.alpha = e->blend[3];
        c_bl.stencil_ref = (uint8_t)e->stencil_ref;
        MAD_APPEND(&c_bl);
    }
    c_ras = e->pso->raster;
    c_ras.next.ptr = NULL;
    MAD_APPEND(&c_ras);
    for (i = 0; i < 16; i++) {
        if (!(e->pso->vb_mask & (1u << i)) || !e->vb[i].res) continue;
        /* ml878: stride differences are handled by mad_pso_for_strides above */
    }
    if ((g_list_seq <= 3 || (g_list_seq >= 12000 && g_list_seq < 12400) || g_census_on) && g_dump_draws < 40000) {   /* ml893: ~3 frames mid-run */
        char line[1200]; int n; unsigned k;
        g_dump_draws++;
        n = snprintf(line, sizeof(line), "[draw-dump] list#%u enc#%u vs='%s' ps='%s' rt=%u", g_list_seq, e->renc_seq,
                     e->pso->vs_name, e->pso->ps_name, e->enc_nrt);
        for (k = 0; k < e->enc_nrt && k < 8; k++) n += snprintf(line + n, sizeof(line) - n, "%s%ux%u/f%u", k ? "," : "[",
                     e->enc_rt[k] ? e->enc_rt[k]->width : 0, e->enc_rt[k] ? e->enc_rt[k]->height : 0,
                     e->enc_rt[k] ? (unsigned)e->enc_rt[k]->desc.Format : 0);
        if (e->enc_nrt) n += snprintf(line + n, sizeof(line) - n, "]");
        if (e->enc_depth)
            n += snprintf(line + n, sizeof(line) - n, " depth=%ux%u/f%u", e->enc_depth->width, e->enc_depth->height, (unsigned)e->enc_depth->desc.Format);
        else
            n += snprintf(line + n, sizeof(line) - n, " depth=n");
        n += snprintf(line + n, sizeof(line) - n, " cull=%u wind=%s dtest=%u/func%u/w%u st=%u/func%u/r%x/w%x/ref%u wm=%x%x%x%x%x%x vp=%g,%g,%gx%g,z%g-%g sc=%s%ld,%ld-%ld,%ld",
                      (unsigned)e->pso->raster.cull_mode, e->pso->raster.winding == WMTWindingCounterClockwise ? "ccw" : "cw",
                      e->pso->dbg_denable, e->pso->dbg_dfunc, e->pso->dbg_dwrite,
                      e->pso->dbg_senable, e->pso->dbg_sfunc, e->pso->dbg_srmask, e->pso->dbg_swmask, (unsigned)e->stencil_ref,
                      e->pso->dbg_wmask[0], e->pso->dbg_wmask[1], e->pso->dbg_wmask[2], e->pso->dbg_wmask[3], e->pso->dbg_wmask[4], e->pso->dbg_wmask[5],
                      e->has_vp ? e->vp.TopLeftX : -1.0f, e->has_vp ? e->vp.TopLeftY : -1.0f, e->has_vp ? e->vp.Width : 0.0f, e->has_vp ? e->vp.Height : 0.0f,
                      e->has_vp ? e->vp.MinDepth : 0.0f, e->has_vp ? e->vp.MaxDepth : 0.0f,
                      e->has_sc ? "" : "none", e->has_sc ? (long)e->sc.left : 0L, e->has_sc ? (long)e->sc.top : 0L, e->has_sc ? (long)e->sc.right : 0L, e->has_sc ? (long)e->sc.bottom : 0L);
        n += snprintf(line + n, sizeof(line) - n, " srv=%s smp=%s nsrv=%u used=%u vb=[",
                      e->srv ? "y" : "n", e->smp ? "y" : "n", dev->nsrv, e->l->nused);
        for (k = 0; k < 16 && n < (int)sizeof(line) - 120; k++) if (e->vb[k].res)
            n += snprintf(line + n, sizeof(line) - n, " %u:off%llu/sz%llu/st%u%s", k, (unsigned long long)e->vb[k].off,
                          (unsigned long long)e->vb[k].res->size, e->vb[k].stride, e->vb[k].res->buffer ? "" : "(NOBUF)");
        n += snprintf(line + n, sizeof(line) - n, " ]");
        if (c->kind == MC_DRAW_INDIRECT || c->kind == MC_DRAW_INDEXED_INDIRECT)
            n += snprintf(line + n, sizeof(line) - n, " INDIRECT args-off=%llu", (unsigned long long)c->u.ind.off);
        else if (c->kind == MC_DRAW_INDEXED)
            n += snprintf(line + n, sizeof(line) - n, " ib=%s off%llu/sz%llu/%s idx=%u start=%u base=%d inst=%u",
                          e->ib ? "y" : "NONE", (unsigned long long)e->ib_off, e->ib ? (unsigned long long)e->ib->size : 0ull,
                          e->ib_type == WMTIndexTypeUInt32 ? "u32" : "u16", c->u.drawi.icount, c->u.drawi.start,
                          (int)c->u.drawi.base, c->u.drawi.inst);
        else
            n += snprintf(line + n, sizeof(line) - n, " draw vcount=%u start=%u inst=%u",
                          c->u.draw.vcount, c->u.draw.vstart, c->u.draw.icount);
        d3d12_log("%s\n", line);
    }
    if (gsemu) {   /* ml927 */
        if (c->kind == MC_DRAW_INDEXED && (!e->ib || !e->ib->buffer)) { e->skipped++; tail->next.ptr = NULL; return; }
        MAD_APPEND(&c_mesh);
    } else if (c->kind == MC_DRAW_INDEXED_INDIRECT) {
        if (!e->ib || !e->ib->buffer) { e->skipped++; tail->next.ptr = NULL; return; }
        memset(&c_dii, 0, sizeof c_dii);
        c_dii.type = WMTRenderCommandDrawIndexedIndirect;
        c_dii.primitive_type = mad_prim(e->topo);
        c_dii.index_type = e->ib_type;
        c_dii.index_buffer = e->ib->buffer;
        c_dii.index_buffer_offset = e->ib_off;
        c_dii.indirect_args_buffer = c->u.ind.args->buffer;
        c_dii.indirect_args_offset = c->u.ind.off;
        MAD_APPEND(&c_dii);
    } else if (c->kind == MC_DRAW_INDIRECT) {
        memset(&c_di, 0, sizeof c_di);
        c_di.type = WMTRenderCommandDrawIndirect;
        c_di.primitive_type = mad_prim(e->topo);
        c_di.indirect_args_buffer = c->u.ind.args->buffer;
        c_di.indirect_args_offset = c->u.ind.off;
        MAD_APPEND(&c_di);
    } else if (c->kind == MC_DRAW_INDEXED) {
        if (!e->ib || !e->ib->buffer) { e->skipped++; tail->next.ptr = NULL; return; }
        memset(&c_dix, 0, sizeof c_dix);
        c_dix.type = WMTRenderCommandDrawIndexed;
        c_dix.primitive_type = mad_prim(e->topo);
        c_dix.index_type = e->ib_type;
        c_dix.index_count = c->u.drawi.icount;
        c_dix.index_buffer = e->ib->buffer;
        c_dix.index_buffer_offset = e->ib_off + (UINT64)c->u.drawi.start * (e->ib_type == WMTIndexTypeUInt32 ? 4 : 2);
        c_dix.instance_count = c->u.drawi.inst ? c->u.drawi.inst : 1;
        c_dix.base_vertex = c->u.drawi.base;
        c_dix.base_instance = c->u.drawi.istart;
        MAD_APPEND(&c_dix);
    } else {
        memset(&c_draw, 0, sizeof c_draw);
        c_draw.type = WMTRenderCommandDraw;
        c_draw.primitive_type = mad_prim(e->topo);
        c_draw.vertex_start = c->u.draw.vstart;
        c_draw.vertex_count = c->u.draw.vcount;
        c_draw.instance_count = c->u.draw.icount ? c->u.draw.icount : 1;
        c_draw.base_instance = c->u.draw.istart;
        MAD_APPEND(&c_draw);
    }
    tail->next.ptr = NULL;
#undef MAD_APPEND
    MTLRenderCommandEncoder_encodeCommands(e->renc, (const struct wmtcmd_base *)&c_pso);
    e->draws++;
    if (e->nrt && e->rt[0] && e->rtp[0].layers > 1) {   /* ml926: layered draws */
        static unsigned said;
        if (said++ < 24)
            d3d12_log("[layered-draw] list#%u vs='%s' ps='%s' rt0=%s %ux%u t%u pf%u layers %u first %u | %s vcount=%u inst=%u\n", g_list_seq,
                      e->pso ? e->pso->vs_name : "?", e->pso ? e->pso->ps_name : "?", e->rt[0]->name, e->rt[0]->width, e->rt[0]->height,
                      (unsigned)e->rt[0]->tex_type, (unsigned)e->rt[0]->tex_pf, e->rtp[0].layers, e->rt[0]->tex_type == WMTTextureType3D ? e->rtp[0].plane : e->rtp[0].slice,
                      c->kind == MC_DRAW ? "draw" : "drawi", c->kind == MC_DRAW ? c->u.draw.vcount : c->u.drawi.icount,
                      c->kind == MC_DRAW ? c->u.draw.icount : c->u.drawi.inst);
        static unsigned k14_done;   /* ml928: at most four in the whole run; g_cap_kinds resets every flush and this burnt the capture budget */
        if (k14_done < 4 && !(g_cap_kinds & (1u << 14)) && e->q->device->cap_total < 2000) {
            char lab[160]; UINT mid = e->rtp[0].layers / 2;
            g_cap_kinds |= 1u << 14; k14_done++;
            snprintf(lab, sizeof lab, "K14 OUT after layered '%s' %s %ux%u pf%u slice0", e->pso ? e->pso->vs_name : "?", e->rt[0]->name, e->rt[0]->width, e->rt[0]->height, (unsigned)e->rt[0]->tex_pf);
            exec_capture_texels(e, lab, e->rt[0], 0, 0);
            snprintf(lab, sizeof lab, "K14 OUT after layered '%s' %s %ux%u pf%u slice%u", e->pso ? e->pso->vs_name : "?", e->rt[0]->name, e->rt[0]->width, e->rt[0]->height, (unsigned)e->rt[0]->tex_pf, mid);
            exec_capture_texels(e, lab, e->rt[0], mid, 0);
        }
    }
    if (e->cap_after) {   /* ml918: the output of this draw, before anything else touches it */
        char lab[160]; unsigned kk = e->cap_after; e->cap_after = 0;
        if (e->rt[0]) { snprintf(lab, sizeof lab, "K%u OUT rt0 %s %ux%u pf%u", kk, e->rt[0]->name, e->rt[0]->width, e->rt[0]->height, (unsigned)e->rt[0]->tex_pf);
                        exec_capture_texels(e, lab, e->rt[0], 0, 0); }
    }
}

static void exec_copy(struct mad_exec *e, const struct mad_cmd *c) {
    if (!exec_begin_blit(e)) { e->skipped++; return; }
    switch (c->kind) {
    case MC_FILL_BB: {
        struct wmtcmd_blit_fillbuffer k;
        if (!c->u.fill.res->buffer) { e->skipped++; return; }
        memset(&k, 0, sizeof k);
        k.type = WMTBlitCommandFillBuffer;
        k.buffer = c->u.fill.res->buffer; k.offset = c->u.fill.off; k.length = c->u.fill.len; k.value = c->u.fill.byte;
        MTLBlitCommandEncoder_encodeCommands(e->benc, (const struct wmtcmd_base *)&k);
        return;
    }
    case MC_COPY_BB: {
        struct wmtcmd_blit_copy_from_buffer_to_buffer k;
        if (!c->u.bb.dst->buffer || !c->u.bb.src->buffer) { e->skipped++; return; }
        memset(&k, 0, sizeof k);
        k.type = WMTBlitCommandCopyFromBufferToBuffer;
        k.src = c->u.bb.src->buffer; k.src_offset = c->u.bb.soff;
        k.dst = c->u.bb.dst->buffer; k.dst_offset = c->u.bb.doff;
        k.copy_length = c->u.bb.len;
        MTLBlitCommandEncoder_encodeCommands(e->benc, (const struct wmtcmd_base *)&k);
        return;
    }
    case MC_COPY_B2T: {
        struct wmtcmd_blit_copy_from_buffer_to_texture k;
        if (!c->u.bt.tex->texture || !c->u.bt.buf->buffer) { e->skipped++; return; }
        memset(&k, 0, sizeof k);
        k.type = WMTBlitCommandCopyFromBufferToTexture;
        k.src = c->u.bt.buf->buffer; k.src_offset = c->u.bt.off;
        k.bytes_per_row = c->u.bt.row; k.bytes_per_image = c->u.bt.row * c->u.bt.rows;
        k.size.width = c->u.bt.w; k.size.height = c->u.bt.h; k.size.depth = c->u.bt.d;
        k.dst = c->u.bt.tex->texture; k.slice = c->u.bt.slice; k.level = c->u.bt.level;
        k.origin.x = c->u.bt.x; k.origin.y = c->u.bt.y; k.origin.z = c->u.bt.z;
        MTLBlitCommandEncoder_encodeCommands(e->benc, (const struct wmtcmd_base *)&k);
        return;
    }
    case MC_COPY_T2B: {
        struct wmtcmd_blit_copy_from_texture_to_buffer k;
        if (!c->u.bt.tex->texture || !c->u.bt.buf->buffer) { e->skipped++; return; }
        memset(&k, 0, sizeof k);
        k.type = WMTBlitCommandCopyFromTextureToBuffer;
        k.src = c->u.bt.tex->texture; k.slice = c->u.bt.slice; k.level = c->u.bt.level;
        k.origin.x = c->u.bt.x; k.origin.y = c->u.bt.y; k.origin.z = c->u.bt.z;
        k.size.width = c->u.bt.w; k.size.height = c->u.bt.h; k.size.depth = c->u.bt.d;
        k.dst = c->u.bt.buf->buffer; k.offset = c->u.bt.off;
        k.bytes_per_row = c->u.bt.row; k.bytes_per_image = c->u.bt.row * c->u.bt.rows;
        MTLBlitCommandEncoder_encodeCommands(e->benc, (const struct wmtcmd_base *)&k);
        return;
    }
    case MC_COPY_T2T: {
        struct wmtcmd_blit_copy_from_texture_to_texture k;
        if (!c->u.tt.dst->texture || !c->u.tt.src->texture) { e->skipped++; return; }
        memset(&k, 0, sizeof k);
        k.type = WMTBlitCommandCopyFromTextureToTexture;
        k.src = c->u.tt.src->texture; k.src_slice = c->u.tt.sslice; k.src_level = c->u.tt.slevel;
        k.src_origin.x = c->u.tt.sx; k.src_origin.y = c->u.tt.sy; k.src_origin.z = c->u.tt.sz;
        k.src_size.width = c->u.tt.w; k.src_size.height = c->u.tt.h; k.src_size.depth = c->u.tt.d;
        k.dst = c->u.tt.dst->texture; k.dst_slice = c->u.tt.dslice; k.dst_level = c->u.tt.dlevel;
        k.dst_origin.x = c->u.tt.dx; k.dst_origin.y = c->u.tt.dy; k.dst_origin.z = c->u.tt.dz;
        MTLBlitCommandEncoder_encodeCommands(e->benc, (const struct wmtcmd_base *)&k);
        return;
    }
    default: return;
    }
}

static void exec_dispatch(struct mad_exec *e, const struct mad_cmd *c) {
    struct wmtcmd_compute_setpso c_pso;
    struct wmtcmd_compute_setbuffer sb[3];
    struct wmtcmd_compute_useresource ur[256];
    struct wmtcmd_compute_dispatch c_disp;
    struct wmtcmd_compute_dispatch_indirect c_dispi;
    struct wmtcmd_base *tail;
    obj_handle_t argbuf = 0; UINT64 argoff = 0;
    unsigned nsb = 0, nur = 0, i;
    struct mad_device *dev = e->q->device;
    static unsigned said_nopso;
    if (!e->cpso || !e->cpso->cps) {
        if (!said_nopso++) d3d12_log("[madeira-d3d12] Dispatch without a compute pipeline; skipped\n");
        e->skipped++;
        return;
    }
    /* ml930: pre-dispatch captures FIRST. exec_capture_cs blits through
     * exec_begin_blit, which ends every open encoder; doing it after the
     * compute encoder was created left e->cenc = 0 and the dispatch encoded
     * into nothing (the host took 0 as nil and did no work). Every compute
     * measurement in a census frame, and the census frames themselves, were
     * wrong because of that (Astra, 2026-09-16). */
    if (g_census_on) exec_capture_cs(e, c);   /* ml920 */
    if (!e->cenc) {
        exec_end(e);
        e->cenc = MTLCommandBuffer_computeCommandEncoder(e->cb, false); if (e->cenc) g_enc_seq++;
        if (!e->cenc) { d3d12_log("[madeira-d3d12] no compute encoder\n"); e->skipped++; return; }
    }
    if (!exec_arg_slot_for(e, e->crs, e->croot, (const UINT32 (*)[64])e->cconsts, &argbuf, &argoff,
                           e->cpso->has_root_off ? e->cpso->root_off : NULL, e->cpso)) { e->skipped++; return; }
    if (g_census_on) exec_desc_check(e, e->crs, e->croot, e->cpso->vs_name);   /* ml913 */

    if (((g_list_seq >= 12000 && g_list_seq < 12400) || g_census_on) && g_dump_draws < 40000) {   /* ml893 census + ml898 in-game window */
        g_dump_draws++;
        d3d12_log("[dispatch-dump] list#%u '%s' %s %ux%ux%u\n", g_list_seq, e->cpso->vs_name,
                  c->kind == MC_DISPATCH_INDIRECT ? "indirect" : "", c->u.dispatch.x, c->u.dispatch.y, c->u.dispatch.z);
    }
    memset(&c_pso, 0, sizeof c_pso);
    c_pso.type = WMTComputeCommandSetPSO; c_pso.pso = e->cpso->cps;
    c_pso.threadgroup_size.width = e->cpso->tg[0]; c_pso.threadgroup_size.height = e->cpso->tg[1]; c_pso.threadgroup_size.depth = e->cpso->tg[2];
    tail = (struct wmtcmd_base *)&c_pso;
#define MAD_APPEND(node) do { tail->next.ptr = (node); tail = (struct wmtcmd_base *)(node); } while (0)
    memset(sb, 0, sizeof sb);
#define MAD_CSETBUF(buf_, off_, idx_) do { sb[nsb].type = WMTComputeCommandSetBuffer; sb[nsb].buffer = (buf_); \
        sb[nsb].offset = (off_); sb[nsb].index = (idx_); MAD_APPEND(&sb[nsb]); nsb++; } while (0)
    MAD_CSETBUF(argbuf, argoff, 2);
    if (e->srv && e->srv->buffer) MAD_CSETBUF(e->srv->buffer, 0, 0);
    if (e->smp && e->smp->buffer) MAD_CSETBUF(e->smp->buffer, 0, 1);
#undef MAD_CSETBUF
    memset(ur, 0, sizeof ur);
#define MAD_CUSE(h, u) do { if ((h) && nur < 256) { ur[nur].type = WMTComputeCommandUseResource; ur[nur].resource = (h); \
        ur[nur].usage = (u); MAD_APPEND(&ur[nur]); nur++; } } while (0)
    if (e->srv) MAD_CUSE(e->srv->buffer, WMTResourceUsageRead);
    if (e->smp) MAD_CUSE(e->smp->buffer, WMTResourceUsageRead);
    for (i = e->l->nused > 64 ? e->l->nused - 64 : 0; i < e->l->nused; i++) {
        struct mad_resource *r = e->l->used[i];
        if (r) MAD_CUSE(r->texture ? r->texture : r->buffer, (enum WMTResourceUsage)(WMTResourceUsageRead | WMTResourceUsageWrite));
    }
    for (i = 0; i < dev->nsrv && nur < 256; i++) { struct mad_resource *r = dev->srv_res[i]; if (r) MAD_CUSE(r->texture ? r->texture : r->buffer, WMTResourceUsageRead); }
    for (i = 0; i < dev->nuav && nur < 256; i++) { struct mad_resource *r = dev->uav_res[i]; if (r) MAD_CUSE(r->texture ? r->texture : r->buffer, (enum WMTResourceUsage)(WMTResourceUsageRead | WMTResourceUsageWrite)); }
#undef MAD_CUSE
    if (c->kind == MC_DISPATCH_INDIRECT) {
        memset(&c_dispi, 0, sizeof c_dispi);
        c_dispi.type = WMTComputeCommandDispatchIndirect;
        c_dispi.indirect_args_buffer = c->u.ind.args->buffer;
        c_dispi.indirect_args_offset = c->u.ind.off;
        MAD_APPEND(&c_dispi);
    } else {
        memset(&c_disp, 0, sizeof c_disp);
        c_disp.type = WMTComputeCommandDispatch;
        c_disp.size.width = c->u.dispatch.x; c_disp.size.height = c->u.dispatch.y; c_disp.size.depth = c->u.dispatch.z;
        MAD_APPEND(&c_disp);
    }
    tail->next.ptr = NULL;
#undef MAD_APPEND
    MTLComputeCommandEncoder_encodeCommands(e->cenc, (const struct wmtcmd_base *)&c_pso);
    e->draws++;
    if (e->ncap_after_buf) {   /* ml922 */
        unsigned j; for (j = 0; j < e->ncap_after_buf; j++) exec_capture_bytes(e, e->cap_after_buf[j].label, e->cap_after_buf[j].r, e->cap_after_buf[j].off, 64, 15);
        e->ncap_after_buf = 0;
    }
    if (e->ncap_after_tex) {   /* ml924 */
        unsigned j; for (j = 0; j < e->ncap_after_tex; j++) exec_capture_texels(e, e->cap_after_tex[j].label, e->cap_after_tex[j].r, e->cap_after_tex[j].slice, 0);
        e->ncap_after_tex = 0;
    }
    if (e->cap_after_cs) {   /* ml920: the texture this dispatch was chosen for, right after it */
        char lab[160]; struct mad_resource *r = e->cap_after_cs; e->cap_after_cs = NULL;
        snprintf(lab, sizeof lab, "K9 OUT after '%s' %s %ux%u pf%u", e->cpso->vs_name, r->name, r->width, r->height, (unsigned)r->tex_pf);
        exec_capture_texels(e, lab, r, 0, 0);
        snprintf(lab, sizeof lab, "K9 OUT after '%s' %s at (100,100)", e->cpso->vs_name, r->name);
        exec_capture_region(e, lab, r, 0, 0, 100, 100, 4, 4, 0);
    }
}

static void mad_exec_list(struct mad_queue *q, struct mad_list *l, obj_handle_t cb) {
    g_list_seq++;
    struct mad_exec e;
    unsigned i;
    memset(&e, 0, sizeof e);
    e.q = q; e.l = l; e.cb = cb;
    e.topo = D3D_PRIMITIVE_TOPOLOGY_TRIANGLELIST;
    for (i = 0; i < l->ncmds; i++) {
        const struct mad_cmd *c = &l->cmds[i];
        switch (c->kind) {
        case MC_PSO: if (c->u.pso && c->u.pso->is_compute) e.cpso = c->u.pso; else e.pso = c->u.pso; break;
        case MC_CROOTSIG: e.crs = c->u.rootsig; break;
        case MC_CROOT: if (c->u.root.index < MAD_ROOT_PARAM_MAX) e.croot[c->u.root.index] = c->u.root.value; break;
        case MC_CROOT_CONST:
            if (c->u.rconst.index < MAD_ROOT_PARAM_MAX && c->u.rconst.dst + c->u.rconst.n <= 64)
                memcpy(&e.cconsts[c->u.rconst.index][c->u.rconst.dst], &l->cdata[c->u.rconst.data], c->u.rconst.n * 4);
            break;
        case MC_ROOT:
            if (c->u.root.index < MAD_ROOT_PARAM_MAX) {
                e.root[c->u.root.index] = c->u.root.value;
                if (c->u.root.index + 1 > e.nroot) e.nroot = c->u.root.index + 1;
            }
            break;
        case MC_HEAPS: if (c->u.heaps.srv) e.srv = c->u.heaps.srv; if (c->u.heaps.smp) e.smp = c->u.heaps.smp; break;
        case MC_VP: e.vp = c->u.vp; e.has_vp = 1; break;
        case MC_SCISSOR: e.sc = c->u.scissor; e.has_sc = 1; break;
        case MC_TOPO: e.topo = c->u.topo; break;
        case MC_IB: e.ib = c->u.ib.res; e.ib_off = c->u.ib.off; e.ib_type = c->u.ib.type; break;
        case MC_VB: if (c->u.vb.slot < 16) { e.vb[c->u.vb.slot].res = c->u.vb.res; e.vb[c->u.vb.slot].off = c->u.vb.off; e.vb[c->u.vb.slot].stride = c->u.vb.stride; } break;
        case MC_RTS:
            memcpy(e.rt, c->u.rts.rt, sizeof e.rt); e.nrt = c->u.rts.n; e.depth = c->u.rts.depth;
            memcpy(e.rtp, c->u.rts.v, sizeof e.rtp); e.dp = c->u.rts.dv;   /* ml925 */
            break;
        case MC_CLEAR_RT: exec_add_clear(&e, c->u.clear.res, &c->u.clear.v, c->u.clear.rgba, 0.0f, 0, 0, 0); break;
        case MC_CLEAR_DS: exec_add_clear(&e, c->u.clear.res, &c->u.clear.v, NULL, c->u.clear.depth, 1, c->u.clear.stencil, c->u.clear.flags); break;
        case MC_ROOTSIG: e.rs = c->u.rootsig; break;
        case MC_ROOT_CONST:
            if (c->u.rconst.index < MAD_ROOT_PARAM_MAX && c->u.rconst.dst + c->u.rconst.n <= 64)
                memcpy(&e.consts[c->u.rconst.index][c->u.rconst.dst], &l->cdata[c->u.rconst.data], c->u.rconst.n * 4);
            break;
        case MC_STENCIL_REF: e.stencil_ref = c->u.stencil_ref; break;
        case MC_DRAW: case MC_DRAW_INDEXED: exec_draw(&e, c); break;
        case MC_DRAW_INDIRECT: case MC_DRAW_INDEXED_INDIRECT: case MC_DISPATCH_INDIRECT: {
            struct mad_cmd t = *c; UINT k;
            if (!c->u.ind.args || !c->u.ind.args->buffer) { e.skipped++; break; }
            for (k = 0; k < c->u.ind.count; k++) {
                t.u.ind.off = c->u.ind.off + (UINT64)k * c->u.ind.stride;
                if (c->kind == MC_DISPATCH_INDIRECT) exec_dispatch(&e, &t); else exec_draw(&e, &t);
            }
            break;
        }
        case MC_COPY_BB: case MC_COPY_B2T: case MC_COPY_T2B: case MC_COPY_T2T: case MC_FILL_BB: exec_copy(&e, c); break;
        case MC_BLEND_FACTOR: memcpy(e.blend, c->u.blend.rgba, sizeof e.blend); e.has_blend = 1; break;
        case MC_DISPATCH: exec_dispatch(&e, c); break;
        }
    }
    exec_end(&e);
    while (e.npend) exec_flush_clear(&e, 0);
    {
        static unsigned said;
        if ((said < 12 || (g_list_seq >= 12000 && g_list_seq < 12400) || g_census_on) && (e.draws || e.skipped)) {
            said++;
            d3d12_log("[madeira-d3d12] list executed: %u commands, %u draws, %u skipped\n", l->ncmds, e.draws, e.skipped);
        }
    }
}

static void STDMETHODCALLTYPE queue_ExecuteCommandLists(ID3D12CommandQueue *This, UINT count,
                                                        ID3D12CommandList *const *lists) {
    struct mad_queue *q = (struct mad_queue *)This;
    for (UINT i = 0; i < count; i++) {
        struct mad_list *l = (struct mad_list *)lists[i];
        if (l && !l->closed) {
            d3d12_log("[madeira-d3d12] ExecuteCommandLists: list %u is still recording\n", i);
            q->rejected++;
            continue;
        }
        if (l && l->alloc && l->recorded_generation != l->alloc->generation) {
            d3d12_log("[madeira-d3d12] ExecuteCommandLists: list %u was recorded against "
                      "allocator generation %ld but the allocator is now at %ld\n",
                      i, (long)l->recorded_generation, (long)l->alloc->generation);
            q->rejected++;
            continue;
        }
        if (!q->open_cb) {
            if (q->device->resset && InterlockedExchange(&q->device->resset_dirty, 0))
                MTLResidencySet_commit(q->device->resset);
            q->open_cb = MTLCommandQueue_commandBuffer(q->device->mtl_queue);
            if (!q->open_cb) { d3d12_log("[madeira-d3d12] no command buffer\n"); q->rejected++; continue; }
            /* commandBuffer returns an AUTORELEASED object locally and an interned
             * one remotely; holding it across calls means taking our own reference. */
            NSObject_retain(q->open_cb);
        }
        if (l) mad_exec_list(q, l, q->open_cb);
        q->open_lists++;
        q->executed++;
        if (q->open_lists >= 48) mad_queue_flush(q);   /* bound the batch */
    }
}
/* Cross-queue synchronisation. Every queue here submits to the one Metal
 * queue in CPU order, and Signal only advances a fence once the GPU has
 * finished the work before it, so "wait until the fence reaches v" is the
 * same as ordering this thread behind the signalling thread. The wait is
 * bounded: a signal that never comes is logged and released rather than
 * parking the render thread forever, because a hang here looks identical to
 * every other hang and says nothing. */
/* ml884: commit the queue's open command buffer and track it for fencing. */
static void mad_queue_flush(struct mad_queue *q) {
    if (!q || !q->open_cb) return;
    if (q->npending == 16) {
        for (unsigned k = 0; k < q->npending; k++) {
            MTLCommandBuffer_waitUntilCompleted(q->pending[k]);
            NSObject_release(q->pending[k]);
        }
        q->npending = 0;
    }
    MTLCommandBuffer_commit(q->open_cb);
    q->pending[q->npending++] = q->open_cb;      /* the reference taken at open moves here */
    q->open_cb = 0; q->open_lists = 0; q->batches++;
    if (q->batches <= 3 || (q->batches % 500) == 0)
        d3d12_log("[madeira-d3d12] batch #%llu committed (%llu lists so far)\n",
                  (unsigned long long)q->batches, (unsigned long long)q->executed);
}
static void mad_device_flush_all(struct mad_device *d) {
    unsigned i;
    if (!d) return;
    for (i = 0; i < d->nqueues; i++) mad_queue_flush(d->queues[i]);
}

static HRESULT STDMETHODCALLTYPE queue_Wait(ID3D12CommandQueue *This, ID3D12Fence *fence, UINT64 value) {
    struct mad_fence *f = (struct mad_fence *)fence;
    unsigned waited = 0;
    static unsigned said;
    if (!f) return E_INVALIDARG;
    mad_device_flush_all(((struct mad_queue *)This)->device);   /* ml884: the signal may sit in an open buffer */
    while (waited < 5000) {
        UINT64 v;
        EnterCriticalSection(&f->lock);
        v = f->value;
        LeaveCriticalSection(&f->lock);
        if (v >= value) return S_OK;
        Sleep(1);
        waited++;
    }
    if (said++ < 4)
        d3d12_log("[madeira-d3d12] Queue::Wait: fence %p never reached %llu in 5 s (at %llu); continuing\n",
                  (void *)f, (unsigned long long)value, (unsigned long long)f->value);
    return S_OK;
}

static HRESULT STDMETHODCALLTYPE queue_Signal(ID3D12CommandQueue *This, ID3D12Fence *fence, UINT64 value) {
    struct mad_queue *q = (struct mad_queue *)This;
    if (!fence) return E_INVALIDARG;
    mad_queue_flush(q);                              /* ml884: commit the batch this signal covers */
    /* The fence must not advance until the work submitted before it has
     * actually finished on the GPU. Signalling at submission time would make
     * the fence a counter, and a readback taken after the waiter woke could
     * legitimately contain nothing.
     *
     * This is the conservative form the design permits: block here rather than
     * completing asynchronously. It costs a stall the real renderer will not
     * want, but it makes the ordering guarantee true, which is the part the
     * readback test is actually checking. */
    for (unsigned i = 0; i < q->npending; i++) {
        MTLCommandBuffer_waitUntilCompleted(q->pending[i]);
        NSObject_release(q->pending[i]);
    }
    q->npending = 0;
    mad_capture_flush(q->device);   /* ml910 */
    return ID3D12Fence_Signal(fence, value);
}

/* ---- device -------------------------------------------------------------- */





static ID3D12Device10Vtbl g_device_vtbl;
static ID3D12CommandQueueVtbl g_queue_vtbl;
static ID3D12CommandAllocatorVtbl g_alloc_vtbl;
static ID3D12GraphicsCommandListVtbl g_list_vtbl;
static ID3D12FenceVtbl g_fence_vtbl;

static HRESULT STDMETHODCALLTYPE device_QI(ID3D12Device *This, REFIID riid, void **out) {
    HRESULT hr;
    /* ml877: ID3D12Device1..8 are the same object with a longer vtable. UE 5.4
     * refuses to run without Device1 AND Device2 ("Missing full support for
     * Direct3D 12", D3D12Adapter.cpp:946) and uses Device2::CreatePipelineState,
     * Device4::CreateCommandList1/CreateCommittedResource1 when present.
     * Device9/10 (shader cache sessions, enhanced barriers) stay refused so the
     * log names them if a title asks. */
    if (out && riid && (IsEqualGUID(riid, &IID_ID3D12Device1) || IsEqualGUID(riid, &IID_ID3D12Device2) ||
                        IsEqualGUID(riid, &IID_ID3D12Device3) || IsEqualGUID(riid, &IID_ID3D12Device4) ||
                        IsEqualGUID(riid, &IID_ID3D12Device5) || IsEqualGUID(riid, &IID_ID3D12Device6) ||
                        IsEqualGUID(riid, &IID_ID3D12Device7) || IsEqualGUID(riid, &IID_ID3D12Device8))) {
        InterlockedIncrement(&((struct mad_obj *)This)->refs);
        *out = This;
        return S_OK;
    }
    hr = mad_qi((struct mad_obj *)This, riid, out, 0);
    if (hr == E_NOINTERFACE && riid) {
        /* Name the interface the engine wanted, once each: ID3D12Device1..N,
         * ID3D12InfoQueue and friends are how a title discovers optional
         * capabilities, and a silent E_NOINTERFACE hides which one it was. */
        static GUID seen[16]; static unsigned nseen;
        unsigned i;
        for (i = 0; i < nseen; i++) if (IsEqualGUID(&seen[i], riid)) return hr;
        if (nseen < 16) seen[nseen++] = *riid;
        d3d12_log("[madeira-d3d12] device QueryInterface refused: {%08lx-%04x-%04x-%02x%02x-%02x%02x%02x%02x%02x%02x}\n",
                  (unsigned long)riid->Data1, riid->Data2, riid->Data3, riid->Data4[0], riid->Data4[1],
                  riid->Data4[2], riid->Data4[3], riid->Data4[4], riid->Data4[5], riid->Data4[6], riid->Data4[7]);
    }
    return hr;
}

/* Truthful capability answers. Only what this runtime can actually do is
 * claimed: feature level 11_0, shader model 6.6 (the converter's DXIL ceiling),
 * root signature 1.1, a unified-memory architecture. Every other feature id
 * is refused by name so the engine's next requirement appears in the log
 * instead of being satisfied with a guess. */
static HRESULT STDMETHODCALLTYPE device_CheckFeatureSupport(ID3D12Device *This,
        D3D12_FEATURE feature, void *data, UINT size) {
    (void)This;
    if (!data) return E_INVALIDARG;
    switch (feature) {
    case D3D12_FEATURE_D3D12_OPTIONS: {
        D3D12_FEATURE_DATA_D3D12_OPTIONS *o = data;
        if (size < sizeof *o) return E_INVALIDARG;
        memset(o, 0, sizeof *o);
        o->ResourceBindingTier = D3D12_RESOURCE_BINDING_TIER_2;
        o->ResourceHeapTier = D3D12_RESOURCE_HEAP_TIER_2;   /* heaps here are descriptions; any mix is fine */
        o->VPAndRTArrayIndexFromAnyShaderFeedingRasterizerSupportedWithoutGSEmulation = TRUE;
        return S_OK;
    }
    case D3D12_FEATURE_ARCHITECTURE: {
        D3D12_FEATURE_DATA_ARCHITECTURE *a = data;
        if (size < sizeof *a) return E_INVALIDARG;
        a->TileBasedRenderer = TRUE; a->UMA = TRUE; a->CacheCoherentUMA = TRUE;
        return S_OK;
    }
    case D3D12_FEATURE_ARCHITECTURE1: {
        D3D12_FEATURE_DATA_ARCHITECTURE1 *a = data;
        if (size < sizeof *a) return E_INVALIDARG;
        a->TileBasedRenderer = TRUE; a->UMA = TRUE; a->CacheCoherentUMA = TRUE; a->IsolatedMMU = TRUE;
        return S_OK;
    }
    case D3D12_FEATURE_FEATURE_LEVELS: {
        D3D12_FEATURE_DATA_FEATURE_LEVELS *f = data;
        if (size < sizeof *f) return E_INVALIDARG;
        /* The highest of the levels the caller listed that this runtime
         * claims. 12_0 is the ceiling: it is what makes an engine choose its
         * DXIL shaders, and the converter takes nothing older. */
        {
            UINT i;
            f->MaxSupportedFeatureLevel = (D3D_FEATURE_LEVEL)0;
            for (i = 0; f->pFeatureLevelsRequested && i < f->NumFeatureLevels; i++) {
                D3D_FEATURE_LEVEL lv = f->pFeatureLevelsRequested[i];
                if (lv <= D3D_FEATURE_LEVEL_12_0 && lv > f->MaxSupportedFeatureLevel) f->MaxSupportedFeatureLevel = lv;
            }
            if (!f->MaxSupportedFeatureLevel) f->MaxSupportedFeatureLevel = D3D_FEATURE_LEVEL_12_0;
        }
        return S_OK;
    }
    case D3D12_FEATURE_SHADER_MODEL: {
        D3D12_FEATURE_DATA_SHADER_MODEL *m = data;
        if (size < sizeof *m) return E_INVALIDARG;
        if (m->HighestShaderModel > D3D_SHADER_MODEL_6_6) m->HighestShaderModel = D3D_SHADER_MODEL_6_6;
        return S_OK;
    }
    case D3D12_FEATURE_ROOT_SIGNATURE: {
        D3D12_FEATURE_DATA_ROOT_SIGNATURE *r = data;
        if (size < sizeof *r) return E_INVALIDARG;
        r->HighestVersion = D3D_ROOT_SIGNATURE_VERSION_1_1;
        return S_OK;
    }
    case D3D12_FEATURE_D3D12_OPTIONS1: {
        /* Shader model 6 needs wave operations; Apple GPUs execute SIMD
         * groups of 32 and the converter maps wave intrinsics onto them. */
        D3D12_FEATURE_DATA_D3D12_OPTIONS1 *o = data;
        if (size < sizeof *o) return E_INVALIDARG;
        memset(o, 0, sizeof *o);
        o->WaveOps = TRUE;
        o->WaveLaneCountMin = 32;
        o->WaveLaneCountMax = 32;
        o->TotalLaneCount = 4096;
        o->ExpandedComputeResourceStates = TRUE;
        o->Int64ShaderOps = TRUE;
        return S_OK;
    }
    case D3D12_FEATURE_D3D12_OPTIONS2:
    case D3D12_FEATURE_D3D12_OPTIONS3: case D3D12_FEATURE_D3D12_OPTIONS4:
    case D3D12_FEATURE_D3D12_OPTIONS5: case D3D12_FEATURE_D3D12_OPTIONS6:
    case D3D12_FEATURE_D3D12_OPTIONS7: case D3D12_FEATURE_D3D12_OPTIONS8:
    case D3D12_FEATURE_D3D12_OPTIONS10: case D3D12_FEATURE_D3D12_OPTIONS12:
    case D3D12_FEATURE_D3D12_OPTIONS13: case D3D12_FEATURE_D3D12_OPTIONS14:
    case D3D12_FEATURE_D3D12_OPTIONS15: case D3D12_FEATURE_D3D12_OPTIONS16:
    case D3D12_FEATURE_D3D12_OPTIONS17: case D3D12_FEATURE_D3D12_OPTIONS18:
        /* All-zero is the honest answer: no optional feature in these is
         * implemented, and zero means "not supported" for every field. */
        memset(data, 0, size);
        return S_OK;
    case D3D12_FEATURE_D3D12_OPTIONS9: {
        /* 64-bit atomics: Metal 3.1 on Apple family 9 and Mac2 has them on
         * buffers, and the converter emits them for DXIL 64-bit atomics. An
         * engine with Nanite-style rasterisation refuses shader model 6
         * without this answer (UE 5.4 asked for exactly this, ml869). */
        D3D12_FEATURE_DATA_D3D12_OPTIONS9 *o = data;
        if (size < sizeof *o) return E_INVALIDARG;
        memset(o, 0, sizeof *o);
        o->AtomicInt64OnTypedResourceSupported = TRUE;
        o->AtomicInt64OnGroupSharedSupported = TRUE;
        return S_OK;
    }
    case D3D12_FEATURE_D3D12_OPTIONS11: {
        D3D12_FEATURE_DATA_D3D12_OPTIONS11 *o = data;
        if (size < sizeof *o) return E_INVALIDARG;
        o->AtomicInt64OnDescriptorHeapResourceSupported = TRUE;
        return S_OK;
    }
    case D3D12_FEATURE_FORMAT_SUPPORT: {
        /* What a texture of this format can do here. Colour formats: every
         * ordinary use including typed UAV access; depth formats: depth
         * stencil only; anything the format table lacks: nothing. */
        D3D12_FEATURE_DATA_FORMAT_SUPPORT *f = data;
        enum WMTPixelFormat pf; int is_depth;
        if (size < sizeof *f) return E_INVALIDARG;
        f->Support1 = D3D12_FORMAT_SUPPORT1_NONE; f->Support2 = D3D12_FORMAT_SUPPORT2_NONE;
        if (f->Format == DXGI_FORMAT_UNKNOWN) {
            f->Support1 = D3D12_FORMAT_SUPPORT1_BUFFER | D3D12_FORMAT_SUPPORT1_IA_VERTEX_BUFFER | D3D12_FORMAT_SUPPORT1_IA_INDEX_BUFFER;
            return S_OK;
        }
        if (!mad_map_texture_format(f->Format, D3D12_RESOURCE_FLAG_ALLOW_DEPTH_STENCIL, &pf, &is_depth)) return E_FAIL;
        if (is_depth) {
            f->Support1 = D3D12_FORMAT_SUPPORT1_TEXTURE2D | D3D12_FORMAT_SUPPORT1_TEXTURECUBE | D3D12_FORMAT_SUPPORT1_SHADER_LOAD |
                          D3D12_FORMAT_SUPPORT1_SHADER_SAMPLE | D3D12_FORMAT_SUPPORT1_SHADER_SAMPLE_COMPARISON |
                          D3D12_FORMAT_SUPPORT1_DEPTH_STENCIL | D3D12_FORMAT_SUPPORT1_MULTISAMPLE_RENDERTARGET | D3D12_FORMAT_SUPPORT1_MULTISAMPLE_LOAD;
        } else {
            UINT bytes, block;
            mad_format_info(f->Format, &bytes, &block);
            f->Support1 = D3D12_FORMAT_SUPPORT1_BUFFER | D3D12_FORMAT_SUPPORT1_IA_VERTEX_BUFFER | D3D12_FORMAT_SUPPORT1_TEXTURE1D |
                          D3D12_FORMAT_SUPPORT1_TEXTURE2D | D3D12_FORMAT_SUPPORT1_TEXTURE3D | D3D12_FORMAT_SUPPORT1_TEXTURECUBE |
                          D3D12_FORMAT_SUPPORT1_SHADER_LOAD | D3D12_FORMAT_SUPPORT1_SHADER_SAMPLE | D3D12_FORMAT_SUPPORT1_MIP |
                          D3D12_FORMAT_SUPPORT1_SHADER_GATHER | D3D12_FORMAT_SUPPORT1_MULTISAMPLE_LOAD;
            if (block == 1) {   /* uncompressed: render and unordered access too */
                f->Support1 |= D3D12_FORMAT_SUPPORT1_RENDER_TARGET | D3D12_FORMAT_SUPPORT1_BLENDABLE | D3D12_FORMAT_SUPPORT1_DISPLAY |
                               D3D12_FORMAT_SUPPORT1_MULTISAMPLE_RESOLVE | D3D12_FORMAT_SUPPORT1_MULTISAMPLE_RENDERTARGET |
                               D3D12_FORMAT_SUPPORT1_TYPED_UNORDERED_ACCESS_VIEW;
                f->Support2 = D3D12_FORMAT_SUPPORT2_UAV_TYPED_LOAD | D3D12_FORMAT_SUPPORT2_UAV_TYPED_STORE;
                if (f->Format == DXGI_FORMAT_R32_UINT || f->Format == DXGI_FORMAT_R32_SINT)
                    f->Support2 |= D3D12_FORMAT_SUPPORT2_UAV_ATOMIC_ADD | D3D12_FORMAT_SUPPORT2_UAV_ATOMIC_BITWISE_OPS |
                                   D3D12_FORMAT_SUPPORT2_UAV_ATOMIC_COMPARE_STORE_OR_COMPARE_EXCHANGE |
                                   D3D12_FORMAT_SUPPORT2_UAV_ATOMIC_EXCHANGE | D3D12_FORMAT_SUPPORT2_UAV_ATOMIC_SIGNED_MIN_OR_MAX |
                                   D3D12_FORMAT_SUPPORT2_UAV_ATOMIC_UNSIGNED_MIN_OR_MAX;
                if (f->Format == DXGI_FORMAT_R16_UINT || f->Format == DXGI_FORMAT_R32_UINT)
                    f->Support1 |= D3D12_FORMAT_SUPPORT1_IA_INDEX_BUFFER;
            }
        }
        return S_OK;
    }
    case D3D12_FEATURE_MULTISAMPLE_QUALITY_LEVELS: {
        D3D12_FEATURE_DATA_MULTISAMPLE_QUALITY_LEVELS *m = data;
        if (size < sizeof *m) return E_INVALIDARG;
        m->NumQualityLevels = (m->SampleCount == 1 || m->SampleCount == 2 || m->SampleCount == 4) ? 1 : 0;
        return S_OK;
    }
    case D3D12_FEATURE_FORMAT_INFO: {
        D3D12_FEATURE_DATA_FORMAT_INFO *fi = data;
        enum WMTPixelFormat pf; int is_depth;
        if (size < sizeof *fi) return E_INVALIDARG;
        if (fi->Format != DXGI_FORMAT_UNKNOWN && !mad_map_texture_format(fi->Format, D3D12_RESOURCE_FLAG_ALLOW_DEPTH_STENCIL, &pf, &is_depth)) return E_INVALIDARG;
        fi->PlaneCount = (fi->Format != DXGI_FORMAT_UNKNOWN && is_depth && pf == WMTPixelFormatDepth32Float_Stencil8) ? 2 : 1;
        return S_OK;
    }
    case D3D12_FEATURE_GPU_VIRTUAL_ADDRESS_SUPPORT: {
        D3D12_FEATURE_DATA_GPU_VIRTUAL_ADDRESS_SUPPORT *g = data;
        if (size < sizeof *g) return E_INVALIDARG;
        g->MaxGPUVirtualAddressBitsPerResource = 40; g->MaxGPUVirtualAddressBitsPerProcess = 40;
        return S_OK;
    }
    case D3D12_FEATURE_SHADER_CACHE: {
        D3D12_FEATURE_DATA_SHADER_CACHE *c = data;
        if (size < sizeof *c) return E_INVALIDARG;
        c->SupportFlags = D3D12_SHADER_CACHE_SUPPORT_SINGLE_PSO;
        return S_OK;
    }
    case D3D12_FEATURE_COMMAND_QUEUE_PRIORITY: {
        D3D12_FEATURE_DATA_COMMAND_QUEUE_PRIORITY *q = data;
        if (size < sizeof *q) return E_INVALIDARG;
        q->PriorityForTypeIsSupported = q->Priority != D3D12_COMMAND_QUEUE_PRIORITY_GLOBAL_REALTIME;
        return S_OK;
    }
    case D3D12_FEATURE_EXISTING_HEAPS: { D3D12_FEATURE_DATA_EXISTING_HEAPS *e = data; if (size < sizeof *e) return E_INVALIDARG; e->Supported = FALSE; return S_OK; }
    case D3D12_FEATURE_SERIALIZATION: { D3D12_FEATURE_DATA_SERIALIZATION *e = data; if (size < sizeof *e) return E_INVALIDARG; e->HeapSerializationTier = D3D12_HEAP_SERIALIZATION_TIER_0; return S_OK; }
    case D3D12_FEATURE_CROSS_NODE: { D3D12_FEATURE_DATA_CROSS_NODE *e = data; if (size < sizeof *e) return E_INVALIDARG; e->SharingTier = D3D12_CROSS_NODE_SHARING_TIER_NOT_SUPPORTED; e->AtomicShaderInstructions = FALSE; return S_OK; }
    case D3D12_FEATURE_DISPLAYABLE: { D3D12_FEATURE_DATA_DISPLAYABLE *e = data; if (size < sizeof *e) return E_INVALIDARG; memset(e, 0, sizeof *e); return S_OK; }
    case D3D12_FEATURE_PROTECTED_RESOURCE_SESSION_SUPPORT: { D3D12_FEATURE_DATA_PROTECTED_RESOURCE_SESSION_SUPPORT *e = data; if (size < sizeof *e) return E_INVALIDARG; e->Support = D3D12_PROTECTED_RESOURCE_SESSION_SUPPORT_FLAG_NONE; return S_OK; }
    case D3D12_FEATURE_PROTECTED_RESOURCE_SESSION_TYPE_COUNT: { D3D12_FEATURE_DATA_PROTECTED_RESOURCE_SESSION_TYPE_COUNT *e = data; if (size < sizeof *e) return E_INVALIDARG; e->Count = 0; return S_OK; }
    default: {
        static UINT seen[32]; static unsigned nseen; unsigned i;
        for (i = 0; i < nseen; i++) if (seen[i] == (UINT)feature) return E_INVALIDARG;
        if (nseen < 32) seen[nseen++] = (UINT)feature;
        d3d12_log("[madeira-d3d12] CheckFeatureSupport(feature %u, %u bytes) refused: not implemented\n",
                  (unsigned)feature, size);
        return E_INVALIDARG;
    }
    }
}
static ULONG STDMETHODCALLTYPE device_AddRef(ID3D12Device *This) { return mad_addref((struct mad_obj *)This); }
static ULONG STDMETHODCALLTYPE device_Release(ID3D12Device *This) {
    struct mad_device *d = (struct mad_device *)This;
    LONG n = InterlockedDecrement(&d->refs);
    if (n == 0) {
        /* These were retained on creation and were previously leaked. */
        if (d->dsso) NSObject_release(d->dsso);
        if (d->mtl_queue) NSObject_release(d->mtl_queue);
        if (d->mtl_device) NSObject_release(d->mtl_device);
        DeleteCriticalSection(&d->live_lock);
        d3d12_log("[madeira-d3d12] destroyed %s\n", d->name);
        free(d);
    }
    return (ULONG)n;
}

static HRESULT STDMETHODCALLTYPE device_CreateCommandQueue(ID3D12Device *This,
        const D3D12_COMMAND_QUEUE_DESC *desc, REFIID riid, void **out) {
    (void)This;
    if (!desc || !out) return E_INVALIDARG;
    if (!mad_list_type_ok(desc->Type)) {
        d3d12_log("[madeira-d3d12] CreateCommandQueue: type %d is not implemented\n", desc->Type);
        return E_NOTIMPL;
    }
    d3d12_log("[madeira-d3d12] command queue: type %d\n", desc->Type);
    struct mad_queue *q = calloc(1, sizeof *q);
    if (!q) return E_OUTOFMEMORY;
    q->type = desc->Type;
    q->vtbl = &g_queue_vtbl; q->refs = 1; q->iid = &IID_ID3D12CommandQueue; q->name = "CommandQueue";
    q->device = (struct mad_device *)This;
    {
        struct mad_device *d = (struct mad_device *)This;
        EnterCriticalSection(&d->live_lock);
        if (d->nqueues < 16) d->queues[d->nqueues++] = q;
        LeaveCriticalSection(&d->live_lock);
    }
    HRESULT hr = queue_QI((ID3D12CommandQueue *)q, riid, out);
    queue_Release((ID3D12CommandQueue *)q);
    return hr;
}

static HRESULT STDMETHODCALLTYPE device_CreateCommandAllocator(ID3D12Device *This,
        D3D12_COMMAND_LIST_TYPE type, REFIID riid, void **out) {
    (void)This;
    if (!out) return E_INVALIDARG;
    if (!mad_list_type_ok(type)) return E_NOTIMPL;
    struct mad_alloc *a = calloc(1, sizeof *a);
    if (!a) return E_OUTOFMEMORY;
    a->type = type;
    a->vtbl = &g_alloc_vtbl; a->refs = 1; a->iid = &IID_ID3D12CommandAllocator; a->name = "CommandAllocator";
    HRESULT hr = alloc_QI((ID3D12CommandAllocator *)a, riid, out);
    alloc_Release((ID3D12CommandAllocator *)a);
    return hr;
}

static HRESULT STDMETHODCALLTYPE device_CreateCommandList(ID3D12Device *This, UINT node,
        D3D12_COMMAND_LIST_TYPE type, ID3D12CommandAllocator *allocator,
        ID3D12PipelineState *pso, REFIID riid, void **out) {
    (void)This; (void)node; (void)pso;
    if (!out || !allocator) return E_INVALIDARG;
    if (!mad_list_type_ok(type)) return E_NOTIMPL;
    if (((struct mad_alloc *)allocator)->type != type) return E_INVALIDARG;
    struct mad_list *l = calloc(1, sizeof *l);
    if (!l) return E_OUTOFMEMORY;
    l->type = type;
    l->vtbl = &g_list_vtbl; l->refs = 1; l->iid = &IID_ID3D12GraphicsCommandList; l->name = "GraphicsCommandList";
    l->device = (struct mad_device *)This;
    l->alloc = (struct mad_alloc *)allocator;
    ID3D12CommandAllocator_AddRef(allocator);
    InterlockedIncrement(&l->alloc->recording);   /* lists are created recording */
    l->recorded_generation = l->alloc->generation;
    HRESULT hr = list_QI((ID3D12GraphicsCommandList *)l, riid, out);
    list_Release((ID3D12GraphicsCommandList *)l);
    return hr;
}

static HRESULT STDMETHODCALLTYPE device_CreateFence(ID3D12Device *This, UINT64 initial,
        D3D12_FENCE_FLAGS flags, REFIID riid, void **out) {
    (void)This;
    if (!out) return E_INVALIDARG;
    if (flags != D3D12_FENCE_FLAG_NONE) return E_NOTIMPL;
    struct mad_fence *f = calloc(1, sizeof *f);
    if (!f) return E_OUTOFMEMORY;
    f->vtbl = &g_fence_vtbl; f->refs = 1; f->iid = &IID_ID3D12Fence; f->name = "Fence";
    f->value = initial;
    InitializeCriticalSection(&f->lock);
    InitializeConditionVariable(&f->cv);
    HRESULT hr = fence_QI((ID3D12Fence *)f, riid, out);
    fence_Release((ID3D12Fence *)f);
    return hr;
}

static UINT STDMETHODCALLTYPE device_GetNodeCount(ID3D12Device *This) { (void)This; return 1; }

/* ---- command signature ---------------------------------------------------
 * The layout of an ExecuteIndirect argument record. The object only has to
 * remember the description faithfully; the interpretation happens when
 * ExecuteIndirect is implemented. UE5 creates these during RHI init, before
 * any draw, so a refusal here ends the run before rendering starts. */
#define MAD_CMDSIG_ARGS_MAX 16
struct mad_cmdsig {
    ID3D12CommandSignatureVtbl *vtbl;
    LONG refs;
    const IID *iid;
    const char *name;
    struct mad_device *device;
    D3D12_COMMAND_SIGNATURE_DESC desc;
    D3D12_INDIRECT_ARGUMENT_DESC args[MAD_CMDSIG_ARGS_MAX];
};
static ID3D12CommandSignatureVtbl g_cmdsig_vtbl;

static HRESULT STDMETHODCALLTYPE cmdsig_QI(ID3D12CommandSignature *This, REFIID riid, void **out) {
    struct mad_obj *o = (struct mad_obj *)This;
    if (!out) return E_POINTER;
    if (IsEqualGUID(riid, &IID_ID3D12Pageable)) { InterlockedIncrement(&o->refs); *out = This; return S_OK; }
    return mad_qi(o, riid, out, 1);
}
static ULONG STDMETHODCALLTYPE cmdsig_AddRef(ID3D12CommandSignature *This) { return mad_addref((struct mad_obj *)This); }
static ULONG STDMETHODCALLTYPE cmdsig_Release(ID3D12CommandSignature *This) { return mad_release((struct mad_obj *)This); }
static HRESULT STDMETHODCALLTYPE cmdsig_GetPrivateData(ID3D12CommandSignature *This, REFGUID g, UINT *n, void *d) {
    (void)This; (void)g; (void)d; if (n) *n = 0; return DXGI_ERROR_NOT_FOUND;
}
static HRESULT STDMETHODCALLTYPE cmdsig_SetPrivateData(ID3D12CommandSignature *This, REFGUID g, UINT n, const void *d) {
    (void)This; (void)g; (void)n; (void)d; return S_OK;
}
static HRESULT STDMETHODCALLTYPE cmdsig_SetPrivateDataInterface(ID3D12CommandSignature *This, REFGUID g, const IUnknown *d) {
    (void)This; (void)g; (void)d; return S_OK;
}
static HRESULT STDMETHODCALLTYPE cmdsig_SetName(ID3D12CommandSignature *This, LPCWSTR name) { (void)This; (void)name; return S_OK; }
static HRESULT STDMETHODCALLTYPE cmdsig_GetDevice(ID3D12CommandSignature *This, REFIID riid, void **out) {
    struct mad_cmdsig *s = (struct mad_cmdsig *)This;
    return s->device->vtbl->QueryInterface((ID3D12Device10 *)s->device, riid, out);
}

static HRESULT STDMETHODCALLTYPE device_CreateCommandSignature(ID3D12Device *This,
        const D3D12_COMMAND_SIGNATURE_DESC *desc, ID3D12RootSignature *root_signature,
        REFIID riid, void **out) {
    struct mad_cmdsig *s;
    HRESULT hr;
    UINT i;
    if (!out) return E_INVALIDARG;
    *out = NULL;
    if (!desc || !desc->pArgumentDescs || desc->NumArgumentDescs == 0) return E_INVALIDARG;
    if (desc->NumArgumentDescs > MAD_CMDSIG_ARGS_MAX) {
        d3d12_log("[madeira-d3d12] CreateCommandSignature refused: %u argument descs (limit %u)\n",
                  desc->NumArgumentDescs, (unsigned)MAD_CMDSIG_ARGS_MAX);
        return E_NOTIMPL;
    }
    s = calloc(1, sizeof *s);
    if (!s) return E_OUTOFMEMORY;
    s->vtbl = &g_cmdsig_vtbl; s->refs = 1; s->iid = &IID_ID3D12CommandSignature; s->name = "CommandSignature";
    s->device = (struct mad_device *)This;
    s->desc = *desc;
    memcpy(s->args, desc->pArgumentDescs, desc->NumArgumentDescs * sizeof s->args[0]);
    s->desc.pArgumentDescs = s->args;
    {
        /* One line per signature: argument kinds are what ExecuteIndirect will
         * have to support, so the log lists them in creation order. */
        char kinds[MAD_CMDSIG_ARGS_MAX * 4 + 1];
        int n = 0;
        for (i = 0; i < desc->NumArgumentDescs && n < (int)sizeof kinds - 4; i++)
            n += snprintf(kinds + n, sizeof kinds - n, "%s%u", i ? "," : "", (unsigned)s->args[i].Type);
        d3d12_log("[madeira-d3d12] command signature: stride %u, %u args (types %s), root sig %s\n",
                  desc->ByteStride, desc->NumArgumentDescs, kinds, root_signature ? "given" : "none");
    }
    hr = cmdsig_QI((ID3D12CommandSignature *)s, riid, out);
    cmdsig_Release((ID3D12CommandSignature *)s);
    return hr;
}

/* ---- formats -------------------------------------------------------------
 * Bytes per pixel, or per 4x4 block for the compressed formats. Only the
 * layouts an upload needs; an unknown format is named once and treated as
 * four bytes so the arithmetic stays finite rather than dividing by zero. */
static void mad_format_info(DXGI_FORMAT f, UINT *bytes, UINT *block) {
    *block = 1;
    if (f >= DXGI_FORMAT_R32G32B32A32_TYPELESS && f <= DXGI_FORMAT_R32G32B32A32_SINT) { *bytes = 16; return; }
    if (f >= DXGI_FORMAT_R32G32B32_TYPELESS && f <= DXGI_FORMAT_R32G32B32_SINT) { *bytes = 12; return; }
    if (f >= DXGI_FORMAT_R16G16B16A16_TYPELESS && f <= DXGI_FORMAT_R32G32_SINT) { *bytes = 8; return; }
    if (f >= DXGI_FORMAT_R32G8X24_TYPELESS && f <= DXGI_FORMAT_X32_TYPELESS_G8X24_UINT) { *bytes = 8; return; }
    if (f >= DXGI_FORMAT_R10G10B10A2_TYPELESS && f <= DXGI_FORMAT_X24_TYPELESS_G8_UINT) { *bytes = 4; return; }
    if (f >= DXGI_FORMAT_R8G8_TYPELESS && f <= DXGI_FORMAT_R16_SINT) { *bytes = 2; return; }
    if (f >= DXGI_FORMAT_R8_TYPELESS && f <= DXGI_FORMAT_A8_UNORM) { *bytes = 1; return; }
    if (f == DXGI_FORMAT_R9G9B9E5_SHAREDEXP || f == DXGI_FORMAT_R8G8_B8G8_UNORM || f == DXGI_FORMAT_G8R8_G8B8_UNORM) { *bytes = 4; return; }
    if ((f >= DXGI_FORMAT_BC1_TYPELESS && f <= DXGI_FORMAT_BC1_UNORM_SRGB) ||
        (f >= DXGI_FORMAT_BC4_TYPELESS && f <= DXGI_FORMAT_BC4_SNORM)) { *bytes = 8; *block = 4; return; }
    if ((f >= DXGI_FORMAT_BC2_TYPELESS && f <= DXGI_FORMAT_BC3_UNORM_SRGB) ||
        (f >= DXGI_FORMAT_BC5_TYPELESS && f <= DXGI_FORMAT_BC5_SNORM) ||
        (f >= DXGI_FORMAT_BC6H_TYPELESS && f <= DXGI_FORMAT_BC7_UNORM_SRGB)) { *bytes = 16; *block = 4; return; }
    if (f == DXGI_FORMAT_B5G6R5_UNORM || f == DXGI_FORMAT_B5G5R5A1_UNORM) { *bytes = 2; return; }
    if (f >= DXGI_FORMAT_B8G8R8A8_UNORM && f <= DXGI_FORMAT_B8G8R8X8_UNORM_SRGB) { *bytes = 4; return; }
    if (f == DXGI_FORMAT_UNKNOWN) { *bytes = 1; return; }
    {
        static DXGI_FORMAT seen[16]; static unsigned n; unsigned i;
        for (i = 0; i < n; i++) if (seen[i] == f) { *bytes = 4; return; }
        if (n < 16) seen[n++] = f;
        d3d12_log("[madeira-d3d12] format %u has no size entry; assuming 4 bytes per pixel\n", (unsigned)f);
    }
    *bytes = 4;
}

static UINT64 mad_align(UINT64 v, UINT64 a) { return (v + a - 1) & ~(a - 1); }

/* The standard subresource layout: rows padded to 256 bytes, each subresource
 * starting on a 512-byte boundary. Both constants are the API's own. */
static void STDMETHODCALLTYPE device_GetCopyableFootprints(ID3D12Device *This,
        const D3D12_RESOURCE_DESC *desc, UINT first, UINT count, UINT64 base_offset,
        D3D12_PLACED_SUBRESOURCE_FOOTPRINT *layouts, UINT *row_count, UINT64 *row_size,
        UINT64 *total_bytes) {
    UINT bytes, block, i;
    UINT64 offset = base_offset;
    UINT mips = desc->MipLevels ? desc->MipLevels : 1;
    (void)This;
    mad_format_info(desc->Format, &bytes, &block);
    for (i = 0; i < count; i++) {
        UINT s = first + i, mip = s % mips;
        UINT64 w, h, d, rowbytes, pitch, rows;
        if (desc->Dimension == D3D12_RESOURCE_DIMENSION_BUFFER) {
            w = desc->Width; h = 1; d = 1; rowbytes = desc->Width;
        } else {
            w = desc->Width >> mip; if (!w) w = 1;
            h = desc->Height >> mip; if (!h) h = 1;
            d = 1;
            if (desc->Dimension == D3D12_RESOURCE_DIMENSION_TEXTURE3D) {
                d = desc->DepthOrArraySize >> mip; if (!d) d = 1;
            }
            rowbytes = ((w + block - 1) / block) * bytes;
        }
        rows = (h + block - 1) / block;
        pitch = mad_align(rowbytes, D3D12_TEXTURE_DATA_PITCH_ALIGNMENT);
        offset = mad_align(offset, D3D12_TEXTURE_DATA_PLACEMENT_ALIGNMENT);
        if (layouts) {
            layouts[i].Offset = offset;
            layouts[i].Footprint.Format = desc->Format;
            layouts[i].Footprint.Width = (UINT)w;
            layouts[i].Footprint.Height = (UINT)h;
            layouts[i].Footprint.Depth = (UINT)d;
            layouts[i].Footprint.RowPitch = (UINT)pitch;
        }
        if (row_count) row_count[i] = (UINT)rows;
        if (row_size) row_size[i] = rowbytes;
        offset += pitch * rows * d;
    }
    if (total_bytes) *total_bytes = offset - base_offset;
}

static D3D12_RESOURCE_ALLOCATION_INFO * STDMETHODCALLTYPE device_GetResourceAllocationInfo(
        ID3D12Device *This, D3D12_RESOURCE_ALLOCATION_INFO *ret, UINT visible_mask, UINT n,
        const D3D12_RESOURCE_DESC *descs) {
    UINT64 total = 0, align = D3D12_DEFAULT_RESOURCE_PLACEMENT_ALIGNMENT, i;
    (void)visible_mask;
    for (i = 0; i < n; i++) {
        const D3D12_RESOURCE_DESC *d = &descs[i];
        UINT64 bytes = 0, a = D3D12_DEFAULT_RESOURCE_PLACEMENT_ALIGNMENT;
        if (d->Dimension == D3D12_RESOURCE_DIMENSION_BUFFER) bytes = d->Width;
        else {
            UINT subs = (d->MipLevels ? d->MipLevels : 1) *
                        (d->Dimension == D3D12_RESOURCE_DIMENSION_TEXTURE3D ? 1 : (d->DepthOrArraySize ? d->DepthOrArraySize : 1));
            device_GetCopyableFootprints(This, d, 0, subs, 0, NULL, NULL, NULL, &bytes);
            if (d->SampleDesc.Count > 1) a = D3D12_DEFAULT_MSAA_RESOURCE_PLACEMENT_ALIGNMENT;
        }
        if (a > align) align = a;
        total = mad_align(total, a) + mad_align(bytes, a);
    }
    ret->SizeInBytes = mad_align(total, align);
    ret->Alignment = align;
    if (n == 1 && descs[0].Dimension == D3D12_RESOURCE_DIMENSION_BUFFER && descs[0].Width >= (32u << 20)) {
        static unsigned said;
        if (said++ < 64)
            d3d12_log("[madeira-d3d12] alloc-info: buffer %llu MB flags %#x req-align %llu -> size %llu KB align %llu\n",
                      (unsigned long long)(descs[0].Width >> 20), (unsigned)descs[0].Flags, (unsigned long long)descs[0].Alignment,
                      (unsigned long long)(ret->SizeInBytes >> 10), (unsigned long long)ret->Alignment);
    }
    return ret;
}

static D3D12_RESOURCE_DESC1 * STDMETHODCALLTYPE res_GetDesc1(ID3D12Resource2 *This, D3D12_RESOURCE_DESC1 *ret) {
    memset(ret, 0, sizeof *ret);
    memcpy(ret, &((struct mad_resource *)This)->desc, sizeof(D3D12_RESOURCE_DESC));   /* DESC is a prefix of DESC1 */
    return ret;
}
static D3D12_RESOURCE_DESC * STDMETHODCALLTYPE res_GetDesc(ID3D12Resource *This, D3D12_RESOURCE_DESC *ret) {
    *ret = ((struct mad_resource *)This)->desc;
    return ret;
}

/* ---- descriptors beyond textures ------------------------------------------
 * The converter's buffer entry: address in the first word, byte size in the
 * low half of the third (IRDescriptorTableSetBuffer / GetBufferMetadata);
 * bit 63 marks a typed buffer, which nothing here produces yet. */
static void mad_set_buffer_descriptor(struct mad_descriptor *e, UINT64 va, UINT64 size) {
    e->gpu_va = va;
    e->texture_view_id = 0;
    e->metadata = size & 0xffffffffu;
}

static int mad_map_texture_format(DXGI_FORMAT f, D3D12_RESOURCE_FLAGS flags, enum WMTPixelFormat *out, int *is_depth);
/* ml905: a typed buffer view. Returns 1 and fills the descriptor per the
 * converter's IRDescriptorTableSetBufferView contract: gpuVA = buffer + byte
 * offset, textureViewID = a texture-buffer view whose first element is at an
 * aligned offset, metadata = size | offset-in-elements << 32 | typed bit 63.
 * Without this, UE's manual vertex fetch (positions, tangents, UVs read from
 * Buffer<float>/Buffer<float4> SRVs) sees a raw address the converted shader
 * never dereferences: every scene vertex came out at the origin and nothing
 * rasterised (depth 0.0 % written, GBuffers 0.0 %). */
static int mad_typed_buffer_view(struct mad_device *d, struct mad_resource *r, DXGI_FORMAT fmt,
                                 UINT64 first, UINT64 num, int uav, struct mad_descriptor *e) {
    enum WMTPixelFormat pf; int is_depth = 0; UINT bytes, block; unsigned k;
    UINT64 byte_off, aligned, elem_off, width, bpr;
    struct WMTTextureInfo ti;
    obj_handle_t tex;
    static unsigned said_fail, said_ok;
    if (!r->buffer || !mad_map_texture_format(fmt, 0, &pf, &is_depth) || is_depth) return 0;
    mad_format_info(fmt, &bytes, &block);
    if (!bytes || block != 1) return 0;
    byte_off = first * bytes;
    for (k = 0; k < r->ntview; k++)
        if (r->tview[k].fmt == (UINT)fmt && r->tview[k].off == byte_off && r->tview[k].num == num && r->tview[k].uav == (UINT8)uav) break;
    if (k == r->ntview) {
        aligned = byte_off & ~(UINT64)63;                   /* linear texture alignment on Apple GPUs is <= 64 */
        elem_off = (byte_off - aligned) / bytes;
        width = num + elem_off;
        if (aligned + width * bytes > r->size) width = (r->size - aligned) / bytes;
        if (!width || width > (1u << 28)) return 0;
        bpr = width * bytes;
        memset(&ti, 0, sizeof ti);
        ti.pixel_format = pf; ti.width = (uint32_t)width; ti.height = 1; ti.depth = 1; ti.array_length = 1;
        ti.type = WMTTextureTypeTextureBuffer; ti.mipmap_level_count = 1; ti.sample_count = 1;
        ti.usage = uav ? (WMTTextureUsageShaderRead | WMTTextureUsageShaderWrite) : WMTTextureUsageShaderRead;
        ti.options = r->cpu ? WMTResourceStorageModeShared : WMTResourceStorageModePrivate;
        tex = MTLBuffer_newTexture(r->buffer, &ti, aligned, bpr);
        if (!tex || !ti.gpu_resource_id) {
            if (said_fail++ < 8)
                d3d12_log("[madeira-d3d12] typed buffer view FAILED: fmt %u first %llu num %llu (buffer %llu bytes)\n",
                          (unsigned)fmt, (unsigned long long)first, (unsigned long long)num, (unsigned long long)r->size);
            return 0;
        }
        mad_resident(d, tex);
        if (r->ntview < 16) k = r->ntview++;
        else { k = r->tview_next++ % 16; if (r->tview[k].tex) NSObject_release(r->tview[k].tex); }
        r->tview[k].fmt = (UINT)fmt; r->tview[k].off = byte_off; r->tview[k].num = num; r->tview[k].uav = (UINT8)uav;
        r->tview[k].tex = tex; r->tview[k].id = ti.gpu_resource_id;
        if (said_ok++ < 12)
            d3d12_log("[madeira-d3d12] typed buffer view: fmt %u first %llu num %llu%s -> %ux1 texture buffer, element offset %llu\n",
                      (unsigned)fmt, (unsigned long long)first, (unsigned long long)num, uav ? " (UAV)" : "",
                      (unsigned)width, (unsigned long long)elem_off);
    }
    aligned = r->tview[k].off & ~(UINT64)63; elem_off = (r->tview[k].off - aligned) / bytes;
    e->gpu_va = r->gpu_address + r->tview[k].off;
    e->texture_view_id = r->tview[k].id;
    e->metadata = ((num * bytes) & 0xffffffffull) | ((elem_off & 0x7fffffffull) << 32) | (1ull << 63);
    return 1;
}

/* ml913: the texture resource id a descriptor should carry for a view of the
 * given D3D dimension and sub-range. The base texture when it already matches;
 * otherwise a (cached) Metal texture view of the right type. */
/* ml918: pf = 0 keeps the texture's own format; swz packs four
 * WMTTextureSwizzle values (r | g<<8 | b<<16 | a<<24), 0 = identity. */
#define MAD_SWZ_IDENTITY (2u | 3u << 8 | 4u << 16 | 5u << 24)
static UINT64 mad_texture_view_id(struct mad_device *d, struct mad_resource *r, enum WMTTextureType want,
                                  UINT lvl0, UINT nlvl, UINT sl0, UINT nsl, enum WMTPixelFormat pf, UINT swz) {
    unsigned k; UINT64 id = 0; obj_handle_t tex;
    struct WMTTextureSwizzleChannels sw;
    static unsigned said, said_fail;
    if (!r->texture) return 0;
    if (!swz) swz = MAD_SWZ_IDENTITY;
    if (!pf || r->is_depth) pf = r->tex_pf;   /* depth textures keep their format: sampled as depth */
    if (nlvl == 0 || nlvl == ~0u || lvl0 + nlvl > r->tex_mips) nlvl = r->tex_mips > lvl0 ? r->tex_mips - lvl0 : 1;
    if (nsl == 0 || nsl == ~0u || sl0 + nsl > r->tex_layers) nsl = r->tex_layers > sl0 ? r->tex_layers - sl0 : 1;
    if (want == r->tex_type && lvl0 == 0 && nlvl == r->tex_mips && sl0 == 0 && nsl == r->tex_layers && pf == r->tex_pf && swz == MAD_SWZ_IDENTITY)
        return r->gpu_resource_id;
    if (want == WMTTextureTypeCube) nsl = 6;
    if (want == WMTTextureTypeCubeArray) nsl = (nsl / 6) * 6 ? (nsl / 6) * 6 : 6;
    for (k = 0; k < r->nxview; k++)
        if (r->xview[k].type == (UINT)want && r->xview[k].lvl0 == lvl0 && r->xview[k].nlvl == nlvl && r->xview[k].sl0 == sl0 && r->xview[k].nsl == nsl &&
            r->xview[k].pf == (UINT)pf && r->xview[k].swz == swz)
            return r->xview[k].id;
    sw.r = (enum WMTTextureSwizzle)(swz & 0xff); sw.g = (enum WMTTextureSwizzle)((swz >> 8) & 0xff);
    sw.b = (enum WMTTextureSwizzle)((swz >> 16) & 0xff); sw.a = (enum WMTTextureSwizzle)((swz >> 24) & 0xff);
    tex = MTLTexture_newTextureView(r->texture, pf, want, (uint16_t)lvl0, (uint16_t)nlvl, (uint16_t)sl0, (uint16_t)nsl, sw, &id);
    if (!tex || !id) {
        if (said_fail++ < 12)
            d3d12_log("[madeira-d3d12] texture view FAILED: type %u -> %u, levels %u+%u, slices %u+%u of %ux%u (%s)\n",
                      (unsigned)r->tex_type, (unsigned)want, lvl0, nlvl, sl0, nsl, r->width, r->height, r->name);
        return r->gpu_resource_id;   /* keep the old behaviour rather than an empty slot */
    }
    mad_resident(d, tex);
    if (r->nxview < 8) k = r->nxview++;
    else { k = r->xview_next++ % 8; if (r->xview[k].tex) NSObject_release(r->xview[k].tex); }
    r->xview[k].type = (UINT)want; r->xview[k].lvl0 = lvl0; r->xview[k].nlvl = nlvl; r->xview[k].sl0 = sl0; r->xview[k].nsl = nsl;
    r->xview[k].pf = (UINT)pf; r->xview[k].swz = swz;
    r->xview[k].tex = tex; r->xview[k].id = id;
    if (said++ < 24)
        d3d12_log("[madeira-d3d12] texture view: type %u -> %u, fmt %u -> %u, swz %08x, levels %u+%u, slices %u+%u of %ux%u x%u (%s)\n",
                  (unsigned)r->tex_type, (unsigned)want, (unsigned)r->tex_pf, (unsigned)pf, swz, lvl0, nlvl, sl0, nsl, r->width, r->height, r->tex_layers, r->name);
    return id;
}

static void STDMETHODCALLTYPE device_CreateConstantBufferView(ID3D12Device *This,
        const D3D12_CONSTANT_BUFFER_VIEW_DESC *desc, D3D12_CPU_DESCRIPTOR_HANDLE h) {
    struct mad_descriptor *e = (struct mad_descriptor *)h.ptr;
    (void)This;
    if (!e) return;
    if (!desc || !desc->BufferLocation) { memset(e, 0, sizeof *e); return; }   /* a null view */
    mad_set_buffer_descriptor(e, desc->BufferLocation, desc->SizeInBytes);
}

static void STDMETHODCALLTYPE device_CreateUnorderedAccessView(ID3D12Device *This,
        ID3D12Resource *res, ID3D12Resource *counter, const D3D12_UNORDERED_ACCESS_VIEW_DESC *desc,
        D3D12_CPU_DESCRIPTOR_HANDLE h) {
    struct mad_resource *r = (struct mad_resource *)res;
    struct mad_descriptor *e = (struct mad_descriptor *)h.ptr;
    static int said_counter, said_kind;
    if (!e) return;
    if (!r) { memset(e, 0, sizeof *e); return; }                                /* a null view */
    if (counter && !said_counter++)
        d3d12_log("[madeira-d3d12] CreateUnorderedAccessView: counter resources are ignored\n");
    if (r->buffer) {
        UINT64 stride = 4, first = 0, num = r->size / 4;
        if (desc && desc->ViewDimension == D3D12_UAV_DIMENSION_BUFFER) {
            UINT bytes, block;
            first = desc->Buffer.FirstElement; num = desc->Buffer.NumElements;
            if (desc->Buffer.StructureByteStride) stride = desc->Buffer.StructureByteStride;
            else if (desc->Format != DXGI_FORMAT_UNKNOWN) {
                mad_format_info(desc->Format, &bytes, &block); stride = bytes;
                if (!(desc->Buffer.Flags & D3D12_BUFFER_UAV_FLAG_RAW) &&
                    mad_typed_buffer_view((struct mad_device *)This, r, desc->Format, first, num, 1, e)) return;   /* ml905 */
            }
        }
        mad_set_buffer_descriptor(e, r->gpu_address + first * stride, num * stride);
        return;
    }
    {
        struct mad_device *dev = (struct mad_device *)This;
        unsigned k;
        for (k = 0; k < dev->nuav; k++) if (dev->uav_res[k] == r) break;
        if (k == dev->nuav && mad_grow((void **)&dev->uav_res, &dev->nuav_cap, dev->nuav + 1, sizeof *dev->uav_res))
            dev->uav_res[dev->nuav++] = r;
    }
    if (r->texture) {
        UINT64 view_id = r->gpu_resource_id;
        if (desc) {   /* ml913: one mip, the named slices, the named dimension */
            enum WMTTextureType want = r->tex_type; UINT lvl0 = 0, sl0 = 0, nsl = ~0u;
            switch (desc->ViewDimension) {
            case D3D12_UAV_DIMENSION_TEXTURE1D: want = WMTTextureType2DArray; lvl0 = desc->Texture1D.MipSlice; nsl = 1; break;   /* ml932: arrays everywhere */
            case D3D12_UAV_DIMENSION_TEXTURE1DARRAY: want = WMTTextureType2DArray; lvl0 = desc->Texture1DArray.MipSlice; sl0 = desc->Texture1DArray.FirstArraySlice; nsl = desc->Texture1DArray.ArraySize; break;
            case D3D12_UAV_DIMENSION_TEXTURE2D: want = WMTTextureType2DArray; lvl0 = desc->Texture2D.MipSlice; nsl = 1; break;
            case D3D12_UAV_DIMENSION_TEXTURE2DARRAY: want = WMTTextureType2DArray; lvl0 = desc->Texture2DArray.MipSlice; sl0 = desc->Texture2DArray.FirstArraySlice; nsl = desc->Texture2DArray.ArraySize; break;
            case D3D12_UAV_DIMENSION_TEXTURE3D: want = WMTTextureType3D; lvl0 = desc->Texture3D.MipSlice; break;
            default: break;
            }
            /* ml928: a UAV may reinterpret the resource's format (an RG32Float
             * grid written through an RG32Uint view, a typeless resource
             * viewed as a concrete format). Before this every UAV used the
             * resource's own Metal format, so a kernel storing uints into a
             * float texture had its values converted numerically -- UE's
             * local-exposure bilateral grid became garbage and the tonemapper
             * flattened the whole frame to grey. */
            {
                enum WMTPixelFormat pf = 0; int vd = 0;
                if (desc->Format != DXGI_FORMAT_UNKNOWN && !r->is_depth && mad_map_texture_format(desc->Format, 0, &pf, &vd) && !vd && pf != r->tex_pf) {
                    static unsigned said; if (said++ < 8)
                        d3d12_log("[madeira-d3d12] UAV reinterprets %s %ux%u t%u pf%u as format %u -> pf%u\n", r->name, r->width, r->height,
                                  (unsigned)r->tex_type, (unsigned)r->tex_pf, (unsigned)desc->Format, (unsigned)pf);
                } else pf = 0;
                view_id = mad_texture_view_id((struct mad_device *)This, r, want, lvl0, 1, sl0, nsl, pf, MAD_SWZ_IDENTITY);
            }
        }
        e->gpu_va = 0; e->texture_view_id = view_id; e->metadata = 0;
        return;
    }
    if (!said_kind++) d3d12_log("[madeira-d3d12] CreateUnorderedAccessView: resource has no backend object\n");
    memset(e, 0, sizeof *e);
}

/* Descriptors are plain bytes in both heap kinds, so a copy is a copy. The
 * stride is the heap type's, which is why the type is part of the call. */
static void STDMETHODCALLTYPE device_CopyDescriptorsSimple(ID3D12Device *This, UINT n,
        D3D12_CPU_DESCRIPTOR_HANDLE dst, D3D12_CPU_DESCRIPTOR_HANDLE src, D3D12_DESCRIPTOR_HEAP_TYPE type) {
    (void)This;
    if (!n || !dst.ptr || !src.ptr) return;
    memmove((void *)dst.ptr, (const void *)src.ptr, (size_t)n * mad_descriptor_stride(type));
}

static void STDMETHODCALLTYPE device_CopyDescriptors(ID3D12Device *This,
        UINT ndst, const D3D12_CPU_DESCRIPTOR_HANDLE *dsts, const UINT *dst_sizes,
        UINT nsrc, const D3D12_CPU_DESCRIPTOR_HANDLE *srcs, const UINT *src_sizes,
        D3D12_DESCRIPTOR_HEAP_TYPE type) {
    UINT stride = mad_descriptor_stride(type);
    UINT di = 0, si = 0, dpos = 0, spos = 0;
    (void)This;
    /* Sizes may be NULL, meaning every range is one descriptor long. */
    while (di < ndst && si < nsrc) {
        UINT dlen = dst_sizes ? dst_sizes[di] : 1, slen = src_sizes ? src_sizes[si] : 1;
        UINT take = (dlen - dpos < slen - spos) ? dlen - dpos : slen - spos;
        if (take && dsts[di].ptr && srcs[si].ptr)
            memmove((char *)dsts[di].ptr + (size_t)dpos * stride,
                    (const char *)srcs[si].ptr + (size_t)spos * stride, (size_t)take * stride);
        dpos += take; spos += take;
        if (dpos >= dlen) { di++; dpos = 0; }
        if (spos >= slen) { si++; spos = 0; }
    }
}

/* ---- query heap -----------------------------------------------------------
 * Queries are accepted and resolve to zero: no timing, no occlusion counts.
 * That is the honest minimum the engine's startup needs (it creates the heaps
 * and verifies the results). Zero occlusion counts will hide geometry once
 * culling runs, so the first resolve says so in the log. */
struct mad_queryheap {
    ID3D12QueryHeapVtbl *vtbl; LONG refs; const IID *iid; const char *name;
    struct mad_device *device;
    D3D12_QUERY_HEAP_DESC desc;
};
static ID3D12QueryHeapVtbl g_qheap_vtbl;
static HRESULT STDMETHODCALLTYPE qheap_QI(ID3D12QueryHeap *This, REFIID riid, void **out) {
    struct mad_obj *o = (struct mad_obj *)This;
    if (!out) return E_POINTER;
    if (IsEqualGUID(riid, &IID_ID3D12Pageable)) { InterlockedIncrement(&o->refs); *out = This; return S_OK; }
    return mad_qi(o, riid, out, 1);
}
static ULONG STDMETHODCALLTYPE qheap_AddRef(ID3D12QueryHeap *This) { return mad_addref((struct mad_obj *)This); }
static ULONG STDMETHODCALLTYPE qheap_Release(ID3D12QueryHeap *This) { return mad_release((struct mad_obj *)This); }
static HRESULT STDMETHODCALLTYPE qheap_GetPrivateData(ID3D12QueryHeap *This, REFGUID g, UINT *n, void *d) {
    (void)This; (void)g; (void)d; if (n) *n = 0; return DXGI_ERROR_NOT_FOUND;
}
static HRESULT STDMETHODCALLTYPE qheap_SetPrivateData(ID3D12QueryHeap *This, REFGUID g, UINT n, const void *d) {
    (void)This; (void)g; (void)n; (void)d; return S_OK;
}
static HRESULT STDMETHODCALLTYPE qheap_SetPrivateDataInterface(ID3D12QueryHeap *This, REFGUID g, const IUnknown *d) {
    (void)This; (void)g; (void)d; return S_OK;
}
static HRESULT STDMETHODCALLTYPE qheap_SetName(ID3D12QueryHeap *This, LPCWSTR name) { (void)This; (void)name; return S_OK; }
static HRESULT STDMETHODCALLTYPE qheap_GetDevice(ID3D12QueryHeap *This, REFIID riid, void **out) {
    struct mad_queryheap *q = (struct mad_queryheap *)This;
    return q->device->vtbl->QueryInterface((ID3D12Device10 *)q->device, riid, out);
}

static HRESULT STDMETHODCALLTYPE device_CreateQueryHeap(ID3D12Device *This,
        const D3D12_QUERY_HEAP_DESC *desc, REFIID riid, void **out) {
    struct mad_queryheap *q;
    HRESULT hr;
    if (!out) return E_INVALIDARG;
    *out = NULL;
    if (!desc) return E_INVALIDARG;
    q = calloc(1, sizeof *q);
    if (!q) return E_OUTOFMEMORY;
    q->vtbl = &g_qheap_vtbl; q->refs = 1; q->iid = &IID_ID3D12QueryHeap; q->name = "QueryHeap";
    q->device = (struct mad_device *)This;
    q->desc = *desc;
    d3d12_log("[madeira-d3d12] query heap: type %u, %u queries (results resolve to zero)\n",
              (unsigned)desc->Type, desc->Count);
    hr = qheap_QI((ID3D12QueryHeap *)q, riid, out);
    qheap_Release((ID3D12QueryHeap *)q);
    return hr;
}

static void STDMETHODCALLTYPE list_BeginQuery(ID3D12GraphicsCommandList *This, ID3D12QueryHeap *heap,
        D3D12_QUERY_TYPE type, UINT index) { (void)This; (void)heap; (void)type; (void)index; }
static void STDMETHODCALLTYPE list_EndQuery(ID3D12GraphicsCommandList *This, ID3D12QueryHeap *heap,
        D3D12_QUERY_TYPE type, UINT index) { (void)This; (void)heap; (void)type; (void)index; }
static void STDMETHODCALLTYPE list_ResolveQueryData(ID3D12GraphicsCommandList *This, ID3D12QueryHeap *heap,
        D3D12_QUERY_TYPE type, UINT start, UINT count, ID3D12Resource *dst, UINT64 offset) {
    struct mad_resource *r = (struct mad_resource *)dst;
    static int said;
    UINT64 each = (type == D3D12_QUERY_TYPE_PIPELINE_STATISTICS) ? sizeof(D3D12_QUERY_DATA_PIPELINE_STATISTICS) : 8;
    (void)This; (void)heap; (void)start;
    if (!said++) d3d12_log("[madeira-d3d12] ResolveQueryData: occlusion answers 'visible', other queries zero (not measured yet)\n");
    /* Written immediately rather than at execution: a constant is the same
     * value whenever it lands, and the destination is a readback buffer the
     * CPU owns. ml889: occlusion queries must NOT resolve to zero -- the engine
     * reads zero samples as "occluded" and culls the object next frame, which
     * emptied the whole 3D scene while the UI still drew. */
    if (r && r->cpu && offset + (UINT64)count * each <= r->size) {
        if (type == D3D12_QUERY_TYPE_OCCLUSION || type == D3D12_QUERY_TYPE_BINARY_OCCLUSION) {
            UINT64 *q = (UINT64 *)((char *)r->cpu + offset); UINT k;
            for (k = 0; k < count; k++) q[k] = 1;
        } else
            memset((char *)r->cpu + offset, 0, (size_t)(count * each));
    }
}

/* ---- queue queries --------------------------------------------------------- */
static HRESULT STDMETHODCALLTYPE queue_GetTimestampFrequency(ID3D12CommandQueue *This, UINT64 *freq) {
    (void)This;
    if (!freq) return E_INVALIDARG;
    *freq = 1000000000ull;   /* nanosecond ticks; the zero timestamps above are in the same unit */
    return S_OK;
}
static HRESULT STDMETHODCALLTYPE queue_GetClockCalibration(ID3D12CommandQueue *This, UINT64 *gpu, UINT64 *cpu) {
    LARGE_INTEGER now;
    (void)This;
    QueryPerformanceCounter(&now);
    if (gpu) *gpu = 0;
    if (cpu) *cpu = (UINT64)now.QuadPart;
    return S_OK;
}
static D3D12_COMMAND_QUEUE_DESC * STDMETHODCALLTYPE queue_GetDesc(ID3D12CommandQueue *This, D3D12_COMMAND_QUEUE_DESC *ret) {
    (void)This;
    memset(ret, 0, sizeof *ret);
    ret->Type = ((struct mad_queue *)This)->type;
    return ret;
}

/* ---- resource ------------------------------------------------------------ */
static ID3D12Resource2Vtbl g_res_vtbl;

static void mad_track(struct mad_device *d, struct mad_resource *r) {
    if (!d || !r) return;
    EnterCriticalSection(&d->live_lock);
    if (mad_grow((void **)&d->live, &d->live_cap, d->nlive + 1, sizeof *d->live)) d->live[d->nlive++] = r;
    LeaveCriticalSection(&d->live_lock);
}
static void mad_untrack(struct mad_device *d, struct mad_resource *r) {
    if (!d || !r) return;
    EnterCriticalSection(&d->live_lock);
    for (unsigned i = 0; i < d->nlive; i++)
        if (d->live[i] == r) { d->live[i] = d->live[--d->nlive]; break; }
    LeaveCriticalSection(&d->live_lock);
}
static struct mad_resource *mad_resolve_address(struct mad_device *d, UINT64 addr, UINT64 *off) {
    struct mad_resource *found = NULL;
    if (!d || !addr) return NULL;
    EnterCriticalSection(&d->live_lock);
    for (unsigned i = 0; i < d->nlive; i++) {
        struct mad_resource *r = d->live[i];
        if (r->gpu_address && addr >= r->gpu_address && addr < r->gpu_address + r->size) {
            found = r;
            if (off) *off = addr - r->gpu_address;
            break;
        }
    }
    LeaveCriticalSection(&d->live_lock);
    return found;
}

static HRESULT STDMETHODCALLTYPE res_QI(ID3D12Resource *This, REFIID riid, void **out) {
    /* ml886: ID3D12Resource1/2 are the same object with more slots. */
    if (out && riid && (IsEqualGUID(riid, &IID_ID3D12Resource1) || IsEqualGUID(riid, &IID_ID3D12Resource2))) {
        InterlockedIncrement(&((struct mad_obj *)This)->refs);
        *out = This;
        return S_OK;
    }
    return mad_qi((struct mad_obj *)This, riid, out, 1);
}
static ULONG STDMETHODCALLTYPE res_AddRef(ID3D12Resource *This) { return mad_addref((struct mad_obj *)This); }
static ULONG STDMETHODCALLTYPE res_Release(ID3D12Resource *This) {
    struct mad_resource *r = (struct mad_resource *)This;
    LONG n = InterlockedDecrement(&r->refs);
    if (n == 0) {
        /* The backend owns the storage, so releasing the buffer is the whole
         * teardown; there is no separate free to order against it. */
        mad_untrack(r->owner, r);
        if (r->owner) {   /* ml920: srv_res / uav_res kept freed resources; the residency
                           * loops read r->texture from them, and a longer walk
                           * (ml918 capture) faulted on a partially unmapped one. */
            struct mad_device *dd = r->owner; unsigned i;
            for (i = 0; i < dd->nsrv; i++) if (dd->srv_res[i] == r) { dd->srv_res[i] = dd->srv_res[--dd->nsrv]; break; }
            for (i = 0; i < dd->nuav; i++) if (dd->uav_res[i] == r) { dd->uav_res[i] = dd->uav_res[--dd->nuav]; break; }
        }
        { unsigned k; for (k = 0; k < r->ntview; k++) if (r->tview[k].tex) NSObject_release(r->tview[k].tex); }   /* ml905 */
        { unsigned k; for (k = 0; k < r->nxview; k++) if (r->xview[k].tex) NSObject_release(r->xview[k].tex); }   /* ml913 */
        if (r->buffer) NSObject_release(r->buffer);
        if (r->texture && !r->borrowed) NSObject_release(r->texture);
        free(r);
    }
    return (ULONG)n;
}
static HRESULT STDMETHODCALLTYPE res_Map(ID3D12Resource *This, UINT sub,
                                         const D3D12_RANGE *read_range, void **data) {
    struct mad_resource *r = (struct mad_resource *)This;
    (void)read_range;
    if (sub != 0) return E_INVALIDARG;            /* buffers have one subresource */
    if (!r->cpu) {
        /* DEFAULT lives in GPU-private storage; mapping it is not a thing the
         * API allows, and pretending otherwise would hand back a pointer the
         * GPU never reads. */
        d3d12_log("[madeira-d3d12] Map refused on a DEFAULT-heap resource\n");
        return E_INVALIDARG;
    }
    InterlockedIncrement(&r->mapped);
    if (data) *data = r->cpu;
    return S_OK;
}
static void STDMETHODCALLTYPE res_Unmap(ID3D12Resource *This, UINT sub, const D3D12_RANGE *written) {
    struct mad_resource *r = (struct mad_resource *)This;
    (void)sub; (void)written;
    if (r->mapped) InterlockedDecrement(&r->mapped);
}
static D3D12_GPU_VIRTUAL_ADDRESS STDMETHODCALLTYPE res_GetGPUVirtualAddress(ID3D12Resource *This) {
    struct mad_resource *r = (struct mad_resource *)This;
    /* Deliberately the backend's own address. The design warns against putting
     * synthetic guest addresses where the GPU will dereference them. */
    return (D3D12_GPU_VIRTUAL_ADDRESS)r->gpu_address;
}

/* ---- texture formats -------------------------------------------------------
 * DXGI to Metal. Typeless formats take the natural interpretation, and the
 * depth-capable typeless ones become depth when the resource allows a depth
 * stencil view. Metal has no 24-bit depth on Apple GPUs, so D24S8 widens to
 * D32S8, which changes the stored precision and nothing the application can
 * observe through the API. Unknown formats are named once and refused. */
static int mad_map_texture_format(DXGI_FORMAT f, D3D12_RESOURCE_FLAGS flags,
                                  enum WMTPixelFormat *out, int *is_depth) {
    int ds = (flags & D3D12_RESOURCE_FLAG_ALLOW_DEPTH_STENCIL) != 0;
    *is_depth = 0;
    switch (f) {
    case DXGI_FORMAT_R8G8B8A8_TYPELESS: case DXGI_FORMAT_R8G8B8A8_UNORM: *out = WMTPixelFormatRGBA8Unorm; return 1;
    case DXGI_FORMAT_R8G8B8A8_UNORM_SRGB: *out = WMTPixelFormatRGBA8Unorm_sRGB; return 1;
    case DXGI_FORMAT_R8G8B8A8_SNORM: *out = WMTPixelFormatRGBA8Snorm; return 1;
    case DXGI_FORMAT_R8G8B8A8_UINT: *out = WMTPixelFormatRGBA8Uint; return 1;
    case DXGI_FORMAT_R8G8B8A8_SINT: *out = WMTPixelFormatRGBA8Sint; return 1;
    case DXGI_FORMAT_B8G8R8A8_TYPELESS: case DXGI_FORMAT_B8G8R8A8_UNORM:
    case DXGI_FORMAT_B8G8R8X8_TYPELESS: case DXGI_FORMAT_B8G8R8X8_UNORM: *out = WMTPixelFormatBGRA8Unorm; return 1;
    case DXGI_FORMAT_B8G8R8A8_UNORM_SRGB: case DXGI_FORMAT_B8G8R8X8_UNORM_SRGB: *out = WMTPixelFormatBGRA8Unorm_sRGB; return 1;
    case DXGI_FORMAT_R16G16B16A16_TYPELESS: case DXGI_FORMAT_R16G16B16A16_FLOAT: *out = WMTPixelFormatRGBA16Float; return 1;
    case DXGI_FORMAT_R16G16B16A16_UNORM: *out = WMTPixelFormatRGBA16Unorm; return 1;
    case DXGI_FORMAT_R16G16B16A16_SNORM: *out = WMTPixelFormatRGBA16Snorm; return 1;
    case DXGI_FORMAT_R16G16B16A16_UINT: *out = WMTPixelFormatRGBA16Uint; return 1;
    case DXGI_FORMAT_R16G16B16A16_SINT: *out = WMTPixelFormatRGBA16Sint; return 1;
    case DXGI_FORMAT_R32G32B32A32_TYPELESS: case DXGI_FORMAT_R32G32B32A32_FLOAT: *out = WMTPixelFormatRGBA32Float; return 1;
    case DXGI_FORMAT_R32G32B32A32_UINT: *out = WMTPixelFormatRGBA32Uint; return 1;
    case DXGI_FORMAT_R32G32B32A32_SINT: *out = WMTPixelFormatRGBA32Sint; return 1;
    case DXGI_FORMAT_R32G32_TYPELESS: case DXGI_FORMAT_R32G32_FLOAT: *out = WMTPixelFormatRG32Float; return 1;
    case DXGI_FORMAT_R32G32_UINT: *out = WMTPixelFormatRG32Uint; return 1;
    case DXGI_FORMAT_R32G32_SINT: *out = WMTPixelFormatRG32Sint; return 1;
    case DXGI_FORMAT_R16G16_TYPELESS: case DXGI_FORMAT_R16G16_FLOAT: *out = WMTPixelFormatRG16Float; return 1;
    case DXGI_FORMAT_R16G16_UNORM: *out = WMTPixelFormatRG16Unorm; return 1;
    case DXGI_FORMAT_R16G16_SNORM: *out = WMTPixelFormatRG16Snorm; return 1;
    case DXGI_FORMAT_R16G16_UINT: *out = WMTPixelFormatRG16Uint; return 1;
    case DXGI_FORMAT_R16G16_SINT: *out = WMTPixelFormatRG16Sint; return 1;
    case DXGI_FORMAT_R32_TYPELESS: if (ds) { *out = WMTPixelFormatDepth32Float; *is_depth = 1; } else *out = WMTPixelFormatR32Float; return 1;
    case DXGI_FORMAT_D32_FLOAT: *out = WMTPixelFormatDepth32Float; *is_depth = 1; return 1;
    case DXGI_FORMAT_R32_FLOAT: *out = WMTPixelFormatR32Float; return 1;
    case DXGI_FORMAT_R32_UINT: *out = WMTPixelFormatR32Uint; return 1;
    case DXGI_FORMAT_R32_SINT: *out = WMTPixelFormatR32Sint; return 1;
    case DXGI_FORMAT_R24G8_TYPELESS: case DXGI_FORMAT_D24_UNORM_S8_UINT:
    case DXGI_FORMAT_R24_UNORM_X8_TYPELESS: case DXGI_FORMAT_X24_TYPELESS_G8_UINT:
    case DXGI_FORMAT_R32G8X24_TYPELESS: case DXGI_FORMAT_D32_FLOAT_S8X24_UINT:
    case DXGI_FORMAT_R32_FLOAT_X8X24_TYPELESS: case DXGI_FORMAT_X32_TYPELESS_G8X24_UINT:
        *out = WMTPixelFormatDepth32Float_Stencil8; *is_depth = 1; return 1;
    case DXGI_FORMAT_R16_TYPELESS: if (ds) { *out = WMTPixelFormatDepth16Unorm; *is_depth = 1; } else *out = WMTPixelFormatR16Unorm; return 1;
    case DXGI_FORMAT_D16_UNORM: *out = WMTPixelFormatDepth16Unorm; *is_depth = 1; return 1;
    case DXGI_FORMAT_R16_FLOAT: *out = WMTPixelFormatR16Float; return 1;
    case DXGI_FORMAT_R16_UNORM: *out = WMTPixelFormatR16Unorm; return 1;
    case DXGI_FORMAT_R16_SNORM: *out = WMTPixelFormatR16Snorm; return 1;
    case DXGI_FORMAT_R16_UINT: *out = WMTPixelFormatR16Uint; return 1;
    case DXGI_FORMAT_R16_SINT: *out = WMTPixelFormatR16Sint; return 1;
    case DXGI_FORMAT_R8_TYPELESS: case DXGI_FORMAT_R8_UNORM: *out = WMTPixelFormatR8Unorm; return 1;
    case DXGI_FORMAT_R8_SNORM: *out = WMTPixelFormatR8Snorm; return 1;
    case DXGI_FORMAT_R8_UINT: *out = WMTPixelFormatR8Uint; return 1;
    case DXGI_FORMAT_R8_SINT: *out = WMTPixelFormatR8Sint; return 1;
    case DXGI_FORMAT_A8_UNORM: *out = WMTPixelFormatA8Unorm; return 1;
    case DXGI_FORMAT_R8G8_TYPELESS: case DXGI_FORMAT_R8G8_UNORM: *out = WMTPixelFormatRG8Unorm; return 1;
    case DXGI_FORMAT_R8G8_SNORM: *out = WMTPixelFormatRG8Snorm; return 1;
    case DXGI_FORMAT_R8G8_UINT: *out = WMTPixelFormatRG8Uint; return 1;
    case DXGI_FORMAT_R8G8_SINT: *out = WMTPixelFormatRG8Sint; return 1;
    case DXGI_FORMAT_R10G10B10A2_TYPELESS: case DXGI_FORMAT_R10G10B10A2_UNORM: *out = WMTPixelFormatRGB10A2Unorm; return 1;
    case DXGI_FORMAT_R10G10B10A2_UINT: *out = WMTPixelFormatRGB10A2Uint; return 1;
    case DXGI_FORMAT_R11G11B10_FLOAT: *out = WMTPixelFormatRG11B10Float; return 1;
    case DXGI_FORMAT_R9G9B9E5_SHAREDEXP: *out = WMTPixelFormatRGB9E5Float; return 1;
    case DXGI_FORMAT_B5G6R5_UNORM: *out = WMTPixelFormatB5G6R5Unorm; return 1;
    case DXGI_FORMAT_B5G5R5A1_UNORM: *out = WMTPixelFormatBGR5A1Unorm; return 1;
    case DXGI_FORMAT_BC1_TYPELESS: case DXGI_FORMAT_BC1_UNORM: *out = WMTPixelFormatBC1_RGBA; return 1;
    case DXGI_FORMAT_BC1_UNORM_SRGB: *out = WMTPixelFormatBC1_RGBA_sRGB; return 1;
    case DXGI_FORMAT_BC2_TYPELESS: case DXGI_FORMAT_BC2_UNORM: *out = WMTPixelFormatBC2_RGBA; return 1;
    case DXGI_FORMAT_BC2_UNORM_SRGB: *out = WMTPixelFormatBC2_RGBA_sRGB; return 1;
    case DXGI_FORMAT_BC3_TYPELESS: case DXGI_FORMAT_BC3_UNORM: *out = WMTPixelFormatBC3_RGBA; return 1;
    case DXGI_FORMAT_BC3_UNORM_SRGB: *out = WMTPixelFormatBC3_RGBA_sRGB; return 1;
    case DXGI_FORMAT_BC4_TYPELESS: case DXGI_FORMAT_BC4_UNORM: *out = WMTPixelFormatBC4_RUnorm; return 1;
    case DXGI_FORMAT_BC4_SNORM: *out = WMTPixelFormatBC4_RSnorm; return 1;
    case DXGI_FORMAT_BC5_TYPELESS: case DXGI_FORMAT_BC5_UNORM: *out = WMTPixelFormatBC5_RGUnorm; return 1;
    case DXGI_FORMAT_BC5_SNORM: *out = WMTPixelFormatBC5_RGSnorm; return 1;
    case DXGI_FORMAT_BC6H_TYPELESS: case DXGI_FORMAT_BC6H_UF16: *out = WMTPixelFormatBC6H_RGBUfloat; return 1;
    case DXGI_FORMAT_BC6H_SF16: *out = WMTPixelFormatBC6H_RGBFloat; return 1;
    case DXGI_FORMAT_BC7_TYPELESS: case DXGI_FORMAT_BC7_UNORM: *out = WMTPixelFormatBC7_RGBAUnorm; return 1;
    case DXGI_FORMAT_BC7_UNORM_SRGB: *out = WMTPixelFormatBC7_RGBAUnorm_sRGB; return 1;
    default: {
        static DXGI_FORMAT seen[16]; static unsigned n; unsigned i;
        for (i = 0; i < n; i++) if (seen[i] == f) return 0;
        if (n < 16) seen[n++] = f;
        d3d12_log("[madeira-d3d12] texture format %u has no Metal mapping\n", (unsigned)f);
        return 0;
    }
    }
}

/* Bytes in one row of the top mip, from the resource's own format. */
static UINT64 mad_res_row_bytes(const struct mad_resource *r) {
    UINT bytes, block;
    mad_format_info(r->desc.Format, &bytes, &block);
    return ((UINT64)(r->width + block - 1) / block) * bytes;
}

/* ---- resource creation core ---------------------------------------------
 * Shared by committed and placed resources. A placed resource here is an
 * allocation of its own: the backend exposes no heaps, so the heap offset only
 * says where the application THINKS the memory is. Without aliasing every
 * placed resource keeps its own storage, which costs memory but never
 * corrupts data. */
/* ml886: a refused creation returns an error the engine may not check --
 * UE 5.4 dereferenced the null RHI resource it got back. Name every refusal. */
static void mad_refuse_log(const D3D12_RESOURCE_DESC *desc, D3D12_HEAP_TYPE heap_type, const char *why) {
    static unsigned said;
    if (said++ < 32)
        d3d12_log("[madeira-d3d12] resource creation REFUSED (%s): dim %u fmt %u %llux%ux%u mips %u samples %u flags 0x%x heap-type %u\n",
                  why, (unsigned)desc->Dimension, (unsigned)desc->Format, (unsigned long long)desc->Width, desc->Height,
                  desc->DepthOrArraySize, desc->MipLevels, desc->SampleDesc.Count, (unsigned)desc->Flags, (unsigned)heap_type);
}
static HRESULT mad_create_resource(struct mad_device *d, D3D12_HEAP_TYPE heap_type,
                                   const D3D12_RESOURCE_DESC *desc, REFIID riid, void **out) {
    struct mad_resource *r;
    HRESULT hr;
    if (desc->Dimension == D3D12_RESOURCE_DIMENSION_UNKNOWN) { mad_refuse_log(desc, heap_type, "dimension UNKNOWN"); return E_INVALIDARG; }

    r = calloc(1, sizeof *r);
    if (!r) return E_OUTOFMEMORY;
    r->vtbl = &g_res_vtbl; r->refs = 1; r->iid = &IID_ID3D12Resource; r->name = "Resource";
    r->size = desc->Width;
    r->heap = heap_type;
    r->desc = *desc;
    r->owner = d;

    if (desc->Dimension != D3D12_RESOURCE_DIMENSION_BUFFER) {
        struct WMTTextureInfo ti;
        enum WMTPixelFormat pf;
        int is_depth;
        UINT layers = desc->DepthOrArraySize ? desc->DepthOrArraySize : 1;
        if (!mad_map_texture_format(desc->Format, desc->Flags, &pf, &is_depth)) { free(r); mad_refuse_log(desc, heap_type, "texture format has no Metal mapping"); return E_NOTIMPL; }
        memset(&ti, 0, sizeof ti);
        ti.pixel_format = pf;
        ti.width = (uint32_t)desc->Width;
        ti.height = desc->Dimension == D3D12_RESOURCE_DIMENSION_TEXTURE1D ? 1 : desc->Height;
        ti.depth = 1;
        ti.array_length = 1;
        ti.mipmap_level_count = desc->MipLevels ? desc->MipLevels : 1;
        ti.sample_count = desc->SampleDesc.Count ? desc->SampleDesc.Count : 1;
        /* ml932: every 1D/2D texture is allocated as an ARRAY (length >= 1),
         * matching shaders converted with IRCompatibilityFlagForceTextureArray
         * (the converter manual's "Texture arrays" table). 3D is unchanged. */
        switch (desc->Dimension) {
        case D3D12_RESOURCE_DIMENSION_TEXTURE1D:
            ti.type = WMTTextureType2DArray; ti.height = 1; ti.array_length = layers; break;
        case D3D12_RESOURCE_DIMENSION_TEXTURE3D:
            ti.type = WMTTextureType3D; ti.depth = layers; break;
        default:
            ti.type = ti.sample_count > 1 ? WMTTextureType2DMultisampleArray : WMTTextureType2DArray;
            ti.array_length = layers;
            break;
        }
        ti.usage = WMTTextureUsageShaderRead;
        if (desc->Flags & (D3D12_RESOURCE_FLAG_ALLOW_RENDER_TARGET | D3D12_RESOURCE_FLAG_ALLOW_DEPTH_STENCIL))
            ti.usage = (enum WMTTextureUsage)(ti.usage | WMTTextureUsageRenderTarget);
        if (desc->Flags & D3D12_RESOURCE_FLAG_ALLOW_UNORDERED_ACCESS)
            ti.usage = (enum WMTTextureUsage)(ti.usage | WMTTextureUsageShaderWrite);
        /* Views may reinterpret typeless and sRGB/linear pairs. */
        ti.usage = (enum WMTTextureUsage)(ti.usage | WMTTextureUsagePixelFormatView);
        ti.options = WMTResourceStorageModePrivate;
        r->texture = MTLDevice_newTexture(d->mtl_device, &ti);
        if (!r->texture) { free(r); return mad_creation_failure(d, "newTexture"); }
        mad_resident(d, r->texture);
        r->width = ti.width; r->height = ti.height;
        r->gpu_resource_id = ti.gpu_resource_id;
        r->tex_type = ti.type; r->tex_pf = pf; r->tex_mips = ti.mipmap_level_count;   /* ml913 */
        r->tex_layers = ti.type == WMTTextureType3D ? 1 : ti.array_length;
        r->tex_depth = ti.type == WMTTextureType3D ? ti.depth : 1;   /* ml924 */
        r->name = is_depth ? "DepthTarget" : (desc->Flags & D3D12_RESOURCE_FLAG_ALLOW_RENDER_TARGET) ? "RenderTarget" : "Texture";
        r->is_depth = is_depth;
        r->has_stencil = (pf == WMTPixelFormatDepth32Float_Stencil8);
        r->samples = ti.sample_count;
        hr = res_QI((ID3D12Resource *)r, riid, out);
        if (FAILED(hr)) mad_refuse_log(desc, heap_type, "interface not answered");
        res_Release((ID3D12Resource *)r);
        return hr;
    }

    {
        struct WMTBufferInfo info;
        memset(&info, 0, sizeof info);
        info.length = desc->Width ? desc->Width : 1;
        /* UPLOAD and READBACK are CPU visible: the backend owns the storage and
         * hands back the mapping (see the alignment trap noted at ml839: caller
         * memory must be page aligned in both pointer and length). */
        info.options = heap_type == D3D12_HEAP_TYPE_DEFAULT ? WMTResourceStorageModePrivate : WMTResourceStorageModeShared;
        info.memory.ptr = NULL;
        r->buffer = MTLDevice_newBuffer(d->mtl_device, &info);
        if (!r->buffer) { free(r); return mad_creation_failure(d, "newBuffer"); }
        mad_resident(d, r->buffer);
        r->cpu = info.memory.ptr;      /* NULL for GPU-private, which is correct */
        r->gpu_address = info.gpu_address;
        mad_track(d, r);
        if (info.length >= (16u << 20)) {            /* ml885: big buffers, with where they live */
            static unsigned said_big;
            if (said_big++ < 40)
                d3d12_log("[madeira-d3d12] big buffer: %llu MB heap-type %u cpu=%p gpu=0x%llx flags 0x%x\n",
                          (unsigned long long)(info.length >> 20), (unsigned)heap_type, r->cpu,
                          (unsigned long long)r->gpu_address, (unsigned)desc->Flags);
        }
        if (heap_type != D3D12_HEAP_TYPE_DEFAULT && !r->cpu) {
            d3d12_log("[madeira-d3d12] CPU-visible buffer came back without a mapping\n");
            mad_untrack(d, r);
            NSObject_release(r->buffer);
            free(r);
            return E_FAIL;
        }
    }
    hr = res_QI((ID3D12Resource *)r, riid, out);
        if (FAILED(hr)) mad_refuse_log(desc, heap_type, "interface not answered");
    res_Release((ID3D12Resource *)r);
    return hr;
}

static HRESULT STDMETHODCALLTYPE device_CreateCommittedResource(ID3D12Device *This,
        const D3D12_HEAP_PROPERTIES *heap, D3D12_HEAP_FLAGS heap_flags,
        const D3D12_RESOURCE_DESC *desc, D3D12_RESOURCE_STATES state,
        const D3D12_CLEAR_VALUE *clear, REFIID riid, void **out) {
    (void)heap_flags; (void)state; (void)clear;
    HRESULT hr;
    static unsigned said;
    if (!heap || !desc || !out) { if (said++ < 8) d3d12_log("[madeira-d3d12] CreateCommittedResource: null props/desc/out\n"); return E_INVALIDARG; }
    hr = mad_create_resource((struct mad_device *)This, heap->Type, desc, riid, out);
    if (desc->Width >= (32u << 20) && desc->Dimension == D3D12_RESOURCE_DIMENSION_BUFFER && said++ < 64)
        d3d12_log("[madeira-d3d12] committed: %llu MB flags %#x heap-type %u -> hr %#lx\n",
                  (unsigned long long)(desc->Width >> 20), (unsigned)desc->Flags, (unsigned)heap->Type, (unsigned long)hr);
    return hr;
}

/* ---- heaps -----------------------------------------------------------------
 * A heap is a promise of memory the application will carve up itself. This
 * runtime keeps the description and nothing else; the resources placed in it
 * allocate on their own (see mad_create_resource). */
struct mad_memheap {
    ID3D12HeapVtbl *vtbl; LONG refs; const IID *iid; const char *name;
    struct mad_device *device;
    D3D12_HEAP_DESC desc;
};
static ID3D12HeapVtbl g_memheap_vtbl;
static HRESULT STDMETHODCALLTYPE memheap_QI(ID3D12Heap *This, REFIID riid, void **out) {
    struct mad_obj *o = (struct mad_obj *)This;
    if (!out) return E_POINTER;
    if (IsEqualGUID(riid, &IID_ID3D12Pageable)) { InterlockedIncrement(&o->refs); *out = This; return S_OK; }
    return mad_qi(o, riid, out, 1);
}
static ULONG STDMETHODCALLTYPE memheap_AddRef(ID3D12Heap *This) { return mad_addref((struct mad_obj *)This); }
static ULONG STDMETHODCALLTYPE memheap_Release(ID3D12Heap *This) {
    struct mad_obj *o = (struct mad_obj *)This;
    LONG n = InterlockedDecrement(&o->refs);
    if (n == 0) {
        struct mad_memheap *h = (struct mad_memheap *)This;
        static unsigned said;
        if (h->desc.Alignment == 4194304 && (h->desc.Flags & 0x1000) && said++ < 200)
            d3d12_log("[transient] list#%u heap %p DESTROYED (%llu KB)\n", g_list_seq, (void *)h,
                      (unsigned long long)h->desc.SizeInBytes >> 10);   /* ml895 */
        free(o);
    }
    return (ULONG)n;
}
static HRESULT STDMETHODCALLTYPE memheap_GetPrivateData(ID3D12Heap *This, REFGUID g, UINT *n, void *d) {
    (void)This; (void)g; (void)d; if (n) *n = 0; return DXGI_ERROR_NOT_FOUND;
}
static HRESULT STDMETHODCALLTYPE memheap_SetPrivateData(ID3D12Heap *This, REFGUID g, UINT n, const void *d) {
    (void)This; (void)g; (void)n; (void)d; return S_OK;
}
static HRESULT STDMETHODCALLTYPE memheap_SetPrivateDataInterface(ID3D12Heap *This, REFGUID g, const IUnknown *d) {
    (void)This; (void)g; (void)d; return S_OK;
}
static HRESULT STDMETHODCALLTYPE memheap_SetName(ID3D12Heap *This, LPCWSTR name) { (void)This; (void)name; return S_OK; }
static HRESULT STDMETHODCALLTYPE memheap_GetDevice(ID3D12Heap *This, REFIID riid, void **out) {
    struct mad_memheap *h = (struct mad_memheap *)This;
    return h->device->vtbl->QueryInterface((ID3D12Device10 *)h->device, riid, out);
}
static D3D12_HEAP_DESC * STDMETHODCALLTYPE memheap_GetDesc(ID3D12Heap *This, D3D12_HEAP_DESC *ret) {
    *ret = ((struct mad_memheap *)This)->desc;
    return ret;
}

static HRESULT STDMETHODCALLTYPE device_CreateHeap(ID3D12Device *This, const D3D12_HEAP_DESC *desc,
                                                   REFIID riid, void **out) {
    struct mad_memheap *h;
    HRESULT hr;
    static unsigned said;
    if (!desc || !out) return E_INVALIDARG;
    *out = NULL;
    h = calloc(1, sizeof *h);
    if (!h) return E_OUTOFMEMORY;
    h->vtbl = &g_memheap_vtbl; h->refs = 1; h->iid = &IID_ID3D12Heap; h->name = "Heap";
    h->device = (struct mad_device *)This;
    h->desc = *desc;
    if (said < 4096) {   /* ml891: every heap, with its alignment -- the transient allocator lives here */
        said++;
        d3d12_log("[madeira-d3d12] heap: %llu KB, type %u, flags %#x, align %llu -> %p\n",
                  (unsigned long long)(desc->SizeInBytes / 1024), (unsigned)desc->Properties.Type, (unsigned)desc->Flags,
                  (unsigned long long)desc->Alignment, (void *)h);
    }
    hr = memheap_QI((ID3D12Heap *)h, riid, out);
    memheap_Release((ID3D12Heap *)h);
    return hr;
}

static HRESULT STDMETHODCALLTYPE device_CreatePlacedResource(ID3D12Device *This, ID3D12Heap *heap,
        UINT64 offset, const D3D12_RESOURCE_DESC *desc, D3D12_RESOURCE_STATES state,
        const D3D12_CLEAR_VALUE *clear, REFIID riid, void **out) {
    struct mad_memheap *h = (struct mad_memheap *)heap;
    HRESULT hr;
    static unsigned said;
    (void)state; (void)clear;
    if (!h || !desc || !out) { if (said++ < 8) d3d12_log("[madeira-d3d12] CreatePlacedResource: null heap/desc/out\n"); return E_INVALIDARG; }
    hr = mad_create_resource((struct mad_device *)This, h->desc.Properties.Type, desc, riid, out);
    /* ml895: every placement inside a TRANSIENT heap (4 MB aligned, NOT_ZEROED)
     * with the list sequence, so a heap's occupancy can be replayed offline.
     * The RenderThread fault behind every menu crash is UE's transient
     * allocator handing RDG a NULL buffer: its heap cache returned a heap
     * that could not fit the request instead of creating a third heap. */
    if (h->desc.Alignment == 4194304 && (h->desc.Flags & 0x1000)) {
        static unsigned tsaid;
        if (tsaid++ < 3000)
            d3d12_log("[transient] list#%u heap %p +%llu size %llu KB dim %u flags %#x -> hr %#lx\n",
                      g_list_seq, (void *)h, (unsigned long long)offset,
                      (unsigned long long)(desc->Dimension == D3D12_RESOURCE_DIMENSION_BUFFER ? desc->Width : 0) >> 10,
                      (unsigned)desc->Dimension, (unsigned)desc->Flags, (unsigned long)hr);
    }
    if (desc->Width >= (32u << 20) && said++ < 64)
        d3d12_log("[madeira-d3d12] placed: %llu MB dim %u flags %#x in heap %p (%llu KB, flags %#x) at offset %llu -> hr %#lx\n",
                  (unsigned long long)(desc->Width >> 20), (unsigned)desc->Dimension, (unsigned)desc->Flags, (void *)h,
                  (unsigned long long)(h->desc.SizeInBytes / 1024), (unsigned)h->desc.Flags, (unsigned long long)offset, (unsigned long)hr);
    return hr;
}



/* ---- root signature, pipeline state, descriptor heap --------------------- */
static ID3D12RootSignatureVtbl g_rootsig_vtbl;
static ID3D12PipelineStateVtbl g_pso_vtbl;
static ID3D12DescriptorHeapVtbl g_heap_vtbl;


static HRESULT STDMETHODCALLTYPE rootsig_QI(ID3D12RootSignature *T, REFIID r, void **o) { return mad_qi((struct mad_obj *)T, r, o, 1); }
static ULONG STDMETHODCALLTYPE rootsig_AddRef(ID3D12RootSignature *T) { return mad_addref((struct mad_obj *)T); }
static ULONG STDMETHODCALLTYPE rootsig_Release(ID3D12RootSignature *T) { return mad_release((struct mad_obj *)T); }

static HRESULT STDMETHODCALLTYPE heap_QI(ID3D12DescriptorHeap *T, REFIID r, void **o) { return mad_qi((struct mad_obj *)T, r, o, 1); }
static ULONG STDMETHODCALLTYPE heap_AddRef(ID3D12DescriptorHeap *T) { return mad_addref((struct mad_obj *)T); }
static ULONG STDMETHODCALLTYPE heap_Release(ID3D12DescriptorHeap *T) {
    struct mad_heap *h = (struct mad_heap *)T;
    LONG r = InterlockedDecrement(&h->refs);
    if (r == 0) {
        /* The Metal buffer of a shader-visible heap is deliberately kept: a
         * command buffer already submitted may still read it. CPU-only
         * storage has no such reader. */
        free(h->slots);
        if (!h->buffer) free(h->cpu);
        free(h);
    }
    return (ULONG)r;
}
/* The header returns this struct through a hidden out-pointer on this ABI, so
 * the slot signature is not the one the method appears to have. Matching the
 * header exactly is the whole reason the vtables are generated from it. */
static D3D12_DESCRIPTOR_HEAP_DESC * STDMETHODCALLTYPE heap_GetDesc(ID3D12DescriptorHeap *T, D3D12_DESCRIPTOR_HEAP_DESC *ret) {
    *ret = ((struct mad_heap *)T)->desc;
    return ret;
}

/* Unified memory: every heap type lives in the one pool, and the CPU page
 * property is the one the standard heap of that type implies. */
static D3D12_HEAP_PROPERTIES * STDMETHODCALLTYPE device_GetCustomHeapProperties(ID3D12Device *This,
        D3D12_HEAP_PROPERTIES *ret, UINT node_mask, D3D12_HEAP_TYPE type) {
    (void)This; (void)node_mask;
    memset(ret, 0, sizeof *ret);
    ret->Type = D3D12_HEAP_TYPE_CUSTOM;
    ret->MemoryPoolPreference = D3D12_MEMORY_POOL_L0;
    ret->CPUPageProperty = (type == D3D12_HEAP_TYPE_UPLOAD)   ? D3D12_CPU_PAGE_PROPERTY_WRITE_COMBINE
                         : (type == D3D12_HEAP_TYPE_READBACK) ? D3D12_CPU_PAGE_PROPERTY_WRITE_BACK
                         : D3D12_CPU_PAGE_PROPERTY_NOT_AVAILABLE;
    ret->CreationNodeMask = 1; ret->VisibleNodeMask = 1;
    return ret;
}

static D3D12_CPU_DESCRIPTOR_HANDLE * STDMETHODCALLTYPE
heap_GetCPUDescriptorHandleForHeapStart(ID3D12DescriptorHeap *T, D3D12_CPU_DESCRIPTOR_HANDLE *out) {
    /* The address of slot zero, so an application that computes
     * `start + index * increment` lands on the slot it meant. Both kinds of
     * heap answer in their own storage: RTV and DSV heaps in an array of
     * resource pointers that never reaches the GPU, shader-visible heaps in the
     * Metal buffer the shader reads.
     *
     * This is still not a GPU address and is never dereferenced as one. The GPU
     * handle below is the separate namespace, and only shader-visible heaps
     * have one at all. */
    struct mad_heap *h = (struct mad_heap *)T;
    if (out) out->ptr = h->cpu ? (SIZE_T)h->cpu : (SIZE_T)h->slots;
    return out;
}

static D3D12_GPU_DESCRIPTOR_HANDLE * STDMETHODCALLTYPE
heap_GetGPUDescriptorHandleForHeapStart(ID3D12DescriptorHeap *T, D3D12_GPU_DESCRIPTOR_HANDLE *out) {
    /* Measured, not assumed: a descriptor table root argument is the ABSOLUTE
     * GPU address of its first descriptor. A byte offset and a descriptor index
     * were both tried on a real device and rendered nothing
     * (tests/native/table_abi_probe.mm). Returning the heap's base address here
     * means the application's own handle arithmetic produces exactly that. */
    struct mad_heap *h = (struct mad_heap *)T;
    if (out) out->ptr = h->gpu_address;
    return out;
}

static ULONG STDMETHODCALLTYPE pso_AddRef(ID3D12PipelineState *T) { return mad_addref((struct mad_obj *)T); }
static HRESULT STDMETHODCALLTYPE pso_QI(ID3D12PipelineState *T, REFIID r, void **o) { return mad_qi((struct mad_obj *)T, r, o, 1); }
static ULONG STDMETHODCALLTYPE pso_Release(ID3D12PipelineState *T) {
    struct mad_pso *p = (struct mad_pso *)T;
    LONG n = InterlockedDecrement(&p->refs);
    if (n == 0) {
        if (p->rps) NSObject_release(p->rps);
        { unsigned k; for (k = 0; k < p->nvar; k++) if (p->var[k].rps) NSObject_release(p->var[k].rps); }
        if (p->has_vd) DeleteCriticalSection(&p->var_lock);
        if (p->vs_fn) NSObject_release(p->vs_fn);
        if (p->ps_fn) NSObject_release(p->ps_fn);
        if (p->vs_lib) NSObject_release(p->vs_lib);
        if (p->ps_lib) NSObject_release(p->ps_lib);
        if (p->si_lib) NSObject_release(p->si_lib);   /* ml927 */
        if (p->gs_lib) NSObject_release(p->gs_lib);
        if (p->dsso) NSObject_release(p->dsso);
        if (p->cps) NSObject_release(p->cps);
        free(p);
    }
    return (ULONG)n;
}

/* ---- serialized root signatures -------------------------------------------
 *
 * The real D3D12 container, not a private encoding: a DXBC wrapper around an
 * RTS0 chunk. Games ship precompiled root signatures in exactly this form, so
 * a runtime that only understood something we invented would stop working the
 * moment it met real content. The layout below was read from a working
 * implementation (wine's vkd3d) rather than recalled.
 *
 *   DXBC header : "DXBC", 16-byte digest, u32 version, u32 total size,
 *                 u32 chunk count, u32 chunk offsets[count]
 *   chunk       : "RTS0", u32 size, payload
 *   payload     : u32 version, u32 param count, u32 param offset,
 *                 u32 sampler count, u32 sampler offset, u32 flags
 *   parameter   : u32 type, u32 visibility, u32 payload offset
 *   constants   : u32 shader register, u32 register space, u32 count
 *   descriptor  : u32 shader register, u32 register space, u32 flags   (1.1)
 *   table       : u32 range count, u32 range offset
 *   range       : u32 type, u32 count, u32 base register, u32 space,
 *                 u32 flags, u32 table offset                          (1.1)
 *
 * Every offset is relative to the start of the chunk payload. */
static UINT32 rs_rd(const unsigned char *b, SIZE_T n, SIZE_T off, int *bad) {
    if (off + 4 > n) { *bad = 1; return 0; }
    return (UINT32)b[off] | ((UINT32)b[off+1] << 8) |
           ((UINT32)b[off+2] << 16) | ((UINT32)b[off+3] << 24);
}
static void rs_wr(unsigned char *b, SIZE_T off, UINT32 v) {
    b[off] = (unsigned char)(v); b[off+1] = (unsigned char)(v >> 8);
    b[off+2] = (unsigned char)(v >> 16); b[off+3] = (unsigned char)(v >> 24);
}

static UINT32 rs_vis(D3D12_SHADER_VISIBILITY v) {
    switch (v) {
    case D3D12_SHADER_VISIBILITY_VERTEX:   return MADEIRA_IR_VIS_VERTEX;
    case D3D12_SHADER_VISIBILITY_HULL:     return MADEIRA_IR_VIS_HULL;
    case D3D12_SHADER_VISIBILITY_DOMAIN:   return MADEIRA_IR_VIS_DOMAIN;
    case D3D12_SHADER_VISIBILITY_GEOMETRY: return MADEIRA_IR_VIS_GEOMETRY;
    case D3D12_SHADER_VISIBILITY_PIXEL:    return MADEIRA_IR_VIS_PIXEL;
    default:                               return MADEIRA_IR_VIS_ALL;
    }
}

/* Find the RTS0 chunk. Returns its payload, or NULL with a named reason. */
static const unsigned char *rs_find_chunk(const unsigned char *b, SIZE_T n,
                                          SIZE_T *out_n, const char **why) {
    int bad = 0;
    if (n < 32 || memcmp(b, "DXBC", 4) != 0) { *why = "not a DXBC container"; return NULL; }
    UINT32 nchunk = rs_rd(b, n, 28, &bad);
    if (bad || nchunk == 0 || nchunk > 32) { *why = "implausible chunk count"; return NULL; }
    for (UINT32 i = 0; i < nchunk; i++) {
        UINT32 off = rs_rd(b, n, 32 + 4 * i, &bad);
        if (bad || (SIZE_T)off + 8 > n) { *why = "chunk offset out of range"; return NULL; }
        UINT32 sz = rs_rd(b, n, off + 4, &bad);
        if (bad || (SIZE_T)off + 8 + sz > n) { *why = "chunk size out of range"; return NULL; }
        if (memcmp(b + off, "RTS0", 4) == 0) { *out_n = sz; return b + off + 8; }
    }
    *why = "no RTS0 chunk";
    return NULL;
}

static HRESULT STDMETHODCALLTYPE device_CreateRootSignature(ID3D12Device *This, UINT node,
        const void *blob, SIZE_T blob_len, REFIID riid, void **out) {
    (void)This; (void)node;
    if (!out || !blob) return E_INVALIDARG;

    SIZE_T n = 0;
    const char *why = "?";
    const unsigned char *p = rs_find_chunk((const unsigned char *)blob, blob_len, &n, &why);
    if (!p) {
        d3d12_log("[madeira-d3d12] CreateRootSignature: %s -- refusing rather than assuming a layout\n", why);
        return E_INVALIDARG;
    }

    int bad = 0;
    UINT32 version   = rs_rd(p, n, 0,  &bad);
    UINT32 nparam    = rs_rd(p, n, 4,  &bad);
    UINT32 poff      = rs_rd(p, n, 8,  &bad);
    UINT32 nsampler  = rs_rd(p, n, 12, &bad);
    if (bad) { d3d12_log("[madeira-d3d12] CreateRootSignature: truncated RTS0 header\n"); return E_INVALIDARG; }
    if (version != 1 && version != 2) {
        d3d12_log("[madeira-d3d12] CreateRootSignature: root signature version %u is not supported\n", version);
        return E_NOTIMPL;
    }
    UINT32 soff = rs_rd(p, n, 16, &bad);
    if (nsampler > 32) {
        d3d12_log("[madeira-d3d12] CreateRootSignature: %u static samplers exceeds the 32 this build handles\n", nsampler);
        return E_NOTIMPL;
    }
    if (nparam > MAD_ROOT_PARAM_MAX) {
        d3d12_log("[madeira-d3d12] CreateRootSignature: %u parameters exceeds the %u this build handles\n",
                  nparam, (unsigned)MAD_ROOT_PARAM_MAX);
        return E_NOTIMPL;
    }

    struct mad_rootsig *r = calloc(1, sizeof *r);
    if (!r) return E_OUTOFMEMORY;
    r->vtbl = &g_rootsig_vtbl; r->refs = 1; r->iid = &IID_ID3D12RootSignature; r->name = "RootSignature";
    r->nparams = nparam;
    /* Static samplers: 13 dwords each, the D3D12 description verbatim, the
     * same in root signature versions 1.0 and 1.1 (1.2 adds a flags word and
     * is refused above by version). */
    r->nsamplers = nsampler;
    r->stab = 0; r->stab_gpu = 0;
    for (UINT32 i = 0; i < nsampler; i++) {
        struct madeira_ir_static_sampler *ss = &r->samplers[i];
        UINT32 at = soff + 52 * i, w[13], k;
        for (k = 0; k < 13; k++) w[k] = rs_rd(p, n, at + 4 * k, &bad);
        if (bad) goto truncated;
        ss->filter = w[0]; ss->address_u = w[1]; ss->address_v = w[2]; ss->address_w = w[3];
        memcpy(&ss->mip_lod_bias, &w[4], 4);
        ss->max_anisotropy = w[5]; ss->comparison = w[6]; ss->border_color = w[7];
        memcpy(&ss->min_lod, &w[8], 4); memcpy(&ss->max_lod, &w[9], 4);
        ss->shader_register = w[10]; ss->register_space = w[11];
        ss->visibility = w[12] == 1 ? MADEIRA_IR_VIS_VERTEX : w[12] == 2 ? MADEIRA_IR_VIS_HULL : w[12] == 3 ? MADEIRA_IR_VIS_DOMAIN
                       : w[12] == 4 ? MADEIRA_IR_VIS_GEOMETRY : w[12] == 5 ? MADEIRA_IR_VIS_PIXEL : MADEIRA_IR_VIS_ALL;
    }

    if (nsampler) {   /* ml923: the sampler descriptors the converter's implicit table slot points at */
        struct mad_device *dd = (struct mad_device *)This;
        struct WMTBufferInfo bi; memset(&bi, 0, sizeof bi);
        bi.length = (uint64_t)nsampler * sizeof(struct mad_descriptor); bi.options = WMTResourceStorageModeShared;
        r->stab = MTLDevice_newBuffer(dd->mtl_device, &bi);
        if (r->stab && bi.memory.ptr) {
            struct mad_descriptor *tab = (struct mad_descriptor *)bi.memory.ptr; UINT32 i, ok = 0;
            memset(tab, 0, bi.length);
            for (i = 0; i < nsampler; i++) {
                struct madeira_ir_static_sampler *ss = &r->samplers[i]; struct WMTSamplerInfo si; obj_handle_t smp; UINT32 bias_bits;
                mad_sampler_info(&si, ss->filter, ss->address_u, ss->address_v, ss->address_w, ss->max_anisotropy, ss->comparison, ss->border_color, ss->min_lod, ss->max_lod);
                smp = MTLDevice_newSamplerState(dd->mtl_device, &si);
                if (!smp || !si.gpu_resource_id) continue;
                memcpy(&bias_bits, &ss->mip_lod_bias, 4);
                tab[i].gpu_va = si.gpu_resource_id; tab[i].texture_view_id = 0; tab[i].metadata = (UINT64)bias_bits;
                mad_note_sampler(dd, smp); ok++;
            }
            mad_resident(dd, r->stab);
            r->stab_gpu = bi.gpu_address;
            { static unsigned said; if (said++ < 4) d3d12_log("[madeira-d3d12] static sampler table: %u/%u samplers at %llx\n", ok, nsampler, (unsigned long long)r->stab_gpu); }
        } else { if (r->stab) { NSObject_release(r->stab); r->stab = 0; } d3d12_log("[madeira-d3d12] static sampler table: buffer creation failed\n"); }
    }

    for (UINT32 i = 0; i < nparam; i++) {
        UINT32 type = rs_rd(p, n, poff + 12 * i,     &bad);
        UINT32 vis  = rs_rd(p, n, poff + 12 * i + 4, &bad);
        UINT32 off  = rs_rd(p, n, poff + 12 * i + 8, &bad);
        if (bad) goto truncated;
        r->params[i].visibility = rs_vis((D3D12_SHADER_VISIBILITY)vis);
        switch (type) {
        case D3D12_ROOT_PARAMETER_TYPE_32BIT_CONSTANTS:
            r->params[i].type = MADEIRA_IR_PARAM_CONSTANTS;
            r->params[i].shader_register = rs_rd(p, n, off,     &bad);
            r->params[i].register_space  = rs_rd(p, n, off + 4, &bad);
            r->params[i].num_constants   = rs_rd(p, n, off + 8, &bad);
            break;
        case D3D12_ROOT_PARAMETER_TYPE_CBV:
        case D3D12_ROOT_PARAMETER_TYPE_SRV:
        case D3D12_ROOT_PARAMETER_TYPE_UAV:
            r->params[i].type = type == D3D12_ROOT_PARAMETER_TYPE_CBV ? MADEIRA_IR_PARAM_CBV
                              : type == D3D12_ROOT_PARAMETER_TYPE_SRV ? MADEIRA_IR_PARAM_SRV
                                                                      : MADEIRA_IR_PARAM_UAV;
            r->params[i].shader_register = rs_rd(p, n, off,     &bad);
            r->params[i].register_space  = rs_rd(p, n, off + 4, &bad);
            break;
        case D3D12_ROOT_PARAMETER_TYPE_DESCRIPTOR_TABLE: {
            UINT32 nr   = rs_rd(p, n, off,     &bad);
            UINT32 roff = rs_rd(p, n, off + 4, &bad);
            if (bad) goto truncated;
            if (r->nranges + nr > MAD_ROOT_RANGE_MAX) {
                d3d12_log("[madeira-d3d12] CreateRootSignature: more descriptor ranges than this build handles\n");
                rootsig_Release((ID3D12RootSignature *)r);
                return E_NOTIMPL;
            }
            r->params[i].type = MADEIRA_IR_PARAM_TABLE;
            r->params[i].first_range = r->nranges;
            r->params[i].num_ranges = nr;
            /* 1.0 ranges have five words, 1.1 adds a flags word before the
             * table offset. Reading a 1.0 blob with the 1.1 stride would shift
             * every later range, so the stride follows the declared version. */
            UINT32 stride = (version == 2) ? 24 : 20;
            for (UINT32 j = 0; j < nr; j++) {
                struct madeira_ir_root_range *rg = &r->ranges[r->nranges + j];
                SIZE_T b0 = roff + (SIZE_T)stride * j;
                UINT32 rt = rs_rd(p, n, b0,      &bad);
                rg->num_descriptors = rs_rd(p, n, b0 + 4,  &bad);
                rg->base_register   = rs_rd(p, n, b0 + 8,  &bad);
                rg->register_space  = rs_rd(p, n, b0 + 12, &bad);
                rg->table_offset    = rs_rd(p, n, b0 + (stride == 24 ? 20 : 16), &bad);
                switch (rt) {
                case D3D12_DESCRIPTOR_RANGE_TYPE_SRV:     rg->range_type = MADEIRA_IR_RANGE_SRV; break;
                case D3D12_DESCRIPTOR_RANGE_TYPE_UAV:     rg->range_type = MADEIRA_IR_RANGE_UAV; break;
                case D3D12_DESCRIPTOR_RANGE_TYPE_CBV:     rg->range_type = MADEIRA_IR_RANGE_CBV; break;
                case D3D12_DESCRIPTOR_RANGE_TYPE_SAMPLER: rg->range_type = MADEIRA_IR_RANGE_SAMPLER; break;
                default:
                    d3d12_log("[madeira-d3d12] CreateRootSignature: unknown descriptor range type %u\n", rt);
                    rootsig_Release((ID3D12RootSignature *)r);
                    return E_INVALIDARG;
                }
            }
            r->nranges += nr;
            break;
        }
        default:
            d3d12_log("[madeira-d3d12] CreateRootSignature: root parameter type %u is not supported\n", type);
            rootsig_Release((ID3D12RootSignature *)r);
            return E_NOTIMPL;
        }
        if (bad) goto truncated;
    }

    d3d12_log("[madeira-d3d12] root signature parsed from the application blob: "
              "version 1.%u, %u parameter(s), %u descriptor range(s), %u static sampler(s)\n",
              version == 2 ? 1u : 0u, r->nparams, r->nranges, r->nsamplers);
    HRESULT hr = rootsig_QI((ID3D12RootSignature *)r, riid, out);
    rootsig_Release((ID3D12RootSignature *)r);
    return hr;

truncated:
    d3d12_log("[madeira-d3d12] CreateRootSignature: RTS0 chunk is truncated\n");
    rootsig_Release((ID3D12RootSignature *)r);
    return E_INVALIDARG;
}

/* Emits the same container the parser above reads, so a test can build a real
 * root signature instead of the runtime accepting a private shortcut. The DXBC
 * digest is left zero: nothing in this path verifies it, and writing a
 * plausible-looking but wrong checksum would be worse than an obvious zero. */
__declspec(dllexport) HRESULT WINAPI MadeiraD3D12SerializeRootSignature(
        const D3D12_ROOT_SIGNATURE_DESC1 *desc, unsigned char *out, SIZE_T *io_len) {
    if (!desc || !io_len) return E_INVALIDARG;
    if (desc->NumStaticSamplers && !desc->pStaticSamplers) return E_INVALIDARG;

    UINT32 nparam = desc->NumParameters;
    UINT32 nrange = 0;
    for (UINT32 i = 0; i < nparam; i++)
        if (desc->pParameters[i].ParameterType == D3D12_ROOT_PARAMETER_TYPE_DESCRIPTOR_TABLE)
            nrange += desc->pParameters[i].DescriptorTable.NumDescriptorRanges;

    /* payload = header(24) + params(12 each) + per-param payload + ranges(24 each) */
    UINT32 payload_params = 12 * nparam;
    UINT32 payload_bodies = 0;
    for (UINT32 i = 0; i < nparam; i++)
        payload_bodies += (desc->pParameters[i].ParameterType == D3D12_ROOT_PARAMETER_TYPE_DESCRIPTOR_TABLE) ? 8 : 12;
    UINT32 sampler_at = 24 + payload_params + payload_bodies + 24 * nrange;
    UINT32 chunk = sampler_at + 52 * desc->NumStaticSamplers;
    UINT32 total = 32 + 4 /*one chunk offset*/ + 8 + chunk;

    if (!out || *io_len < total) { *io_len = total; return out ? E_NOT_SUFFICIENT_BUFFER : S_OK; }
    memset(out, 0, total);
    memcpy(out, "DXBC", 4);
    rs_wr(out, 20, 1);          /* container version */
    rs_wr(out, 24, total);
    rs_wr(out, 28, 1);          /* chunk count */
    rs_wr(out, 32, 36);         /* offset of the one chunk */
    memcpy(out + 36, "RTS0", 4);
    rs_wr(out, 40, chunk);

    unsigned char *p = out + 44;   /* chunk payload; offsets are relative here */
    rs_wr(p, 0, 2);                /* root signature version 1.1 */
    rs_wr(p, 4, nparam);
    rs_wr(p, 8, 24);               /* parameters follow the header */
    rs_wr(p, 12, desc->NumStaticSamplers);
    /* With no samplers the offset still points past the end of the parameter
     * tables, which is what the reference compiler emits (verified against a
     * dxc blob: byte-identical apart from the digest left zero). */
    rs_wr(p, 16, sampler_at);
    for (UINT32 i = 0; i < desc->NumStaticSamplers; i++) {
        /* The D3D12 description is thirteen 32-bit words in declaration order. */
        memcpy(p + sampler_at + 52 * i, &desc->pStaticSamplers[i], 52);
    }
    rs_wr(p, 20, (UINT32)desc->Flags);

    UINT32 body = 24 + payload_params;
    UINT32 range_at = 24 + payload_params + payload_bodies;
    for (UINT32 i = 0; i < nparam; i++) {
        const D3D12_ROOT_PARAMETER1 *rp = &desc->pParameters[i];
        rs_wr(p, 24 + 12 * i,     (UINT32)rp->ParameterType);
        rs_wr(p, 24 + 12 * i + 4, (UINT32)rp->ShaderVisibility);
        rs_wr(p, 24 + 12 * i + 8, body);
        if (rp->ParameterType == D3D12_ROOT_PARAMETER_TYPE_32BIT_CONSTANTS) {
            rs_wr(p, body,     rp->Constants.ShaderRegister);
            rs_wr(p, body + 4, rp->Constants.RegisterSpace);
            rs_wr(p, body + 8, rp->Constants.Num32BitValues);
            body += 12;
        } else if (rp->ParameterType == D3D12_ROOT_PARAMETER_TYPE_DESCRIPTOR_TABLE) {
            rs_wr(p, body,     rp->DescriptorTable.NumDescriptorRanges);
            rs_wr(p, body + 4, range_at);
            for (UINT32 j = 0; j < rp->DescriptorTable.NumDescriptorRanges; j++) {
                const D3D12_DESCRIPTOR_RANGE1 *dr = &rp->DescriptorTable.pDescriptorRanges[j];
                rs_wr(p, range_at,      (UINT32)dr->RangeType);
                rs_wr(p, range_at + 4,  dr->NumDescriptors);
                rs_wr(p, range_at + 8,  dr->BaseShaderRegister);
                rs_wr(p, range_at + 12, dr->RegisterSpace);
                rs_wr(p, range_at + 16, (UINT32)dr->Flags);
                rs_wr(p, range_at + 20, dr->OffsetInDescriptorsFromTableStart);
                range_at += 24;
            }
            body += 8;
        } else {
            rs_wr(p, body,     rp->Descriptor.ShaderRegister);
            rs_wr(p, body + 4, rp->Descriptor.RegisterSpace);
            rs_wr(p, body + 8, (UINT32)rp->Descriptor.Flags);
            body += 12;
        }
    }
    *io_len = total;
    return S_OK;
}

static HRESULT STDMETHODCALLTYPE device_CreateDescriptorHeap(ID3D12Device *This,
        const D3D12_DESCRIPTOR_HEAP_DESC *desc, REFIID riid, void **out) {
    if (!desc || !out) return E_INVALIDARG;
    struct mad_device *d = (struct mad_device *)This;
    int shader_visible = (desc->Type == D3D12_DESCRIPTOR_HEAP_TYPE_CBV_SRV_UAV ||
                          desc->Type == D3D12_DESCRIPTOR_HEAP_TYPE_SAMPLER);
    if (!shader_visible &&
        desc->Type != D3D12_DESCRIPTOR_HEAP_TYPE_RTV &&
        desc->Type != D3D12_DESCRIPTOR_HEAP_TYPE_DSV) {
        d3d12_log("[madeira-d3d12] CreateDescriptorHeap: type %u is not supported\n", desc->Type);
        return E_NOTIMPL;
    }
    struct mad_heap *h = calloc(1, sizeof *h);
    if (!h) return E_OUTOFMEMORY;
    h->vtbl = &g_heap_vtbl; h->refs = 1; h->iid = &IID_ID3D12DescriptorHeap; h->name = "DescriptorHeap";
    h->type = desc->Type; h->count = desc->NumDescriptors; h->owner = d;
    h->desc = *desc;
    h->shader_visible = shader_visible && (desc->Flags & D3D12_DESCRIPTOR_HEAP_FLAG_SHADER_VISIBLE);
    {
        static unsigned said;
        if (said < 24) {
            said++;
            d3d12_log("[madeira-d3d12] descriptor heap: type %u, %u descriptors, %s\n",
                      (unsigned)desc->Type, desc->NumDescriptors, h->shader_visible ? "shader-visible" : "CPU only");
        }
    }
    if (!shader_visible) {
        h->slots = calloc(desc->NumDescriptors ? desc->NumDescriptors : 1, sizeof *h->slots);
        if (!h->slots) { free(h); return E_OUTOFMEMORY; }
    } else if (!h->shader_visible) {
        /* A staging heap: the application writes views here and copies them
         * into a shader-visible heap. Plain memory, same 24-byte entries. */
        h->cpu = calloc(desc->NumDescriptors ? desc->NumDescriptors : 1, sizeof *h->cpu);
        if (!h->cpu) { free(h); return E_OUTOFMEMORY; }
    } else {
        /* A shader-visible heap IS a Metal buffer: the shader indexes it
         * directly, and a descriptor table root argument is the address of one
         * of its entries. Shared storage so views can be written from the CPU
         * without a staging copy. */
        struct WMTBufferInfo bi;
        memset(&bi, 0, sizeof bi);
        bi.length = (uint64_t)sizeof(struct mad_descriptor) * (desc->NumDescriptors ? desc->NumDescriptors : 1);
        bi.options = WMTResourceStorageModeShared;
        h->buffer = MTLDevice_newBuffer(d->mtl_device, &bi);
        if (!h->buffer) { free(h); return mad_creation_failure(d, "descriptor heap buffer"); }
        h->cpu = (struct mad_descriptor *)bi.memory.ptr;
        h->gpu_address = bi.gpu_address;
        if (h->cpu) memset(h->cpu, 0, (size_t)bi.length);
    }
    HRESULT hr = heap_QI((ID3D12DescriptorHeap *)h, riid, out);
    heap_Release((ID3D12DescriptorHeap *)h);
    return hr;
}

static void STDMETHODCALLTYPE device_CreateDepthStencilView(ID3D12Device *This,
        ID3D12Resource *res, const D3D12_DEPTH_STENCIL_VIEW_DESC *desc,
        D3D12_CPU_DESCRIPTOR_HANDLE h) {
    struct mad_rtv *v = (struct mad_rtv *)h.ptr; struct mad_resource *r = (struct mad_resource *)res;
    static unsigned said;
    (void)This;
    if (!v) return;
    v->res = r; v->p.level = 0; v->p.slice = 0; v->p.plane = 0; v->p.layers = 1;
    if (!r) return;
    if (!desc) { mad_view_all(r, &v->p, 0, (UINT)-1, 0); }
    else switch (desc->ViewDimension) {   /* ml925 */
    case D3D12_DSV_DIMENSION_TEXTURE1D: v->p.level = (UINT16)desc->Texture1D.MipSlice; break;
    case D3D12_DSV_DIMENSION_TEXTURE2D: v->p.level = (UINT16)desc->Texture2D.MipSlice; break;
    case D3D12_DSV_DIMENSION_TEXTURE1DARRAY: v->p.level = (UINT16)desc->Texture1DArray.MipSlice; mad_view_all(r, &v->p, desc->Texture1DArray.FirstArraySlice, desc->Texture1DArray.ArraySize, 0); break;
    case D3D12_DSV_DIMENSION_TEXTURE2DARRAY: v->p.level = (UINT16)desc->Texture2DArray.MipSlice; mad_view_all(r, &v->p, desc->Texture2DArray.FirstArraySlice, desc->Texture2DArray.ArraySize, 0); break;
    case D3D12_DSV_DIMENSION_TEXTURE2DMSARRAY: mad_view_all(r, &v->p, desc->Texture2DMSArray.FirstArraySlice, desc->Texture2DMSArray.ArraySize, 0); break;
    default: break;
    }
    if (v->p.layers > 1 && said++ < 6)
        d3d12_log("[madeira-d3d12] layered DSV: %s %ux%u level %u first %u layers %u\n", r->name, r->width, r->height, v->p.level, v->p.slice, v->p.layers);
}

static void mad_view_all(struct mad_resource *r, struct mad_rtvp *p, UINT first, UINT count, int is3d) {
    UINT total = r ? (is3d ? (r->tex_depth >> p->level) : r->tex_layers) : 1;
    if (!total) total = 1;
    if (count == (UINT)-1 || first + count > total) count = total > first ? total - first : 1;
    if (!count) count = 1;
    if (is3d) p->plane = (UINT16)first; else p->slice = (UINT16)first;
    p->layers = (UINT16)count;
}
static void STDMETHODCALLTYPE device_CreateRenderTargetView(ID3D12Device *This,
        ID3D12Resource *res, const D3D12_RENDER_TARGET_VIEW_DESC *desc,
        D3D12_CPU_DESCRIPTOR_HANDLE h) {
    struct mad_rtv *v = (struct mad_rtv *)h.ptr; struct mad_resource *r = (struct mad_resource *)res;
    static unsigned said;
    (void)This;
    if (!v) return;
    v->res = r; v->p.level = 0; v->p.slice = 0; v->p.plane = 0; v->p.layers = 1;
    if (!r) return;
    if (!desc) { mad_view_all(r, &v->p, 0, (UINT)-1, r->tex_type == WMTTextureType3D); }
    else switch (desc->ViewDimension) {   /* ml925 */
    case D3D12_RTV_DIMENSION_TEXTURE1D: v->p.level = (UINT16)desc->Texture1D.MipSlice; break;
    case D3D12_RTV_DIMENSION_TEXTURE2D: v->p.level = (UINT16)desc->Texture2D.MipSlice; break;
    case D3D12_RTV_DIMENSION_TEXTURE1DARRAY: v->p.level = (UINT16)desc->Texture1DArray.MipSlice; mad_view_all(r, &v->p, desc->Texture1DArray.FirstArraySlice, desc->Texture1DArray.ArraySize, 0); break;
    case D3D12_RTV_DIMENSION_TEXTURE2DARRAY: v->p.level = (UINT16)desc->Texture2DArray.MipSlice; mad_view_all(r, &v->p, desc->Texture2DArray.FirstArraySlice, desc->Texture2DArray.ArraySize, 0); break;
    case D3D12_RTV_DIMENSION_TEXTURE2DMSARRAY: mad_view_all(r, &v->p, desc->Texture2DMSArray.FirstArraySlice, desc->Texture2DMSArray.ArraySize, 0); break;
    case D3D12_RTV_DIMENSION_TEXTURE3D: v->p.level = (UINT16)desc->Texture3D.MipSlice; mad_view_all(r, &v->p, desc->Texture3D.FirstWSlice, desc->Texture3D.WSize, 1); break;
    default: break;
    }
    if (v->p.layers > 1 && said++ < 6)
        d3d12_log("[madeira-d3d12] layered RTV: %s %ux%u t%u level %u first %u layers %u\n", r->name, r->width, r->height, (unsigned)r->tex_type,
                  v->p.level, r->tex_type == WMTTextureType3D ? v->p.plane : v->p.slice, v->p.layers);
}

static UINT STDMETHODCALLTYPE device_GetDescriptorHandleIncrementSize(ID3D12Device *This,
        D3D12_DESCRIPTOR_HEAP_TYPE type) {
    (void)This;
    return mad_descriptor_stride(type);
}

/* A texture descriptor. The encoding is the converter's
 * IRDescriptorTableSetTexture: the resource id in the second word, the min LOD
 * clamp in the low half of the third. */
static void STDMETHODCALLTYPE device_CreateShaderResourceView(ID3D12Device *This,
        ID3D12Resource *res, const D3D12_SHADER_RESOURCE_VIEW_DESC *desc,
        D3D12_CPU_DESCRIPTOR_HANDLE h) {
    struct mad_resource *r = (struct mad_resource *)res;
    struct mad_descriptor *e = (struct mad_descriptor *)h.ptr;
    if (!e) return;
    if (!r) { memset(e, 0, sizeof *e); return; }                                /* a null view */
    if (r->buffer) {
        UINT64 stride = 4, first = 0, num = r->size / 4;
        if (desc && desc->ViewDimension == D3D12_SRV_DIMENSION_BUFFER) {
            UINT bytes, block;
            first = desc->Buffer.FirstElement; num = desc->Buffer.NumElements;
            if (desc->Buffer.StructureByteStride) stride = desc->Buffer.StructureByteStride;
            else if (desc->Format != DXGI_FORMAT_UNKNOWN) {
                mad_format_info(desc->Format, &bytes, &block); stride = bytes;
                if (!(desc->Buffer.Flags & D3D12_BUFFER_SRV_FLAG_RAW) &&
                    mad_typed_buffer_view((struct mad_device *)This, r, desc->Format, first, num, 0, e)) return;   /* ml905 */
            }
        }
        mad_set_buffer_descriptor(e, r->gpu_address + first * stride, num * stride);
        return;
    }
    if (!r->texture) {
        static int said;
        if (!said++) d3d12_log("[madeira-d3d12] CreateShaderResourceView: resource has no backend object; descriptor left empty\n");
        memset(e, 0, sizeof *e);
        return;
    }
    float min_lod = 0.0f;
    UINT32 lod_bits;
    UINT64 view_id = r->gpu_resource_id;
    if (desc) {   /* ml913: honour the view dimension and sub-range */
        enum WMTTextureType want = r->tex_type; UINT lvl0 = 0, nlvl = ~0u, sl0 = 0, nsl = ~0u;
        switch (desc->ViewDimension) {
        case D3D12_SRV_DIMENSION_TEXTURE1D: want = WMTTextureType2DArray; lvl0 = desc->Texture1D.MostDetailedMip; nlvl = desc->Texture1D.MipLevels; nsl = 1; break;   /* ml932: arrays everywhere */
        case D3D12_SRV_DIMENSION_TEXTURE1DARRAY: want = WMTTextureType2DArray; lvl0 = desc->Texture1DArray.MostDetailedMip; nlvl = desc->Texture1DArray.MipLevels; sl0 = desc->Texture1DArray.FirstArraySlice; nsl = desc->Texture1DArray.ArraySize; break;
        case D3D12_SRV_DIMENSION_TEXTURE2D: want = WMTTextureType2DArray; lvl0 = desc->Texture2D.MostDetailedMip; nlvl = desc->Texture2D.MipLevels; nsl = 1; break;
        case D3D12_SRV_DIMENSION_TEXTURE2DARRAY: want = WMTTextureType2DArray; lvl0 = desc->Texture2DArray.MostDetailedMip; nlvl = desc->Texture2DArray.MipLevels; sl0 = desc->Texture2DArray.FirstArraySlice; nsl = desc->Texture2DArray.ArraySize; break;
        case D3D12_SRV_DIMENSION_TEXTURE2DMS: want = WMTTextureType2DMultisampleArray; nsl = 1; break;
        case D3D12_SRV_DIMENSION_TEXTURE2DMSARRAY: want = WMTTextureType2DMultisampleArray; sl0 = desc->Texture2DMSArray.FirstArraySlice; nsl = desc->Texture2DMSArray.ArraySize; break;
        case D3D12_SRV_DIMENSION_TEXTURE3D: want = WMTTextureType3D; lvl0 = desc->Texture3D.MostDetailedMip; nlvl = desc->Texture3D.MipLevels; break;
        case D3D12_SRV_DIMENSION_TEXTURECUBE: want = WMTTextureTypeCubeArray; lvl0 = desc->TextureCube.MostDetailedMip; nlvl = desc->TextureCube.MipLevels; nsl = 6; break;
        case D3D12_SRV_DIMENSION_TEXTURECUBEARRAY: want = WMTTextureTypeCubeArray; lvl0 = desc->TextureCubeArray.MostDetailedMip; nlvl = desc->TextureCubeArray.MipLevels; sl0 = desc->TextureCubeArray.First2DArrayFace; nsl = desc->TextureCubeArray.NumCubes * 6; break;
        default: break;
        }
        if (r->tex_type == WMTTextureType2DMultisample || r->tex_type == WMTTextureType2DMultisampleArray) { lvl0 = 0; nlvl = 1; }
        {   /* ml918: the view's format (typeless -> typed, sRGB/linear) and Shader4ComponentMapping */
            enum WMTPixelFormat pf = 0; int vd = 0; UINT swz = 0, c, m = desc->Shader4ComponentMapping;
            if (desc->Format != DXGI_FORMAT_UNKNOWN && !r->is_depth && mad_map_texture_format(desc->Format, 0, &pf, &vd) && !vd && pf != r->tex_pf) { /* keep pf */ } else pf = 0;
            for (c = 0; c < 4; c++) {
                UINT sel = (m >> (3 * c)) & 7, v;   /* 0-3 = component, 4 = force 0, 5 = force 1 */
                v = sel <= 3 ? 2 + sel : sel == 4 ? 0 : 1;
                swz |= v << (8 * c);
            }
            view_id = mad_texture_view_id((struct mad_device *)This, r, want, lvl0, nlvl, sl0, nsl, pf, swz);
        }
        if (desc->ViewDimension == D3D12_SRV_DIMENSION_TEXTURE2D) min_lod = desc->Texture2D.ResourceMinLODClamp;
    }
    memcpy(&lod_bits, &min_lod, sizeof lod_bits);
    e->gpu_va = 0;
    e->texture_view_id = view_id;
    e->metadata = (UINT64)lod_bits;

    struct mad_device *dev = (struct mad_device *)This;
    for (unsigned i = 0; i < dev->nsrv; i++) if (dev->srv_res[i] == r) return;
    if (mad_grow((void **)&dev->srv_res, &dev->nsrv_cap, dev->nsrv + 1, sizeof *dev->srv_res))
        dev->srv_res[dev->nsrv++] = r;
}

/* ml923: the full D3D12 sampler description -> Metal. D3D12_FILTER packs
 * mip (bit 0), mag (bit 2), min (bit 4), anisotropic (0x40) and comparison
 * (0x80). The previous mapping had no mipmapping, clamp-only addressing and
 * never a comparison function, which breaks tiling, shadow PCF and LOD. */
static void mad_sampler_info(struct WMTSamplerInfo *si, UINT filter, UINT au, UINT av, UINT aw, UINT aniso, UINT cmp, UINT border, float minlod, float maxlod) {
    /* D3D12_TEXTURE_ADDRESS_MODE: 1 wrap, 2 mirror, 3 clamp, 4 border, 5 mirror-once */
    static const enum WMTSamplerAddressMode am[6] = { WMTSamplerAddressModeClampToEdge, WMTSamplerAddressModeRepeat, WMTSamplerAddressModeMirrorRepeat,
                                                      WMTSamplerAddressModeClampToEdge, WMTSamplerAddressModeClampToBorderColor, WMTSamplerAddressModeMirrorClampToEdge };
    memset(si, 0, sizeof *si);
    si->min_filter = (filter & 0x10) ? WMTSamplerMinMagFilterLinear : WMTSamplerMinMagFilterNearest;
    si->mag_filter = (filter & 0x04) ? WMTSamplerMinMagFilterLinear : WMTSamplerMinMagFilterNearest;
    si->mip_filter = (filter & 0x01) ? WMTSamplerMipFilterLinear : WMTSamplerMipFilterNearest;
    if (filter & 0x40) { si->min_filter = si->mag_filter = WMTSamplerMinMagFilterLinear; si->mip_filter = WMTSamplerMipFilterLinear; }
    si->r_address_mode = am[au < 6 ? au : 3]; si->s_address_mode = am[av < 6 ? av : 3]; si->t_address_mode = am[aw < 6 ? aw : 3];
    si->border_color = border == 2 ? WMTSamplerBorderColorOpaqueWhite : border == 1 ? WMTSamplerBorderColorOpaqueBlack : WMTSamplerBorderColorTransparentBlack;
    si->compare_function = (filter & 0x80) ? mad_compare((D3D12_COMPARISON_FUNC)cmp) : WMTCompareFunctionNever;
    si->lod_min_clamp = minlod; si->lod_max_clamp = maxlod > 1000.0f ? 1000.0f : maxlod;
    si->max_anisotroy = (filter & 0x40) ? (aniso ? aniso : 16) : 1;
    si->normalized_coords = true;
    si->support_argument_buffers = true;
}

static void STDMETHODCALLTYPE device_CreateSampler(ID3D12Device *This,
        const D3D12_SAMPLER_DESC *desc, D3D12_CPU_DESCRIPTOR_HANDLE h) {
    struct mad_device *d = (struct mad_device *)This;
    struct mad_descriptor *e = (struct mad_descriptor *)h.ptr;
    if (!e) return;

    struct WMTSamplerInfo si;
    if (desc) {
        UINT border = (desc->BorderColor[0] > 0.5f) ? 2u : (desc->BorderColor[3] > 0.5f) ? 1u : 0u;
        mad_sampler_info(&si, desc->Filter, desc->AddressU, desc->AddressV, desc->AddressW, desc->MaxAnisotropy, desc->ComparisonFunc, border, desc->MinLOD, desc->MaxLOD);
    } else mad_sampler_info(&si, D3D12_FILTER_MIN_MAG_MIP_LINEAR, 3, 3, 3, 1, 0, 0, 0.0f, 1000.0f);

    obj_handle_t smp = MTLDevice_newSamplerState(d->mtl_device, &si);
    if (!smp || !si.gpu_resource_id) {
        d3d12_log("[madeira-d3d12] CreateSampler: the backend gave no argument-buffer sampler\n");
        memset(e, 0, sizeof *e);
        return;
    }
    /* IRDescriptorTableSetSampler: resource id first, LOD bias in the metadata. */
    float bias = desc ? desc->MipLODBias : 0.0f;
    UINT32 bias_bits;
    memcpy(&bias_bits, &bias, sizeof bias_bits);
    e->gpu_va = si.gpu_resource_id;
    e->texture_view_id = 0;
    e->metadata = (UINT64)bias_bits;
    /* The sampler object itself is kept alive by the device for the process's
     * life. Samplers are few and immutable, and tying one to a descriptor slot
     * that the application may overwrite would need a lifetime story that this
     * milestone does not have. */
    mad_note_sampler(d, smp);
}

/* ---- pipeline state -------------------------------------------------------
 *
 * RUNTIME CONVERSION. The DXIL the application supplied is converted here, on
 * this machine, by Apple's Metal Shader Converter, using the root signature the
 * application actually created. No shader is embedded in this DLL and no
 * bytecode is recognised by hash.
 *
 * The previous build matched supplied DXIL against preconverted libraries and
 * refused anything else. That proved the plumbing but could never run a shader
 * it had not been built with, so removing it -- not passing another test with
 * it in place -- is what makes this a translation layer.
 *
 * Conversion runs on the guest even when rendering is remote, because it is a
 * byte transform that touches no Metal object. What must follow the rendering
 * backend is the TARGET, and that is chosen from the real device below. */

/* The converter's own family values, from its header. Written out rather than
 * included because this side must not depend on the converter's headers. */
/* Read from metal_irconverter.h, not inferred. The first version of this block
 * was off by two on every entry, so asking for Apple9 actually asked for
 * Apple7. Nothing failed: every wrong value was still a valid enum member, so
 * the build simply targeted a lower family than intended. */
#define MAD_IR_FAMILY_APPLE6  1006
#define MAD_IR_FAMILY_APPLE7  1007
#define MAD_IR_FAMILY_APPLE8  1008
#define MAD_IR_FAMILY_APPLE9  1009
#define MAD_IR_FAMILY_METAL3  5001

/* Read from winemetal.h's WMTGPUFamily. These are a DIFFERENT numbering from
 * the converter's above, which is exactly why both are written out here. */
#define MAD_MTL_FAMILY_APPLE7 1007
#define MAD_MTL_FAMILY_APPLE8 1008
#define MAD_MTL_FAMILY_APPLE9 1009
#define MAD_MTL_FAMILY_MAC2   2002

/* One conversion target, decided ONCE from the device that will actually run
 * the shaders, then reused. The previous build compiled for both platforms and
 * kept whichever library the backend happened to accept; that hid which target
 * was live and would silently pick the wrong one the moment both loaded. */
struct mad_target {
    int resolved;
    uint32_t os;          /* madeira_ir_os */
    uint32_t family;      /* IRGPUFamily */
    char os_version[16];
};
static struct mad_target g_target;

static void mad_resolve_target(struct mad_device *d) {
    if (g_target.resolved) return;

    /* Everything here returns a plain integer. The first version asked the
     * device for its NAME, which is the documented ownership trap: winemetal's
     * LOCAL implementation returns `[device name]`, an autoreleased string we
     * do not own, while the REMOTE one returns a freshly allocated +1 string.
     * Releasing it was correct remotely and an over-release locally, and it
     * killed the A15 at teardown when the autorelease pool popped and released
     * an object that had already gone. The remote backend never showed it.
     *
     * So the platform is decided by a capability instead. Mac2 is reported by
     * Apple silicon Macs and by no iPhone, supportsFamily is routed to the host
     * in remote mode, and it hands back a bool rather than an object. */
    int is_mac = MTLDevice_supportsFamily(d->mtl_device, MAD_MTL_FAMILY_MAC2);
    int apple9 = MTLDevice_supportsFamily(d->mtl_device, MAD_MTL_FAMILY_APPLE9);
    int apple8 = MTLDevice_supportsFamily(d->mtl_device, MAD_MTL_FAMILY_APPLE8);
    int apple7 = MTLDevice_supportsFamily(d->mtl_device, MAD_MTL_FAMILY_APPLE7);

    if (is_mac) {
        g_target.os = MADEIRA_IR_OS_MACOS;
        g_target.family = MAD_IR_FAMILY_METAL3;
        snprintf(g_target.os_version, sizeof g_target.os_version, "15.0");
    } else {
        g_target.os = MADEIRA_IR_OS_IOS;
        g_target.family = apple9 ? MAD_IR_FAMILY_APPLE9
                        : apple8 ? MAD_IR_FAMILY_APPLE8
                        : apple7 ? MAD_IR_FAMILY_APPLE7
                                 : MAD_IR_FAMILY_APPLE6;
        snprintf(g_target.os_version, sizeof g_target.os_version, "17.0");
    }
    g_target.resolved = 1;
    d3d12_log("[madeira-d3d12] conversion target: %s, family %u, min %s "
              "(device reports mac2=%d apple9=%d apple8=%d apple7=%d)\n",
              g_target.os == MADEIRA_IR_OS_MACOS ? "macOS" : "iOS",
              g_target.family, g_target.os_version, is_mac, apple9, apple8, apple7);
}

static const char *mad_ir_status_name(uint32_t st) {
    switch (st) {
    case MADEIRA_IR_OK:               return "ok";
    case MADEIRA_IR_NO_DYLIB:         return "the shader converter could not be loaded";
    case MADEIRA_IR_NO_SYMBOL:        return "the shader converter is missing an entry point";
    case MADEIRA_IR_BAD_DXIL:         return "the converter rejected the bytecode";
    case MADEIRA_IR_BAD_ROOTSIG:      return "the converter rejected the root signature";
    case MADEIRA_IR_COMPILE_FAILED:   return "compile/link failed";
    case MADEIRA_IR_NO_METALLIB:      return "compiled but produced no library";
    case MADEIRA_IR_BUFFER_TOO_SMALL: return "output buffer too small";
    case MADEIRA_IR_EMPTY_ENTRY:      return "no such entry point (reflection returned an empty name)";
    case MADEIRA_IR_UNSUPPORTED:      return "a root parameter this build does not model";
    case MADEIRA_IR_NO_MEMORY:        return "out of memory";
    default:                          return "unknown";
    }
}

/* Convert one stage and build its MTLFunction. The metallib buffer is sized by
 * asking first, so a shader larger than any fixed guess still works. */
#define MAD_LOC_MAX 64
/* ml927: what a geometry-shader pipeline needs from the converter beyond the
 * plain conversion: emulation mode, the input topology, the input layout the
 * stage-in function is synthesized from (vertex stage), and the numbers
 * reflection reports back. */
struct mad_convert_opts {
    int gs_emulation; UINT topology;
    const struct madeira_ir_input_layout *layout;
    obj_handle_t *lib2_out;            /* the stage-in library (vertex stage with a layout) */
    UINT *vs_output_size, *gs_max_prims;
    char *name_out; size_t name_cap;   /* the converter's entry name, per call (g_last_entry is a shared global and
                                        * the engine creates pipelines from several threads at once) */
};
static obj_handle_t mad_convert_stage_opts(struct mad_device *d, struct mad_rootsig *rs,
                                      const void *dxil, SIZE_T dxil_len, const char *entry,
                                      obj_handle_t *lib_out, const char *tag,
                                      struct madeira_ir_vs_input *vsin, unsigned vsin_cap, unsigned *vsin_n,
                                      UINT *tg_out, struct madeira_ir_loc *locs, unsigned *nlocs,
                                      const struct mad_convert_opts *o);
static obj_handle_t mad_convert_stage(struct mad_device *d, struct mad_rootsig *rs,
                                      const void *dxil, SIZE_T dxil_len, const char *entry,
                                      obj_handle_t *lib_out, const char *tag,
                                      struct madeira_ir_vs_input *vsin, unsigned vsin_cap, unsigned *vsin_n,
                                      UINT *tg_out, struct madeira_ir_loc *locs, unsigned *nlocs) {
    return mad_convert_stage_opts(d, rs, dxil, dxil_len, entry, lib_out, tag, vsin, vsin_cap, vsin_n, tg_out, locs, nlocs, NULL);
}
static obj_handle_t mad_convert_stage_opts(struct mad_device *d, struct mad_rootsig *rs,
                                      const void *dxil, SIZE_T dxil_len, const char *entry,
                                      obj_handle_t *lib_out, const char *tag,
                                      struct madeira_ir_vs_input *vsin, unsigned vsin_cap, unsigned *vsin_n,
                                      UINT *tg_out, struct madeira_ir_loc *locs, unsigned *nlocs,
                                      const struct mad_convert_opts *o) {
    struct madeira_ir_convert_args a;
    char name[MADEIRA_IR_ENTRY_MAX];
    unsigned char *buf2 = NULL; const SIZE_T cap2 = 256u * 1024u;
    memset(&a, 0, sizeof a);
    a.dxil = (uint64_t)(uintptr_t)dxil;
    a.dxil_len = (uint64_t)dxil_len;
    a.entry_point = (uint64_t)(uintptr_t)entry;
    a.params = (uint64_t)(uintptr_t)(rs ? rs->params : NULL);
    a.num_params = rs ? rs->nparams : 0;
    a.ranges = (uint64_t)(uintptr_t)(rs ? rs->ranges : NULL);
    a.num_ranges = rs ? rs->nranges : 0;
    a.target_os = g_target.os;
    a.gpu_family = g_target.family;
    a.os_version = (uint64_t)(uintptr_t)g_target.os_version;
    a.out_entry = (uint64_t)(uintptr_t)name;
    a.samplers = (uint64_t)(uintptr_t)(rs ? rs->samplers : NULL);
    a.num_samplers = rs ? rs->nsamplers : 0;
    if (o) { a.gs_emulation = o->gs_emulation ? 1u : 0u; a.input_topology = o->topology; a.layout = (uint64_t)(uintptr_t)o->layout; }   /* ml927 */

    /* Ask for the size, then convert into a buffer that fits. */
    MadeiraIRConvert(&a);
    if (a.ret_status != MADEIRA_IR_BUFFER_TOO_SMALL && a.ret_status != MADEIRA_IR_OK) {
        const unsigned char *b = (const unsigned char *)dxil;
        d3d12_log("[madeira-d3d12] %s conversion failed: %s (converter code %u); %llu bytes, head "
                  "%02x%02x%02x%02x %02x%02x%02x%02x %02x%02x%02x%02x %02x%02x%02x%02x\n",
                  tag, mad_ir_status_name(a.ret_status), a.ret_error_code, (unsigned long long)dxil_len,
                  b[0], b[1], b[2], b[3], b[4], b[5], b[6], b[7], b[8], b[9], b[10], b[11], b[12], b[13], b[14], b[15]);
        if (a.ret_note[0]) d3d12_log("[madeira-d3d12] converter service: %s\n", a.ret_note);
        /* A small container fits in the log whole; that is worth more than a
         * file that may never be written. */
        if (dxil_len <= 1024) {
            SIZE_T off;
            for (off = 0; off < dxil_len; off += 32) {
                char line[32 * 2 + 8], *w = line;
                SIZE_T k;
                for (k = 0; k < 32 && off + k < dxil_len; k++) w += sprintf(w, "%02x", b[off + k]);
                *w = 0;
                d3d12_log("[madeira-d3d12]   %04x: %s\n", (unsigned)off, line);
            }
        }
        return 0;
    }
    SIZE_T need = (SIZE_T)a.ret_len;
    if (!need) {
        d3d12_log("[madeira-d3d12] %s conversion produced no bytes\n", tag);
        return 0;
    }
    unsigned char *buf = malloc(need);
    if (!buf) return 0;
    if (o && o->layout) { buf2 = malloc(cap2); if (!buf2) { free(buf); return 0; } }   /* ml927: the stage-in metallib */

    memset(&a, 0, sizeof a);
    a.dxil = (uint64_t)(uintptr_t)dxil;
    a.dxil_len = (uint64_t)dxil_len;
    a.entry_point = (uint64_t)(uintptr_t)entry;
    a.params = (uint64_t)(uintptr_t)(rs ? rs->params : NULL);
    a.num_params = rs ? rs->nparams : 0;
    a.ranges = (uint64_t)(uintptr_t)(rs ? rs->ranges : NULL);
    a.num_ranges = rs ? rs->nranges : 0;
    a.target_os = g_target.os;
    a.gpu_family = g_target.family;
    a.os_version = (uint64_t)(uintptr_t)g_target.os_version;
    a.out_buf = (uint64_t)(uintptr_t)buf;
    a.out_cap = (uint64_t)need;
    a.out_vs_inputs = (uint64_t)(uintptr_t)vsin;
    a.vs_input_cap = vsin ? vsin_cap : 0;
    a.out_locs = (uint64_t)(uintptr_t)locs;
    a.loc_cap = locs ? MAD_LOC_MAX : 0;
    a.samplers = (uint64_t)(uintptr_t)(rs ? rs->samplers : NULL);
    a.num_samplers = rs ? rs->nsamplers : 0;
    if (o) { a.gs_emulation = o->gs_emulation ? 1u : 0u; a.input_topology = o->topology; a.layout = (uint64_t)(uintptr_t)o->layout; }   /* ml927 */
    a.out_entry = (uint64_t)(uintptr_t)name;
    if (buf2) { a.out_buf2 = (uint64_t)(uintptr_t)buf2; a.out_cap2 = cap2; }
    MadeiraIRConvert(&a);
    if (a.ret_status != MADEIRA_IR_OK) {
        d3d12_log("[madeira-d3d12] %s conversion failed: %s (converter code %u)\n",
                  tag, mad_ir_status_name(a.ret_status), a.ret_error_code);
        free(buf); free(buf2);
        return 0;
    }
    if (o) {   /* ml927 */
        if (o->vs_output_size) *o->vs_output_size = a.ret_vs_output_size;
        if (o->gs_max_prims) *o->gs_max_prims = a.ret_gs_max_prims;
        if (o->lib2_out) {
            *o->lib2_out = 0;
            if (a.ret_len2 && a.ret_len2 <= cap2 && buf2) {
                obj_handle_t dd2 = DispatchData_alloc_init((uint64_t)(uintptr_t)buf2, (uint64_t)a.ret_len2), err2 = 0;
                if (dd2) { *o->lib2_out = MTLDevice_newLibrary(d->mtl_device, dd2, &err2); NSObject_release(dd2); }
                if (err2) NSObject_release(err2);
            }
            if (!*o->lib2_out) d3d12_log("[madeira-d3d12] %s: no stage-in library (%llu bytes reported; %s)\n", tag,
                                         (unsigned long long)a.ret_len2, a.ret_note[0] ? a.ret_note : "no note");
        }
        if (o->gs_emulation)
            d3d12_log("[madeira-d3d12] %s converted with geometry emulation: vertex output %u B, gs max prims %u, payload %u, passthrough %u, stage-in %llu B\n",
                      tag, a.ret_vs_output_size, a.ret_gs_max_prims, a.ret_gs_payload, a.ret_gs_passthrough, (unsigned long long)a.ret_len2);
    }
    free(buf2);

    if (vsin_n) *vsin_n = a.ret_vs_input_count < vsin_cap ? a.ret_vs_input_count : vsin_cap;
    if (nlocs) *nlocs = a.ret_loc_count < MAD_LOC_MAX ? a.ret_loc_count : MAD_LOC_MAX;
    if (tg_out) { tg_out[0] = a.ret_tg_size[0]; tg_out[1] = a.ret_tg_size[1]; tg_out[2] = a.ret_tg_size[2]; }
    obj_handle_t dd = DispatchData_alloc_init((uint64_t)(uintptr_t)buf, (uint64_t)a.ret_len);
    obj_handle_t fn = 0, err = 0, lib = 0;
    if (dd) {
        lib = MTLDevice_newLibrary(d->mtl_device, dd, &err);
        NSObject_release(dd);
    }
    if (err) NSObject_release(err);
    if (!lib) {
        d3d12_log("[madeira-d3d12] %s: the backend rejected the converted library (%u bytes)\n",
                  tag, (unsigned)a.ret_len);
        free(buf);
        return 0;
    }
    /* The converter RENAMES entry points, so the function is looked up by the
     * name reflection reported, never by the D3D-side name. */
    fn = MTLLibrary_newFunction(lib, name);
    if (!fn) {
        d3d12_log("[madeira-d3d12] %s: converted library has no function '%s'\n", tag, name);
        NSObject_release(lib);
        free(buf);
        return 0;
    }
    d3d12_log("[madeira-d3d12] %s converted at runtime: %u bytes of DXIL -> %u bytes of metallib, "
              "entry '%s' (taken from the bytecode)\n", tag, (unsigned)dxil_len,
              (unsigned)a.ret_len, name);
    snprintf(g_last_entry, sizeof g_last_entry, "%s", name);
    if (o && o->name_out && o->name_cap) snprintf(o->name_out, o->name_cap, "%s", name);   /* ml927b */
    if (!strcmp(name, "WriteToSliceMainVS") || !strcmp(name, "WriteToSliceMainGS")) {   /* ml926: bytes for offline disassembly */
        static unsigned said; if (said++ < 2) {
            const unsigned char *b = (const unsigned char *)dxil; unsigned i, j; char line[200];
            d3d12_log("[dxil-hex] %s '%s' %u bytes begin\n", tag, name, (unsigned)dxil_len);
            for (i = 0; i < dxil_len; i += 64) {
                int n = snprintf(line, sizeof line, "[dxil-hex] %05x ", i);
                for (j = 0; j < 64 && i + j < dxil_len; j++) n += snprintf(line + n, sizeof line - n, "%02x", b[i + j]);
                d3d12_log("%s\n", line);
            }
            d3d12_log("[dxil-hex] end\n");
        }
    }
    *lib_out = lib;
    free(buf);
    return fn;
}

/* Colour formats this build can present. Anything else is refused by name
 * rather than quietly replaced with the one the cube happens to use. */
static int mad_map_rtv_format(DXGI_FORMAT f, enum WMTPixelFormat *out) {
    switch (f) {
    case DXGI_FORMAT_R8G8B8A8_UNORM:      *out = WMTPixelFormatRGBA8Unorm;     return 1;
    case DXGI_FORMAT_R8G8B8A8_UNORM_SRGB: *out = WMTPixelFormatRGBA8Unorm_sRGB;return 1;
    case DXGI_FORMAT_B8G8R8A8_UNORM:      *out = WMTPixelFormatBGRA8Unorm;     return 1;
    case DXGI_FORMAT_B8G8R8A8_UNORM_SRGB: *out = WMTPixelFormatBGRA8Unorm_sRGB;return 1;
    case DXGI_FORMAT_R16G16B16A16_FLOAT:  *out = WMTPixelFormatRGBA16Float;    return 1;
    default: return 0;
    }
}

/* ---- pipeline state (ml859) --------------------------------------------- */
static enum WMTBlendFactor mad_blend_factor(D3D12_BLEND b) {
    switch (b) {
    case D3D12_BLEND_ZERO: return WMTBlendFactorZero;
    case D3D12_BLEND_ONE: return WMTBlendFactorOne;
    case D3D12_BLEND_SRC_COLOR: return WMTBlendFactorSourceColor;
    case D3D12_BLEND_INV_SRC_COLOR: return WMTBlendFactorOneMinusSourceColor;
    case D3D12_BLEND_SRC_ALPHA: return WMTBlendFactorSourceAlpha;
    case D3D12_BLEND_INV_SRC_ALPHA: return WMTBlendFactorOneMinusSourceAlpha;
    case D3D12_BLEND_DEST_ALPHA: return WMTBlendFactorDestinationAlpha;
    case D3D12_BLEND_INV_DEST_ALPHA: return WMTBlendFactorOneMinusDestinationAlpha;
    case D3D12_BLEND_DEST_COLOR: return WMTBlendFactorDestinationColor;
    case D3D12_BLEND_INV_DEST_COLOR: return WMTBlendFactorOneMinusDestinationColor;
    case D3D12_BLEND_SRC_ALPHA_SAT: return WMTBlendFactorSourceAlphaSaturated;
    case D3D12_BLEND_BLEND_FACTOR: return WMTBlendFactorBlendColor;
    case D3D12_BLEND_INV_BLEND_FACTOR: return WMTBlendFactorOneMinusBlendColor;
    case D3D12_BLEND_SRC1_COLOR: return WMTBlendFactorSource1Color;
    case D3D12_BLEND_INV_SRC1_COLOR: return WMTBlendFactorOneMinusSource1Color;
    case D3D12_BLEND_SRC1_ALPHA: return WMTBlendFactorSource1Alpha;
    case D3D12_BLEND_INV_SRC1_ALPHA: return WMTBlendFactorOneMinusSource1Alpha;
    default: return WMTBlendFactorOne;
    }
}
static enum WMTBlendOperation mad_blend_op(D3D12_BLEND_OP o) {
    switch (o) {
    case D3D12_BLEND_OP_SUBTRACT: return WMTBlendOperationSubtract;
    case D3D12_BLEND_OP_REV_SUBTRACT: return WMTBlendOperationReverseSubtract;
    case D3D12_BLEND_OP_MIN: return WMTBlendOperationMin;
    case D3D12_BLEND_OP_MAX: return WMTBlendOperationMax;
    default: return WMTBlendOperationAdd;
    }
}
static uint8_t mad_write_mask(UINT8 m) {
    return (uint8_t)(((m & D3D12_COLOR_WRITE_ENABLE_RED) ? WMTColorWriteMaskRed : 0) |
                     ((m & D3D12_COLOR_WRITE_ENABLE_GREEN) ? WMTColorWriteMaskGreen : 0) |
                     ((m & D3D12_COLOR_WRITE_ENABLE_BLUE) ? WMTColorWriteMaskBlue : 0) |
                     ((m & D3D12_COLOR_WRITE_ENABLE_ALPHA) ? WMTColorWriteMaskAlpha : 0));
}
static enum WMTCompareFunction mad_compare(D3D12_COMPARISON_FUNC f) {
    return (f >= D3D12_COMPARISON_FUNC_NEVER && f <= D3D12_COMPARISON_FUNC_ALWAYS)
         ? (enum WMTCompareFunction)(f - D3D12_COMPARISON_FUNC_NEVER) : WMTCompareFunctionAlways;
}
static enum WMTStencilOperation mad_stencil_op(D3D12_STENCIL_OP o) {
    return (o >= D3D12_STENCIL_OP_KEEP && o <= D3D12_STENCIL_OP_DECR)
         ? (enum WMTStencilOperation)(o - D3D12_STENCIL_OP_KEEP) : WMTStencilOperationKeep;
}
static void mad_stencil_face(struct WMTStencilInfo *s, const D3D12_DEPTH_STENCILOP_DESC *d, BOOL enabled,
                             UINT8 read_mask, UINT8 write_mask) {
    s->enabled = enabled != 0;
    s->depth_stencil_pass_op = mad_stencil_op(d->StencilPassOp);
    s->stencil_fail_op = mad_stencil_op(d->StencilFailOp);
    s->depth_fail_op = mad_stencil_op(d->StencilDepthFailOp);
    s->stencil_compare_function = mad_compare(d->StencilFunc);
    s->read_mask = read_mask; s->write_mask = write_mask;
}

/* MTLVertexFormat, by value: the descriptor carries the raw number. */
static uint32_t mad_vertex_format(DXGI_FORMAT f) {
    switch (f) {
    case DXGI_FORMAT_R32G32B32A32_FLOAT: return 31; case DXGI_FORMAT_R32G32B32_FLOAT: return 30;
    case DXGI_FORMAT_R32G32_FLOAT: return 29; case DXGI_FORMAT_R32_FLOAT: return 28;
    case DXGI_FORMAT_R32G32B32A32_UINT: return 39; case DXGI_FORMAT_R32G32B32_UINT: return 38;
    case DXGI_FORMAT_R32G32_UINT: return 37; case DXGI_FORMAT_R32_UINT: return 36;
    case DXGI_FORMAT_R32G32B32A32_SINT: return 35; case DXGI_FORMAT_R32G32B32_SINT: return 34;
    case DXGI_FORMAT_R32G32_SINT: return 33; case DXGI_FORMAT_R32_SINT: return 32;
    case DXGI_FORMAT_R16G16B16A16_FLOAT: return 27; case DXGI_FORMAT_R16G16_FLOAT: return 25; case DXGI_FORMAT_R16_FLOAT: return 53;
    case DXGI_FORMAT_R16G16B16A16_UNORM: return 21; case DXGI_FORMAT_R16G16_UNORM: return 19; case DXGI_FORMAT_R16_UNORM: return 51;
    case DXGI_FORMAT_R16G16B16A16_SNORM: return 24; case DXGI_FORMAT_R16G16_SNORM: return 22; case DXGI_FORMAT_R16_SNORM: return 52;
    case DXGI_FORMAT_R16G16B16A16_UINT: return 15; case DXGI_FORMAT_R16G16_UINT: return 13; case DXGI_FORMAT_R16_UINT: return 49;
    case DXGI_FORMAT_R16G16B16A16_SINT: return 18; case DXGI_FORMAT_R16G16_SINT: return 16; case DXGI_FORMAT_R16_SINT: return 50;
    case DXGI_FORMAT_R8G8B8A8_UNORM: return 9; case DXGI_FORMAT_R8G8_UNORM: return 7; case DXGI_FORMAT_R8_UNORM: return 47;
    case DXGI_FORMAT_R8G8B8A8_SNORM: return 12; case DXGI_FORMAT_R8G8_SNORM: return 10; case DXGI_FORMAT_R8_SNORM: return 48;
    case DXGI_FORMAT_R8G8B8A8_UINT: return 3; case DXGI_FORMAT_R8G8_UINT: return 1; case DXGI_FORMAT_R8_UINT: return 45;
    case DXGI_FORMAT_R8G8B8A8_SINT: return 6; case DXGI_FORMAT_R8G8_SINT: return 4; case DXGI_FORMAT_R8_SINT: return 46;
    case DXGI_FORMAT_B8G8R8A8_UNORM: return 42;
    case DXGI_FORMAT_R10G10B10A2_UNORM: case DXGI_FORMAT_R10G10B10A2_UINT: return 41;
    case DXGI_FORMAT_R11G11B10_FLOAT: return 54;
    case DXGI_FORMAT_R9G9B9E5_SHAREDEXP: return 55;
    default: return 0;
    }
}

/* The converter names an input after its semantic; the exact spelling is
 * read from the log the first times it appears. Matching takes the part
 * after the last '.', ignores case, and accepts either NAME (index 0) or
 * NAME<index>. */
static int mad_semantic_match(const char *refl, const char *sem, UINT sem_index) {
    const char *t = strrchr(refl, '.');
    char want[80];
    size_t n;
    t = t ? t + 1 : refl;
    n = strlen(sem);
    if (_strnicmp(t, sem, n) != 0) return 0;
    if (t[n] == 0) return sem_index == 0;
    snprintf(want, sizeof want, "%s%u", sem, sem_index);
    return _stricmp(t, want) == 0;
}

/* The top-level argument buffer layout. ml883: MEASURED OFFLINE against the
 * converter (IRRootSignatureGetResourceLocations on six signature shapes):
 * strictly DECLARATION ORDER, one entry per root parameter, each at its
 * natural alignment -- 32-bit constants take 4*N bytes at 4-byte alignment,
 * every pointer parameter takes 8 bytes at 8-byte alignment. Static samplers
 * add one implicit trailing table entry after the last parameter. The old
 * "constants first" rule was only ever right for signatures that declared
 * their constants first; a compute signature with constants after a CBV had
 * the CBV pointer written into the constants' slot. */
static UINT mad_root_layout(const struct mad_rootsig *rs, UINT offsets[MAD_ROOT_PARAM_MAX]) {
    UINT i, off = 0;
    for (i = 0; i < rs->nparams && i < MAD_ROOT_PARAM_MAX; i++) {
        if (rs->params[i].type == MADEIRA_IR_PARAM_CONSTANTS) {
            off = (off + 3) & ~3u; offsets[i] = off; off += rs->params[i].num_constants * 4;
        } else {
            off = (off + 7) & ~7u; offsets[i] = off; off += 8;
        }
    }
    return off;
}

/* ml882: reconcile the computed layout with the converter's reflection. A
 * mismatch here was invisible: the shader read a CBV pointer from one slot
 * while the runtime wrote it into another, and the GPU dereferenced whatever
 * happened to be there. Reflection wins; the computed rule is only a default
 * for parameters the shader never touches. */
static void mad_apply_reflected_layout(struct mad_pso *p, const struct mad_rootsig *rs,
                                       const struct madeira_ir_loc *locs, unsigned n, const char *tag) {
    static unsigned said_dump, said_mismatch;
    unsigned i, k;
    if (!rs) return;
    if (!p->has_root_off) { mad_root_layout(rs, p->root_off); p->has_root_off = 1; }
    if (said_dump < 12 && n) {
        char line[700]; int c = snprintf(line, sizeof line, "[root-layout] %s '%s' %u params:", tag, p->vs_name, rs->nparams);
        said_dump++;
        for (k = 0; k < n && c < (int)sizeof(line) - 40; k++)
            c += snprintf(line + c, sizeof(line) - c, " t%u s%u r%u@%u/%u", locs[k].type, locs[k].space, locs[k].slot, locs[k].offset, (unsigned)locs[k].size);
        d3d12_log("%s\n", line);
    }
    /* ml883: reflection entry i IS root parameter i (declaration order; the
     * only extra entry is the implicit static-sampler table at the end).
     * Matching by register was ambiguous: per-stage signatures declare the
     * same register once per visibility, and the first hit flip-flopped
     * between the vertex and pixel entries. */
    (void)k;
    if (rs->nsamplers && n > rs->nparams && locs[rs->nparams].type == MADEIRA_IR_PARAM_TABLE) {   /* ml923 */
        p->static_off = locs[rs->nparams].offset; p->has_static_off = 1;
        { static unsigned said; if (said++ < 6) d3d12_log("[root-layout] %s '%s': static-sampler table slot at %u\n", tag, p->vs_name, p->static_off); }
    }
    for (i = 0; i < n && i < rs->nparams && i < MAD_ROOT_PARAM_MAX; i++) {
        const struct madeira_ir_loc *L = &locs[i];
        if (rs->params[i].type != L->type) {
            if (said_mismatch++ < 16)
                d3d12_log("[root-layout] %s '%s': param %u is type %u here but the converter lists type %u at entry %u; leaving the computed offset\n",
                          tag, p->vs_name, i, rs->params[i].type, L->type, i);
            continue;
        }
        if (p->root_off[i] != L->offset) {
            if (said_mismatch++ < 16)
                d3d12_log("[root-layout] MISMATCH %s '%s': param %u (type %u) computed at %u, converter put it at %u -- using the converter's\n",
                          tag, p->vs_name, i, rs->params[i].type, p->root_off[i], L->offset);
            p->root_off[i] = L->offset;
        }
    }
}

static HRESULT STDMETHODCALLTYPE device_CreateGraphicsPipelineState(ID3D12Device *This,
        const D3D12_GRAPHICS_PIPELINE_STATE_DESC *desc, REFIID riid, void **out) {
    struct mad_device *d = (struct mad_device *)This;
    struct mad_rootsig *rs;
    struct mad_pso *p;
    struct WMTRenderPipelineInfo rp;
    struct WMTVertexDescriptorInfo vd;
    struct WMTDepthStencilInfo dsi;
    struct madeira_ir_vs_input vsin[32];
    unsigned nvsin = 0, i;
    int has_vd = 0, is_depth;
    static unsigned said_inputs, said_pso;
    HRESULT hr;
    if (!desc || !out) return E_INVALIDARG;
    if (!desc->VS.pShaderBytecode) { d3d12_log("[madeira-d3d12] pipeline has no vertex shader\n"); return E_INVALIDARG; }
    if (desc->GS.pShaderBytecode || desc->HS.pShaderBytecode || desc->DS.pShaderBytecode) {   /* ml926: stages this runtime cannot run yet */
        static unsigned said; if (said++ < 12)
            d3d12_log("[madeira-d3d12] pipeline carries %s%s%s (%u/%u/%u bytes) which this runtime DROPS; VS %u B, PS %u B\n",
                      desc->GS.pShaderBytecode ? "GS " : "", desc->HS.pShaderBytecode ? "HS " : "", desc->DS.pShaderBytecode ? "DS " : "",
                      (unsigned)desc->GS.BytecodeLength, (unsigned)desc->HS.BytecodeLength, (unsigned)desc->DS.BytecodeLength,
                      (unsigned)desc->VS.BytecodeLength, (unsigned)desc->PS.BytecodeLength);
    }
    rs = (struct mad_rootsig *)desc->pRootSignature;
    mad_resolve_target(d);

    p = calloc(1, sizeof *p);
    if (!p) return E_OUTOFMEMORY;
    p->vtbl = &g_pso_vtbl; p->refs = 1; p->iid = &IID_ID3D12PipelineState; p->name = "PipelineState";

    {
        struct madeira_ir_loc locs[MAD_LOC_MAX]; unsigned nl = 0;
        if (desc->GS.pShaderBytecode) {   /* ml927: geometry-shader pipeline -> converter mesh emulation */
            struct madeira_ir_input_layout *L = calloc(1, sizeof *L);
            struct mad_convert_opts ov, og;
            UINT running[16] = {0};
            char gsname[64];
            if (!L) { pso_Release((ID3D12PipelineState *)p); return E_OUTOFMEMORY; }
            for (i = 0; i < desc->InputLayout.NumElements && L->n < 31; i++) {
                const D3D12_INPUT_ELEMENT_DESC *el = &desc->InputLayout.pInputElementDescs[i];
                UINT slot = el->InputSlot, bytes, block, off;
                struct madeira_ir_input_element *ie = &L->el[L->n];
                if (slot >= 16) continue;
                mad_format_info(el->Format, &bytes, &block);
                off = (el->AlignedByteOffset == D3D12_APPEND_ALIGNED_ELEMENT) ? ((running[slot] + 3) & ~3u) : el->AlignedByteOffset;
                if (off + bytes > running[slot]) running[slot] = off + bytes;
                snprintf(ie->semantic, sizeof ie->semantic, "%s", el->SemanticName ? el->SemanticName : "");
                ie->semantic_index = el->SemanticIndex; ie->format = (UINT)el->Format; ie->slot = slot; ie->offset = off;
                ie->per_instance = el->InputSlotClass == D3D12_INPUT_CLASSIFICATION_PER_INSTANCE_DATA ? 1u : 0u;
                ie->step_rate = el->InstanceDataStepRate;
                p->vb_mask |= 1u << slot;
                L->n++;
            }
            for (i = 0; i < 16; i++) if (p->vb_mask & (1u << i)) p->vb_stride[i] = (running[i] + 3) & ~3u;
            memset(&ov, 0, sizeof ov); ov.gs_emulation = 1; ov.topology = (UINT)desc->PrimitiveTopologyType; ov.layout = L->n ? L : NULL;
            ov.lib2_out = &p->si_lib; ov.vs_output_size = &p->gs_vertex_size; ov.name_out = p->vs_name; ov.name_cap = sizeof p->vs_name;
            p->vs_fn = mad_convert_stage_opts(d, rs, desc->VS.pShaderBytecode, desc->VS.BytecodeLength, NULL, &p->vs_lib, "VS(gs)",
                                              vsin, 32, &nvsin, NULL, locs, &nl, &ov);
            if (p->vs_fn) mad_apply_reflected_layout(p, rs, locs, nl, "VS");
            memset(&og, 0, sizeof og); og.gs_emulation = 1; og.topology = (UINT)desc->PrimitiveTopologyType; og.gs_max_prims = &p->gs_max_prims;
            og.name_out = gsname; og.name_cap = sizeof gsname; gsname[0] = 0;
            nl = 0;
            {
                obj_handle_t gfn = mad_convert_stage_opts(d, rs, desc->GS.pShaderBytecode, desc->GS.BytecodeLength, NULL, &p->gs_lib, "GS",
                                                          NULL, 0, NULL, NULL, locs, &nl, &og);
                if (gfn) { mad_apply_reflected_layout(p, rs, locs, nl, "GS"); NSObject_release(gfn); }
                else gsname[0] = 0;
            }
            { UINT ln = L->n; free(L); L = NULL;
            if (p->vs_fn && gsname[0] && (!ln || p->si_lib) && p->gs_max_prims) {
                p->gs_emu = 1;
                snprintf(p->gs_name, sizeof p->gs_name, "%s", gsname);
            } else {
                d3d12_log("[madeira-d3d12] geometry pipeline: conversion incomplete (vs %d, gs '%s', stage-in %d, max prims %u); the geometry shader is DROPPED for this pipeline\n",
                          !!p->vs_fn, gsname, !!p->si_lib, p->gs_max_prims);
                if (p->si_lib) { NSObject_release(p->si_lib); p->si_lib = 0; }
                if (p->gs_lib) { NSObject_release(p->gs_lib); p->gs_lib = 0; }
                if (p->vs_fn) { NSObject_release(p->vs_fn); p->vs_fn = 0; }
                if (p->vs_lib) { NSObject_release(p->vs_lib); p->vs_lib = 0; }
                nvsin = 0; nl = 0;
            } }
        }
        if (!p->gs_emu) {
        p->vs_fn = mad_convert_stage(d, rs, desc->VS.pShaderBytecode, desc->VS.BytecodeLength, NULL, &p->vs_lib, "VS",
                                     vsin, 32, &nvsin, NULL, locs, &nl);
        if (p->vs_fn) { snprintf(p->vs_name, sizeof p->vs_name, "%s", g_last_entry); mad_apply_reflected_layout(p, rs, locs, nl, "VS"); }
        }
        if (desc->PS.pShaderBytecode) {
            struct mad_convert_opts op; memset(&op, 0, sizeof op); op.name_out = p->ps_name; op.name_cap = sizeof p->ps_name;   /* ml927b: per-call name */
            nl = 0;
            p->ps_fn = mad_convert_stage_opts(d, rs, desc->PS.pShaderBytecode, desc->PS.BytecodeLength, NULL, &p->ps_lib, "PS",
                                              NULL, 0, NULL, NULL, locs, &nl, &op);
            if (p->ps_fn) mad_apply_reflected_layout(p, rs, locs, nl, "PS");
        }
    }
    if (!p->vs_fn || (desc->PS.pShaderBytecode && !p->ps_fn)) { pso_Release((ID3D12PipelineState *)p); return E_FAIL; }

    /* Input layout -> vertex descriptor, through the attribute indices the
     * converted vertex shader reports. Element offsets follow D3D's append
     * rule; the per-slot stride is not part of a D3D12 pipeline, so the
     * tightest stride that covers the declared elements is used and every
     * draw checks it against the bound buffer's real stride. */
    memset(&vd, 0, sizeof vd);
    if (desc->InputLayout.NumElements && nvsin) {
        UINT running[16] = {0};
        if (said_inputs < 3) {
            said_inputs++;
            for (i = 0; i < nvsin && i < 32; i++)
                d3d12_log("[madeira-d3d12] VS input %u: '%s' -> attribute %u\n", i, vsin[i].name, vsin[i].attribute);
        }
        for (i = 0; i < desc->InputLayout.NumElements; i++) {
            const D3D12_INPUT_ELEMENT_DESC *el = &desc->InputLayout.pInputElementDescs[i];
            UINT slot = el->InputSlot, bytes, block, off, j, ai;
            uint32_t fmt = mad_vertex_format(el->Format);
            if (slot >= 16) continue;
            mad_format_info(el->Format, &bytes, &block);
            off = (el->AlignedByteOffset == D3D12_APPEND_ALIGNED_ELEMENT) ? ((running[slot] + 3) & ~3u) : el->AlignedByteOffset;
            if (off + bytes > running[slot]) running[slot] = off + bytes;
            for (j = 0; j < nvsin && j < 32; j++) {
                if (!mad_semantic_match(vsin[j].name, el->SemanticName, el->SemanticIndex)) continue;
                /* ml878: the converter's attributeIndex is the input's ORDINAL
                 * (attribute13 -> 1); the converted shader reads it from Metal
                 * attribute kIRStageInAttributeStartIndex (11) + ordinal. Every
                 * pipeline with an input layout failed with "attribute0(11) is
                 * missing from the vertex descriptor" before this. */
                ai = 11 + vsin[j].attribute;
                if (ai >= 31) break;
                if (!fmt) { d3d12_log("[madeira-d3d12] input element %s%u has vertex format %u with no Metal equivalent\n",
                                      el->SemanticName, el->SemanticIndex, (unsigned)el->Format); break; }
                vd.attributes[ai].format = fmt;
                vd.attributes[ai].offset = off;
                vd.attributes[ai].buffer_index = 6 + slot;
                vd.attribute_mask |= 1u << ai;
                vd.layouts[6 + slot].step_function = (el->InputSlotClass == D3D12_INPUT_CLASSIFICATION_PER_INSTANCE_DATA) ? 2 : 1;
                vd.layouts[6 + slot].step_rate = el->InstanceDataStepRate ? el->InstanceDataStepRate : 1;
                vd.layout_mask |= 1u << (6 + slot);
                has_vd = 1;
                break;
            }
            if (j == nvsin || j == 32) {
                static unsigned said_nomatch;
                if (said_nomatch++ < 8)
                    d3d12_log("[madeira-d3d12] input element %s%u matched no vertex-shader input\n", el->SemanticName, el->SemanticIndex);
            }
        }
        for (i = 0; i < 16; i++) if (vd.layout_mask & (1u << (6 + i))) {
            vd.layouts[6 + i].stride = (running[i] + 3) & ~3u;
            p->vb_stride[i] = vd.layouts[6 + i].stride;
            p->vb_mask |= 1u << i;
        }
    } else if (desc->InputLayout.NumElements) {
        d3d12_log("[madeira-d3d12] input layout has %u elements but the vertex shader reported no inputs\n",
                  desc->InputLayout.NumElements);
    }

    memset(&rp, 0, sizeof rp);
    rp.vertex_function = p->vs_fn;
    rp.fragment_function = p->ps_fn;
    rp.rasterization_enabled = true;
    rp.raster_sample_count = desc->SampleDesc.Count ? desc->SampleDesc.Count : 1;
    rp.alpha_to_coverage_enabled = desc->BlendState.AlphaToCoverageEnable != 0;
    for (i = 0; i < desc->NumRenderTargets && i < 8; i++) {
        const D3D12_RENDER_TARGET_BLEND_DESC *b = &desc->BlendState.RenderTarget[desc->BlendState.IndependentBlendEnable ? i : 0];
        enum WMTPixelFormat pf;
        if (desc->RTVFormats[i] == DXGI_FORMAT_UNKNOWN) continue;
        if (!mad_map_texture_format(desc->RTVFormats[i], D3D12_RESOURCE_FLAG_ALLOW_RENDER_TARGET, &pf, &is_depth) || is_depth) {
            d3d12_log("[madeira-d3d12] pipeline render target %u format %u is not supported\n", i, (unsigned)desc->RTVFormats[i]);
            pso_Release((ID3D12PipelineState *)p); return E_NOTIMPL;
        }
        rp.colors[i].pixel_format = pf;
        rp.colors[i].blending_enabled = b->BlendEnable != 0;
        rp.colors[i].rgb_blend_operation = mad_blend_op(b->BlendOp);
        rp.colors[i].alpha_blend_operation = mad_blend_op(b->BlendOpAlpha);
        rp.colors[i].src_rgb_blend_factor = mad_blend_factor(b->SrcBlend);
        rp.colors[i].dst_rgb_blend_factor = mad_blend_factor(b->DestBlend);
        rp.colors[i].src_alpha_blend_factor = mad_blend_factor(b->SrcBlendAlpha);
        rp.colors[i].dst_alpha_blend_factor = mad_blend_factor(b->DestBlendAlpha);
        rp.colors[i].write_mask = mad_write_mask(b->RenderTargetWriteMask);
        if (b->LogicOpEnable) { static unsigned said; if (!said++) d3d12_log("[madeira-d3d12] logic ops are not implemented\n"); }
    }
    rp.depth_pixel_format = WMTPixelFormatInvalid;
    rp.stencil_pixel_format = WMTPixelFormatInvalid;
    if (desc->DSVFormat != DXGI_FORMAT_UNKNOWN) {
        enum WMTPixelFormat pf;
        if (!mad_map_texture_format(desc->DSVFormat, D3D12_RESOURCE_FLAG_ALLOW_DEPTH_STENCIL, &pf, &is_depth) || !is_depth) {
            d3d12_log("[madeira-d3d12] pipeline depth format %u is not supported\n", (unsigned)desc->DSVFormat);
            pso_Release((ID3D12PipelineState *)p); return E_NOTIMPL;
        }
        rp.depth_pixel_format = pf;
        p->uses_depth = 1;
        if (pf == WMTPixelFormatDepth32Float_Stencil8) { rp.stencil_pixel_format = pf; p->uses_stencil = 1; }
    }
    switch (desc->PrimitiveTopologyType) {
    case D3D12_PRIMITIVE_TOPOLOGY_TYPE_POINT: rp.input_primitive_topology = WMTPrimitiveTopologyClassPoint; break;
    case D3D12_PRIMITIVE_TOPOLOGY_TYPE_LINE: rp.input_primitive_topology = WMTPrimitiveTopologyClassLine; break;
    default: rp.input_primitive_topology = WMTPrimitiveTopologyClassTriangle; break;
    }
    rp.max_tessellation_factor = 16;   /* Metal requires 1..64 even when unused */

    if (p->gs_emu) {   /* ml927 */
        struct WMTMeshRenderPipelineInfo mp; struct WMTGeometryEmulationInfo ge; obj_handle_t err = 0;
        memset(&mp, 0, sizeof mp); memset(&ge, 0, sizeof ge);
        memcpy(mp.colors, rp.colors, sizeof mp.colors);
        mp.alpha_to_coverage_enabled = rp.alpha_to_coverage_enabled;
        mp.rasterization_enabled = rp.rasterization_enabled;
        mp.raster_sample_count = rp.raster_sample_count;
        mp.depth_pixel_format = rp.depth_pixel_format; mp.stencil_pixel_format = rp.stencil_pixel_format;
        ge.stagein_library = p->si_lib; ge.vertex_library = p->vs_lib; ge.geometry_library = p->gs_lib; ge.fragment_library = p->ps_lib;
        snprintf(ge.vertex_function, sizeof ge.vertex_function, "%s", p->vs_name);
        snprintf(ge.geometry_function, sizeof ge.geometry_function, "%s", p->gs_name);
        if (p->ps_fn) snprintf(ge.fragment_function, sizeof ge.fragment_function, "%s", p->ps_name);
        ge.gs_vertex_size_bytes = p->gs_vertex_size; ge.gs_max_input_primitives = p->gs_max_prims;
        p->rps = MTLDevice_newGeometryEmulationPipelineState(d->mtl_device, &mp, &ge, &err);
        if (err) NSObject_release(err);
        { static unsigned said; if (said++ < 8) d3d12_log("[madeira-d3d12] geometry pipeline %s: vs '%s' gs '%s' ps '%s' (vertex %u B, %u prims/tg, %u targets)\n",
                                                        p->rps ? "created" : "FAILED", ge.vertex_function, ge.geometry_function, ge.fragment_function,
                                                        p->gs_vertex_size, p->gs_max_prims, desc->NumRenderTargets); }
        if (!p->rps) { p->gs_emu = 0; d3d12_log("[madeira-d3d12] geometry pipeline: falling back to a plain vertex pipeline (geometry shader DROPPED)\n"); }
    }
    if (!p->gs_emu) {
        obj_handle_t err = 0;
        p->rps = has_vd ? MTLDevice_newRenderPipelineStateVD(d->mtl_device, &rp, &vd, &err)
                        : MTLDevice_newRenderPipelineState(d->mtl_device, &rp, &err);
        if (err) NSObject_release(err);
    }
    if (!p->rps) {
        d3d12_log("[madeira-d3d12] newRenderPipelineState failed (%u targets, depth %u, %u input elements)\n",
                  desc->NumRenderTargets, (unsigned)desc->DSVFormat, desc->InputLayout.NumElements);
        pso_Release((ID3D12PipelineState *)p);
        return E_FAIL;
    }
    if (has_vd) { p->rp = rp; p->vd = vd; p->has_vd = 1; p->device_handle = d->mtl_device; InitializeCriticalSection(&p->var_lock); }

    /* Depth-stencil state is encoder state in Metal; one object per pipeline. */
    memset(&dsi, 0, sizeof dsi);
    p->dbg_denable = desc->DepthStencilState.DepthEnable != 0;
    p->dbg_dfunc = (UINT8)desc->DepthStencilState.DepthFunc;
    p->dbg_dwrite = desc->DepthStencilState.DepthWriteMask == D3D12_DEPTH_WRITE_MASK_ALL;
    { unsigned wi; for (wi = 0; wi < 8; wi++) p->dbg_wmask[wi] = desc->BlendState.RenderTarget[wi].RenderTargetWriteMask; }
    p->dbg_senable = desc->DepthStencilState.StencilEnable != 0; p->dbg_sfunc = (UINT8)desc->DepthStencilState.FrontFace.StencilFunc;
    p->dbg_srmask = desc->DepthStencilState.StencilReadMask; p->dbg_swmask = desc->DepthStencilState.StencilWriteMask;
    if (desc->DepthStencilState.DepthEnable) {
        dsi.depth_compare_function = mad_compare(desc->DepthStencilState.DepthFunc);
        dsi.depth_write_enabled = desc->DepthStencilState.DepthWriteMask == D3D12_DEPTH_WRITE_MASK_ALL;
    } else {
        dsi.depth_compare_function = WMTCompareFunctionAlways;
        dsi.depth_write_enabled = false;
    }
    mad_stencil_face(&dsi.front_stencil, &desc->DepthStencilState.FrontFace, desc->DepthStencilState.StencilEnable,
                     desc->DepthStencilState.StencilReadMask, desc->DepthStencilState.StencilWriteMask);
    mad_stencil_face(&dsi.back_stencil, &desc->DepthStencilState.BackFace, desc->DepthStencilState.StencilEnable,
                     desc->DepthStencilState.StencilReadMask, desc->DepthStencilState.StencilWriteMask);
    p->dsso = MTLDevice_newDepthStencilState(d->mtl_device, &dsi);

    memset(&p->raster, 0, sizeof p->raster);
    p->raster.type = WMTRenderCommandSetRasterizerState;
    p->raster.fill_mode = desc->RasterizerState.FillMode == D3D12_FILL_MODE_WIREFRAME ? WMTTriangleFillModeLines : WMTTriangleFillModeFill;
    p->raster.cull_mode = desc->RasterizerState.CullMode == D3D12_CULL_MODE_FRONT ? WMTCullModeFront
                        : desc->RasterizerState.CullMode == D3D12_CULL_MODE_BACK ? WMTCullModeBack : WMTCullModeNone;
    p->raster.depth_clip_mode = desc->RasterizerState.DepthClipEnable ? WMTDepthClipModeClip : WMTDepthClipModeClamp;
    p->raster.winding = desc->RasterizerState.FrontCounterClockwise ? WMTWindingCounterClockwise : WMTWindingClockwise;
    p->raster.depth_bias = (float)desc->RasterizerState.DepthBias;
    p->raster.scole_scale = desc->RasterizerState.SlopeScaledDepthBias;
    p->raster.depth_bias_clamp = desc->RasterizerState.DepthBiasClamp;

    if (said_pso < 8) {
        said_pso++;
        d3d12_log("[madeira-d3d12] pipeline: %u targets (fmt %u), depth fmt %u, %u input elements%s, %s\n",
                  desc->NumRenderTargets, (unsigned)desc->RTVFormats[0], (unsigned)desc->DSVFormat,
                  desc->InputLayout.NumElements, has_vd ? " (vertex descriptor)" : "", p->ps_fn ? "VS+PS" : "VS only");
    }
    hr = pso_QI((ID3D12PipelineState *)p, riid, out);
    pso_Release((ID3D12PipelineState *)p);
    return hr;
}


static HRESULT STDMETHODCALLTYPE device_CreateComputePipelineState(ID3D12Device *This,
        const D3D12_COMPUTE_PIPELINE_STATE_DESC *desc, REFIID riid, void **out) {
    struct mad_device *d = (struct mad_device *)This;
    struct mad_pso *p;
    struct WMTComputePipelineInfo ci;
    obj_handle_t err = 0;
    static unsigned said;
    HRESULT hr;
    if (!desc || !out) return E_INVALIDARG;
    if (!desc->CS.pShaderBytecode) return E_INVALIDARG;
    mad_resolve_target(d);
    p = calloc(1, sizeof *p);
    if (!p) return E_OUTOFMEMORY;
    p->vtbl = &g_pso_vtbl; p->refs = 1; p->iid = &IID_ID3D12PipelineState; p->name = "ComputePipelineState";
    p->is_compute = 1;
    {
        struct madeira_ir_loc locs[MAD_LOC_MAX]; unsigned nl = 0;
        p->vs_fn = mad_convert_stage(d, (struct mad_rootsig *)desc->pRootSignature, desc->CS.pShaderBytecode,
                                     desc->CS.BytecodeLength, NULL, &p->vs_lib, "CS", NULL, 0, NULL, p->tg, locs, &nl);
        {   /* ml931 */
            char fn[96]; static unsigned ndump;
            if (ndump++ < 400) { snprintf(fn, sizeof fn, "cs_%p_%u.dxil", (void *)p, (unsigned)desc->CS.BytecodeLength); mad_dump_blob(fn, desc->CS.pShaderBytecode, desc->CS.BytecodeLength); }
        }
        snprintf(p->vs_name, sizeof p->vs_name, "%s", g_last_entry);   /* ml880: kernel name for the logs */
        if (p->vs_fn) mad_apply_reflected_layout(p, (struct mad_rootsig *)desc->pRootSignature, locs, nl, "CS");
    }
    if (!p->vs_fn) { pso_Release((ID3D12PipelineState *)p); return E_FAIL; }
    if (!p->tg[0]) { p->tg[0] = 1; }
    if (!p->tg[1]) { p->tg[1] = 1; }
    if (!p->tg[2]) { p->tg[2] = 1; }
    memset(&ci, 0, sizeof ci);
    ci.compute_function = p->vs_fn;
    p->cps = MTLDevice_newComputePipelineState(d->mtl_device, &ci, &err);
    if (err) NSObject_release(err);
    if (!p->cps) {
        d3d12_log("[madeira-d3d12] newComputePipelineState failed\n");
        pso_Release((ID3D12PipelineState *)p);
        return E_FAIL;
    }
    if (said < 8) {
        said++;
        d3d12_log("[madeira-d3d12] compute pipeline: threadgroup %ux%ux%u\n", p->tg[0], p->tg[1], p->tg[2]);
    }
    hr = pso_QI((ID3D12PipelineState *)p, riid, out);
    pso_Release((ID3D12PipelineState *)p);
    return hr;
}

/* ---- render recording ---------------------------------------------------- */
/* ---- recording ------------------------------------------------------------ */
static void mad_subresource(const struct mad_resource *r, UINT sub, UINT *level, UINT *slice) {
    UINT mips = r->desc.MipLevels ? r->desc.MipLevels : 1;
    *level = sub % mips; *slice = sub / mips;
}
static void mad_mip_dims(const struct mad_resource *r, UINT level, UINT *w, UINT *h, UINT *d) {
    *w = (UINT)(r->desc.Width >> level); if (!*w) *w = 1;
    *h = r->desc.Height >> level; if (!*h) *h = 1;
    *d = (r->desc.Dimension == D3D12_RESOURCE_DIMENSION_TEXTURE3D) ? (r->desc.DepthOrArraySize >> level) : 1;
    if (!*d) *d = 1;
}

static void STDMETHODCALLTYPE list_OMSetRenderTargets(ID3D12GraphicsCommandList *This, UINT n,
        const D3D12_CPU_DESCRIPTOR_HANDLE *rtvs, BOOL single, const D3D12_CPU_DESCRIPTOR_HANDLE *dsv) {
    struct mad_list *l = (struct mad_list *)This;
    struct mad_cmd *c = mad_list_push(l, MC_RTS);
    UINT i;
    if (!c) return;
    if (n > 8) n = 8;
    for (i = 0; i < n && rtvs; i++) {
        /* With `single`, the handles are consecutive slots after the first. */
        SIZE_T h = single ? rtvs[0].ptr + i * sizeof(struct mad_rtv) : rtvs[i].ptr;
        c->u.rts.rt[i] = mad_slot_resource(h); c->u.rts.v[i] = mad_slot_view(h);
    }
    c->u.rts.n = rtvs ? n : 0;
    c->u.rts.depth = dsv ? mad_slot_resource(dsv->ptr) : NULL;
    c->u.rts.dv = mad_slot_view(dsv ? dsv->ptr : 0);
}
static void STDMETHODCALLTYPE list_ClearRenderTargetView(ID3D12GraphicsCommandList *This,
        D3D12_CPU_DESCRIPTOR_HANDLE rtv, const FLOAT rgba[4], UINT n, const D3D12_RECT *rects) {
    struct mad_list *l = (struct mad_list *)This;
    struct mad_resource *rt = mad_slot_resource(rtv.ptr);
    struct mad_cmd *c;
    static unsigned said_rects;
    if (!rt) return;
    if (n && rects && !said_rects++) d3d12_log("[madeira-d3d12] ClearRenderTargetView: rects are ignored; the whole target is cleared\n");
    c = mad_list_push(l, MC_CLEAR_RT);
    if (!c) return;
    c->u.clear.res = rt; c->u.clear.v = mad_slot_view(rtv.ptr);
    if (rgba) memcpy(c->u.clear.rgba, rgba, sizeof c->u.clear.rgba);
}
static void STDMETHODCALLTYPE list_ClearDepthStencilView(ID3D12GraphicsCommandList *This,
        D3D12_CPU_DESCRIPTOR_HANDLE dsv, D3D12_CLEAR_FLAGS flags, FLOAT depth, UINT8 stencil,
        UINT n, const D3D12_RECT *rects) {
    struct mad_list *l = (struct mad_list *)This;
    struct mad_resource *d = mad_slot_resource(dsv.ptr);
    struct mad_cmd *c;
    static unsigned said, said_rect;
    if (!d) return;
    if (n && rects && said_rect++ < 4)
        d3d12_log("[madeira-d3d12] ClearDepthStencilView: %u clear rects ignored (whole view cleared)\n", n);
    if (said++ < 24)
        d3d12_log("[madeira-d3d12] ClearDepthStencilView: res %p %ux%u flags %#x depth %g stencil %u\n", (void *)d,
                  d->width, d->height, (unsigned)flags, depth, (unsigned)stencil);
    c = mad_list_push(l, MC_CLEAR_DS);
    if (!c) return;
    c->u.clear.res = d; c->u.clear.v = mad_slot_view(dsv.ptr); c->u.clear.depth = depth; c->u.clear.stencil = stencil;
    c->u.clear.flags = (UINT8)(flags & (D3D12_CLEAR_FLAG_DEPTH | D3D12_CLEAR_FLAG_STENCIL));
    if (!c->u.clear.flags) c->u.clear.flags = D3D12_CLEAR_FLAG_DEPTH | D3D12_CLEAR_FLAG_STENCIL;
}
static void STDMETHODCALLTYPE list_SetPipelineState(ID3D12GraphicsCommandList *This, ID3D12PipelineState *pso) {
    struct mad_cmd *c = mad_list_push((struct mad_list *)This, MC_PSO);
    if (c) c->u.pso = (struct mad_pso *)pso;
}
static void STDMETHODCALLTYPE list_SetGraphicsRootSignature(ID3D12GraphicsCommandList *This, ID3D12RootSignature *rs) {
    struct mad_cmd *c = mad_list_push((struct mad_list *)This, MC_ROOTSIG);
    if (c) c->u.rootsig = (struct mad_rootsig *)rs;
}
static void STDMETHODCALLTYPE list_SetComputeRootSignature(ID3D12GraphicsCommandList *This, ID3D12RootSignature *rs) {
    struct mad_cmd *c = mad_list_push((struct mad_list *)This, MC_CROOTSIG);
    if (c) c->u.rootsig = (struct mad_rootsig *)rs;
}
static void mad_record_croot(struct mad_list *l, UINT index, UINT64 value, int resolve) {
    struct mad_cmd *c;
    if (index >= MAD_ROOT_PARAM_MAX) return;
    c = mad_list_push(l, MC_CROOT);
    if (!c) return;
    c->u.root.index = index; c->u.root.value = value;
    if (resolve) { UINT64 off = 0; mad_list_note_used(l, mad_resolve_address(l->device, value, &off)); }
}
static void STDMETHODCALLTYPE list_SetComputeRootConstantBufferView(ID3D12GraphicsCommandList *This, UINT index, D3D12_GPU_VIRTUAL_ADDRESS a) { mad_record_croot((struct mad_list *)This, index, a, 1); }
static void STDMETHODCALLTYPE list_SetComputeRootShaderResourceView(ID3D12GraphicsCommandList *This, UINT index, D3D12_GPU_VIRTUAL_ADDRESS a) { mad_record_croot((struct mad_list *)This, index, a, 1); }
static void STDMETHODCALLTYPE list_SetComputeRootUnorderedAccessView(ID3D12GraphicsCommandList *This, UINT index, D3D12_GPU_VIRTUAL_ADDRESS a) { mad_record_croot((struct mad_list *)This, index, a, 1); }
static void STDMETHODCALLTYPE list_SetComputeRootDescriptorTable(ID3D12GraphicsCommandList *This, UINT index, D3D12_GPU_DESCRIPTOR_HANDLE h) { mad_record_croot((struct mad_list *)This, index, h.ptr, 0); }
static void STDMETHODCALLTYPE list_SetComputeRoot32BitConstants(ID3D12GraphicsCommandList *This,
        UINT index, UINT n, const void *data, UINT dst_offset) {
    struct mad_list *l = (struct mad_list *)This;
    struct mad_cmd *c;
    if (!n || !data || index >= MAD_ROOT_PARAM_MAX || dst_offset + n > 64) return;
    if (!mad_grow((void **)&l->cdata, &l->cdcap, l->ncdata + n, sizeof *l->cdata)) return;
    c = mad_list_push(l, MC_CROOT_CONST);
    if (!c) return;
    memcpy(&l->cdata[l->ncdata], data, n * 4);
    c->u.rconst.index = index; c->u.rconst.dst = dst_offset; c->u.rconst.n = n; c->u.rconst.data = l->ncdata;
    l->ncdata += n;
}
static void STDMETHODCALLTYPE list_SetComputeRoot32BitConstant(ID3D12GraphicsCommandList *This, UINT index, UINT data, UINT dst_offset) {
    list_SetComputeRoot32BitConstants(This, index, 1, &data, dst_offset);
}
/* ml892: UAV clears for BUFFER views through the blit fill. The CPU handle
 * points at our descriptor entry, whose address+size name the range; the
 * resource is found by address. Metal fills bytes, so a value whose four
 * bytes are equal is exact and anything else is approximated by its low byte
 * and named once. Texture UAV clears are not implemented yet. */
static void mad_record_uav_clear(ID3D12GraphicsCommandList *This, D3D12_CPU_DESCRIPTOR_HANDLE cpu, const UINT32 v[4], const char *what) {
    struct mad_list *l = (struct mad_list *)This;
    struct mad_descriptor *e = (struct mad_descriptor *)cpu.ptr;
    struct mad_resource *r; UINT64 off = 0; UINT64 len;
    struct mad_cmd *c;
    static unsigned said_tex, said_approx;
    if (!e || !l) return;
    if (!e->gpu_va) { if (said_tex++ < 2) d3d12_log("[madeira-d3d12] %s on a texture view is not implemented; skipped\n", what); return; }
    r = mad_resolve_address(l->device, e->gpu_va, &off);
    if (!r || !r->buffer) return;
    len = e->metadata & 0xffffffffu;
    if (!len || off + len > r->size) len = r->size > off ? r->size - off : 0;
    if (!len) return;
    c = mad_list_push(l, MC_FILL_BB);
    if (!c) return;
    c->u.fill.res = r; c->u.fill.off = off; c->u.fill.len = len;
    {
        UINT32 x = v ? v[0] : 0; UINT8 b = (UINT8)(x & 0xff);
        int exact = v && v[0] == v[1] && v[1] == v[2] && v[2] == v[3] &&
                    ((x >> 8) & 0xff) == b && ((x >> 16) & 0xff) == b && ((x >> 24) & 0xff) == b;
        if (!exact && said_approx++ < 4)
            d3d12_log("[madeira-d3d12] %s with value %#x is approximated by byte %#x\n", what, x, b);
        c->u.fill.byte = b;
    }
}
static void STDMETHODCALLTYPE list_ClearUnorderedAccessViewUint(ID3D12GraphicsCommandList *This,
        D3D12_GPU_DESCRIPTOR_HANDLE gpu, D3D12_CPU_DESCRIPTOR_HANDLE cpu, ID3D12Resource *res,
        const UINT values[4], UINT n, const D3D12_RECT *rects) {
    (void)gpu; (void)res; (void)n; (void)rects;
    mad_record_uav_clear(This, cpu, values, "ClearUnorderedAccessViewUint");
}
static void STDMETHODCALLTYPE list_ClearUnorderedAccessViewFloat(ID3D12GraphicsCommandList *This,
        D3D12_GPU_DESCRIPTOR_HANDLE gpu, D3D12_CPU_DESCRIPTOR_HANDLE cpu, ID3D12Resource *res,
        const FLOAT values[4], UINT n, const D3D12_RECT *rects) {
    UINT32 u[4]; int i;
    (void)gpu; (void)res; (void)n; (void)rects;
    for (i = 0; i < 4; i++) memcpy(&u[i], &values[i], 4);
    mad_record_uav_clear(This, cpu, u, "ClearUnorderedAccessViewFloat");
}
static void STDMETHODCALLTYPE list_OMSetBlendFactor(ID3D12GraphicsCommandList *This, const FLOAT f[4]) {
    struct mad_cmd *c = mad_list_push((struct mad_list *)This, MC_BLEND_FACTOR);
    if (c) { if (f) memcpy(c->u.blend.rgba, f, sizeof c->u.blend.rgba); else { c->u.blend.rgba[0] = c->u.blend.rgba[1] = c->u.blend.rgba[2] = c->u.blend.rgba[3] = 1.0f; } }
}
static void STDMETHODCALLTYPE list_DiscardResource(ID3D12GraphicsCommandList *This, ID3D12Resource *res, const D3D12_DISCARD_REGION *region) {
    (void)This; (void)res; (void)region;   /* a hint; nothing to do */
}
static void STDMETHODCALLTYPE list_OMSetStencilRef(ID3D12GraphicsCommandList *This, UINT ref) {
    struct mad_cmd *c = mad_list_push((struct mad_list *)This, MC_STENCIL_REF);
    if (c) c->u.stencil_ref = ref;
}
static void mad_record_root(struct mad_list *l, UINT index, UINT64 value, int resolve) {
    struct mad_cmd *c;
    if (index >= MAD_ROOT_PARAM_MAX) {
        static unsigned said;
        if (!said++) d3d12_log("[madeira-d3d12] root parameter index %u is beyond this build's limit\n", index);
        return;
    }
    c = mad_list_push(l, MC_ROOT);
    if (!c) return;
    c->u.root.index = index; c->u.root.value = value;
    if (resolve) {
        UINT64 off = 0;
        mad_list_note_used(l, mad_resolve_address(l->device, value, &off));
    }
}
static void STDMETHODCALLTYPE list_SetGraphicsRootConstantBufferView(ID3D12GraphicsCommandList *This,
        UINT index, D3D12_GPU_VIRTUAL_ADDRESS addr) { mad_record_root((struct mad_list *)This, index, addr, 1); }
static void STDMETHODCALLTYPE list_SetGraphicsRootShaderResourceView(ID3D12GraphicsCommandList *This,
        UINT index, D3D12_GPU_VIRTUAL_ADDRESS addr) { mad_record_root((struct mad_list *)This, index, addr, 1); }
static void STDMETHODCALLTYPE list_SetGraphicsRootUnorderedAccessView(ID3D12GraphicsCommandList *This,
        UINT index, D3D12_GPU_VIRTUAL_ADDRESS addr) { mad_record_root((struct mad_list *)This, index, addr, 1); }
static void STDMETHODCALLTYPE list_SetGraphicsRootDescriptorTable(ID3D12GraphicsCommandList *This,
        UINT index, D3D12_GPU_DESCRIPTOR_HANDLE h) {
    /* The handle already IS the address of the first descriptor. */
    mad_record_root((struct mad_list *)This, index, h.ptr, 0);
}
static void STDMETHODCALLTYPE list_SetGraphicsRoot32BitConstants(ID3D12GraphicsCommandList *This,
        UINT index, UINT n, const void *data, UINT dst_offset) {
    struct mad_list *l = (struct mad_list *)This;
    struct mad_cmd *c;
    if (!n || !data || index >= MAD_ROOT_PARAM_MAX || dst_offset + n > 64) return;
    if (!mad_grow((void **)&l->cdata, &l->cdcap, l->ncdata + n, sizeof *l->cdata)) return;
    c = mad_list_push(l, MC_ROOT_CONST);
    if (!c) return;
    memcpy(&l->cdata[l->ncdata], data, n * 4);
    c->u.rconst.index = index; c->u.rconst.dst = dst_offset; c->u.rconst.n = n; c->u.rconst.data = l->ncdata;
    l->ncdata += n;
}
static void STDMETHODCALLTYPE list_SetGraphicsRoot32BitConstant(ID3D12GraphicsCommandList *This,
        UINT index, UINT data, UINT dst_offset) { list_SetGraphicsRoot32BitConstants(This, index, 1, &data, dst_offset); }
static void STDMETHODCALLTYPE list_SetDescriptorHeaps(ID3D12GraphicsCommandList *This,
        UINT n, ID3D12DescriptorHeap *const *heaps) {
    struct mad_list *l = (struct mad_list *)This;
    struct mad_cmd *c;
    UINT i;
    if (!heaps) return;
    c = mad_list_push(l, MC_HEAPS);
    if (!c) return;
    for (i = 0; i < n; i++) {
        struct mad_heap *h = (struct mad_heap *)heaps[i];
        if (!h || !h->buffer) continue;
        if (h->type == D3D12_DESCRIPTOR_HEAP_TYPE_SAMPLER) c->u.heaps.smp = h; else c->u.heaps.srv = h;
    }
}
static void STDMETHODCALLTYPE list_RSSetViewports(ID3D12GraphicsCommandList *This, UINT n, const D3D12_VIEWPORT *vp) {
    struct mad_cmd *c;
    if (!n || !vp) return;
    c = mad_list_push((struct mad_list *)This, MC_VP);
    if (c) c->u.vp = vp[0];
}
static void STDMETHODCALLTYPE list_RSSetScissorRects(ID3D12GraphicsCommandList *This, UINT n, const D3D12_RECT *r) {
    struct mad_cmd *c;
    if (!n || !r) return;
    c = mad_list_push((struct mad_list *)This, MC_SCISSOR);
    if (c) c->u.scissor = r[0];
}
static void STDMETHODCALLTYPE list_IASetPrimitiveTopology(ID3D12GraphicsCommandList *This, D3D12_PRIMITIVE_TOPOLOGY t) {
    struct mad_cmd *c = mad_list_push((struct mad_list *)This, MC_TOPO);
    static unsigned said;
    if (c) c->u.topo = t;
    if (t >= D3D_PRIMITIVE_TOPOLOGY_LINELIST_ADJ && !said++)
        d3d12_log("[madeira-d3d12] topology %u (adjacency or patches) drawn as triangles\n", (unsigned)t);
}
static void STDMETHODCALLTYPE list_IASetIndexBuffer(ID3D12GraphicsCommandList *This, const D3D12_INDEX_BUFFER_VIEW *view) {
    struct mad_list *l = (struct mad_list *)This;
    struct mad_cmd *c = mad_list_push(l, MC_IB);
    UINT64 off = 0;
    if (!c) return;
    if (!view) return;   /* an unbound index buffer */
    c->u.ib.res = mad_resolve_address(l->device, view->BufferLocation, &off);
    c->u.ib.off = off;
    c->u.ib.type = view->Format == DXGI_FORMAT_R32_UINT ? WMTIndexTypeUInt32 : WMTIndexTypeUInt16;
    if (!c->u.ib.res) {
        static unsigned said;
        if (!said++) d3d12_log("[madeira-d3d12] index buffer address %llx matches no live resource\n",
                               (unsigned long long)view->BufferLocation);
    }
}
static void STDMETHODCALLTYPE list_IASetVertexBuffers(ID3D12GraphicsCommandList *This, UINT start, UINT n,
        const D3D12_VERTEX_BUFFER_VIEW *views) {
    struct mad_list *l = (struct mad_list *)This;
    UINT i;
    for (i = 0; i < n; i++) {
        struct mad_cmd *c = mad_list_push(l, MC_VB);
        UINT64 off = 0;
        if (!c) return;
        c->u.vb.slot = start + i;
        if (views && views[i].BufferLocation) {
            c->u.vb.res = mad_resolve_address(l->device, views[i].BufferLocation, &off);
            c->u.vb.off = off;
            c->u.vb.stride = views[i].StrideInBytes;
        }
    }
}
static void STDMETHODCALLTYPE list_DrawInstanced(ID3D12GraphicsCommandList *This,
        UINT vcount, UINT icount, UINT vstart, UINT istart) {
    struct mad_cmd *c = mad_list_push((struct mad_list *)This, MC_DRAW);
    if (!c) return;
    c->u.draw.vcount = vcount; c->u.draw.icount = icount; c->u.draw.vstart = vstart; c->u.draw.istart = istart;
}
static void STDMETHODCALLTYPE list_DrawIndexedInstanced(ID3D12GraphicsCommandList *This,
        UINT icount, UINT inst, UINT start, INT base, UINT istart) {
    struct mad_cmd *c = mad_list_push((struct mad_list *)This, MC_DRAW_INDEXED);
    if (!c) return;
    c->u.drawi.icount = icount; c->u.drawi.inst = inst; c->u.drawi.start = start;
    c->u.drawi.base = base; c->u.drawi.istart = istart;
}
static void STDMETHODCALLTYPE list_Dispatch(ID3D12GraphicsCommandList *This, UINT x, UINT y, UINT z) {
    struct mad_cmd *c = mad_list_push((struct mad_list *)This, MC_DISPATCH);
    if (c) { c->u.dispatch.x = x; c->u.dispatch.y = y; c->u.dispatch.z = z; }
}
static void STDMETHODCALLTYPE list_ResourceBarrier(ID3D12GraphicsCommandList *This, UINT n, const D3D12_RESOURCE_BARRIER *b) {
    /* Metal tracks hazards on these resources itself; the barrier carries no
     * information the encoder needs. Recorded as nothing, deliberately. */
    (void)This; (void)n; (void)b;
}
/* ml889: ExecuteIndirect. D3D12's argument records are byte-for-byte Metal's
 * indirect argument structs (DRAW_ARGUMENTS == MTLDrawPrimitivesIndirectArguments,
 * DRAW_INDEXED_ARGUMENTS == MTLDrawIndexedPrimitivesIndirectArguments,
 * DISPATCH_ARGUMENTS == MTLDispatchThreadgroupsIndirectArguments), so a
 * single-argument signature is one indirect draw/dispatch per record. Metal
 * has no count buffer: MaxCommandCount records are issued, and a record the
 * GPU zeroed draws nothing. Signatures with root-constant/VBV/IBV changes per
 * record are refused by name. */
static void STDMETHODCALLTYPE list_ExecuteIndirect(ID3D12GraphicsCommandList *This, ID3D12CommandSignature *sig,
        UINT max_count, ID3D12Resource *args, UINT64 args_off, ID3D12Resource *count_buf, UINT64 count_off) {
    struct mad_cmdsig *cs = (struct mad_cmdsig *)sig;
    struct mad_cmd *c;
    enum mad_ck kind;
    static unsigned said_multi, said_count, said_big;
    if (!cs || !args || !max_count) return;
    if (cs->desc.NumArgumentDescs != 1) {
        if (said_multi++ < 4) d3d12_log("[madeira-d3d12] ExecuteIndirect: signature with %u argument descs is not implemented; skipped\n", cs->desc.NumArgumentDescs);
        return;
    }
    switch (cs->args[0].Type) {
    case D3D12_INDIRECT_ARGUMENT_TYPE_DRAW: kind = MC_DRAW_INDIRECT; break;
    case D3D12_INDIRECT_ARGUMENT_TYPE_DRAW_INDEXED: kind = MC_DRAW_INDEXED_INDIRECT; break;
    case D3D12_INDIRECT_ARGUMENT_TYPE_DISPATCH: kind = MC_DISPATCH_INDIRECT; break;
    default:
        if (said_multi++ < 4) d3d12_log("[madeira-d3d12] ExecuteIndirect: argument type %u is not implemented; skipped\n", (unsigned)cs->args[0].Type);
        return;
    }
    if (count_buf && said_count++ < 1)
        d3d12_log("[madeira-d3d12] ExecuteIndirect: count buffers are not honoured yet; issuing all %u records\n", max_count);
    if (max_count > 8192) { if (said_big++ < 4) d3d12_log("[madeira-d3d12] ExecuteIndirect: %u records capped at 8192\n", max_count); max_count = 8192; }
    c = mad_list_push((struct mad_list *)This, kind);
    if (!c) return;
    c->u.ind.args = (struct mad_resource *)args; c->u.ind.off = args_off; c->u.ind.count = max_count;
    c->u.ind.stride = cs->desc.ByteStride ? cs->desc.ByteStride : (kind == MC_DRAW_INDIRECT ? 16 : kind == MC_DRAW_INDEXED_INDIRECT ? 20 : 12);
    c->u.ind.cnt = (struct mad_resource *)count_buf; c->u.ind.cnt_off = count_off;
}
static void STDMETHODCALLTYPE list_CopyBufferRegion(ID3D12GraphicsCommandList *This,
        ID3D12Resource *dst, UINT64 dst_off, ID3D12Resource *src, UINT64 src_off, UINT64 len) {
    struct mad_list *l = (struct mad_list *)This;
    struct mad_resource *d = (struct mad_resource *)dst, *s = (struct mad_resource *)src;
    struct mad_cmd *c;
    if (!d || !s || !len) return;
    if (dst_off + len > d->size || src_off + len > s->size) {
        static unsigned said;
        if (!said++) d3d12_log("[madeira-d3d12] CopyBufferRegion out of range; skipped\n");
        return;
    }
    c = mad_list_push(l, MC_COPY_BB);
    if (!c) return;
    c->u.bb.dst = d; c->u.bb.doff = dst_off; c->u.bb.src = s; c->u.bb.soff = src_off; c->u.bb.len = len;
}
static void STDMETHODCALLTYPE list_CopyTextureRegion(ID3D12GraphicsCommandList *This,
        const D3D12_TEXTURE_COPY_LOCATION *dst, UINT x, UINT y, UINT z,
        const D3D12_TEXTURE_COPY_LOCATION *src, const D3D12_BOX *box) {
    struct mad_list *l = (struct mad_list *)This;
    struct mad_resource *d, *s;
    struct mad_cmd *c;
    UINT bytes, block;
    if (!dst || !src) return;
    d = (struct mad_resource *)dst->pResource; s = (struct mad_resource *)src->pResource;
    if (!d || !s) return;
    if (d->texture && !s->texture) {           /* upload: buffer -> texture */
        const D3D12_PLACED_SUBRESOURCE_FOOTPRINT *f = &src->PlacedFootprint;
        UINT w, h, dd;
        c = mad_list_push(l, MC_COPY_B2T);
        if (!c) return;
        mad_subresource(d, dst->SubresourceIndex, &c->u.bt.level, &c->u.bt.slice);
        mad_mip_dims(d, c->u.bt.level, &w, &h, &dd);
        mad_format_info(d->desc.Format, &bytes, &block);
        c->u.bt.tex = d; c->u.bt.buf = s; c->u.bt.off = f->Offset;
        c->u.bt.w = f->Footprint.Width ? f->Footprint.Width : w;
        c->u.bt.h = f->Footprint.Height ? f->Footprint.Height : h;
        c->u.bt.d = f->Footprint.Depth ? f->Footprint.Depth : dd;
        if (box) { c->u.bt.w = box->right - box->left; c->u.bt.h = box->bottom - box->top; c->u.bt.d = box->back - box->front; }
        c->u.bt.row = f->Footprint.RowPitch ? f->Footprint.RowPitch : (UINT)(((c->u.bt.w + block - 1) / block) * bytes);
        c->u.bt.rows = (c->u.bt.h + block - 1) / block;
        c->u.bt.x = x; c->u.bt.y = y; c->u.bt.z = z;
        return;
    }
    if (s->texture && !d->texture) {           /* readback: texture -> buffer */
        const D3D12_PLACED_SUBRESOURCE_FOOTPRINT *f = &dst->PlacedFootprint;
        UINT w, h, dd;
        c = mad_list_push(l, MC_COPY_T2B);
        if (!c) return;
        mad_subresource(s, src->SubresourceIndex, &c->u.bt.level, &c->u.bt.slice);
        mad_mip_dims(s, c->u.bt.level, &w, &h, &dd);
        mad_format_info(s->desc.Format, &bytes, &block);
        c->u.bt.tex = s; c->u.bt.buf = d; c->u.bt.off = f->Offset;
        c->u.bt.w = w; c->u.bt.h = h; c->u.bt.d = dd;
        c->u.bt.x = 0; c->u.bt.y = 0; c->u.bt.z = 0;
        if (box) { c->u.bt.x = box->left; c->u.bt.y = box->top; c->u.bt.z = box->front;
                   c->u.bt.w = box->right - box->left; c->u.bt.h = box->bottom - box->top; c->u.bt.d = box->back - box->front; }
        c->u.bt.row = f->Footprint.RowPitch ? f->Footprint.RowPitch : (UINT)(((c->u.bt.w + block - 1) / block) * bytes);
        c->u.bt.rows = (c->u.bt.h + block - 1) / block;
        return;
    }
    if (s->texture && d->texture) {            /* texture -> texture */
        UINT w, h, dd;
        c = mad_list_push(l, MC_COPY_T2T);
        if (!c) return;
        mad_subresource(d, dst->SubresourceIndex, &c->u.tt.dlevel, &c->u.tt.dslice);
        mad_subresource(s, src->SubresourceIndex, &c->u.tt.slevel, &c->u.tt.sslice);
        mad_mip_dims(s, c->u.tt.slevel, &w, &h, &dd);
        c->u.tt.dst = d; c->u.tt.src = s;
        c->u.tt.dx = x; c->u.tt.dy = y; c->u.tt.dz = z;
        c->u.tt.w = w; c->u.tt.h = h; c->u.tt.d = dd;
        if (box) { c->u.tt.sx = box->left; c->u.tt.sy = box->top; c->u.tt.sz = box->front;
                   c->u.tt.w = box->right - box->left; c->u.tt.h = box->bottom - box->top; c->u.tt.d = box->back - box->front; }
        return;
    }
    list_CopyBufferRegion(This, dst->pResource, 0, src->pResource, 0, s->size < d->size ? s->size : d->size);
}
static void STDMETHODCALLTYPE list_CopyResource(ID3D12GraphicsCommandList *This, ID3D12Resource *dst, ID3D12Resource *src) {
    struct mad_resource *d = (struct mad_resource *)dst, *s = (struct mad_resource *)src;
    if (!d || !s) return;
    if (d->buffer && s->buffer) { list_CopyBufferRegion(This, dst, 0, src, 0, s->size < d->size ? s->size : d->size); return; }
    if (d->texture && s->texture) {
        UINT mips = s->desc.MipLevels ? s->desc.MipLevels : 1;
        UINT layers = (s->desc.Dimension == D3D12_RESOURCE_DIMENSION_TEXTURE3D) ? 1 : (s->desc.DepthOrArraySize ? s->desc.DepthOrArraySize : 1);
        UINT sub, n = mips * layers;
        D3D12_TEXTURE_COPY_LOCATION a, b;
        memset(&a, 0, sizeof a); memset(&b, 0, sizeof b);
        a.pResource = dst; a.Type = D3D12_TEXTURE_COPY_TYPE_SUBRESOURCE_INDEX;
        b.pResource = src; b.Type = D3D12_TEXTURE_COPY_TYPE_SUBRESOURCE_INDEX;
        for (sub = 0; sub < n; sub++) {
            a.SubresourceIndex = sub; b.SubresourceIndex = sub;
            list_CopyTextureRegion(This, &a, 0, 0, 0, &b, NULL);
        }
        return;
    }
    {
        static unsigned said;
        if (!said++) d3d12_log("[madeira-d3d12] CopyResource between a buffer and a texture is not implemented; skipped\n");
    }
}


/* ---- ID3D12Device1..8 methods (ml877) --------------------------------------
 * Everything here is a thin adapter onto the ID3D12Device implementation:
 * DESC1 is DESC plus a sampler-feedback mip region, protected sessions and
 * castable-format lists are accepted only when empty, and the pipeline-state
 * stream is unpacked into the classic descs. */
static void mad_desc1_to_desc(const D3D12_RESOURCE_DESC1 *d1, D3D12_RESOURCE_DESC *d) {
    memcpy(d, d1, sizeof *d);   /* DESC is an exact prefix of DESC1 */
}

static HRESULT STDMETHODCALLTYPE device_CreateCommittedResource1(ID3D12Device10 *This,
        const D3D12_HEAP_PROPERTIES *hp, D3D12_HEAP_FLAGS hf, const D3D12_RESOURCE_DESC *desc,
        D3D12_RESOURCE_STATES state, const D3D12_CLEAR_VALUE *clear,
        ID3D12ProtectedResourceSession *session, REFIID riid, void **out) {
    if (session) return E_NOTIMPL;
    return device_CreateCommittedResource((ID3D12Device *)This, hp, hf, desc, state, clear, riid, out);
}
static HRESULT STDMETHODCALLTYPE device_CreateCommittedResource2(ID3D12Device10 *This,
        const D3D12_HEAP_PROPERTIES *hp, D3D12_HEAP_FLAGS hf, const D3D12_RESOURCE_DESC1 *desc1,
        D3D12_RESOURCE_STATES state, const D3D12_CLEAR_VALUE *clear,
        ID3D12ProtectedResourceSession *session, REFIID riid, void **out) {
    D3D12_RESOURCE_DESC d;
    if (session || !desc1) return E_NOTIMPL;
    mad_desc1_to_desc(desc1, &d);
    return device_CreateCommittedResource((ID3D12Device *)This, hp, hf, &d, state, clear, riid, out);
}
static HRESULT STDMETHODCALLTYPE device_CreateCommittedResource3(ID3D12Device10 *This,
        const D3D12_HEAP_PROPERTIES *hp, D3D12_HEAP_FLAGS hf, const D3D12_RESOURCE_DESC1 *desc1,
        D3D12_BARRIER_LAYOUT layout, const D3D12_CLEAR_VALUE *clear,
        ID3D12ProtectedResourceSession *session, UINT32 ncast, DXGI_FORMAT *cast, REFIID riid, void **out) {
    D3D12_RESOURCE_DESC d;
    (void)layout; (void)cast;
    if (session || ncast || !desc1) return E_NOTIMPL;
    mad_desc1_to_desc(desc1, &d);
    return device_CreateCommittedResource((ID3D12Device *)This, hp, hf, &d, D3D12_RESOURCE_STATE_COMMON, clear, riid, out);
}
static HRESULT STDMETHODCALLTYPE device_CreateHeap1(ID3D12Device10 *This, const D3D12_HEAP_DESC *desc,
        ID3D12ProtectedResourceSession *session, REFIID riid, void **out) {
    if (session) return E_NOTIMPL;
    return device_CreateHeap((ID3D12Device *)This, desc, riid, out);
}
static HRESULT STDMETHODCALLTYPE device_CreatePlacedResource1(ID3D12Device10 *This, ID3D12Heap *heap,
        UINT64 offset, const D3D12_RESOURCE_DESC1 *desc1, D3D12_RESOURCE_STATES state,
        const D3D12_CLEAR_VALUE *clear, REFIID riid, void **out) {
    D3D12_RESOURCE_DESC d;
    if (!desc1) return E_INVALIDARG;
    mad_desc1_to_desc(desc1, &d);
    return device_CreatePlacedResource((ID3D12Device *)This, heap, offset, &d, state, clear, riid, out);
}
static HRESULT STDMETHODCALLTYPE device_CreatePlacedResource2(ID3D12Device10 *This, ID3D12Heap *heap,
        UINT64 offset, const D3D12_RESOURCE_DESC1 *desc1, D3D12_BARRIER_LAYOUT layout,
        const D3D12_CLEAR_VALUE *clear, UINT32 ncast, DXGI_FORMAT *cast, REFIID riid, void **out) {
    D3D12_RESOURCE_DESC d;
    (void)layout; (void)cast;
    if (!desc1 || ncast) return E_NOTIMPL;
    mad_desc1_to_desc(desc1, &d);
    return device_CreatePlacedResource((ID3D12Device *)This, heap, offset, &d, D3D12_RESOURCE_STATE_COMMON, clear, riid, out);
}
static D3D12_RESOURCE_ALLOCATION_INFO * STDMETHODCALLTYPE device_GetResourceAllocationInfo1(ID3D12Device10 *This,
        D3D12_RESOURCE_ALLOCATION_INFO *ret, UINT visible, UINT n, const D3D12_RESOURCE_DESC *descs,
        D3D12_RESOURCE_ALLOCATION_INFO1 *info1) {
    /* The total comes from the base method; per-resource offsets are laid out
     * sequentially with each resource at its own alignment. */
    UINT64 off = 0, align = 0; UINT i;
    memset(ret, 0, sizeof *ret);
    if (!descs || !n) return ret;
    for (i = 0; i < n; i++) {
        D3D12_RESOURCE_ALLOCATION_INFO one;
        device_GetResourceAllocationInfo((ID3D12Device *)This, &one, visible, 1, &descs[i]);
        if (one.Alignment > align) align = one.Alignment;
        if (one.Alignment) off = (off + one.Alignment - 1) & ~(one.Alignment - 1);
        if (info1) { info1[i].Offset = off; info1[i].Alignment = one.Alignment; info1[i].SizeInBytes = one.SizeInBytes; }
        off += one.SizeInBytes;
    }
    ret->SizeInBytes = off; ret->Alignment = align;
    return ret;
}
static D3D12_RESOURCE_ALLOCATION_INFO * STDMETHODCALLTYPE device_GetResourceAllocationInfo2(ID3D12Device10 *This,
        D3D12_RESOURCE_ALLOCATION_INFO *ret, UINT visible, UINT n, const D3D12_RESOURCE_DESC1 *descs1,
        D3D12_RESOURCE_ALLOCATION_INFO1 *info1) {
    D3D12_RESOURCE_DESC stackd[8], *d = stackd; UINT i;
    memset(ret, 0, sizeof *ret);
    if (!descs1 || !n) return ret;
    if (n > 8) { d = calloc(n, sizeof *d); if (!d) return ret; }
    for (i = 0; i < n; i++) mad_desc1_to_desc(&descs1[i], &d[i]);
    device_GetResourceAllocationInfo1(This, ret, visible, n, d, info1);
    if (d != stackd) free(d);
    return ret;
}
static void STDMETHODCALLTYPE device_GetCopyableFootprints1(ID3D12Device10 *This, const D3D12_RESOURCE_DESC1 *desc1,
        UINT first, UINT count, UINT64 base, D3D12_PLACED_SUBRESOURCE_FOOTPRINT *layouts, UINT *rows,
        UINT64 *rowbytes, UINT64 *total) {
    D3D12_RESOURCE_DESC d;
    if (!desc1) return;
    mad_desc1_to_desc(desc1, &d);
    device_GetCopyableFootprints((ID3D12Device *)This, &d, first, count, base, layouts, rows, rowbytes, total);
}
static HRESULT STDMETHODCALLTYPE device_CreateCommandQueue1(ID3D12Device10 *This, const D3D12_COMMAND_QUEUE_DESC *desc,
        REFIID creator, REFIID riid, void **out) {
    (void)creator;
    return device_CreateCommandQueue((ID3D12Device *)This, desc, riid, out);
}
/* A list born closed: no allocator until the first Reset, which list_Reset
 * already handles (it adopts the allocator it is given). */
static HRESULT STDMETHODCALLTYPE device_CreateCommandList1(ID3D12Device10 *This, UINT node,
        D3D12_COMMAND_LIST_TYPE type, D3D12_COMMAND_LIST_FLAGS flags, REFIID riid, void **out) {
    (void)node;
    if (!out) return E_INVALIDARG;
    if (flags != D3D12_COMMAND_LIST_FLAG_NONE) return E_INVALIDARG;
    if (!mad_list_type_ok(type)) return E_NOTIMPL;
    struct mad_list *l = calloc(1, sizeof *l);
    if (!l) return E_OUTOFMEMORY;
    l->type = type;
    l->vtbl = &g_list_vtbl; l->refs = 1; l->iid = &IID_ID3D12GraphicsCommandList; l->name = "GraphicsCommandList";
    l->device = (struct mad_device *)This;
    l->closed = 1;
    HRESULT hr = list_QI((ID3D12GraphicsCommandList *)l, riid, out);
    list_Release((ID3D12GraphicsCommandList *)l);
    return hr;
}
static HRESULT STDMETHODCALLTYPE device_SetResidencyPriority(ID3D12Device10 *This, UINT n,
        ID3D12Pageable *const *objs, const D3D12_RESIDENCY_PRIORITY *prio) {
    (void)This; (void)n; (void)objs; (void)prio;
    return S_OK;                     /* unified memory: everything is resident */
}
static HRESULT STDMETHODCALLTYPE device_EnqueueMakeResident(ID3D12Device10 *This, D3D12_RESIDENCY_FLAGS flags,
        UINT n, ID3D12Pageable *const *objs, ID3D12Fence *fence, UINT64 value) {
    (void)This; (void)flags; (void)n; (void)objs;
    if (!fence) return E_INVALIDARG;
    return fence_Signal(fence, value);   /* resident already; complete the request at once */
}
static void STDMETHODCALLTYPE device_RemoveDevice(ID3D12Device10 *This) {
    struct mad_device *d = (struct mad_device *)This;
    d3d12_log("[madeira-d3d12] RemoveDevice requested by the application\n");
    InterlockedExchange(&d->device_lost, 1);
}
static HRESULT STDMETHODCALLTYPE device_SetBackgroundProcessingMode(ID3D12Device10 *This,
        D3D12_BACKGROUND_PROCESSING_MODE mode, D3D12_MEASUREMENTS_ACTION action, HANDLE event, WINBOOL *further) {
    (void)This; (void)mode; (void)action;
    if (further) *further = FALSE;
    if (event) SetEvent(event);
    return S_OK;
}
/* Multiple-fence waits: one helper thread per request. ALL waits each fence in
 * turn (order is irrelevant for the conjunction); ANY spawns one waiter per
 * fence and the first to finish signals the event (later ones re-signal, which
 * is harmless for an auto-reset or manual event alike). */
struct mad_multiwait { ID3D12Fence *fence; UINT64 value; HANDLE event; unsigned n; ID3D12Fence **fences; UINT64 *values; };
static DWORD WINAPI mad_multiwait_all(void *arg) {
    struct mad_multiwait *w = arg; unsigned i;
    for (i = 0; i < w->n; i++) { fence_SetEventOnCompletion(w->fences[i], w->values[i], NULL); ID3D12Fence_Release(w->fences[i]); }
    SetEvent(w->event);
    free(w->fences); free(w->values); free(w);
    return 0;
}
static DWORD WINAPI mad_multiwait_one(void *arg) {
    struct mad_multiwait *w = arg;
    fence_SetEventOnCompletion(w->fence, w->value, NULL);
    SetEvent(w->event);
    ID3D12Fence_Release(w->fence);
    free(w);
    return 0;
}
static HRESULT STDMETHODCALLTYPE device_SetEventOnMultipleFenceCompletion(ID3D12Device10 *This,
        ID3D12Fence *const *fences, const UINT64 *values, UINT n, D3D12_MULTIPLE_FENCE_WAIT_FLAGS flags, HANDLE event) {
    unsigned i;
    (void)This;
    if (!fences || !values || !n || !event) return E_INVALIDARG;
    if (flags & D3D12_MULTIPLE_FENCE_WAIT_FLAG_ANY) {
        for (i = 0; i < n; i++) {
            struct mad_multiwait *w = calloc(1, sizeof *w);
            HANDLE t;
            if (!w) return E_OUTOFMEMORY;
            w->fence = fences[i]; w->value = values[i]; w->event = event;
            ID3D12Fence_AddRef(w->fence);
            t = CreateThread(NULL, 0, mad_multiwait_one, w, 0, NULL);
            if (!t) { ID3D12Fence_Release(w->fence); free(w); return E_FAIL; }
            CloseHandle(t);
        }
        return S_OK;
    } else {
        struct mad_multiwait *w = calloc(1, sizeof *w);
        HANDLE t;
        if (!w) return E_OUTOFMEMORY;
        w->n = n; w->event = event;
        w->fences = calloc(n, sizeof *w->fences); w->values = calloc(n, sizeof *w->values);
        if (!w->fences || !w->values) { free(w->fences); free(w->values); free(w); return E_OUTOFMEMORY; }
        for (i = 0; i < n; i++) { w->fences[i] = fences[i]; w->values[i] = values[i]; ID3D12Fence_AddRef(fences[i]); }
        t = CreateThread(NULL, 0, mad_multiwait_all, w, 0, NULL);
        if (!t) { for (i = 0; i < n; i++) ID3D12Fence_Release(fences[i]); free(w->fences); free(w->values); free(w); return E_FAIL; }
        CloseHandle(t);
        return S_OK;
    }
}

/* Pipeline-state stream (ID3D12Device2). Each subobject is a UINT type tag
 * followed by its payload at the payload's own alignment, and the next
 * subobject starts pointer-aligned -- the layout of D3DX12's
 * CD3DX12_PIPELINE_STATE_STREAM_SUBOBJECT. The stream is unpacked into the
 * classic graphics/compute descs and handed to the existing creators. */
static HRESULT STDMETHODCALLTYPE device_CreatePipelineState(ID3D12Device10 *This,
        const D3D12_PIPELINE_STATE_STREAM_DESC *sd, REFIID riid, void **out) {
    D3D12_GRAPHICS_PIPELINE_STATE_DESC g;
    D3D12_COMPUTE_PIPELINE_STATE_DESC c;
    const BYTE *p; SIZE_T off = 0;
    int have_cs = 0, have_gfx = 0;
    unsigned i;
    if (!sd || !sd->pPipelineStateSubobjectStream || !out) return E_INVALIDARG;
    memset(&g, 0, sizeof g); memset(&c, 0, sizeof c);
    /* defaults match D3DX12's CD3DX12_DEFAULT helpers */
    g.SampleMask = 0xffffffffu;
    g.SampleDesc.Count = 1;
    g.RasterizerState.FillMode = D3D12_FILL_MODE_SOLID;
    g.RasterizerState.CullMode = D3D12_CULL_MODE_BACK;
    g.RasterizerState.DepthClipEnable = TRUE;
    g.DepthStencilState.DepthEnable = TRUE;
    g.DepthStencilState.DepthWriteMask = D3D12_DEPTH_WRITE_MASK_ALL;
    g.DepthStencilState.DepthFunc = D3D12_COMPARISON_FUNC_LESS;
    g.DepthStencilState.StencilReadMask = 0xff; g.DepthStencilState.StencilWriteMask = 0xff;
    g.DepthStencilState.FrontFace.StencilFunc = g.DepthStencilState.BackFace.StencilFunc = D3D12_COMPARISON_FUNC_ALWAYS;
    g.DepthStencilState.FrontFace.StencilFailOp = g.DepthStencilState.FrontFace.StencilDepthFailOp =
        g.DepthStencilState.FrontFace.StencilPassOp = D3D12_STENCIL_OP_KEEP;
    g.DepthStencilState.BackFace = g.DepthStencilState.FrontFace;
    for (i = 0; i < 8; i++) {
        g.BlendState.RenderTarget[i].SrcBlend = D3D12_BLEND_ONE; g.BlendState.RenderTarget[i].DestBlend = D3D12_BLEND_ZERO;
        g.BlendState.RenderTarget[i].BlendOp = D3D12_BLEND_OP_ADD;
        g.BlendState.RenderTarget[i].SrcBlendAlpha = D3D12_BLEND_ONE; g.BlendState.RenderTarget[i].DestBlendAlpha = D3D12_BLEND_ZERO;
        g.BlendState.RenderTarget[i].BlendOpAlpha = D3D12_BLEND_OP_ADD;
        g.BlendState.RenderTarget[i].LogicOp = D3D12_LOGIC_OP_NOOP;
        g.BlendState.RenderTarget[i].RenderTargetWriteMask = D3D12_COLOR_WRITE_ENABLE_ALL;
    }
    g.PrimitiveTopologyType = D3D12_PRIMITIVE_TOPOLOGY_TYPE_UNDEFINED;

    p = sd->pPipelineStateSubobjectStream;
    while (off + sizeof(UINT) <= sd->SizeInBytes) {
        UINT t = *(const UINT *)(p + off);
        SIZE_T sz, al;
        const void *pl;
#define SUB(type_) do { sz = sizeof(type_); al = _Alignof(type_); } while (0)
        switch (t) {
        case D3D12_PIPELINE_STATE_SUBOBJECT_TYPE_ROOT_SIGNATURE:      SUB(ID3D12RootSignature *); break;
        case D3D12_PIPELINE_STATE_SUBOBJECT_TYPE_VS: case D3D12_PIPELINE_STATE_SUBOBJECT_TYPE_PS:
        case D3D12_PIPELINE_STATE_SUBOBJECT_TYPE_DS: case D3D12_PIPELINE_STATE_SUBOBJECT_TYPE_HS:
        case D3D12_PIPELINE_STATE_SUBOBJECT_TYPE_GS: case D3D12_PIPELINE_STATE_SUBOBJECT_TYPE_CS:
        case D3D12_PIPELINE_STATE_SUBOBJECT_TYPE_AS: case D3D12_PIPELINE_STATE_SUBOBJECT_TYPE_MS:
                                                                        SUB(D3D12_SHADER_BYTECODE); break;
        case D3D12_PIPELINE_STATE_SUBOBJECT_TYPE_STREAM_OUTPUT:       SUB(D3D12_STREAM_OUTPUT_DESC); break;
        case D3D12_PIPELINE_STATE_SUBOBJECT_TYPE_BLEND:               SUB(D3D12_BLEND_DESC); break;
        case D3D12_PIPELINE_STATE_SUBOBJECT_TYPE_SAMPLE_MASK:         SUB(UINT); break;
        case D3D12_PIPELINE_STATE_SUBOBJECT_TYPE_RASTERIZER:          SUB(D3D12_RASTERIZER_DESC); break;
        case D3D12_PIPELINE_STATE_SUBOBJECT_TYPE_DEPTH_STENCIL:       SUB(D3D12_DEPTH_STENCIL_DESC); break;
        case D3D12_PIPELINE_STATE_SUBOBJECT_TYPE_INPUT_LAYOUT:        SUB(D3D12_INPUT_LAYOUT_DESC); break;
        case D3D12_PIPELINE_STATE_SUBOBJECT_TYPE_IB_STRIP_CUT_VALUE:  SUB(UINT); break;
        case D3D12_PIPELINE_STATE_SUBOBJECT_TYPE_PRIMITIVE_TOPOLOGY:  SUB(UINT); break;
        case D3D12_PIPELINE_STATE_SUBOBJECT_TYPE_RENDER_TARGET_FORMATS: SUB(struct D3D12_RT_FORMAT_ARRAY); break;
        case D3D12_PIPELINE_STATE_SUBOBJECT_TYPE_DEPTH_STENCIL_FORMAT: SUB(DXGI_FORMAT); break;
        case D3D12_PIPELINE_STATE_SUBOBJECT_TYPE_SAMPLE_DESC:         SUB(DXGI_SAMPLE_DESC); break;
        case D3D12_PIPELINE_STATE_SUBOBJECT_TYPE_NODE_MASK:           SUB(UINT); break;
        case D3D12_PIPELINE_STATE_SUBOBJECT_TYPE_CACHED_PSO:          SUB(D3D12_CACHED_PIPELINE_STATE); break;
        case D3D12_PIPELINE_STATE_SUBOBJECT_TYPE_FLAGS:               SUB(UINT); break;
        case D3D12_PIPELINE_STATE_SUBOBJECT_TYPE_DEPTH_STENCIL1:      SUB(D3D12_DEPTH_STENCIL_DESC1); break;
        case D3D12_PIPELINE_STATE_SUBOBJECT_TYPE_VIEW_INSTANCING:     SUB(D3D12_VIEW_INSTANCING_DESC); break;
        default:
            d3d12_log("[madeira-d3d12] CreatePipelineState: unknown subobject type %u at offset %u; refused\n",
                      t, (unsigned)off);
            return E_INVALIDARG;
        }
#undef SUB
        off = (off + sizeof(UINT) + al - 1) & ~(al - 1);      /* payload at its own alignment */
        if (off + sz > sd->SizeInBytes) return E_INVALIDARG;
        pl = p + off;
        switch (t) {
        case D3D12_PIPELINE_STATE_SUBOBJECT_TYPE_ROOT_SIGNATURE: g.pRootSignature = c.pRootSignature = *(ID3D12RootSignature *const *)pl; break;
        case D3D12_PIPELINE_STATE_SUBOBJECT_TYPE_VS: g.VS = *(const D3D12_SHADER_BYTECODE *)pl; if (g.VS.BytecodeLength) have_gfx = 1; break;
        case D3D12_PIPELINE_STATE_SUBOBJECT_TYPE_PS: g.PS = *(const D3D12_SHADER_BYTECODE *)pl; break;
        case D3D12_PIPELINE_STATE_SUBOBJECT_TYPE_DS: g.DS = *(const D3D12_SHADER_BYTECODE *)pl; break;
        case D3D12_PIPELINE_STATE_SUBOBJECT_TYPE_HS: g.HS = *(const D3D12_SHADER_BYTECODE *)pl; break;
        case D3D12_PIPELINE_STATE_SUBOBJECT_TYPE_GS: g.GS = *(const D3D12_SHADER_BYTECODE *)pl; break;
        case D3D12_PIPELINE_STATE_SUBOBJECT_TYPE_CS: c.CS = *(const D3D12_SHADER_BYTECODE *)pl; if (c.CS.BytecodeLength) have_cs = 1; break;
        case D3D12_PIPELINE_STATE_SUBOBJECT_TYPE_AS: case D3D12_PIPELINE_STATE_SUBOBJECT_TYPE_MS:
            if (((const D3D12_SHADER_BYTECODE *)pl)->BytecodeLength) {
                d3d12_log("[madeira-d3d12] CreatePipelineState: mesh/amplification shader stages are not implemented\n");
                return E_NOTIMPL;
            }
            break;
        case D3D12_PIPELINE_STATE_SUBOBJECT_TYPE_STREAM_OUTPUT: g.StreamOutput = *(const D3D12_STREAM_OUTPUT_DESC *)pl; break;
        case D3D12_PIPELINE_STATE_SUBOBJECT_TYPE_BLEND: g.BlendState = *(const D3D12_BLEND_DESC *)pl; break;
        case D3D12_PIPELINE_STATE_SUBOBJECT_TYPE_SAMPLE_MASK: g.SampleMask = *(const UINT *)pl; break;
        case D3D12_PIPELINE_STATE_SUBOBJECT_TYPE_RASTERIZER: g.RasterizerState = *(const D3D12_RASTERIZER_DESC *)pl; break;
        case D3D12_PIPELINE_STATE_SUBOBJECT_TYPE_DEPTH_STENCIL: g.DepthStencilState = *(const D3D12_DEPTH_STENCIL_DESC *)pl; break;
        case D3D12_PIPELINE_STATE_SUBOBJECT_TYPE_DEPTH_STENCIL1:
            memcpy(&g.DepthStencilState, pl, sizeof g.DepthStencilState);   /* DESC is a prefix of DESC1 */
            break;
        case D3D12_PIPELINE_STATE_SUBOBJECT_TYPE_INPUT_LAYOUT: g.InputLayout = *(const D3D12_INPUT_LAYOUT_DESC *)pl; break;
        case D3D12_PIPELINE_STATE_SUBOBJECT_TYPE_IB_STRIP_CUT_VALUE: g.IBStripCutValue = *(const UINT *)pl; break;
        case D3D12_PIPELINE_STATE_SUBOBJECT_TYPE_PRIMITIVE_TOPOLOGY: g.PrimitiveTopologyType = *(const UINT *)pl; break;
        case D3D12_PIPELINE_STATE_SUBOBJECT_TYPE_RENDER_TARGET_FORMATS: {
            const struct D3D12_RT_FORMAT_ARRAY *r = pl;
            g.NumRenderTargets = r->NumRenderTargets;
            for (i = 0; i < 8; i++) g.RTVFormats[i] = r->RTFormats[i];
            break;
        }
        case D3D12_PIPELINE_STATE_SUBOBJECT_TYPE_DEPTH_STENCIL_FORMAT: g.DSVFormat = *(const DXGI_FORMAT *)pl; break;
        case D3D12_PIPELINE_STATE_SUBOBJECT_TYPE_SAMPLE_DESC: g.SampleDesc = *(const DXGI_SAMPLE_DESC *)pl; break;
        case D3D12_PIPELINE_STATE_SUBOBJECT_TYPE_NODE_MASK: g.NodeMask = c.NodeMask = *(const UINT *)pl; break;
        case D3D12_PIPELINE_STATE_SUBOBJECT_TYPE_CACHED_PSO: g.CachedPSO = c.CachedPSO = *(const D3D12_CACHED_PIPELINE_STATE *)pl; break;
        case D3D12_PIPELINE_STATE_SUBOBJECT_TYPE_FLAGS: g.Flags = c.Flags = *(const UINT *)pl; break;
        case D3D12_PIPELINE_STATE_SUBOBJECT_TYPE_VIEW_INSTANCING: {
            const D3D12_VIEW_INSTANCING_DESC *v = pl;
            if (v->ViewInstanceCount > 1) {
                d3d12_log("[madeira-d3d12] CreatePipelineState: view instancing (%u views) is not implemented\n", v->ViewInstanceCount);
                return E_NOTIMPL;
            }
            break;
        }
        }
        off = (off + sz + sizeof(void *) - 1) & ~(sizeof(void *) - 1);   /* next subobject: pointer-aligned */
    }
    if (have_cs && !have_gfx) return device_CreateComputePipelineState((ID3D12Device *)This, &c, riid, out);
    if (have_gfx) return device_CreateGraphicsPipelineState((ID3D12Device *)This, &g, riid, out);
    d3d12_log("[madeira-d3d12] CreatePipelineState: stream carried no VS and no CS; refused\n");
    return E_INVALIDARG;
}

/* ml887: ID3D12DeviceChild::GetDevice for every child. UE 5.4 calls
 * Resource->GetDevice(IID_ID3D12Device, &dev) then dev->GetCopyableFootprints
 * while streaming textures; the generated stub left the out-pointer null and
 * three background workers dereferenced it. */
static HRESULT mad_child_get_device(struct mad_device *d, REFIID riid, void **out) {
    if (!out) return E_POINTER;
    *out = NULL;
    if (!d) d = g_last_device;
    if (!d) return E_FAIL;
    return d->vtbl->QueryInterface((ID3D12Device10 *)d, riid, out);
}
static HRESULT STDMETHODCALLTYPE res_GetDevice(ID3D12Resource2 *This, REFIID riid, void **out) {
    return mad_child_get_device(((struct mad_resource *)This)->owner, riid, out);
}
static HRESULT STDMETHODCALLTYPE list_GetDevice(ID3D12GraphicsCommandList *This, REFIID riid, void **out) {
    return mad_child_get_device(((struct mad_list *)This)->device, riid, out);
}
static HRESULT STDMETHODCALLTYPE queue_GetDevice(ID3D12CommandQueue *This, REFIID riid, void **out) {
    return mad_child_get_device(((struct mad_queue *)This)->device, riid, out);
}
static HRESULT STDMETHODCALLTYPE heap_GetDevice(ID3D12DescriptorHeap *This, REFIID riid, void **out) {
    return mad_child_get_device(((struct mad_heap *)This)->owner, riid, out);
}
static HRESULT STDMETHODCALLTYPE alloc_GetDevice(ID3D12CommandAllocator *This, REFIID riid, void **out) {
    (void)This; return mad_child_get_device(NULL, riid, out);
}
static HRESULT STDMETHODCALLTYPE fence_GetDevice(ID3D12Fence *This, REFIID riid, void **out) {
    (void)This; return mad_child_get_device(NULL, riid, out);
}
static HRESULT STDMETHODCALLTYPE pso_GetDevice(ID3D12PipelineState *This, REFIID riid, void **out) {
    (void)This; return mad_child_get_device(NULL, riid, out);
}
static HRESULT STDMETHODCALLTYPE rootsig_GetDevice(ID3D12RootSignature *This, REFIID riid, void **out) {
    (void)This; return mad_child_get_device(NULL, riid, out);
}

/* ---- vtable construction ------------------------------------------------- */
static void build_vtables(void) {
    static LONG done;
    if (InterlockedCompareExchange(&done, 1, 0) != 0) return;

    madeira_fill_ID3D12Device10(&g_device_vtbl);
    /* ml877: ID3D12Device1..8 */
    g_device_vtbl.CreatePipelineState                = device_CreatePipelineState;
    g_device_vtbl.CreateCommandList1                 = device_CreateCommandList1;
    g_device_vtbl.CreateCommittedResource1           = device_CreateCommittedResource1;
    g_device_vtbl.CreateCommittedResource2           = device_CreateCommittedResource2;
    g_device_vtbl.CreateCommittedResource3           = device_CreateCommittedResource3;
    g_device_vtbl.CreateHeap1                        = device_CreateHeap1;
    g_device_vtbl.CreatePlacedResource1              = device_CreatePlacedResource1;
    g_device_vtbl.CreatePlacedResource2              = device_CreatePlacedResource2;
    g_device_vtbl.GetResourceAllocationInfo1         = device_GetResourceAllocationInfo1;
    g_device_vtbl.GetResourceAllocationInfo2         = device_GetResourceAllocationInfo2;
    g_device_vtbl.GetCopyableFootprints1             = device_GetCopyableFootprints1;
    g_device_vtbl.CreateCommandQueue1                = device_CreateCommandQueue1;
    g_device_vtbl.SetResidencyPriority               = device_SetResidencyPriority;
    g_device_vtbl.EnqueueMakeResident                = device_EnqueueMakeResident;
    g_device_vtbl.RemoveDevice                       = device_RemoveDevice;
    g_device_vtbl.SetBackgroundProcessingMode        = device_SetBackgroundProcessingMode;
    g_device_vtbl.SetEventOnMultipleFenceCompletion  = device_SetEventOnMultipleFenceCompletion;
    g_device_vtbl.QueryInterface = (void *)device_QI;
    g_device_vtbl.AddRef = (void *)device_AddRef;
    g_device_vtbl.Release = (void *)device_Release;
    g_device_vtbl.GetNodeCount = (void *)device_GetNodeCount;
    g_device_vtbl.CreateCommandQueue = (void *)device_CreateCommandQueue;
    g_device_vtbl.CreateCommandAllocator = (void *)device_CreateCommandAllocator;
    g_device_vtbl.CreateCommandList = (void *)device_CreateCommandList;
    g_device_vtbl.CreateFence = (void *)device_CreateFence;
    g_device_vtbl.CreateCommandSignature = (void *)device_CreateCommandSignature;
    g_device_vtbl.CreateQueryHeap = (void *)device_CreateQueryHeap;
    g_device_vtbl.CreateHeap = (void *)device_CreateHeap;
    g_device_vtbl.CreatePlacedResource = (void *)device_CreatePlacedResource;
    g_memheap_vtbl.QueryInterface          = memheap_QI;
    g_memheap_vtbl.AddRef                  = memheap_AddRef;
    g_memheap_vtbl.Release                 = memheap_Release;
    g_memheap_vtbl.GetPrivateData          = memheap_GetPrivateData;
    g_memheap_vtbl.SetPrivateData          = memheap_SetPrivateData;
    g_memheap_vtbl.SetPrivateDataInterface = memheap_SetPrivateDataInterface;
    g_memheap_vtbl.SetName                 = memheap_SetName;
    g_memheap_vtbl.GetDevice               = memheap_GetDevice;
    g_memheap_vtbl.GetDesc                 = memheap_GetDesc;
    g_device_vtbl.CreateConstantBufferView = (void *)device_CreateConstantBufferView;
    g_device_vtbl.CreateUnorderedAccessView = (void *)device_CreateUnorderedAccessView;
    g_device_vtbl.CopyDescriptors = (void *)device_CopyDescriptors;
    g_device_vtbl.CopyDescriptorsSimple = (void *)device_CopyDescriptorsSimple;
    g_device_vtbl.GetCopyableFootprints = (void *)device_GetCopyableFootprints;
    g_device_vtbl.GetResourceAllocationInfo = (void *)device_GetResourceAllocationInfo;
    g_qheap_vtbl.QueryInterface          = qheap_QI;
    g_qheap_vtbl.AddRef                  = qheap_AddRef;
    g_qheap_vtbl.Release                 = qheap_Release;
    g_qheap_vtbl.GetPrivateData          = qheap_GetPrivateData;
    g_qheap_vtbl.SetPrivateData          = qheap_SetPrivateData;
    g_qheap_vtbl.SetPrivateDataInterface = qheap_SetPrivateDataInterface;
    g_qheap_vtbl.SetName                 = qheap_SetName;
    g_qheap_vtbl.GetDevice               = qheap_GetDevice;

    g_cmdsig_vtbl.QueryInterface          = cmdsig_QI;
    g_cmdsig_vtbl.AddRef                  = cmdsig_AddRef;
    g_cmdsig_vtbl.Release                 = cmdsig_Release;
    g_cmdsig_vtbl.GetPrivateData          = cmdsig_GetPrivateData;
    g_cmdsig_vtbl.SetPrivateData          = cmdsig_SetPrivateData;
    g_cmdsig_vtbl.SetPrivateDataInterface = cmdsig_SetPrivateDataInterface;
    g_cmdsig_vtbl.SetName                 = cmdsig_SetName;
    g_cmdsig_vtbl.GetDevice               = cmdsig_GetDevice;
    g_device_vtbl.CreateCommittedResource = (void *)device_CreateCommittedResource;
    g_device_vtbl.CreateRootSignature = (void *)device_CreateRootSignature;
    g_device_vtbl.CreateDescriptorHeap = (void *)device_CreateDescriptorHeap;
    g_device_vtbl.CreateRenderTargetView = (void *)device_CreateRenderTargetView;
    g_device_vtbl.CreateDepthStencilView = (void *)device_CreateDepthStencilView;
    g_device_vtbl.CreateShaderResourceView = (void *)device_CreateShaderResourceView;
    g_device_vtbl.CreateSampler = (void *)device_CreateSampler;
    g_device_vtbl.GetDescriptorHandleIncrementSize = (void *)device_GetDescriptorHandleIncrementSize;
    g_device_vtbl.CreateGraphicsPipelineState = (void *)device_CreateGraphicsPipelineState;
    g_device_vtbl.CheckFeatureSupport = (void *)device_CheckFeatureSupport;

    madeira_fill_ID3D12CommandQueue(&g_queue_vtbl);
    g_queue_vtbl.GetDevice = queue_GetDevice;
    g_queue_vtbl.QueryInterface         = queue_QI;
    g_queue_vtbl.AddRef                 = queue_AddRef;
    g_queue_vtbl.Release                = queue_Release;
    g_queue_vtbl.ExecuteCommandLists    = queue_ExecuteCommandLists;
    g_queue_vtbl.Signal                 = queue_Signal;
    g_queue_vtbl.Wait                   = queue_Wait;
    g_queue_vtbl.GetTimestampFrequency  = queue_GetTimestampFrequency;
    g_queue_vtbl.GetClockCalibration    = queue_GetClockCalibration;
    g_queue_vtbl.GetDesc                = queue_GetDesc;

    madeira_fill_ID3D12CommandAllocator(&g_alloc_vtbl);
    g_alloc_vtbl.GetDevice = alloc_GetDevice;
    g_alloc_vtbl.QueryInterface         = alloc_QI;
    g_alloc_vtbl.AddRef                 = alloc_AddRef;
    g_alloc_vtbl.Release                = alloc_Release;
    g_alloc_vtbl.Reset                  = alloc_Reset;

    madeira_fill_ID3D12Resource2(&g_res_vtbl);
    g_res_vtbl.GetDevice = res_GetDevice;
    g_res_vtbl.GetDesc1 = (void *)res_GetDesc1;
    g_res_vtbl.QueryInterface = (void *)res_QI;
    g_res_vtbl.AddRef = (void *)res_AddRef;
    g_res_vtbl.Release = (void *)res_Release;
    g_res_vtbl.Map = (void *)res_Map;
    g_res_vtbl.Unmap = (void *)res_Unmap;
    g_res_vtbl.GetGPUVirtualAddress = (void *)res_GetGPUVirtualAddress;
    g_res_vtbl.GetDesc = (void *)res_GetDesc;

    madeira_fill_ID3D12GraphicsCommandList(&g_list_vtbl);
    g_list_vtbl.GetDevice = list_GetDevice;
    g_list_vtbl.QueryInterface          = list_QI;
    g_list_vtbl.AddRef                  = list_AddRef;
    g_list_vtbl.Release                 = list_Release;
    g_list_vtbl.Close                   = list_Close;
    g_list_vtbl.Reset                   = list_Reset;
    g_list_vtbl.GetType                 = list_GetType;
    g_list_vtbl.CopyBufferRegion        = list_CopyBufferRegion;
    g_list_vtbl.OMSetRenderTargets      = list_OMSetRenderTargets;
    g_list_vtbl.ClearRenderTargetView   = list_ClearRenderTargetView;
    g_list_vtbl.SetPipelineState        = list_SetPipelineState;
    g_list_vtbl.SetGraphicsRootSignature= list_SetGraphicsRootSignature;
    g_list_vtbl.SetGraphicsRootConstantBufferView = list_SetGraphicsRootConstantBufferView;
    g_list_vtbl.SetGraphicsRootDescriptorTable = list_SetGraphicsRootDescriptorTable;
    g_list_vtbl.SetDescriptorHeaps      = list_SetDescriptorHeaps;
    g_list_vtbl.RSSetViewports          = list_RSSetViewports;
    g_list_vtbl.RSSetScissorRects       = list_RSSetScissorRects;
    g_list_vtbl.IASetVertexBuffers      = list_IASetVertexBuffers;
    g_list_vtbl.OMSetStencilRef         = list_OMSetStencilRef;
    g_list_vtbl.SetComputeRootSignature            = list_SetComputeRootSignature;
    g_list_vtbl.SetComputeRootConstantBufferView   = list_SetComputeRootConstantBufferView;
    g_list_vtbl.SetComputeRootShaderResourceView   = list_SetComputeRootShaderResourceView;
    g_list_vtbl.SetComputeRootUnorderedAccessView  = list_SetComputeRootUnorderedAccessView;
    g_list_vtbl.SetComputeRootDescriptorTable      = list_SetComputeRootDescriptorTable;
    g_list_vtbl.SetComputeRoot32BitConstant        = list_SetComputeRoot32BitConstant;
    g_list_vtbl.SetComputeRoot32BitConstants       = list_SetComputeRoot32BitConstants;
    g_device_vtbl.CreateComputePipelineState = (void *)device_CreateComputePipelineState;
    g_list_vtbl.CopyResource            = list_CopyResource;
    g_list_vtbl.ResourceBarrier         = list_ResourceBarrier;
    g_list_vtbl.Dispatch                = list_Dispatch;
    g_list_vtbl.ExecuteIndirect         = list_ExecuteIndirect;
    g_list_vtbl.SetGraphicsRootShaderResourceView  = list_SetGraphicsRootShaderResourceView;
    g_list_vtbl.SetGraphicsRootUnorderedAccessView = list_SetGraphicsRootUnorderedAccessView;
    g_list_vtbl.SetGraphicsRoot32BitConstant       = list_SetGraphicsRoot32BitConstant;
    g_list_vtbl.SetGraphicsRoot32BitConstants      = list_SetGraphicsRoot32BitConstants;
    g_list_vtbl.ClearUnorderedAccessViewUint  = list_ClearUnorderedAccessViewUint;
    g_list_vtbl.ClearUnorderedAccessViewFloat = list_ClearUnorderedAccessViewFloat;
    g_list_vtbl.OMSetBlendFactor              = list_OMSetBlendFactor;
    g_list_vtbl.DiscardResource               = list_DiscardResource;
    g_list_vtbl.BeginQuery              = list_BeginQuery;
    g_list_vtbl.EndQuery                = list_EndQuery;
    g_list_vtbl.ResolveQueryData        = list_ResolveQueryData;
    g_list_vtbl.IASetPrimitiveTopology  = list_IASetPrimitiveTopology;
    g_list_vtbl.DrawInstanced           = list_DrawInstanced;
    g_list_vtbl.CopyTextureRegion       = list_CopyTextureRegion;
    g_list_vtbl.IASetIndexBuffer        = list_IASetIndexBuffer;
    g_list_vtbl.DrawIndexedInstanced    = list_DrawIndexedInstanced;
    g_list_vtbl.ClearDepthStencilView   = list_ClearDepthStencilView;

    madeira_fill_ID3D12RootSignature(&g_rootsig_vtbl);
    g_rootsig_vtbl.GetDevice = rootsig_GetDevice;
    g_rootsig_vtbl.QueryInterface = rootsig_QI;
    g_rootsig_vtbl.AddRef = rootsig_AddRef;
    g_rootsig_vtbl.Release = rootsig_Release;

    madeira_fill_ID3D12PipelineState(&g_pso_vtbl);
    g_pso_vtbl.GetDevice = pso_GetDevice;
    g_pso_vtbl.QueryInterface = pso_QI;
    g_pso_vtbl.AddRef = pso_AddRef;
    g_pso_vtbl.Release = pso_Release;

    madeira_fill_ID3D12DescriptorHeap(&g_heap_vtbl);
    g_heap_vtbl.GetDevice = heap_GetDevice;
    g_heap_vtbl.QueryInterface = heap_QI;
    g_heap_vtbl.AddRef = heap_AddRef;
    g_heap_vtbl.Release = heap_Release;
    g_heap_vtbl.GetCPUDescriptorHandleForHeapStart = heap_GetCPUDescriptorHandleForHeapStart;
    g_heap_vtbl.GetGPUDescriptorHandleForHeapStart = heap_GetGPUDescriptorHandleForHeapStart;
    g_heap_vtbl.GetDesc = heap_GetDesc;
    g_device_vtbl.GetCustomHeapProperties = (void *)device_GetCustomHeapProperties;

    madeira_fill_ID3D12Fence(&g_fence_vtbl);
    g_fence_vtbl.GetDevice = fence_GetDevice;
    g_fence_vtbl.QueryInterface         = fence_QI;
    g_fence_vtbl.AddRef                 = fence_AddRef;
    g_fence_vtbl.Release                = fence_Release;
    g_fence_vtbl.GetCompletedValue      = fence_GetCompletedValue;
    g_fence_vtbl.SetEventOnCompletion   = fence_SetEventOnCompletion;
    g_fence_vtbl.Signal                 = fence_Signal;
}

/* ---- exports ------------------------------------------------------------- */

/* Lets a caller prove which implementation it reached, and on which
 * architecture, without a debugger. The design asks for exactly this. */
/* ml909: drive the production logger with oversized records from a test so
 * the newline/length contract above is checked where it matters. */
__declspec(dllexport) void MadeiraD3D12LogProbe(const char *msg, unsigned repeat) {
    unsigned i;
    for (i = 0; i < repeat; i++) d3d12_log("[log-probe] %u %s", i, msg ? msg : "");
}
__declspec(dllexport) const char *MadeiraD3D12GetBuildMarker(void) {
#if defined(__aarch64__) || defined(_M_ARM64) || defined(_M_ARM64EC)
    return MADEIRA_D3D12_BUILD " [arm64ec]";
#else
    return MADEIRA_D3D12_BUILD " [x64]";
#endif
}

/* Test hook. ExecuteCommandLists returns void, so a rejected submission has no
 * API-visible effect; without this a negative test could not tell "rejected"
 * from "executed". Named as a Madeira export so it cannot be mistaken for D3D12. */
__declspec(dllexport) void MadeiraD3D12GetQueueStats(ID3D12CommandQueue *queue,
                                                     UINT64 *executed, UINT64 *rejected) {
    struct mad_queue *q = (struct mad_queue *)queue;
    if (!q) return;
    if (executed) *executed = q->executed;
    if (rejected) *rejected = q->rejected;
}

__declspec(dllexport) HRESULT WINAPI MadeiraD3D12CreateDevice(IUnknown *adapter,
        D3D_FEATURE_LEVEL min_feature_level, REFIID riid, void **device) {
    (void)adapter;
    build_vtables();

    /* The design is explicit that accepting the controlled sample's requested
     * baseline is a documented limitation, not a conformance claim. Anything
     * above 11_0 is refused rather than quietly accepted. */
    if (min_feature_level > D3D_FEATURE_LEVEL_12_0) {
        d3d12_log("[madeira-d3d12] feature level %#x refused; 12_0 is the ceiling claimed\n", min_feature_level);
        return E_NOTIMPL;
    }
    if (!device) return S_FALSE;   /* the documented "is it supported" probe */

    struct mad_device *d = calloc(1, sizeof *d);
    if (!d) return E_OUTOFMEMORY;
    d->vtbl = &g_device_vtbl; d->refs = 1; d->iid = &IID_ID3D12Device; d->name = "Device";
    g_last_device = d;

    /* Whichever backend winemetal is configured for, local or remote. Failing
     * here is reported rather than deferred to the first draw. */
    /* Ownership, read from winemetal's local implementations rather than
     * assumed, because the two backends differ and only one of them forgives
     * a mistake:
     *
     *   MTLCopyAllDevices   -> +1, ours to release (the Copy rule).
     *   NSArray objectAtIndex -> UNOWNED. Releasing it is an over-release, and
     *                          locally that is a real Metal object being
     *                          deallocated out from under the process.
     *   newCommandQueue     -> +1, ours to release.
     *
     * Remotely every handle is interned with its own reference, so the same
     * code is harmless there. That asymmetry is why this only ever faulted on
     * the A15, and it faulted during teardown rather than at the call. */
    obj_handle_t devices = WMTCopyAllDevices();
    d->mtl_device = devices ? NSArray_object(devices, 0) : 0;
    if (d->mtl_device) NSObject_retain(d->mtl_device);   /* take our own reference */
    if (devices) NSObject_release(devices);
    InitializeCriticalSection(&d->live_lock);
    if (d->mtl_device) d->mtl_queue = MTLDevice_newCommandQueue(d->mtl_device, 64);
    if (d->mtl_device && d->mtl_queue) {
        struct WMTBufferInfo nbi;
        d->resset = MTLDevice_newResidencySet(d->mtl_device, 4096);
        if (d->resset) MTLCommandQueue_addResidencySet(d->mtl_queue, d->resset);
        d3d12_log("[madeira-d3d12] residency set: %s\n", d->resset ? "attached to the queue" : "UNAVAILABLE (per-draw lists only)");
        memset(&nbi, 0, sizeof nbi);
        nbi.length = 65536;
        nbi.options = WMTResourceStorageModeShared;
        d->null_buffer = MTLDevice_newBuffer(d->mtl_device, &nbi);
        if (d->null_buffer) {
            if (nbi.memory.ptr) memset(nbi.memory.ptr, 0, 65536);
            d->null_gpu = nbi.gpu_address;
            mad_resident(d, d->null_buffer);
        }
    }
    if (d->mtl_device) {
        /* One depth state for the cube: closer fragments win and write. */
        struct WMTDepthStencilInfo dsi;
        memset(&dsi, 0, sizeof dsi);
        dsi.depth_compare_function = WMTCompareFunctionLessEqual;
        dsi.depth_write_enabled = true;
        d->dsso = MTLDevice_newDepthStencilState(d->mtl_device, &dsi);
    }
    if (!d->mtl_device || !d->mtl_queue) {
        d3d12_log("[madeira-d3d12] no Metal device or queue available\n");
        free(d);
        return E_FAIL;
    }
    HRESULT hr = device_QI((ID3D12Device *)d, riid, device);
    device_Release((ID3D12Device *)d);
    if (SUCCEEDED(hr)) d3d12_log("[madeira-d3d12] device created: %s\n", MadeiraD3D12GetBuildMarker());
    return hr;
}

/* ===========================================================================
 * DXGI swapchain bridge (ml857).
 *
 * DXMT's dxgi.dll builds a swapchain by asking the device object it was given
 * for a private interface, IMTLDXGIDevice, and calling CreateSwapChain on it
 * ("Unsupported device type" when the query fails -- the ml856 wall). Our
 * command queue answers that query with a tear-off, and the swapchain itself
 * lives here: D3D12 semantics need N persistent back buffers the application
 * renders into by index, while a Metal layer hands out transient drawables.
 * So the back buffers are ordinary textures and Present blits the current one
 * into the next drawable. dxgi.dll is not modified. */

#define MAD_SWAP_MAX_BUFFERS 8
struct mad_swapchain {
    IDXGISwapChain4Vtbl *vtbl; LONG refs; const IID *iid; const char *name;
    struct mad_device *dev;
    struct mad_queue *queue;
    IDXGIFactory1 *factory;
    HWND hwnd;
    DXGI_SWAP_CHAIN_DESC1 desc;
    DXGI_SWAP_CHAIN_FULLSCREEN_DESC fs;
    obj_handle_t view, layer;
    enum WMTPixelFormat pf;
    struct mad_resource *buffers[MAD_SWAP_MAX_BUFFERS];
    UINT nbuf, index;
    UINT64 presents;
    UINT max_latency;
    HANDLE latency_event;
};
static IDXGISwapChain4Vtbl g_swap_vtbl;

static void mad_swap_release_buffers(struct mad_swapchain *s) {
    UINT i;
    for (i = 0; i < s->nbuf; i++)
        if (s->buffers[i]) { res_Release((ID3D12Resource *)s->buffers[i]); s->buffers[i] = NULL; }
    s->nbuf = 0;
}

static HRESULT mad_swap_make_buffers(struct mad_swapchain *s) {
    D3D12_RESOURCE_DESC rd;
    struct WMTLayerProps props;
    UINT i, n = s->desc.BufferCount ? s->desc.BufferCount : 2;
    int is_depth;
    if (n > MAD_SWAP_MAX_BUFFERS) n = MAD_SWAP_MAX_BUFFERS;
    if (!mad_map_texture_format(s->desc.Format, D3D12_RESOURCE_FLAG_ALLOW_RENDER_TARGET, &s->pf, &is_depth) || is_depth) {
        d3d12_log("[madeira-d3d12] swapchain format %u is not presentable\n", (unsigned)s->desc.Format);
        return DXGI_ERROR_INVALID_CALL;
    }
    memset(&rd, 0, sizeof rd);
    rd.Dimension = D3D12_RESOURCE_DIMENSION_TEXTURE2D;
    rd.Width = s->desc.Width; rd.Height = s->desc.Height;
    rd.DepthOrArraySize = 1; rd.MipLevels = 1;
    rd.Format = s->desc.Format;
    rd.SampleDesc.Count = 1;
    rd.Layout = D3D12_TEXTURE_LAYOUT_UNKNOWN;
    rd.Flags = D3D12_RESOURCE_FLAG_ALLOW_RENDER_TARGET;
    if (s->desc.BufferUsage & DXGI_USAGE_UNORDERED_ACCESS) rd.Flags |= D3D12_RESOURCE_FLAG_ALLOW_UNORDERED_ACCESS;
    for (i = 0; i < n; i++) {
        void *out = NULL;
        HRESULT hr = mad_create_resource(s->dev, D3D12_HEAP_TYPE_DEFAULT, &rd, &IID_ID3D12Resource, &out);
        if (FAILED(hr)) { s->nbuf = i; mad_swap_release_buffers(s); return hr; }
        s->buffers[i] = (struct mad_resource *)out;
        s->buffers[i]->name = "Backbuffer";
    }
    s->nbuf = n;
    s->index = 0;
    /* The layer takes the same pixel format so the presenting blit is a plain
     * copy. framebuffer_only must be off: a framebuffer-only drawable cannot
     * be a blit destination. */
    memset(&props, 0, sizeof props);
    MetalLayer_getProps(s->layer, &props);
    props.device = s->dev->mtl_device;
    props.drawable_width = s->desc.Width;
    props.drawable_height = s->desc.Height;
    props.pixel_format = s->pf;
    props.framebuffer_only = false;
    props.display_sync_enabled = true;
    MetalLayer_setProps(s->layer, &props);
    d3d12_log("[madeira-d3d12] swapchain: %ux%u, %u buffers, format %u, hwnd %p\n",
              s->desc.Width, s->desc.Height, n, (unsigned)s->desc.Format, (void *)s->hwnd);
    return S_OK;
}

static HRESULT STDMETHODCALLTYPE swap_QI(IDXGISwapChain4 *T, REFIID riid, void **out) {
    struct mad_obj *o = (struct mad_obj *)T;
    if (!out) return E_POINTER;
    if (IsEqualGUID(riid, &IID_IUnknown) || IsEqualGUID(riid, &IID_IDXGIObject) ||
        IsEqualGUID(riid, &IID_IDXGIDeviceSubObject) || IsEqualGUID(riid, &IID_IDXGISwapChain) ||
        IsEqualGUID(riid, &IID_IDXGISwapChain1) || IsEqualGUID(riid, &IID_IDXGISwapChain2) ||
        IsEqualGUID(riid, &IID_IDXGISwapChain3) || IsEqualGUID(riid, &IID_IDXGISwapChain4)) {
        InterlockedIncrement(&o->refs); *out = T; return S_OK;
    }
    *out = NULL;
    d3d12_log("[madeira-d3d12] swapchain QueryInterface refused: {%08lx-%04x-%04x-...}\n",
              (unsigned long)riid->Data1, riid->Data2, riid->Data3);
    return E_NOINTERFACE;
}
static ULONG STDMETHODCALLTYPE swap_AddRef(IDXGISwapChain4 *T) { return mad_addref((struct mad_obj *)T); }
static ULONG STDMETHODCALLTYPE swap_Release(IDXGISwapChain4 *T) {
    struct mad_swapchain *s = (struct mad_swapchain *)T;
    LONG n = InterlockedDecrement(&s->refs);
    if (n == 0) {
        mad_swap_release_buffers(s);
        if (s->view) ReleaseMetalView(s->view);
        if (s->latency_event) CloseHandle(s->latency_event);
        if (s->factory) IDXGIFactory1_Release(s->factory);
        ID3D12CommandQueue_Release((ID3D12CommandQueue *)s->queue);
        d3d12_log("[madeira-d3d12] swapchain destroyed after %llu presents\n", (unsigned long long)s->presents);
        free(s);
    }
    return (ULONG)n;
}
static HRESULT STDMETHODCALLTYPE swap_SetPrivateData(IDXGISwapChain4 *T, REFGUID g, UINT n, const void *d) { (void)T; (void)g; (void)n; (void)d; return S_OK; }
static HRESULT STDMETHODCALLTYPE swap_SetPrivateDataInterface(IDXGISwapChain4 *T, REFGUID g, const IUnknown *d) { (void)T; (void)g; (void)d; return S_OK; }
static HRESULT STDMETHODCALLTYPE swap_GetPrivateData(IDXGISwapChain4 *T, REFGUID g, UINT *n, void *d) { (void)T; (void)g; (void)d; if (n) *n = 0; return DXGI_ERROR_NOT_FOUND; }
static HRESULT STDMETHODCALLTYPE swap_GetParent(IDXGISwapChain4 *T, REFIID riid, void **out) {
    struct mad_swapchain *s = (struct mad_swapchain *)T;
    if (!out) return E_POINTER;
    *out = NULL;
    if (!s->factory) return E_NOINTERFACE;
    return IDXGIFactory1_QueryInterface(s->factory, riid, out);
}
static HRESULT STDMETHODCALLTYPE swap_GetDevice(IDXGISwapChain4 *T, REFIID riid, void **out) {
    struct mad_swapchain *s = (struct mad_swapchain *)T;
    return s->dev->vtbl->QueryInterface((ID3D12Device10 *)s->dev, riid, out);
}

static HRESULT STDMETHODCALLTYPE swap_Present(IDXGISwapChain4 *T, UINT sync, UINT flags) {
    struct mad_swapchain *s = (struct mad_swapchain *)T;
    struct mad_resource *src;
    obj_handle_t drawable, tex, cb, enc;
    struct wmtcmd_blit_copy_from_texture_to_texture t2t;
    (void)sync;
    if (flags & DXGI_PRESENT_TEST) return S_OK;
    if (!s->nbuf) return DXGI_ERROR_INVALID_CALL;
    src = s->buffers[s->index];
    mad_device_flush_all(s->queue->device);          /* ml884: the frame's batch precedes the present */
    drawable = MetalLayer_nextDrawable(s->layer);
    if (!drawable) {
        static unsigned said;
        if (said++ < 3) d3d12_log("[madeira-d3d12] Present: the layer gave no drawable\n");
        s->index = (s->index + 1) % s->nbuf;
        return S_OK;   /* a dropped frame, not an error the application can act on */
    }
    tex = MetalDrawable_texture(drawable);
    cb = MTLCommandQueue_commandBuffer(s->queue->device->mtl_queue);
    if (cb && tex) {
        enc = MTLCommandBuffer_blitCommandEncoder(cb); if (enc) g_enc_seq++;
        if (enc) {
            memset(&t2t, 0, sizeof t2t);
            t2t.type = WMTBlitCommandCopyFromTextureToTexture;
            t2t.src = src->texture;
            t2t.src_size.width = src->width;
            t2t.src_size.height = src->height;
            t2t.src_size.depth = 1;
            t2t.dst = tex;
            MTLBlitCommandEncoder_encodeCommands(enc, (const struct wmtcmd_base *)&t2t);
            MTLCommandEncoder_endEncoding(enc);
        }
        /* Submitted after the frame's own command buffers on the same queue,
         * which is what orders the copy after the rendering. */
        MTLCommandBuffer_presentDrawable(cb, drawable);
        MTLCommandBuffer_commit(cb);
    }
    NSObject_release(drawable);
    s->presents++;
    g_census_on = (s->presents >= 1500 && s->presents < 3000 && (s->presents % 200) == 0);   /* ml899 */
    if ((g_list_seq >= 12000 && g_list_seq < 12400) || g_census_on)
        d3d12_log("[draw-dump] ===== Present #%llu (list#%u) =====\n", (unsigned long long)s->presents, g_list_seq);
    if (s->presents <= 3 || (s->presents % 600) == 0)
        d3d12_log("[madeira-d3d12] Present #%llu (buffer %u)\n", (unsigned long long)s->presents, s->index);
    s->index = (s->index + 1) % s->nbuf;
    return S_OK;
}
static HRESULT STDMETHODCALLTYPE swap_GetBuffer(IDXGISwapChain4 *T, UINT i, REFIID riid, void **out) {
    struct mad_swapchain *s = (struct mad_swapchain *)T;
    if (!out) return E_POINTER;
    *out = NULL;
    if (i >= s->nbuf) return DXGI_ERROR_INVALID_CALL;
    return res_QI((ID3D12Resource *)s->buffers[i], riid, out);
}
static HRESULT STDMETHODCALLTYPE swap_SetFullscreenState(IDXGISwapChain4 *T, BOOL fs, IDXGIOutput *target) {
    struct mad_swapchain *s = (struct mad_swapchain *)T;
    (void)target;
    /* The window is what the desktop says it is; fullscreen is recorded so the
     * application reads back what it set, and changes nothing else. */
    s->fs.Windowed = !fs;
    return S_OK;
}
static HRESULT STDMETHODCALLTYPE swap_GetFullscreenState(IDXGISwapChain4 *T, BOOL *fs, IDXGIOutput **target) {
    struct mad_swapchain *s = (struct mad_swapchain *)T;
    if (fs) *fs = !s->fs.Windowed;
    if (target) *target = NULL;
    return S_OK;
}
static HRESULT STDMETHODCALLTYPE swap_GetDesc(IDXGISwapChain4 *T, DXGI_SWAP_CHAIN_DESC *d) {
    struct mad_swapchain *s = (struct mad_swapchain *)T;
    if (!d) return E_INVALIDARG;
    memset(d, 0, sizeof *d);
    d->BufferDesc.Width = s->desc.Width; d->BufferDesc.Height = s->desc.Height;
    d->BufferDesc.Format = s->desc.Format;
    d->BufferDesc.RefreshRate = s->fs.RefreshRate;
    d->BufferDesc.ScanlineOrdering = s->fs.ScanlineOrdering;
    d->BufferDesc.Scaling = s->fs.Scaling;
    d->SampleDesc = s->desc.SampleDesc;
    d->BufferUsage = s->desc.BufferUsage;
    d->BufferCount = s->nbuf;
    d->OutputWindow = s->hwnd;
    d->Windowed = s->fs.Windowed;
    d->SwapEffect = s->desc.SwapEffect;
    d->Flags = s->desc.Flags;
    return S_OK;
}
static HRESULT STDMETHODCALLTYPE swap_ResizeBuffers(IDXGISwapChain4 *T, UINT count, UINT w, UINT h, DXGI_FORMAT fmt, UINT flags) {
    struct mad_swapchain *s = (struct mad_swapchain *)T;
    UINT i;
    for (i = 0; i < s->nbuf; i++)
        if (s->buffers[i] && s->buffers[i]->refs > 1)
            d3d12_log("[madeira-d3d12] ResizeBuffers: back buffer %u still has %ld outside references\n", i, (long)s->buffers[i]->refs - 1);
    mad_swap_release_buffers(s);
    if (count) s->desc.BufferCount = count;
    if (w) s->desc.Width = w;
    if (h) s->desc.Height = h;
    if (fmt != DXGI_FORMAT_UNKNOWN) s->desc.Format = fmt;
    s->desc.Flags = flags;
    return mad_swap_make_buffers(s);
}
static HRESULT STDMETHODCALLTYPE swap_ResizeTarget(IDXGISwapChain4 *T, const DXGI_MODE_DESC *m) { (void)T; (void)m; return S_OK; }
static HRESULT STDMETHODCALLTYPE swap_GetContainingOutput(IDXGISwapChain4 *T, IDXGIOutput **out) {
    struct mad_swapchain *s = (struct mad_swapchain *)T;
    IDXGIAdapter1 *adapter = NULL;
    HRESULT hr;
    if (!out) return E_POINTER;
    *out = NULL;
    if (!s->factory) return DXGI_ERROR_UNSUPPORTED;
    hr = IDXGIFactory1_EnumAdapters1(s->factory, 0, &adapter);
    if (FAILED(hr)) return hr;
    hr = IDXGIAdapter1_EnumOutputs(adapter, 0, out);
    IDXGIAdapter1_Release(adapter);
    return hr;
}
static HRESULT STDMETHODCALLTYPE swap_GetFrameStatistics(IDXGISwapChain4 *T, DXGI_FRAME_STATISTICS *st) {
    struct mad_swapchain *s = (struct mad_swapchain *)T;
    if (!st) return E_INVALIDARG;
    memset(st, 0, sizeof *st);
    st->PresentCount = (UINT)s->presents;
    st->PresentRefreshCount = (UINT)s->presents;
    return S_OK;
}
static HRESULT STDMETHODCALLTYPE swap_GetLastPresentCount(IDXGISwapChain4 *T, UINT *n) {
    if (!n) return E_INVALIDARG;
    *n = (UINT)((struct mad_swapchain *)T)->presents;
    return S_OK;
}
static HRESULT STDMETHODCALLTYPE swap_GetDesc1(IDXGISwapChain4 *T, DXGI_SWAP_CHAIN_DESC1 *d) {
    if (!d) return E_INVALIDARG;
    *d = ((struct mad_swapchain *)T)->desc;
    d->BufferCount = ((struct mad_swapchain *)T)->nbuf;
    return S_OK;
}
static HRESULT STDMETHODCALLTYPE swap_GetFullscreenDesc(IDXGISwapChain4 *T, DXGI_SWAP_CHAIN_FULLSCREEN_DESC *d) {
    if (!d) return E_INVALIDARG;
    *d = ((struct mad_swapchain *)T)->fs;
    return S_OK;
}
static HRESULT STDMETHODCALLTYPE swap_GetHwnd(IDXGISwapChain4 *T, HWND *h) {
    if (!h) return E_INVALIDARG;
    *h = ((struct mad_swapchain *)T)->hwnd;
    return S_OK;
}
static HRESULT STDMETHODCALLTYPE swap_GetCoreWindow(IDXGISwapChain4 *T, REFIID riid, void **out) { (void)T; (void)riid; if (out) *out = NULL; return DXGI_ERROR_INVALID_CALL; }
static HRESULT STDMETHODCALLTYPE swap_Present1(IDXGISwapChain4 *T, UINT sync, UINT flags, const DXGI_PRESENT_PARAMETERS *p) { (void)p; return swap_Present(T, sync, flags); }
static BOOL STDMETHODCALLTYPE swap_IsTemporaryMonoSupported(IDXGISwapChain4 *T) { (void)T; return FALSE; }
static HRESULT STDMETHODCALLTYPE swap_GetRestrictToOutput(IDXGISwapChain4 *T, IDXGIOutput **out) { (void)T; if (out) *out = NULL; return S_OK; }
static HRESULT STDMETHODCALLTYPE swap_SetBackgroundColor(IDXGISwapChain4 *T, const DXGI_RGBA *c) { (void)T; (void)c; return S_OK; }
static HRESULT STDMETHODCALLTYPE swap_GetBackgroundColor(IDXGISwapChain4 *T, DXGI_RGBA *c) { (void)T; if (c) memset(c, 0, sizeof *c); return S_OK; }
static HRESULT STDMETHODCALLTYPE swap_SetRotation(IDXGISwapChain4 *T, DXGI_MODE_ROTATION r) { (void)T; (void)r; return S_OK; }
static HRESULT STDMETHODCALLTYPE swap_GetRotation(IDXGISwapChain4 *T, DXGI_MODE_ROTATION *r) { (void)T; if (r) *r = DXGI_MODE_ROTATION_IDENTITY; return S_OK; }
static HRESULT STDMETHODCALLTYPE swap_SetSourceSize(IDXGISwapChain4 *T, UINT w, UINT h) { (void)T; (void)w; (void)h; return S_OK; }
static HRESULT STDMETHODCALLTYPE swap_GetSourceSize(IDXGISwapChain4 *T, UINT *w, UINT *h) {
    struct mad_swapchain *s = (struct mad_swapchain *)T;
    if (w) *w = s->desc.Width; if (h) *h = s->desc.Height; return S_OK;
}
static HRESULT STDMETHODCALLTYPE swap_SetMaximumFrameLatency(IDXGISwapChain4 *T, UINT n) { ((struct mad_swapchain *)T)->max_latency = n ? n : 1; return S_OK; }
static HRESULT STDMETHODCALLTYPE swap_GetMaximumFrameLatency(IDXGISwapChain4 *T, UINT *n) { if (!n) return E_INVALIDARG; *n = ((struct mad_swapchain *)T)->max_latency; return S_OK; }
static HANDLE STDMETHODCALLTYPE swap_GetFrameLatencyWaitableObject(IDXGISwapChain4 *T) {
    /* Always signalled: presentation never applies back-pressure here, so a
     * waiter must never block on it. */
    struct mad_swapchain *s = (struct mad_swapchain *)T;
    if (!s->latency_event) s->latency_event = CreateEventW(NULL, TRUE, TRUE, NULL);
    return s->latency_event;
}
static HRESULT STDMETHODCALLTYPE swap_SetMatrixTransform(IDXGISwapChain4 *T, const DXGI_MATRIX_3X2_F *m) { (void)T; (void)m; return DXGI_ERROR_INVALID_CALL; }
static HRESULT STDMETHODCALLTYPE swap_GetMatrixTransform(IDXGISwapChain4 *T, DXGI_MATRIX_3X2_F *m) { (void)T; (void)m; return DXGI_ERROR_INVALID_CALL; }
static UINT STDMETHODCALLTYPE swap_GetCurrentBackBufferIndex(IDXGISwapChain4 *T) { return ((struct mad_swapchain *)T)->index; }
static HRESULT STDMETHODCALLTYPE swap_CheckColorSpaceSupport(IDXGISwapChain4 *T, DXGI_COLOR_SPACE_TYPE cs, UINT *flags) {
    (void)T;
    if (!flags) return E_INVALIDARG;
    *flags = (cs == DXGI_COLOR_SPACE_RGB_FULL_G22_NONE_P709) ? DXGI_SWAP_CHAIN_COLOR_SPACE_SUPPORT_FLAG_PRESENT : 0;
    return S_OK;
}
static HRESULT STDMETHODCALLTYPE swap_SetColorSpace1(IDXGISwapChain4 *T, DXGI_COLOR_SPACE_TYPE cs) {
    (void)T;
    if (cs == DXGI_COLOR_SPACE_RGB_FULL_G22_NONE_P709) return S_OK;
    d3d12_log("[madeira-d3d12] SetColorSpace1(%u) refused: only sRGB is presented\n", (unsigned)cs);
    return E_INVALIDARG;
}
static HRESULT STDMETHODCALLTYPE swap_ResizeBuffers1(IDXGISwapChain4 *T, UINT count, UINT w, UINT h, DXGI_FORMAT fmt, UINT flags,
                                                     const UINT *node_masks, IUnknown *const *queues) {
    (void)node_masks; (void)queues;
    return swap_ResizeBuffers(T, count, w, h, fmt, flags);
}
static HRESULT STDMETHODCALLTYPE swap_SetHDRMetaData(IDXGISwapChain4 *T, DXGI_HDR_METADATA_TYPE type, UINT n, void *d) { (void)T; (void)type; (void)n; (void)d; return S_OK; }

static HRESULT mad_swapchain_create(struct mad_queue *q, IDXGIFactory1 *factory, HWND hwnd,
                                    const DXGI_SWAP_CHAIN_DESC1 *desc,
                                    const DXGI_SWAP_CHAIN_FULLSCREEN_DESC *fs, IDXGISwapChain1 **out) {
    struct mad_swapchain *s;
    HRESULT hr;
    if (!out) return E_POINTER;
    *out = NULL;
    if (!q || !desc || !hwnd) return DXGI_ERROR_INVALID_CALL;
    s = calloc(1, sizeof *s);
    if (!s) return E_OUTOFMEMORY;
    s->vtbl = &g_swap_vtbl; s->refs = 1; s->iid = &IID_IDXGISwapChain4; s->name = "SwapChain";
    s->dev = q->device; s->queue = q;
    ID3D12CommandQueue_AddRef((ID3D12CommandQueue *)q);
    s->factory = factory;
    if (factory) IDXGIFactory1_AddRef(factory);
    s->hwnd = hwnd;
    s->desc = *desc;
    if (fs) s->fs = *fs; else s->fs.Windowed = TRUE;
    s->max_latency = 1;
    s->view = CreateMetalViewFromHWND((intptr_t)hwnd, s->dev->mtl_device, &s->layer);
    if (!s->view || !s->layer) {
        d3d12_log("[madeira-d3d12] swapchain: no Metal view for hwnd %p\n", (void *)hwnd);
        swap_Release((IDXGISwapChain4 *)s);
        return DXGI_ERROR_UNSUPPORTED;
    }
    hr = mad_swap_make_buffers(s);
    if (FAILED(hr)) { swap_Release((IDXGISwapChain4 *)s); return hr; }
    *out = (IDXGISwapChain1 *)s;
    return S_OK;
}

/* ---- the tear-off dxgi.dll asks the queue for ---------------------------
 * IMTLDXGIDevice extends IDXGIDevice3; only the last method matters here.
 * GetMTLDevice returns a C++ object with a user-declared constructor, which
 * on this ABI travels through a hidden pointer that the callee returns. */
struct mad_mtl_dxgi_device;
struct mad_mtl_dxgi_device_vtbl {
    HRESULT (STDMETHODCALLTYPE *QueryInterface)(struct mad_mtl_dxgi_device *, REFIID, void **);
    ULONG (STDMETHODCALLTYPE *AddRef)(struct mad_mtl_dxgi_device *);
    ULONG (STDMETHODCALLTYPE *Release)(struct mad_mtl_dxgi_device *);
    HRESULT (STDMETHODCALLTYPE *SetPrivateData)(struct mad_mtl_dxgi_device *, REFGUID, UINT, const void *);
    HRESULT (STDMETHODCALLTYPE *SetPrivateDataInterface)(struct mad_mtl_dxgi_device *, REFGUID, const IUnknown *);
    HRESULT (STDMETHODCALLTYPE *GetPrivateData)(struct mad_mtl_dxgi_device *, REFGUID, UINT *, void *);
    HRESULT (STDMETHODCALLTYPE *GetParent)(struct mad_mtl_dxgi_device *, REFIID, void **);
    HRESULT (STDMETHODCALLTYPE *GetAdapter)(struct mad_mtl_dxgi_device *, IDXGIAdapter **);
    HRESULT (STDMETHODCALLTYPE *CreateSurface)(struct mad_mtl_dxgi_device *, const DXGI_SURFACE_DESC *, UINT, DXGI_USAGE, const DXGI_SHARED_RESOURCE *, IDXGISurface **);
    HRESULT (STDMETHODCALLTYPE *QueryResourceResidency)(struct mad_mtl_dxgi_device *, IUnknown *const *, DXGI_RESIDENCY *, UINT);
    HRESULT (STDMETHODCALLTYPE *SetGPUThreadPriority)(struct mad_mtl_dxgi_device *, INT);
    HRESULT (STDMETHODCALLTYPE *GetGPUThreadPriority)(struct mad_mtl_dxgi_device *, INT *);
    HRESULT (STDMETHODCALLTYPE *SetMaximumFrameLatency)(struct mad_mtl_dxgi_device *, UINT);
    HRESULT (STDMETHODCALLTYPE *GetMaximumFrameLatency)(struct mad_mtl_dxgi_device *, UINT *);
    HRESULT (STDMETHODCALLTYPE *OfferResources)(struct mad_mtl_dxgi_device *, UINT, IDXGIResource *const *, DXGI_OFFER_RESOURCE_PRIORITY);
    HRESULT (STDMETHODCALLTYPE *ReclaimResources)(struct mad_mtl_dxgi_device *, UINT, IDXGIResource *const *, BOOL *);
    HRESULT (STDMETHODCALLTYPE *EnqueueSetEvent)(struct mad_mtl_dxgi_device *, HANDLE);
    void (STDMETHODCALLTYPE *Trim)(struct mad_mtl_dxgi_device *);
    obj_handle_t *(STDMETHODCALLTYPE *GetMTLDevice)(struct mad_mtl_dxgi_device *, obj_handle_t *ret);
    UINT (STDMETHODCALLTYPE *GetLocalD3DKMT)(struct mad_mtl_dxgi_device *);
    HRESULT (STDMETHODCALLTYPE *CreateSwapChain)(struct mad_mtl_dxgi_device *, IDXGIFactory1 *, HWND,
                                                 const DXGI_SWAP_CHAIN_DESC1 *, const DXGI_SWAP_CHAIN_FULLSCREEN_DESC *,
                                                 IDXGISwapChain1 **);
};
struct mad_mtl_dxgi_device {
    const struct mad_mtl_dxgi_device_vtbl *vtbl;
    LONG refs;
    struct mad_queue *queue;
};
static HRESULT STDMETHODCALLTYPE mdd_QI(struct mad_mtl_dxgi_device *T, REFIID riid, void **out) {
    if (!out) return E_POINTER;
    if (IsEqualGUID(riid, &IID_IUnknown) || IsEqualGUID(riid, &IID_IMTLDXGIDevice)) {
        InterlockedIncrement(&T->refs); *out = T; return S_OK;
    }
    /* Anything else is the queue's business. */
    return T->queue->vtbl->QueryInterface((ID3D12CommandQueue *)T->queue, riid, out);
}
static ULONG STDMETHODCALLTYPE mdd_AddRef(struct mad_mtl_dxgi_device *T) { return (ULONG)InterlockedIncrement(&T->refs); }
static ULONG STDMETHODCALLTYPE mdd_Release(struct mad_mtl_dxgi_device *T) {
    LONG n = InterlockedDecrement(&T->refs);
    if (n == 0) { ID3D12CommandQueue_Release((ID3D12CommandQueue *)T->queue); free(T); }
    return (ULONG)n;
}
static HRESULT STDMETHODCALLTYPE mdd_SetPrivateData(struct mad_mtl_dxgi_device *T, REFGUID g, UINT n, const void *d) { (void)T; (void)g; (void)n; (void)d; return S_OK; }
static HRESULT STDMETHODCALLTYPE mdd_SetPrivateDataInterface(struct mad_mtl_dxgi_device *T, REFGUID g, const IUnknown *d) { (void)T; (void)g; (void)d; return S_OK; }
static HRESULT STDMETHODCALLTYPE mdd_GetPrivateData(struct mad_mtl_dxgi_device *T, REFGUID g, UINT *n, void *d) { (void)T; (void)g; (void)d; if (n) *n = 0; return DXGI_ERROR_NOT_FOUND; }
static HRESULT STDMETHODCALLTYPE mdd_GetParent(struct mad_mtl_dxgi_device *T, REFIID riid, void **out) { (void)T; (void)riid; if (out) *out = NULL; return E_NOINTERFACE; }
static HRESULT STDMETHODCALLTYPE mdd_GetAdapter(struct mad_mtl_dxgi_device *T, IDXGIAdapter **out) { (void)T; if (out) *out = NULL; d3d12_log("[madeira-d3d12] IDXGIDevice::GetAdapter is not implemented\n"); return E_NOTIMPL; }
static HRESULT STDMETHODCALLTYPE mdd_CreateSurface(struct mad_mtl_dxgi_device *T, const DXGI_SURFACE_DESC *d, UINT n, DXGI_USAGE u, const DXGI_SHARED_RESOURCE *s, IDXGISurface **out) { (void)T; (void)d; (void)n; (void)u; (void)s; if (out) *out = NULL; return E_NOTIMPL; }
static HRESULT STDMETHODCALLTYPE mdd_QueryResourceResidency(struct mad_mtl_dxgi_device *T, IUnknown *const *r, DXGI_RESIDENCY *st, UINT n) { UINT i; (void)T; (void)r; for (i = 0; st && i < n; i++) st[i] = DXGI_RESIDENCY_FULLY_RESIDENT; return S_OK; }
static HRESULT STDMETHODCALLTYPE mdd_SetGPUThreadPriority(struct mad_mtl_dxgi_device *T, INT p) { (void)T; (void)p; return S_OK; }
static HRESULT STDMETHODCALLTYPE mdd_GetGPUThreadPriority(struct mad_mtl_dxgi_device *T, INT *p) { (void)T; if (p) *p = 0; return S_OK; }
static HRESULT STDMETHODCALLTYPE mdd_SetMaximumFrameLatency(struct mad_mtl_dxgi_device *T, UINT n) { (void)T; (void)n; return S_OK; }
static HRESULT STDMETHODCALLTYPE mdd_GetMaximumFrameLatency(struct mad_mtl_dxgi_device *T, UINT *n) { (void)T; if (n) *n = 1; return S_OK; }
static HRESULT STDMETHODCALLTYPE mdd_OfferResources(struct mad_mtl_dxgi_device *T, UINT n, IDXGIResource *const *r, DXGI_OFFER_RESOURCE_PRIORITY p) { (void)T; (void)n; (void)r; (void)p; return S_OK; }
static HRESULT STDMETHODCALLTYPE mdd_ReclaimResources(struct mad_mtl_dxgi_device *T, UINT n, IDXGIResource *const *r, BOOL *discarded) { UINT i; (void)T; (void)r; for (i = 0; discarded && i < n; i++) discarded[i] = FALSE; return S_OK; }
static HRESULT STDMETHODCALLTYPE mdd_EnqueueSetEvent(struct mad_mtl_dxgi_device *T, HANDLE e) { (void)T; if (e) SetEvent(e); return S_OK; }
static void STDMETHODCALLTYPE mdd_Trim(struct mad_mtl_dxgi_device *T) { (void)T; }
static obj_handle_t * STDMETHODCALLTYPE mdd_GetMTLDevice(struct mad_mtl_dxgi_device *T, obj_handle_t *ret) { *ret = T->queue->device->mtl_device; return ret; }
static UINT STDMETHODCALLTYPE mdd_GetLocalD3DKMT(struct mad_mtl_dxgi_device *T) { (void)T; return 0; }
static HRESULT STDMETHODCALLTYPE mdd_CreateSwapChain(struct mad_mtl_dxgi_device *T, IDXGIFactory1 *factory, HWND hwnd,
        const DXGI_SWAP_CHAIN_DESC1 *desc, const DXGI_SWAP_CHAIN_FULLSCREEN_DESC *fs, IDXGISwapChain1 **out) {
    return mad_swapchain_create(T->queue, factory, hwnd, desc, fs, out);
}
static const struct mad_mtl_dxgi_device_vtbl g_mdd_vtbl = {
    mdd_QI, mdd_AddRef, mdd_Release, mdd_SetPrivateData, mdd_SetPrivateDataInterface, mdd_GetPrivateData,
    mdd_GetParent, mdd_GetAdapter, mdd_CreateSurface, mdd_QueryResourceResidency, mdd_SetGPUThreadPriority,
    mdd_GetGPUThreadPriority, mdd_SetMaximumFrameLatency, mdd_GetMaximumFrameLatency, mdd_OfferResources,
    mdd_ReclaimResources, mdd_EnqueueSetEvent, mdd_Trim, mdd_GetMTLDevice, mdd_GetLocalD3DKMT, mdd_CreateSwapChain,
};

/* The queue's answer to the private query: a fresh tear-off holding the queue. */
static HRESULT mad_queue_dxgi_tearoff(struct mad_queue *q, void **out) {
    struct mad_mtl_dxgi_device *t = calloc(1, sizeof *t);
    if (!t) return E_OUTOFMEMORY;
    t->vtbl = &g_mdd_vtbl; t->refs = 1; t->queue = q;
    ID3D12CommandQueue_AddRef((ID3D12CommandQueue *)q);
    d3d12_log("[madeira-d3d12] dxgi asked the queue for its Metal device; swapchain bridge engaged\n");
    *out = t;
    return S_OK;
}

static void mad_swap_fill_vtbl(void) {
    g_swap_vtbl.QueryInterface = swap_QI; g_swap_vtbl.AddRef = swap_AddRef; g_swap_vtbl.Release = swap_Release;
    g_swap_vtbl.SetPrivateData = swap_SetPrivateData; g_swap_vtbl.SetPrivateDataInterface = swap_SetPrivateDataInterface;
    g_swap_vtbl.GetPrivateData = swap_GetPrivateData; g_swap_vtbl.GetParent = swap_GetParent; g_swap_vtbl.GetDevice = swap_GetDevice;
    g_swap_vtbl.Present = swap_Present; g_swap_vtbl.GetBuffer = swap_GetBuffer;
    g_swap_vtbl.SetFullscreenState = swap_SetFullscreenState; g_swap_vtbl.GetFullscreenState = swap_GetFullscreenState;
    g_swap_vtbl.GetDesc = swap_GetDesc; g_swap_vtbl.ResizeBuffers = swap_ResizeBuffers; g_swap_vtbl.ResizeTarget = swap_ResizeTarget;
    g_swap_vtbl.GetContainingOutput = swap_GetContainingOutput; g_swap_vtbl.GetFrameStatistics = swap_GetFrameStatistics;
    g_swap_vtbl.GetLastPresentCount = swap_GetLastPresentCount; g_swap_vtbl.GetDesc1 = swap_GetDesc1;
    g_swap_vtbl.GetFullscreenDesc = swap_GetFullscreenDesc; g_swap_vtbl.GetHwnd = swap_GetHwnd; g_swap_vtbl.GetCoreWindow = swap_GetCoreWindow;
    g_swap_vtbl.Present1 = swap_Present1; g_swap_vtbl.IsTemporaryMonoSupported = swap_IsTemporaryMonoSupported;
    g_swap_vtbl.GetRestrictToOutput = swap_GetRestrictToOutput; g_swap_vtbl.SetBackgroundColor = swap_SetBackgroundColor;
    g_swap_vtbl.GetBackgroundColor = swap_GetBackgroundColor; g_swap_vtbl.SetRotation = swap_SetRotation; g_swap_vtbl.GetRotation = swap_GetRotation;
    g_swap_vtbl.SetSourceSize = swap_SetSourceSize; g_swap_vtbl.GetSourceSize = swap_GetSourceSize;
    g_swap_vtbl.SetMaximumFrameLatency = swap_SetMaximumFrameLatency; g_swap_vtbl.GetMaximumFrameLatency = swap_GetMaximumFrameLatency;
    g_swap_vtbl.GetFrameLatencyWaitableObject = swap_GetFrameLatencyWaitableObject;
    g_swap_vtbl.SetMatrixTransform = swap_SetMatrixTransform; g_swap_vtbl.GetMatrixTransform = swap_GetMatrixTransform;
    g_swap_vtbl.GetCurrentBackBufferIndex = swap_GetCurrentBackBufferIndex; g_swap_vtbl.CheckColorSpaceSupport = swap_CheckColorSpaceSupport;
    g_swap_vtbl.SetColorSpace1 = swap_SetColorSpace1; g_swap_vtbl.ResizeBuffers1 = swap_ResizeBuffers1; g_swap_vtbl.SetHDRMetaData = swap_SetHDRMetaData;
}

/* ---- test presentation bridge -------------------------------------------
 *
 * Deliberately NOT DXGI. The design says not to make a full DXGI implementation
 * a prerequisite for a visible frame, and a swapchain carries format
 * negotiation, buffer counts, resize and fullscreen transitions that have
 * nothing to do with proving the D3D12 path draws. This is an explicit,
 * separately named bridge: acquire the layer's next drawable, hand it back as a
 * render target, present it. When DXGI arrives it replaces this rather than
 * building on it. */
struct mad_presenter {
    struct mad_device *dev;
    obj_handle_t view, layer, drawable;
    struct mad_resource back;
    UINT width, height;
};

__declspec(dllexport) void *MadeiraD3D12PresenterCreate(ID3D12Device *device, intptr_t hwnd,
                                                        UINT width, UINT height) {
    struct mad_device *d = (struct mad_device *)device;
    if (!d) return NULL;
    struct mad_presenter *p = calloc(1, sizeof *p);
    if (!p) return NULL;
    p->dev = d; p->width = width; p->height = height;
    p->view = CreateMetalViewFromHWND(hwnd, d->mtl_device, &p->layer);
    if (!p->view || !p->layer) {
        d3d12_log("[madeira-d3d12] presenter: no Metal view for hwnd %p\n", (void *)hwnd);
        free(p);
        return NULL;
    }
    struct WMTLayerProps props;
    memset(&props, 0, sizeof props);
    MetalLayer_getProps(p->layer, &props);
    props.device = d->mtl_device;
    props.drawable_width = width;
    props.drawable_height = height;
    props.pixel_format = WMTPixelFormatRGBA8Unorm;
    props.framebuffer_only = false;   /* the cube test reads the target back */
    MetalLayer_setProps(p->layer, &props);
    d3d12_log("[madeira-d3d12] presenter: layer %ux%u ready\n", width, height);
    return p;
}

/* The returned resource borrows the drawable's texture and is valid only until
 * the next Present. Handing back something longer-lived would invite a caller to
 * keep using a texture the layer has already recycled. */
__declspec(dllexport) ID3D12Resource *MadeiraD3D12PresenterAcquire(void *ph) {
    struct mad_presenter *p = (struct mad_presenter *)ph;
    if (!p) return NULL;
    if (p->drawable) { NSObject_release(p->drawable); p->drawable = 0; }
    p->drawable = MetalLayer_nextDrawable(p->layer);
    if (!p->drawable) { d3d12_log("[madeira-d3d12] presenter: no drawable\n"); return NULL; }
    memset(&p->back, 0, sizeof p->back);
    p->back.vtbl = &g_res_vtbl;
    p->back.refs = 1;
    p->back.iid = &IID_ID3D12Resource;
    p->back.name = "Backbuffer";
    p->back.texture = MetalDrawable_texture(p->drawable);
    p->back.width = p->width;
    p->back.height = p->height;
    p->back.borrowed = 1;
    return (ID3D12Resource *)&p->back;
}

__declspec(dllexport) void MadeiraD3D12PresenterPresent(void *ph, ID3D12CommandQueue *queue) {
    struct mad_presenter *p = (struct mad_presenter *)ph;
    struct mad_queue *q = (struct mad_queue *)queue;
    if (!p || !q || !p->drawable) return;
    /* Presentation rides its own command buffer, submitted after the frame's
     * work is already on the queue, so ordering comes from the queue itself. */
    obj_handle_t cb = MTLCommandQueue_commandBuffer(q->device->mtl_queue);
    if (!cb) return;
    MTLCommandBuffer_presentDrawable(cb, p->drawable);
    MTLCommandBuffer_commit(cb);
    NSObject_release(p->drawable);
    p->drawable = 0;
}

__declspec(dllexport) void MadeiraD3D12PresenterDestroy(void *ph) {
    struct mad_presenter *p = (struct mad_presenter *)ph;
    if (!p) return;
    if (p->drawable) NSObject_release(p->drawable);
    if (p->view) ReleaseMetalView(p->view);
    free(p);
}

BOOL WINAPI DllMain(HINSTANCE inst, DWORD reason, LPVOID reserved) {
    (void)inst; (void)reserved;
    if (reason == DLL_PROCESS_ATTACH) { build_vtables(); mad_swap_fill_vtbl(); }
    return TRUE;
}

/* ===========================================================================
 * The standard d3d12.dll surface (ml849).
 *
 * The first UE5 run that got past thread startup called D3D12CreateDevice in
 * Wine's d3d12.dll, which needs Vulkan and reported "Failed to load Vulkan
 * library". So this runtime now presents the ordinary entry points and ships
 * as d3d12.dll as well. The executable delay-loads two of them BY ORDINAL --
 * 101 D3D12CreateDevice and 102 D3D12GetDebugInterface -- so d3d12.def pins
 * those numbers to match Wine's and Microsoft's export tables.
 *
 * Everything unsupported is refused BY NAME and logged, never faked: the point
 * of this stage is to let the engine name its next requirement. */

/* ---- ID3DBlob: what the serializer entry points hand back ---------------- */
struct mad_blob { const ID3D10BlobVtbl *vtbl; LONG refs; void *data; SIZE_T size; };
static HRESULT STDMETHODCALLTYPE blob_QI(ID3D10Blob *T, REFIID riid, void **out) {
    if (!out) return E_POINTER;
    if (IsEqualGUID(riid, &IID_IUnknown) || IsEqualGUID(riid, &IID_ID3D10Blob)) {
        InterlockedIncrement(&((struct mad_blob *)T)->refs); *out = T; return S_OK;
    }
    *out = NULL; return E_NOINTERFACE;
}
static ULONG STDMETHODCALLTYPE blob_AddRef(ID3D10Blob *T) { return (ULONG)InterlockedIncrement(&((struct mad_blob *)T)->refs); }
static ULONG STDMETHODCALLTYPE blob_Release(ID3D10Blob *T) {
    struct mad_blob *b = (struct mad_blob *)T;
    LONG n = InterlockedDecrement(&b->refs);
    if (n == 0) { free(b->data); free(b); }
    return (ULONG)n;
}
static void * STDMETHODCALLTYPE blob_GetBufferPointer(ID3D10Blob *T) { return ((struct mad_blob *)T)->data; }
static SIZE_T STDMETHODCALLTYPE blob_GetBufferSize(ID3D10Blob *T) { return ((struct mad_blob *)T)->size; }
static const ID3D10BlobVtbl g_blob_vtbl = { blob_QI, blob_AddRef, blob_Release, blob_GetBufferPointer, blob_GetBufferSize };

static HRESULT mad_make_blob(const void *bytes, SIZE_T n, ID3D10Blob **out) {
    struct mad_blob *b;
    if (!out) return E_POINTER;
    b = calloc(1, sizeof *b);
    if (!b) return E_OUTOFMEMORY;
    b->data = malloc(n ? n : 1);
    if (!b->data) { free(b); return E_OUTOFMEMORY; }
    memcpy(b->data, bytes, n);
    b->vtbl = &g_blob_vtbl; b->refs = 1; b->size = n;
    *out = (ID3D10Blob *)b;
    return S_OK;
}

/* A 1.0 description differs from 1.1 only by the absence of flags on ranges
 * and root descriptors, so it is lifted to 1.1 with default flags and
 * serialized through the one serializer this runtime has. Bounded: a layout
 * bigger than the parser's own limits is refused here rather than truncated. */
static HRESULT mad_serialize_any(const D3D12_VERSIONED_ROOT_SIGNATURE_DESC *v,
                                 ID3D10Blob **blob, ID3D10Blob **err) {
    D3D12_ROOT_PARAMETER1 params[MAD_ROOT_PARAM_MAX];
    D3D12_DESCRIPTOR_RANGE1 ranges[MAD_ROOT_RANGE_MAX];
    D3D12_ROOT_SIGNATURE_DESC1 d1;
    const D3D12_ROOT_SIGNATURE_DESC1 *use;
    unsigned char out[4096];
    SIZE_T n = sizeof out;
    HRESULT hr;

    if (err) *err = NULL;
    if (!v || !blob) return E_INVALIDARG;
    if (v->Version == D3D_ROOT_SIGNATURE_VERSION_1_1) {
        use = &v->Desc_1_1;
    } else if (v->Version == D3D_ROOT_SIGNATURE_VERSION_1_0) {
        const D3D12_ROOT_SIGNATURE_DESC *d0 = &v->Desc_1_0;
        UINT nr = 0, i, j;
        if (d0->NumParameters > MAD_ROOT_PARAM_MAX) return E_NOTIMPL;
        memset(&d1, 0, sizeof d1);
        d1.NumParameters = d0->NumParameters;
        d1.pParameters = params;
        d1.NumStaticSamplers = d0->NumStaticSamplers;
        d1.pStaticSamplers = d0->pStaticSamplers;
        d1.Flags = d0->Flags;
        for (i = 0; i < d0->NumParameters; i++) {
            const D3D12_ROOT_PARAMETER *p0 = &d0->pParameters[i];
            memset(&params[i], 0, sizeof params[i]);
            params[i].ParameterType = p0->ParameterType;
            params[i].ShaderVisibility = p0->ShaderVisibility;
            switch (p0->ParameterType) {
            case D3D12_ROOT_PARAMETER_TYPE_32BIT_CONSTANTS:
                params[i].Constants = p0->Constants; break;
            case D3D12_ROOT_PARAMETER_TYPE_DESCRIPTOR_TABLE:
                if (nr + p0->DescriptorTable.NumDescriptorRanges > MAD_ROOT_RANGE_MAX) return E_NOTIMPL;
                params[i].DescriptorTable.NumDescriptorRanges = p0->DescriptorTable.NumDescriptorRanges;
                params[i].DescriptorTable.pDescriptorRanges = ranges + nr;
                for (j = 0; j < p0->DescriptorTable.NumDescriptorRanges; j++) {
                    const D3D12_DESCRIPTOR_RANGE *r0 = &p0->DescriptorTable.pDescriptorRanges[j];
                    memset(&ranges[nr], 0, sizeof ranges[nr]);
                    ranges[nr].RangeType = r0->RangeType;
                    ranges[nr].NumDescriptors = r0->NumDescriptors;
                    ranges[nr].BaseShaderRegister = r0->BaseShaderRegister;
                    ranges[nr].RegisterSpace = r0->RegisterSpace;
                    ranges[nr].OffsetInDescriptorsFromTableStart = r0->OffsetInDescriptorsFromTableStart;
                    ranges[nr].Flags = D3D12_DESCRIPTOR_RANGE_FLAG_NONE;
                    nr++;
                }
                break;
            default:
                params[i].Descriptor.ShaderRegister = p0->Descriptor.ShaderRegister;
                params[i].Descriptor.RegisterSpace = p0->Descriptor.RegisterSpace;
                params[i].Descriptor.Flags = D3D12_ROOT_DESCRIPTOR_FLAG_NONE;
                break;
            }
        }
        use = &d1;
    } else {
        d3d12_log("[madeira-d3d12] D3D12SerializeVersionedRootSignature: version %u is not supported\n",
                  (unsigned)v->Version);
        return E_NOTIMPL;
    }
    hr = MadeiraD3D12SerializeRootSignature(use, out, &n);
    if (FAILED(hr)) {
        d3d12_log("[madeira-d3d12] root signature serialization refused (%#lx)\n", (unsigned long)hr);
        return hr;
    }
    return mad_make_blob(out, n, blob);
}

HRESULT WINAPI D3D12SerializeRootSignature(
        const D3D12_ROOT_SIGNATURE_DESC *desc, D3D_ROOT_SIGNATURE_VERSION version,
        ID3D10Blob **blob, ID3D10Blob **err) {
    D3D12_VERSIONED_ROOT_SIGNATURE_DESC v;
    (void)version;   /* the description is 1.0-shaped regardless of the requested output version */
    if (!desc) return E_INVALIDARG;
    memset(&v, 0, sizeof v);
    v.Version = D3D_ROOT_SIGNATURE_VERSION_1_0;
    v.Desc_1_0 = *desc;
    return mad_serialize_any(&v, blob, err);
}

HRESULT WINAPI D3D12SerializeVersionedRootSignature(
        const D3D12_VERSIONED_ROOT_SIGNATURE_DESC *desc, ID3D10Blob **blob, ID3D10Blob **err) {
    return mad_serialize_any(desc, blob, err);
}

HRESULT WINAPI D3D12CreateDevice(IUnknown *adapter, D3D_FEATURE_LEVEL min_level,
                                                       REFIID riid, void **device) {
    /* A NULL out-pointer is the documented capability probe: answer it without
     * building a device, the way the real runtime does (S_FALSE on support). */
    d3d12_log("[madeira-d3d12] D3D12CreateDevice(adapter=%p, feature level %#x, %s)\n",
              adapter, (unsigned)min_level, device ? "create" : "probe");
    if (!device) return (min_level <= D3D_FEATURE_LEVEL_12_0) ? S_FALSE : E_INVALIDARG;
    return MadeiraD3D12CreateDevice(adapter, min_level, riid, device);
}

HRESULT WINAPI D3D12GetDebugInterface(REFIID riid, void **out) {
    (void)riid;
    if (out) *out = NULL;
    d3d12_log("[madeira-d3d12] D3D12GetDebugInterface: no debug layer on this runtime\n");
    return E_NOINTERFACE;
}

HRESULT WINAPI D3D12GetInterface(REFCLSID clsid, REFIID riid, void **out) {
    (void)clsid; (void)riid;
    if (out) *out = NULL;
    d3d12_log("[madeira-d3d12] D3D12GetInterface refused: no Agility SDK layering here\n");
    return E_NOINTERFACE;
}

HRESULT WINAPI D3D12EnableExperimentalFeatures(UINT n, const IID *iids,
                                                                     void *cfg, UINT *sizes) {
    (void)iids; (void)cfg; (void)sizes;
    d3d12_log("[madeira-d3d12] D3D12EnableExperimentalFeatures(%u) refused\n", n);
    return E_NOTIMPL;
}

HRESULT WINAPI D3D12CreateRootSignatureDeserializer(
        const void *blob, SIZE_T n, REFIID riid, void **out) {
    (void)blob; (void)n; (void)riid;
    if (out) *out = NULL;
    d3d12_log("[madeira-d3d12] D3D12CreateRootSignatureDeserializer: not implemented\n");
    return E_NOTIMPL;
}

HRESULT WINAPI D3D12CreateVersionedRootSignatureDeserializer(
        const void *blob, SIZE_T n, REFIID riid, void **out) {
    (void)blob; (void)n; (void)riid;
    if (out) *out = NULL;
    d3d12_log("[madeira-d3d12] D3D12CreateVersionedRootSignatureDeserializer: not implemented\n");
    return E_NOTIMPL;
}

HRESULT WINAPI D3D12CoreCreateLayeredDevice(const void *a, DWORD b, const void *c, REFIID d, void **e) {
    (void)a; (void)b; (void)c; (void)d; if (e) *e = NULL; return E_NOTIMPL;
}
SIZE_T WINAPI D3D12CoreGetLayeredDeviceSize(const void *a, DWORD b) { (void)a; (void)b; return 0; }
HRESULT WINAPI D3D12CoreRegisterLayers(const void *a, DWORD b) { (void)a; (void)b; return E_NOTIMPL; }
