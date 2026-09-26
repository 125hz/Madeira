# ml1990: logs 79–85

Build ml1980 logs: 79 app 22380, 80 app 220, 81 app 304430, 82 app 3525970,
83/84 (identical) app 2707900, 85 app 50130. All changes are generic, each has a
kill switch and an ml1990 tag. Nothing is device-proven.

| Log | Finding | Change |
| --- | --- | --- |
| 85 | Game exits 0x8000DEAD: its executable is a per-user custom executable (Valve CEG) and the downloaded copy was never prepared for the account. Dock/auth/launch all succeeded. | Downloader records CustomExecutable files (`CheckGuid` block) and keeps those depots' manifests in `steamapps/depotcache` (`[steam-ceg] ml1990`, `MADEIRA_STEAM_CEG_RECORDS=0`). Dock calls Valve's `IClientUser::RequestCustomBinaries` (slot 71, pinned in both client builds) before LaunchApp and waits for per-job callback 1020025; failure = host result 49, no launch (`MADEIRA_DOCK_CEG=0`). Existing installs: **Repair installed files** once. |
| 81 | ml1980 start-wait fix works (GC no longer deadlocks). Next: locks in pool-aliased RWX memory lose wake-ups: the excl-alias fault handler left the RW alias in the base register, so `RtlWakeAddressSingle` keyed the wrong address (5 s timeouts). | Store-exclusive on a secondary alias is emulated in place (CAS against the value the paired load-exclusive observed) keeping the base register (`[excl-alias] ml1990 keepbase`, `MADEIRA_EXCL_ALIAS_KEEPBASE=0`). Not addressed yet: the managed heap being carved into the JIT pool (140k store faults/s). |
| 82 | Root-signature deserializers work (159×); the game was still converting shaders at 31 s (no Present yet). Each DXIL stage compiled twice; no DXIL cache. | One-pass conversion (`MADEIRA_D3D12_ONEPASS=0`), persistent content-keyed metallib cache in Documents/shadercache, 512 MB LRU (`MADEIRA_D3D12_DXIL_CACHE=0`, `[d3d12-dxil-cache] ml1990`), CS debug dumps opt-in (`MADEIRA_D3D12_CS_DUMP=1`). |
| 83 | Menu gated on an MP4 (Unity VideoPlayer via MF); 64-bit side could not open MP4 → ~12 retries/s, which exhausted the append-only thread registry (512) and trampoline slots (256), aliasing slot 0's TEB. | wg_parser MP4/MOV: libavformat demux + VideoToolbox H.264/HEVC → NV12/I420/YV12/YUY2/RGB, AudioToolbox AAC (no FFmpeg H.264/AAC decoders) (`MADEIRA_WG_VIDEO=0`, `MADEIRA_WG_VIDEO_FORMAT`). Thread registry and trampoline slots reclaim dead threads, never alias slot 0 (`MADEIRA_THREAD_REG_RECLAIM=0`, `MADEIRA_THREAD_REG_NO_ALIAS=0`, `MADEIRA_TRAMP_RECLAIM=0`). FEX code-buffer generation 32 MB when headroom ≥64 MB (`MADEIRA_TAIL_GEN_WIDE=0`). |
| 80 | Not a crash: main thread waits forever on a job while one worker spins (~87 % CPU); cause unproven. Controller: SDL enumerated XInput once at startup, before any pad slot existed; hot-plug notification unavailable (no plugplay). | Slot 0 published at session start when touch controls are on or a controller is paired (`MADEIRA_PAD_EARLY_SLOT=0`). Hang: may share INSIDE's lost-wake mechanism; needs the next log. |
| 79 | MP3 playback now works (music plays); the crash is identical and deterministic: a background loader thread calls through a NULL pointer taken from its TLS. Cause unproven. | Per-game **CPU cores reported** setting (`MADEIRA_CPU_COUNT`, overrides the global `cpu-count`). Owner A/B: cores = 2; reduced-precision x87 off. |

UI: the "Madeira Dock uses your Steam sign-in…" line is hidden during Dock starts
(`MADEIRA_DOCK_START_NOTE=1` restores); the installed Steam and Other games sections
collapse like Not installed (`MADEIRA_LIBRARY_COLLAPSE=0`).

Validation: host tests (ml1970 incl. CheckGuid, wg-parser incl. MP4/AAC with stub
video decoder, excl-keepbase, thread-slots, dxil-cache, Dock 51 validation cases +
client-layout slot 71 checks) pass; FFmpeg, native, DXMT, madeira_d3d12, Dock builds
pass. IPA `ml1990 · 09-25 22:16`, 166,869,002 bytes / 1,391 entries, SHA-256
`f90ca1754b516af135b15c3c3b51d950585be90cb0000976a748a8ec95da5811`; Dock SHA-256
`69f68bde16efa1098e9957b40ab76d7c08015c57e37325e678f475bee7e8a16c`. Verifier
`.xtool/verify-ml1990.py`. No commit/push.
