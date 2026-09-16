/* Native shader-converter service: DXIL from the guest, metallib back.
 *
 * This is the unix half of one winemetal call. It exists because the converter
 * is a Mach-O dylib and the D3D12 runtime is an ARM64EC PE, so the bytecode has
 * to cross the same boundary every other Metal call already crosses. Riding
 * winemetal's proven unix-call path rather than inventing a second bridge keeps
 * one mechanism to reason about, and it is the bridge this DLL already uses for
 * every device call it makes.
 *
 * The conversion body is the one the M1 canary proved on macOS, on the VM and
 * on the A15. It is reproduced rather than shared because the canary is a test
 * that must stay free to check things a runtime should not do.
 *
 * Runs LOCALLY even when rendering is remote. Conversion is a pure byte
 * transform that never touches a Metal object, so there is no host handle to
 * dereference; what must follow the rendering backend is the TARGET, and that
 * arrives in the arguments rather than being read from the local device. */
#include <dlfcn.h>
#include <sys/stat.h>
#include <errno.h>
#include <pthread.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <Foundation/Foundation.h>

#include "madeira_ir_abi.h"

#define IR_PRIVATE_IMPLEMENTATION 0   /* the canary owns the one definition */
#include <metal_irconverter/metal_irconverter.h>

/* Resolved by name, so a converter that is present but incomplete is reported
 * as a missing symbol instead of crashing on a null call. */
#define IR_FUNC_LIST(X) \
    X(IRObjectCreateFromDXIL) \
    X(IRObjectDestroy) \
    X(IRObjectGetMetalIRShaderStage) \
    X(IRObjectGetMetalLibBinary) \
    X(IRObjectGetReflection) \
    X(IRCompilerCreate) \
    X(IRCompilerDestroy) \
    X(IRCompilerSetGlobalRootSignature) \
    X(IRCompilerSetEntryPointName) \
    X(IRCompilerSetMinimumDeploymentTarget) \
    X(IRCompilerSetMinimumGPUFamily) \
    X(IRCompilerSetCompatibilityFlags) \
    X(IRCompilerAllocCompileAndLink) \
    X(IRRootSignatureCreateFromDescriptor) \
    X(IRRootSignatureDestroy) \
    X(IRMetalLibBinaryCreate) \
    X(IRMetalLibBinaryDestroy) \
    X(IRMetalLibGetBytecodeSize) \
    X(IRMetalLibGetBytecode) \
    X(IRShaderReflectionCreate) \
    X(IRShaderReflectionDestroy) \
    X(IRShaderReflectionGetEntryPointFunctionName) \
    X(IRShaderReflectionCopyVertexInfo) \
    X(IRShaderReflectionCopyComputeInfo) \
    X(IRShaderReflectionReleaseComputeInfo) \
    X(IRShaderReflectionReleaseVertexInfo) \
    X(IRShaderReflectionGetResourceCount) \
    X(IRShaderReflectionGetResourceLocations) \
    X(IRCompilerEnableGeometryAndTessellationEmulation) \
    X(IRCompilerSetInputTopology) \
    X(IRCompilerSetStageInGenerationMode) \
    X(IRMetalLibSynthesizeStageInFunction) \
    X(IRShaderReflectionCopyGeometryInfo) \
    X(IRShaderReflectionReleaseGeometryInfo) \
    X(IRErrorGetCode) \
    X(IRErrorDestroy)

struct IRFns {
    void *handle;
    int   ready;
    int   status;          /* madeira_ir_status when not ready */
#define IR_DECL(n) decltype(&::n) n;
    IR_FUNC_LIST(IR_DECL)
#undef IR_DECL
};
static IRFns g_ir;
static pthread_once_t g_ir_once = PTHREAD_ONCE_INIT;

/* The dylib ships inside the app bundle, so the service finds it itself rather
 * than having the guest pass a path across. A path chosen by the guest would be
 * a guest-controlled dlopen, and the guest has no way to know where the bundle
 * landed anyway. */
