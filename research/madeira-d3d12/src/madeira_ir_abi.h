/* Shared ABI between the ARM64EC D3D12 runtime and the native shader-converter
 * service, crossed exactly once per pipeline creation via winemetal's unix call.
 *
 * Why this lives in its own header rather than inside either side: the two ends
 * are compiled by different toolchains (mingw ARM64EC PE, and Apple clang for
 * the Mach-O side), so a struct described twice would drift silently and the
 * first symptom would be a misread field rather than a build error.
 *
 * Every field is fixed-width and the struct is explicitly padded, because the
 * two compilers only agree on layout if nothing is left to their discretion.
 *
 * Pointers cross as uint64_t. Both sides are 64-bit and share one address
 * space, but writing them as pointers would make the layout depend on each
 * compiler's pointer type, which is exactly what this header exists to avoid. */
#ifndef MADEIRA_IR_ABI_H
#define MADEIRA_IR_ABI_H

#include <stdint.h>

#define MADEIRA_IR_ENTRY_MAX 256

/* Deliberately NOT the D3D12 enum values. The unix side must not include d3d12.h
 * and the converter has its own enum; naming our own constants means the mapping
 * is written out once, in one place, instead of relying on two vendors happening
 * to agree. */
enum madeira_ir_param_type {
    MADEIRA_IR_PARAM_TABLE     = 0,
    MADEIRA_IR_PARAM_CONSTANTS = 1,
    MADEIRA_IR_PARAM_CBV       = 2,
    MADEIRA_IR_PARAM_SRV       = 3,
    MADEIRA_IR_PARAM_UAV       = 4,
};

enum madeira_ir_range_type {
    MADEIRA_IR_RANGE_SRV     = 0,
    MADEIRA_IR_RANGE_UAV     = 1,
    MADEIRA_IR_RANGE_CBV     = 2,
    MADEIRA_IR_RANGE_SAMPLER = 3,
};

enum madeira_ir_visibility {
    MADEIRA_IR_VIS_ALL      = 0,
    MADEIRA_IR_VIS_VERTEX   = 1,
    MADEIRA_IR_VIS_HULL     = 2,
    MADEIRA_IR_VIS_DOMAIN   = 3,
    MADEIRA_IR_VIS_GEOMETRY = 4,
    MADEIRA_IR_VIS_PIXEL    = 5,
};

enum madeira_ir_os { MADEIRA_IR_OS_IOS = 0, MADEIRA_IR_OS_MACOS = 1 };

/* Each distinct failure gets its own code so a device log says which step gave
 * way. A single generic failure code would make "the converter is missing" and
 * "this shader does not compile" indistinguishable, and those need opposite
 * responses. */
enum madeira_ir_status {
    MADEIRA_IR_OK              = 0,
    MADEIRA_IR_NO_DYLIB        = 1,  /* the converter could not be loaded at all */
    MADEIRA_IR_NO_SYMBOL       = 2,  /* loaded, but an entry point is missing */
    MADEIRA_IR_BAD_DXIL        = 3,  /* the converter rejected the bytecode */
    MADEIRA_IR_BAD_ROOTSIG     = 4,  /* the converter rejected the root signature */
    MADEIRA_IR_COMPILE_FAILED  = 5,
    MADEIRA_IR_NO_METALLIB     = 6,  /* compiled, but produced no library */
    MADEIRA_IR_BUFFER_TOO_SMALL= 7,  /* ret_len holds the size actually needed */
    MADEIRA_IR_EMPTY_ENTRY     = 8,  /* reflection gave no name: see below */
    MADEIRA_IR_UNSUPPORTED     = 9,  /* a root parameter we do not model yet */
    MADEIRA_IR_NO_MEMORY       = 10,
};

struct madeira_ir_root_param {
    uint32_t type;              /* madeira_ir_param_type */
    uint32_t shader_register;
    uint32_t register_space;
    uint32_t num_constants;     /* MADEIRA_IR_PARAM_CONSTANTS only */
    uint32_t visibility;        /* madeira_ir_visibility */
    uint32_t num_ranges;        /* MADEIRA_IR_PARAM_TABLE only */
    uint32_t first_range;       /* index into the ranges array */
    uint32_t reserved;
};

struct madeira_ir_root_range {
    uint32_t range_type;        /* madeira_ir_range_type */
    uint32_t num_descriptors;
    uint32_t base_register;
    uint32_t register_space;
    uint32_t table_offset;
    uint32_t reserved;
};

/* One conversion: one DXIL blob, one entry point, one target.
 *
 * The caller supplies the output buffer. The service allocating and handing
 * back converter-owned memory would put a free() across the PE/unix boundary,
 * and the lifetime rule that avoids is the same one the canary follows: nothing
 * the converter owns escapes the call that created it. */
struct madeira_ir_convert_args {
    uint64_t dxil;              /* in: bytecode the application supplied */
    uint64_t dxil_len;          /* in */
    uint64_t entry_point;       /* in: const char *, the D3D-side entry name */

