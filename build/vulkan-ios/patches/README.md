# Direct pipeline-cache export backport

`0001-direct-cache-export.patch` applies to MoltenVK v1.4.2,
`db66022459ffb663aa2b50f6b018bc2e124f5edf`. It changes only the placement
of the existing serialization size calculation in `MVKPipelineCache::writeDataImpl`.
The patch is to Apache-2.0 MoltenVK source; its copyright and license notices are
unchanged. No other experimental MoltenVK policy is included.

The cached `_dataSize` starts at zero. Previously only a `pData == NULL` size
query calculated it. A direct data call used a zero-length stream even when
the application supplied sufficient space, returning VK_INCOMPLETE / zero
bytes. Calculate the size before choosing either branch. Existing locking,
serialization format, buffer bounds and native results remain unchanged.

A prior size query is not a requirement of
[vkGetPipelineCacheData](https://docs.vulkan.org/refpages/latest/refpages/source/vkGetPipelineCacheData.html).
The regression uses valid, complete vertex input with rasterization discarded;
it does not prime the cache with invalid shader interfaces or use game content.
It tests empty/populated caches, direct/queried bytes and cache headers, and a
one-byte buffer. It does not submit rendering or claim an image-readback result.

This is an optional backport for the static backend introduced in #454. It is
not enabled by a runtime cfg switch or by the default official-archive build.
The fix belongs in MoltenVK upstream as well; this patch is narrowly retained
here to make the pinned Madeira-side experiment reproducible while that is
coordinated. Do not present the whole Detroit experiment as validated by it.

## macOS reproduction

The ordinary upstream v1.4.2 library is expected to fail direct exports. Build
only this patch in a dedicated source checkout, with Xcode/dependencies available:

```sh
bash build/vulkan-ios/build-cache-export-source.sh macos
python3 tests/vulkan/check-cache-export-native.py \
  toolchains/moltenvk-cache-export-source/External/Vulkan-Headers/include \
  toolchains/moltenvk-cache-export-source/Package/Release/MoltenVK/dylib/macOS/libMoltenVK.dylib
```

`MADEIRA_MOLTENVK_SOURCE` may select an existing dedicated v1.4.2 checkout.
The helper rejects unrelated tracked changes rather than borrowing the broad
Detroit experiment's library. The helper can also be run again on its exact
one-patch result. Builds use upstream's fetchDependencies and clean Xcode build;
this does not replace the prerequisites in docs/BUILDING.md.

## Optional iOS static build

```sh
bash build/vulkan-ios/fetch.sh
bash build/vulkan-ios/build-cache-export-source.sh ios
MADEIRA_MOLTENVK_LIBRARY="$PWD/toolchains/moltenvk-cache-export/ios-arm64/libMoltenVK.a" \
  bash build/vulkan-ios/build.sh
```

Continue #454's documented native/PE/Xcode Debug build. Both native components
need `MADEIRA_MOLTENVK=1`, and the app needs
`MADEIRA_VULKAN_LDFLAGS=-lmadeira_vulkan`. For this static build the session cfg
selection is `vulkan = static`. Rebuilding just the app does not rebuild the
native archive. Return to the official backend by rebuilding build.sh without
the library override and relinking; no user shader cache deletion is required.

Build the ordinary Windows-side fixture:

```sh
TC=toolchains/llvm-mingw-20260421-ucrt-macos-universal/bin
"$TC/x86_64-w64-mingw32-clang" -O2 -Wall -Wextra -Werror \
  -Itoolchains/moltenvk/MoltenVK/include tests/x64/vulkan-cache-export.c \
  -o vulkan-cache-export-x64.exe
```

Launch it directly as x64 under the matching signed Debug package with JIT.
Acceptance is successful direct and queried exports, matching valid header/data,
VK_INCOMPLETE for the short buffer, final PASS and guest exit0. It has no visible
window. The old broader experiment's iPad/game results are not device proof for
this isolated patch or for the integrated #454 build. This does not promise
Detroit compatibility, faster shader compilation, cache reuse across upgrades,
or debugger-detach stability.