static void ir_load_once(void) {
    memset(&g_ir, 0, sizeof g_ir);
    g_ir.status = MADEIRA_IR_NO_DYLIB;

#ifdef MADEIRA_IR_HOST_TEST
    /* Host-only: lets the offline round-trip test point at the converter in the
     * extracted package. Compiled out of the device build entirely, so the
     * shipping runtime has exactly one place it will load the converter from. */
    {
        const char *dev = getenv("MADEIRA_MSC_DYLIB");
        if (dev) g_ir.handle = dlopen(dev, RTLD_NOW | RTLD_LOCAL);
    }
    if (g_ir.handle) goto bind;
#endif
    @autoreleasepool {
        NSString *base = [[NSBundle mainBundle] bundlePath];
        NSString *p = [base stringByAppendingPathComponent:@"d3d12/libmetalirconverter.dylib"];
        g_ir.handle = dlopen([p UTF8String], RTLD_NOW | RTLD_LOCAL);
        if (!g_ir.handle) {
            /* Also try a plain name: a development build may have it on the
             * loader path rather than in the bundle. Named either way. */
            g_ir.handle = dlopen("libmetalirconverter.dylib", RTLD_NOW | RTLD_LOCAL);
        }
        if (!g_ir.handle) {
            fprintf(stderr, "[madeira-ir] converter not loadable at %s: %s\n",
                    [p UTF8String], dlerror());
            return;
        }
    }

#ifdef MADEIRA_IR_HOST_TEST
bind:
#endif
#define IR_BIND(n) \
    g_ir.n = (decltype(&::n))dlsym(g_ir.handle, #n); \
    if (!g_ir.n) { \
        fprintf(stderr, "[madeira-ir] converter is missing %s\n", #n); \
        g_ir.status = MADEIRA_IR_NO_SYMBOL; \
        return; \
    }
    IR_FUNC_LIST(IR_BIND)
#undef IR_BIND

    g_ir.ready = 1;
    g_ir.status = MADEIRA_IR_OK;
    fprintf(stderr, "[madeira-ir] converter ready (runtime DXIL conversion)\n");
}

static IRShaderVisibility map_visibility(uint32_t v) {
    switch (v) {
    case MADEIRA_IR_VIS_VERTEX:   return IRShaderVisibilityVertex;
    case MADEIRA_IR_VIS_HULL:     return IRShaderVisibilityHull;
    case MADEIRA_IR_VIS_DOMAIN:   return IRShaderVisibilityDomain;
    case MADEIRA_IR_VIS_GEOMETRY: return IRShaderVisibilityGeometry;
    case MADEIRA_IR_VIS_PIXEL:    return IRShaderVisibilityPixel;
    default:                      return IRShaderVisibilityAll;
    }
}

static IRDescriptorRangeType map_range(uint32_t t) {
    switch (t) {
    case MADEIRA_IR_RANGE_UAV:     return IRDescriptorRangeTypeUAV;
    case MADEIRA_IR_RANGE_CBV:     return IRDescriptorRangeTypeCBV;
    case MADEIRA_IR_RANGE_SAMPLER: return IRDescriptorRangeTypeSampler;
    default:                       return IRDescriptorRangeTypeSRV;
    }
}

extern "C" int madeira_ir_convert_impl(struct madeira_ir_convert_args *a) {
    pthread_once(&g_ir_once, ir_load_once);
    if (!a) return MADEIRA_IR_UNSUPPORTED;

    a->ret_len = 0;
    a->ret_stage = 0;
    a->ret_error_code = 0;
    if (a->out_entry) *(char *)(uintptr_t)a->out_entry = '\0';

    if (!g_ir.ready) { a->ret_status = (uint32_t)g_ir.status; return g_ir.status; }

    const struct madeira_ir_root_param *ps =
        (const struct madeira_ir_root_param *)(uintptr_t)a->params;
    const struct madeira_ir_root_range *rs =
        (const struct madeira_ir_root_range *)(uintptr_t)a->ranges;
    const uint64_t np = a->num_params;

    /* Built here rather than by the caller because these are the converter's
     * own types; the guest side speaks only the fixed-width ABI. */
    IRRootParameter1 *irp = NULL;
    IRDescriptorRange1 *irr = NULL;
    IRStaticSamplerDescriptor *irs = NULL;
    IRRootSignature *rsig = NULL;
    IRError *err = NULL;
    IRObject *input = NULL, *output = NULL;
    IRCompiler *compiler = NULL;
    IRMetalLibBinary *lib = NULL;
    IRShaderReflection *refl = NULL;
    int status = MADEIRA_IR_COMPILE_FAILED;
    const char *entry = (const char *)(uintptr_t)a->entry_point;
    IRShaderStage stage = IRShaderStageInvalid;
    size_t need = 0;
    const char *nm = NULL;
    IRVersionedRootSignatureDescriptor desc;

    if (np) {
        irp = (IRRootParameter1 *)calloc((size_t)np, sizeof *irp);
        if (!irp) { status = MADEIRA_IR_NO_MEMORY; goto done; }
    }
    if (a->num_ranges) {
        irr = (IRDescriptorRange1 *)calloc((size_t)a->num_ranges, sizeof *irr);
        if (!irr) { status = MADEIRA_IR_NO_MEMORY; goto done; }
        for (uint64_t i = 0; i < a->num_ranges; i++) {
            irr[i].RangeType = map_range(rs[i].range_type);
            irr[i].NumDescriptors = rs[i].num_descriptors;
            irr[i].BaseShaderRegister = rs[i].base_register;
            irr[i].RegisterSpace = rs[i].register_space;
            irr[i].OffsetInDescriptorsFromTableStart = rs[i].table_offset;
            irr[i].Flags = IRDescriptorRangeFlagNone;
        }
    }

    for (uint64_t i = 0; i < np; i++) {
        irp[i].ShaderVisibility = map_visibility(ps[i].visibility);
        switch (ps[i].type) {
        case MADEIRA_IR_PARAM_CONSTANTS:
            irp[i].ParameterType = IRRootParameterType32BitConstants;
            irp[i].Constants.ShaderRegister = ps[i].shader_register;
            irp[i].Constants.RegisterSpace = ps[i].register_space;
            irp[i].Constants.Num32BitValues = ps[i].num_constants;
            break;
        case MADEIRA_IR_PARAM_CBV:
        case MADEIRA_IR_PARAM_SRV:
        case MADEIRA_IR_PARAM_UAV:
            irp[i].ParameterType = ps[i].type == MADEIRA_IR_PARAM_CBV ? IRRootParameterTypeCBV
                                 : ps[i].type == MADEIRA_IR_PARAM_SRV ? IRRootParameterTypeSRV
                                                                      : IRRootParameterTypeUAV;
            irp[i].Descriptor.ShaderRegister = ps[i].shader_register;
            irp[i].Descriptor.RegisterSpace = ps[i].register_space;
            irp[i].Descriptor.Flags = IRRootDescriptorFlagNone;
            break;
        case MADEIRA_IR_PARAM_TABLE:
            if (!irr || ps[i].first_range + ps[i].num_ranges > a->num_ranges) {
                status = MADEIRA_IR_UNSUPPORTED; goto done;
            }
            irp[i].ParameterType = IRRootParameterTypeDescriptorTable;
            irp[i].DescriptorTable.NumDescriptorRanges = ps[i].num_ranges;
            irp[i].DescriptorTable.pDescriptorRanges = irr + ps[i].first_range;
            break;
        default:
            status = MADEIRA_IR_UNSUPPORTED; goto done;
        }
    }

    if (a->num_samplers) {
        const struct madeira_ir_static_sampler *ss = (const struct madeira_ir_static_sampler *)(uintptr_t)a->samplers;
        irs = (IRStaticSamplerDescriptor *)calloc(a->num_samplers, sizeof *irs);
        if (!irs || !ss) { status = MADEIRA_IR_NO_MEMORY; goto done; }
        for (uint32_t i = 0; i < a->num_samplers; i++) {
            irs[i].Filter = (IRFilter)ss[i].filter;
            irs[i].AddressU = (IRTextureAddressMode)ss[i].address_u;
            irs[i].AddressV = (IRTextureAddressMode)ss[i].address_v;
            irs[i].AddressW = (IRTextureAddressMode)ss[i].address_w;
            irs[i].MipLODBias = ss[i].mip_lod_bias;
            irs[i].MaxAnisotropy = ss[i].max_anisotropy;
            irs[i].ComparisonFunc = (IRComparisonFunction)ss[i].comparison;
            irs[i].BorderColor = (IRStaticBorderColor)ss[i].border_color;
            irs[i].MinLOD = ss[i].min_lod;
            irs[i].MaxLOD = ss[i].max_lod;
            irs[i].ShaderRegister = ss[i].shader_register;
            irs[i].RegisterSpace = ss[i].register_space;
            irs[i].ShaderVisibility = map_visibility(ss[i].visibility);
        }
    }
    memset(&desc, 0, sizeof desc);
    desc.version = IRRootSignatureVersion_1_1;
    desc.desc_1_1.NumParameters = (uint32_t)np;
    desc.desc_1_1.pParameters = irp;
    desc.desc_1_1.NumStaticSamplers = a->num_samplers;
    desc.desc_1_1.pStaticSamplers = irs;
    desc.desc_1_1.Flags = IRRootSignatureFlagNone;

    rsig = g_ir.IRRootSignatureCreateFromDescriptor(&desc, &err);
    if (!rsig) {
        a->ret_error_code = err ? g_ir.IRErrorGetCode(err) : 0;
        status = MADEIRA_IR_BAD_ROOTSIG;
        goto done;
    }

    input = g_ir.IRObjectCreateFromDXIL((const uint8_t *)(uintptr_t)a->dxil,
                                        (size_t)a->dxil_len, IRBytecodeOwnershipNone);
    if (!input) { status = MADEIRA_IR_BAD_DXIL; goto done; }

    compiler = g_ir.IRCompilerCreate();
    if (!compiler) { status = MADEIRA_IR_NO_MEMORY; goto done; }
    g_ir.IRCompilerSetGlobalRootSignature(compiler, rsig);
    /* The name is OPTIONAL, and D3D12 never supplies one: a shader bytecode
     * blob is already compiled for a single entry point. Passing NULL lets the
     * converter use the one that is actually in the bytecode instead of the
     * runtime asserting a name it cannot know. Setting it to NULL explicitly
     * crashes the converter, so the call is skipped entirely. */
    if (entry && entry[0]) g_ir.IRCompilerSetEntryPointName(compiler, entry);
    g_ir.IRCompilerSetMinimumDeploymentTarget(
        compiler,
        a->target_os == MADEIRA_IR_OS_MACOS ? IROperatingSystem_macOS : IROperatingSystem_iOS,
        (const char *)(uintptr_t)a->os_version);
    g_ir.IRCompilerSetMinimumGPUFamily(compiler, (IRGPUFamily)a->gpu_family);
    /* ml932: "HLSL shaders may legally treat textures as texture arrays and
     * vice-versa" (converter manual, Texture arrays). UE binds one resource
     * as a Texture2DArray slice to one kernel and as a Texture2D to the next
     * (TSR history: update declares 2darray, resolve declares 2d); Metal
     * returns zeros on the mismatch. With this flag every 1D/2D/cube texture
     * is an array in the converted shader, and the runtime allocates and
     * views every such texture as an array to match. */
    g_ir.IRCompilerSetCompatibilityFlags(compiler, IRCompatibilityFlagForceTextureArray);
    a->ret_len2 = 0; a->ret_vs_output_size = 0; a->ret_gs_max_prims = 0; a->ret_gs_payload = 0; a->ret_gs_passthrough = 0;
    if (a->gs_emulation) {   /* ml927 */
        IRInputTopology topo = IRInputTopologyTriangle;
        if (a->input_topology == 1) topo = IRInputTopologyPoint;
        else if (a->input_topology == 2) topo = IRInputTopologyLine;
        g_ir.IRCompilerEnableGeometryAndTessellationEmulation(compiler, true);
        g_ir.IRCompilerSetInputTopology(compiler, topo);
        if (a->layout) g_ir.IRCompilerSetStageInGenerationMode(compiler, IRStageInCodeGenerationModeUseSeparateStageInFunction);
    }

    output = g_ir.IRCompilerAllocCompileAndLink(compiler, (entry && entry[0]) ? entry : NULL,
                                                input, &err);
    if (!output) {
        a->ret_error_code = err ? g_ir.IRErrorGetCode(err) : 0;
        status = MADEIRA_IR_COMPILE_FAILED;
        /* ml863: keep the bytecode the converter refused, so the failure can
         * be reproduced on a Mac with the same converter and the real
         * diagnostics, instead of a code number on a phone. */
        {
            static int dumped;
            const char *home = getenv("HOME");
            char dir[512], path[640];
            if (!home) home = getenv("CFFIXED_USER_HOME");
            if (!home) home = "/tmp";
            snprintf(dir, sizeof dir, "%s/Documents/madeira-failed-shaders", home);
            if (dumped < 16) {
                FILE *f;
                mkdir(dir, 0755);
                snprintf(path, sizeof path, "%s/shader_%02d_code%u.bin", dir, dumped, a->ret_error_code);
                f = fopen(path, "wb");
                if (f) {
                    fwrite((const void *)(uintptr_t)a->dxil, 1, (size_t)a->dxil_len, f); fclose(f); dumped++;
                    snprintf(a->ret_note, sizeof a->ret_note, "bytecode saved to %s", path);
                } else {
                    snprintf(a->ret_note, sizeof a->ret_note, "could not save bytecode to %s (errno %d)", path, errno);
                }
            }
        }
        goto done;
    }

    stage = g_ir.IRObjectGetMetalIRShaderStage(output);
    a->ret_stage = (uint32_t)stage;

    lib = g_ir.IRMetalLibBinaryCreate();
    if (!lib || !g_ir.IRObjectGetMetalLibBinary(output, stage, lib)) {
        status = MADEIRA_IR_NO_METALLIB; goto done;
    }
    need = g_ir.IRMetalLibGetBytecodeSize(lib);
    a->ret_len = need;
    if (!need) { status = MADEIRA_IR_NO_METALLIB; goto done; }
    if (!a->out_buf || a->out_cap < need) { status = MADEIRA_IR_BUFFER_TOO_SMALL; goto done; }
    a->ret_len = g_ir.IRMetalLibGetBytecode(lib, (uint8_t *)(uintptr_t)a->out_buf);

    /* The converter RENAMES entry points, so the name to give Metal comes from
     * reflection rather than from what D3D called it.
     *
     * An empty name here is the converter's only signal that the entry point
     * did not exist: it does not reject an unknown name, it compiles and links
     * happily and produces a library with nothing callable in it. Treating that
     * as success would move the failure to a missing MTLFunction much later. */
    refl = g_ir.IRShaderReflectionCreate();
    if (refl && g_ir.IRObjectGetReflection(output, stage, refl)) {
        nm = g_ir.IRShaderReflectionGetEntryPointFunctionName(refl);
        if (nm && nm[0] && a->out_entry)
            snprintf((char *)(uintptr_t)a->out_entry, MADEIRA_IR_ENTRY_MAX, "%s", nm);
        a->ret_vs_input_count = 0;
        a->ret_loc_count = 0;
        if (a->out_locs && g_ir.IRShaderReflectionGetResourceCount && g_ir.IRShaderReflectionGetResourceLocations) {
            size_t n = g_ir.IRShaderReflectionGetResourceCount(refl);
            a->ret_loc_count = (uint32_t)n;
            if (n) {
                IRResourceLocation *rl = (IRResourceLocation *)calloc(n, sizeof *rl);
                if (rl) {
                    struct madeira_ir_loc *out = (struct madeira_ir_loc *)(uintptr_t)a->out_locs;
                    g_ir.IRShaderReflectionGetResourceLocations(refl, rl);
                    for (size_t i = 0; i < n && i < a->loc_cap; i++) {
                        out[i].type = (uint32_t)rl[i].resourceType; out[i].space = rl[i].space; out[i].slot = rl[i].slot;
                        out[i].offset = rl[i].topLevelOffset; out[i].size = rl[i].sizeBytes;
                    }
                    free(rl);
                }
            }
        }
        if (stage == IRShaderStageCompute && g_ir.IRShaderReflectionCopyComputeInfo && g_ir.IRShaderReflectionReleaseComputeInfo) {
            IRVersionedCSInfo csi;
            memset(&csi, 0, sizeof csi);
            if (g_ir.IRShaderReflectionCopyComputeInfo(refl, IRReflectionVersion_1_0, &csi)) {
                a->ret_tg_size[0] = csi.info_1_0.tg_size[0];
                a->ret_tg_size[1] = csi.info_1_0.tg_size[1];
                a->ret_tg_size[2] = csi.info_1_0.tg_size[2];
                g_ir.IRShaderReflectionReleaseComputeInfo(&csi);
            }
        }
        if (stage == IRShaderStageVertex && g_ir.IRShaderReflectionCopyVertexInfo && g_ir.IRShaderReflectionReleaseVertexInfo) {
            IRVersionedVSInfo vsi;
            memset(&vsi, 0, sizeof vsi);
            if (g_ir.IRShaderReflectionCopyVertexInfo(refl, IRReflectionVersion_1_0, &vsi)) {
                struct madeira_ir_vs_input *out = (struct madeira_ir_vs_input *)(uintptr_t)a->out_vs_inputs;
                size_t n = vsi.info_1_0.num_vertex_inputs;
                a->ret_vs_output_size = vsi.info_1_0.vertex_output_size_in_bytes;   /* ml927 */
                a->ret_vs_input_count = (uint32_t)n;
                for (size_t i = 0; out && i < n && i < a->vs_input_cap; i++) {
                    const IRVertexInputInfo_1_0 *vi = &vsi.info_1_0.vertex_inputs[i];
                    snprintf(out[i].name, sizeof out[i].name, "%s", vi->name ? vi->name : "");
                    out[i].attribute = vi->attributeIndex;
                }
                g_ir.IRShaderReflectionReleaseVertexInfo(&vsi);
            }
            /* ml927: the stage-in function for the object stage of a
             * geometry-emulation pipeline, synthesized from the application's
             * input layout (semantic names + formats). IRFormat numbering is
             * the DXGI numbering, so the formats pass through. */
            if (a->gs_emulation && a->layout) {
                const struct madeira_ir_input_layout *L = (const struct madeira_ir_input_layout *)(uintptr_t)a->layout;
                IRVersionedInputLayoutDescriptor il;
                IRMetalLibBinary *lib2 = g_ir.IRMetalLibBinaryCreate();
                memset(&il, 0, sizeof il);
                il.version = IRInputLayoutDescriptorVersion_1;
                il.desc_1_0.numElements = L->n > 31 ? 31 : L->n;
                for (uint32_t i = 0; i < il.desc_1_0.numElements; i++) {
                    il.desc_1_0.semanticNames[i] = L->el[i].semantic;
                    il.desc_1_0.inputElementDescs[i].semanticIndex = L->el[i].semantic_index;
                    il.desc_1_0.inputElementDescs[i].format = (IRFormat)L->el[i].format;
                    il.desc_1_0.inputElementDescs[i].inputSlot = L->el[i].slot;
                    il.desc_1_0.inputElementDescs[i].alignedByteOffset = L->el[i].offset;
                    il.desc_1_0.inputElementDescs[i].instanceDataStepRate = L->el[i].step_rate;
                    il.desc_1_0.inputElementDescs[i].inputSlotClass = L->el[i].per_instance ? IRInputClassificationPerInstanceData : IRInputClassificationPerVertexData;
                }
                if (lib2 && g_ir.IRMetalLibSynthesizeStageInFunction(compiler, refl, &il, lib2)) {
                    size_t n2 = g_ir.IRMetalLibGetBytecodeSize(lib2);
                    a->ret_len2 = n2;
                    if (a->out_buf2 && a->out_cap2 >= n2) g_ir.IRMetalLibGetBytecode(lib2, (uint8_t *)(uintptr_t)a->out_buf2);
                    else snprintf(a->ret_note, sizeof a->ret_note, "stage-in metallib needs %zu bytes", n2);
                } else snprintf(a->ret_note, sizeof a->ret_note, "stage-in function synthesis failed (%u elements)", il.desc_1_0.numElements);
                if (lib2) g_ir.IRMetalLibBinaryDestroy(lib2);
            }
        }
        if (stage == IRShaderStageGeometry && g_ir.IRShaderReflectionCopyGeometryInfo) {   /* ml927 */
            IRVersionedGSInfo gsi;
            memset(&gsi, 0, sizeof gsi);
            if (g_ir.IRShaderReflectionCopyGeometryInfo(refl, IRReflectionVersion_1_0, &gsi)) {
                a->ret_gs_max_prims = gsi.info_1_0.max_input_primitives_per_mesh_threadgroup;
                a->ret_gs_payload = gsi.info_1_0.max_payload_size_in_bytes;
                a->ret_gs_passthrough = gsi.info_1_0.is_passthrough ? 1u : 0u;
                g_ir.IRShaderReflectionReleaseGeometryInfo(&gsi);
            }
        }
    }
    if (!a->out_entry || !*(const char *)(uintptr_t)a->out_entry) {
        status = MADEIRA_IR_EMPTY_ENTRY;
        goto done;
    }

    status = MADEIRA_IR_OK;
done:
    if (refl) g_ir.IRShaderReflectionDestroy(refl);
    if (lib) g_ir.IRMetalLibBinaryDestroy(lib);
    if (output) g_ir.IRObjectDestroy(output);
    if (compiler) g_ir.IRCompilerDestroy(compiler);
    if (input) g_ir.IRObjectDestroy(input);
    if (rsig) g_ir.IRRootSignatureDestroy(rsig);
    if (err) g_ir.IRErrorDestroy(err);
    free(irs);
    free(irr);
    free(irp);
    a->ret_status = (uint32_t)status;
    return status;
}

/* winemetal's unix dispatch table entry. Signature matches every other slot. */
extern "C" int madeira_ir_convert(void *args) {
    madeira_ir_convert_impl((struct madeira_ir_convert_args *)args);
    return 0;   /* the call itself succeeded; ret_status carries the outcome */
}
