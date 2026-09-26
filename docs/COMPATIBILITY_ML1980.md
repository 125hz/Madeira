# ml1980: logs 73–78 and the owner's feature list

Build ml1970 logs: 73 app 17410 (long session), 74 app 220 (Dock content wait),
75 app 3525970, 76 app 304430, 77 app 22380, 78 a 32-bit D3D9 title's cursor.
Every change below is generic, has a kill switch and an ml1980/ml1970 tag.
Nothing is device-proven yet.

| Log | Finding | Change |
| --- | --- | --- |
| 74 | Dock's ml1970 wait works: error 17 → `launch-update-wait`, retries every 10/20/30 s. Session ended at ~40 s with Steam's update still *Queued* (0 bytes); no download evidence yet. | Progress banner shows an activity indicator while queued/verifying, then a bar with speed and time left. If Steam never starts, "Repair installed files" now writes the owner records Steam expects (ml1970). |
| 76 | Same GC deadlock as log 70: the ml1970 clear never ran. The server's `init_process_done` reply is `suspend=1` (normal Wine), but the iOS client (`server_ios.c`) always overrides it to 0, so the first thread never parks and never posts its start context. | Clear `ios_start_pending` in `init_process_done` regardless of the reply; a context left PENDING by an early reader becomes refreshable (`[ctx-start] ml1980`). |
| 75 | dcomp/typed-UAV fixes worked: D3D12 device, queues, heaps created. Every shader then failed on `D3D12CreateRootSignatureDeserializer` = E_NOTIMPL (203×); a later null dereference exited the game. | Both root-signature deserializers implemented (1.0/1.1, shared RTS0 rules, stable descs, bounded refusals) (`[d3d12-rsdeser] ml1980`, `MADEIRA_D3D12_RS_DESERIALIZER=0`); native x86-64 round-trip test, 8920 checks. |
| 77 | Not a hang: the game crashed (NULL read in the game) right after the intro video, while its MP3 music could not play (quartz MPEG-I/"GStreamer" splitter fail — the port's wg_parser was entirely unimplemented). | ffmpeg-backed wg_parser for audio (see below). |
| 73 | No crash; late 30–35 fps windows are heavier scenes (GPU ms/pass flat, ≤5 % thermal). ~45 forced queue drains/s from managed-texture lock readbacks serialise CPU and GPU. | Read back all stale mip levels in one drain on the first lock (`MADEIRA_D3D9_MIRROR_BATCH=0`); `[d9-drain] ml1980` drain count/time. |
| 78 | The "big cursor" is Madeira's fallback arrow (14×21 pt fixed) revealed over a game that never set a cursor and draws its own; the user steered an arrow the game ignores. Input delivery itself works. | Fallback arrow sized in guest pixels (`MADEIRA_CURSOR_FALLBACK_SCALE=0`); no reveal when the program never supplied a cursor (`MADEIRA_CURSOR_REVEAL_UNSET=1` restores). |

## App

* Downloads in the background: iOS 26+ `BGContinuedProcessingTask` for the queue
  (system progress UI fed from the downloader's byte counts; expiry pauses cleanly);
  otherwise the normal short grace period, then a clean pause + resume on return.
  Local notifications for finished/failed/paused downloads while in the background.
  `MADEIRA_BACKGROUND_DOWNLOADS=0`, `MADEIRA_DOWNLOAD_NOTIFICATIONS=0`, `[bg-download] ml1980`.
  Info.plist `BGTaskSchedulerPermittedIdentifiers` = `<bundle id>.download.*`; a
  re-signed bundle ID that no longer matches only disables the iOS 26 path (logged).
* Steam playtime and last played: `Player.GetOwnedGames#1` over the account's own
  connection, cached, refreshed at start/library refresh/session end; shown in list
  rows, cards, details and the Steam game sheet (`MADEIRA_STEAM_PLAYTIME=0`, `[steam-playtime] ml1970`).
* Library layout **Compact list** (one short row, same badges and playtime).
* The "Steam" pill is gone ("Not installed" stays; `MADEIRA_STEAM_BADGE=1`).
* The details page stays until the starting screen takes over (or an error/prompt
  needs the library) instead of showing the library for 1–2 s (`MADEIRA_DETAIL_HOLD=0`).

## DirectShow audio (log 77)

`build/ntdll-unix/wg_parser_av_ios.c` (included by `winegstreamer_unixlib_ios.c`):
the wg_parser subset quartz and the MF media source use, on libavformat/libavcodec/
libswresample. Pull-mode AVIO over the PE read thread's get_next_read_offset/push_data
protocol; MP3 (mp1/mp2/mp3) and WAV/PCM only, decoded to interleaved PCM; compressed-
output splitters accept PCM only so an MP3 falls through to the decoding splitter; video
and unknown input are refused at connect. Accurate seek/stop, read-error and disconnect
handling, native + wow64 tables with 32-bit layout asserts. `MADEIRA_WG_PARSER=0`,
`[wg-parser] ml1980` (16 lines/process). FFmpeg now also builds libavformat (mp3/wav
demuxers, mpegaudio parser, mp1/2/3 + pcm decoders), still LGPL-only; linked via
`.xtool/prepare.py`; THIRD-PARTY-NOTICES updated. Host test `check-wg-parser.py`
(ASan/UBSan; real MP3 + synthetic MPEG audio + WAV, seek/stop/error/disconnect) passes.
Whether the game then survives its New Game transition is unproven.

## Validation and artifact

Host: check-ml1970, check-wg-parser, steam-native/library, onboarding, control
presets/edit, launch-view and compatibility suites pass; D3D12 deserializer round-trip
(8920 checks). Builds: FFmpeg, native ntdll/wineserver, DXMT PE (i386/aarch64/arm64ec),
madeira_d3d12. `xtool/Madeira.ipa` `ml1980 · 09-25 20:47`, 166,716,173 bytes / 1,391
entries, SHA-256 `244144eab23608c00e596134bb70d5ce6e0f74685e8ce113fd96af763b37ab7e`,
verifier `.xtool/verify-ml1980.py` (report `.xtool/logs/ml1980-verified.json`).
Dock unchanged. No commit/push.
