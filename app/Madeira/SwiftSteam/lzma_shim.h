#ifndef lzma_shim_h
#define lzma_shim_h

#include <stddef.h>
#include <stdint.h>

/// Decode a raw LZMA1 stream using the 5-byte LZMA property block
/// (props byte + 4-byte dictionary size, as found in Steam's VZip chunks).
/// Returns 0 (LZMA_OK) on success; out_produced receives bytes written.
int lzma_shim_decode(const uint8_t *props, size_t props_size,
                     const uint8_t *in, size_t in_size,
                     uint8_t *out, size_t out_size,
                     size_t *out_produced);

#include "zstd_edu.h"

#endif
