// madeira-bcd: helper kernels for madeira_d3d12.dll, compiled to a metallib by
// build/madeira-d3d12/build-pe.sh and embedded in the DLL.
#include <metal_stdlib>
using namespace metal;

// Diagnostics: copy the first n words of an argument record (indirect draw or
// dispatch arguments the GPU wrote) to a CPU-visible ring, read seconds later.
kernel void mad_probe_words(device const uint *src [[buffer(0)]],
                            device uint *dst [[buffer(1)]],
                            constant uint &n [[buffer(2)]],
                            uint i [[thread_position_in_grid]])
{
    if (i < n)
        dst[i] = src[i];
}