    uint64_t params;            /* in: const struct madeira_ir_root_param * */
    uint64_t num_params;        /* in */
    uint64_t ranges;            /* in: const struct madeira_ir_root_range * */
    uint64_t num_ranges;        /* in */
    uint64_t root_flags;        /* in: reserved, must be 0 */

    uint32_t target_os;         /* in: madeira_ir_os */
    uint32_t gpu_family;        /* in: IRGPUFamily, chosen from the real device */
    uint64_t os_version;        /* in: const char *, e.g. "17.0" */

    uint64_t out_buf;           /* in: where to write the metallib, may be 0 */
    uint64_t out_cap;           /* in: capacity of out_buf */
    uint64_t out_entry;         /* in: char[MADEIRA_IR_ENTRY_MAX] for the name */

    uint64_t ret_len;           /* out: metallib size, set even when too small */
    uint32_t ret_stage;         /* out: IRShaderStage the converter reported */
    uint32_t ret_status;        /* out: madeira_ir_status */
    uint32_t ret_error_code;    /* out: the converter's own code, when it gave one */
    uint32_t reserved;
    /* ml859: vertex-stage inputs from reflection, so a pipeline can map the
     * application's input layout onto the attribute indices the converted
     * vertex shader actually reads. Ignored for other stages. */
    uint64_t out_vs_inputs;     /* in: struct madeira_ir_vs_input[vs_input_cap], may be 0 */
    uint32_t vs_input_cap;      /* in */
    uint32_t ret_vs_input_count;/* out: how many the shader has (may exceed cap) */
    uint64_t samplers;          /* in: const struct madeira_ir_static_sampler *, may be 0 */
    uint32_t num_samplers;      /* in */
    uint32_t reserved2;
    uint32_t ret_tg_size[3];    /* out: compute threadgroup size from reflection */
    uint32_t reserved3;
    char ret_note[128];         /* out: a diagnostic sentence from the service, may be empty */
    /* ml882: where the converter placed each top-level resource in the
     * argument buffer (IRShaderReflectionGetResourceLocations). Ground truth
     * for the layout; the runtime's own computation is checked against it. */
    uint64_t out_locs;          /* in: struct madeira_ir_loc[loc_cap], may be 0 */
    uint32_t loc_cap;           /* in */
    uint32_t ret_loc_count;     /* out: how many the shader references (may exceed cap) */
    /* ml927: geometry-shader pipelines go through the converter's mesh
     * emulation. Every stage of such a pipeline is compiled with emulation on;
     * the vertex stage also gets a stage-in function synthesized from the
     * application's input layout (a second metallib), and reflection reports
     * the numbers the pipeline and the draws need. */
    uint32_t gs_emulation;      /* in: 1 = this stage belongs to a pipeline with a geometry shader */
    uint32_t input_topology;    /* in: D3D12_PRIMITIVE_TOPOLOGY_TYPE (1 point, 2 line, 3 triangle) */
    uint64_t layout;            /* in: const struct madeira_ir_input_layout *, vertex stage only */
    uint64_t out_buf2;          /* in: where the stage-in metallib goes, may be 0 */
    uint64_t out_cap2;          /* in */
    uint64_t ret_len2;          /* out: stage-in metallib size (0 = none produced) */
    uint32_t ret_vs_output_size;/* out: vertex-stage output size in bytes */
    uint32_t ret_gs_max_prims;  /* out: geometry stage: max input primitives per mesh threadgroup */
    uint32_t ret_gs_payload;    /* out: geometry stage: payload bytes */
    uint32_t ret_gs_passthrough;/* out: geometry stage: the converter calls it a passthrough */
};
struct madeira_ir_input_element {
    char semantic[32];
    uint32_t semantic_index, format /* DXGI_FORMAT == IRFormat numbering */, slot, offset, per_instance, step_rate;
};
struct madeira_ir_input_layout {
    uint32_t n, reserved;
    struct madeira_ir_input_element el[31];
};
struct madeira_ir_loc {
    uint32_t type;              /* IRResourceType: 0 table, 1 constant, 2 cbv, 3 srv, 4 uav, 5 sampler */
    uint32_t space, slot;       /* DXIL space / register */
    uint32_t offset;            /* byte offset in the top-level argument buffer */
    uint64_t size;              /* entry size in bytes */
};
/* ml861: a static sampler, field for field the D3D12 description. The
 * converter's enums carry the D3D12 numbering, so every value passes through
 * unchanged and is baked into the shader as a constant sampler. */
struct madeira_ir_static_sampler {
    uint32_t filter, address_u, address_v, address_w;
    float mip_lod_bias;
    uint32_t max_anisotropy, comparison, border_color;
    float min_lod, max_lod;
    uint32_t shader_register, register_space, visibility;
    uint32_t reserved;
};
struct madeira_ir_vs_input {
    char name[60];              /* the converter's name for the input */
    uint32_t attribute;         /* Metal vertex attribute index */
};

#endif /* MADEIRA_IR_ABI_H */
