# Third-party components

Madeira is built from several upstream projects plus original work. Each
component keeps its own license. This file records what is here, what ships in
the binary, and what is still unresolved.

Madeira's own code, and the combined application as distributed, are under
**GPL-3.0-or-later** (`LICENSE`). Each upstream keeps its own license; the
dependency license texts are in `LICENSES/`. See "Why GPL-3.0-or-later" below.

## Components that ship in the built app

| Component | Upstream license | **Madeira's fork** | Notes |
|---|---|---|---|
| **Wine** | LGPL-2.1-or-later | **GPL-3.0-or-later** | Fork relicensed under LGPL-2.1 §3, which expressly permits applying the ordinary GPL to a copy. `ntdll`, `wineserver`, `win32u`, ARM64EC loader modified for iOS. |
| **FEX-Emu** | MIT | upstream MIT + **modifications GPL-3.0-or-later** | Forked. x86-64 → ARM64 translation. |
| **DXMT** | MIT | upstream MIT + **modifications GPL-3.0-or-later** | Forked. D3D11 → Metal. |
| **DXMT — Direct3D 9 / DXSO frontend** | **LGPL-2.1-or-later** | **GPL-3.0-or-later** | Imported into `research/dxmt` from a different fork of the same upstream: `https://github.com/dacevedo12/dxmt.git`, tag `v0.4-d3d9`, commit `e8dd4c656dcb74a6d970a30a397d1558b0e3fb2b` ("Copyright (c) 2023-2026 Feifan He for CodeWeavers"). That tag postdates upstream's MIT→LGPL relicense, so it is **not** MIT. Converted under LGPL-2.1 §3, which expressly permits distributing a copy under the ordinary GPL — the same route this repository took for its Wine fork. Licence text in `research/dxmt/COPYING.LIB`; the file-by-file list is in `research/dxmt/LICENSE-MADEIRA.md`. |
| **rpmalloc** | 0BSD | 0BSD + **Will Faust's modifications GPL-3.0-or-later** | Nested submodule of FEX, forked to `willfaust/rpmalloc`. Commits by Ryan Houdek are **not** relicensed. |
| **GMP** 6.3.0 | **LGPL-3.0-or-later** or GPL-2.0-or-later | Static (`libgmp.a`). |
| **Nettle / Hogweed** 3.10.1 | **LGPL-3.0-or-later** or GPL-2.0-or-later | Static (`libnettle.a`, `libhogweed.a`). |
| **GnuTLS** 3.8.9 | LGPL-2.1-or-later | Static (`libgnutls.a`). Used by Wine's bcrypt/secur32/crypt32. |
| **FFmpeg** 7.1.1 — libavcodec, libavutil, libswresample | **LGPL-2.1-or-later** | Static (`libavcodec.a`, `libavutil.a`, `libswresample.a`). Configured `--disable-gpl --disable-nonfree --disable-version3`, `--disable-everything` plus the six WMA-family decoders (`wmav1,wmav2,wmapro,wmalossless,xma1,xma2`); no GPL or non-free component is enabled, and no `--enable-version3` component, so the result is LGPL-2.1-or-later. Used only by `build/ntdll-unix/winegstreamer_unixlib_ios.c`, which is winegstreamer's unix side on this port (the Windows WMA decoder MFT/DMO — upstream decodes it with GStreamer, which does not exist on iOS). |
| **{fmt}** | MIT | Static (`libfmt.a`), via FEX. |
| **xxHash** | BSD-2-Clause | Static (`libxxhash.a`). |
| **Cephes** | permissive (Moshier) | Static (`libcephes_128bit.a`), via FEX. |
| **Berkeley SoftFloat 3e** | BSD-3-Clause | Static (`libsoftfloat_3e.a`), via FEX. |

## Why GPL-3.0-or-later

The intent is that derivatives stay open source. LGPL deliberately permits
proprietary applications to link against the covered work, which does not serve
that intent; GPL requires distributed derivative and combined works to remain
GPL-compatible and to offer source.

The dependencies permit this. Wine and GnuTLS are LGPL-2.1-**or-later** and GMP
and Nettle are LGPL-3.0-or-later; LGPL explicitly allows a combined work to be
distributed under GPL terms, and the MIT and BSD components impose no obstacle.

What GPL does and does not achieve here, stated plainly so it is not
over-relied on:

- Obligations attach on **distribution**. Someone may modify this privately and
  never publish anything.
- It does **not** cover games, data files or other independent programs merely
  run through Madeira. They are separate works.
- It cannot stop anyone independently reimplementing the same functionality.
- FEX-Emu and DXMT code already published under MIT **remains available under
  MIT**. Choosing GPL here cannot revoke a grant those projects already made.
  If the intent is for changes inside the submodule forks to be GPL too, those
  repositories need their own licensing decision; this file governs the main
  repository.

## Each fork carries its own license notice

`THIRD-PARTY-NOTICES.md` in this repository does **not** relicense code that
lives in a separate submodule. Each fork therefore carries its own
`LICENSE-MADEIRA.md` and `CONTRIBUTING.md` stating what is licensed how:

- `wine/LICENSE-MADEIRA.md` — the LGPL-2.1 §3 conversion, exactly what changed
  and the two deliberate exceptions.
- `FEX/LICENSE-MADEIRA.md`, `research/dxmt/LICENSE-MADEIRA.md` — upstream MIT
  preserved; Madeira's modifications GPL-3.0-or-later. `research/dxmt`'s notice
  also records the LGPL-2.1-or-later Direct3D 9 / DXSO import and its §3
  conversion, file by file.
- `FEX/External/rpmalloc/LICENSE-MADEIRA.md` — 0BSD preserved; only Will
  Faust's commits are GPL, and authorship is distinguishable via `git log`.

### What relicensing does and does not achieve

The goal is that **distributed** derivatives stay open source. Stated honestly:

- **It is not retroactive.** The FEX, DXMT and Wine forks were public before
  this change, under their upstream permissive/lesser licenses. Anyone who
  already obtained a copy keeps those rights, and that grant cannot be revoked.
  Only contributions from 2026-08-28 onward are GPL-only.
- Upstream projects are unaffected and their code stays available from them
  under its original license.
- The GPL constrains distribution, not private modification or internal use.
- It does not cover games or other independent programs merely run through
  Madeira.

## Original vs. derived work in this repository

Do **not** assume that everything outside the submodules is original. It is not.

- `build/ntdll-unix/`, `build/wineserver/`, `build/win32u-unix/` and similar are
  substantially **Wine-derived**. Files such as `build/ntdll-unix/loader_ios.c`
  are forks of upstream Wine sources and retain upstream copyright headers
  (e.g. "Copyright (C) 2020 Alexandre Julliard"). Roughly 2,700 files under
  `build/` carry an upstream copyright notice of some kind.
- `build/gnutls-ios/` contains build scripting only; the library sources are
  fetched separately (see the open issue below).
- `app/`, `tools/`, `scripts/` and `patches/` are largely original, but contain
  vendored and derived files too.

Rather than claim authorship of whole directories: **original Madeira-authored
files that do not carry another license notice are licensed under
GPL-3.0-or-later.** Files carrying their own copyright or license header are
governed by that header.

## Microsoft Visual C++ runtime redistributables — NOT DISTRIBUTED

Games built with MSVC require Microsoft's Visual C++ runtime DLLs. Those are
Microsoft-authored binaries, redistributable only under the Visual Studio
redistributable terms and only in unmodified form. They are **not** covered by
this project's license and are **no longer tracked in this repository**;
`app/Madeira/x86_64-vcruntime/*.dll` is gitignored and must be supplied locally.
See `tools/fetch-vcruntime.md`.

### Earlier malformed copies were purged from history

Twelve such DLLs were previously committed here, and they had been modified:
each one's Authenticode signature had been truncated away, removing exactly the
advertised certificate payload and leaving a PE header still claiming a
signature the file no longer contained.

Those blobs have been removed from this repository's history entirely. Anyone
holding a clone or fork taken before the rewrite may still have them, and should
not redistribute those copies.

## Corresponding source for the statically linked libraries

`libgmp.a`, `libnettle.a`, `libhogweed.a` and `libgnutls.a` are tracked as
compiled binaries, so the exact sources they were built from are tracked too:

- `build/gnutls-ios/src/gmp-6.3.0.tar.xz`
- `build/gnutls-ios/src/nettle-3.10.1.tar.gz`
- `build/gnutls-ios/src/gnutls-3.8.9.tar.xz`
- `build/gnutls-ios/src/SHA256SUMS` -- checksums for the above
- `build/gnutls-ios/build.sh` -- the exact build machinery and configure flags

All three are unmodified upstream releases; no patches are applied. A reference
to an upstream project would not have been enough on its own, which is why the
tarballs themselves are here.

FFmpeg is handled differently on purpose: its archives are **not** tracked as
compiled binaries in this repository, so there is nothing here that a source
tarball would have to correspond to. The build script fetches the unmodified
upstream release itself and refuses to build anything else:

- `.xtool/build-ffmpeg.sh` -- the exact build machinery and configure flags,
  including the release (`7.1.1`), its download URL on `ffmpeg.org`, and the
  SHA-256 (`733984395e0dbbe5c046abda2dc49a5544e7e0e1e2366bba849222ae9e3a03b1`)
  that every run verifies before extracting. No patches are applied.

Anyone distributing a built `.ipa` that contains these archives owes the same
corresponding source as for the crypto stack above; the pinned version and
checksum identify it exactly.

## Relinking and static linking

The Wine-derived unix libraries and the crypto stack are linked **statically**
into the app binary.

LGPL section 6 (v2.1) / section 4 (v3) contemplates a recipient being able to
relink the application against a modified version of the library. Providing the
library's source alone does not satisfy this; the relevant clauses also
contemplate supplying the application in a form — object code or source — that
permits relinking. This repository does not currently ship such a package.

Note the distinction between publishing source and distributing binaries.
Publishing this repository alone distributes no combined binary, so the
question does not arise. **Handing someone a built `.ipa` does distribute one.**

For any `.ipa` given to a tester, supply the corresponding source at that exact
commit together with the build and signing instructions needed to reproduce it.
That is a practice to follow, not something the repository can satisfy on its
own.

If relinking needs to be supported properly, shipping the Wine-derived parts as
a dynamic framework is one possible approach, and easier to plan for than to
retrofit -- though on iOS it is not a complete answer by itself, since code
signing may still prevent a recipient from substituting a modified framework
into a signed app.

## Present in the working tree but not distributed

`LiveContainer/` and `research/LiveContainer/` are AGPL-3.0 reference copies
used for local research. Both are gitignored, untracked, and no part of them is
linked into or shipped with the app. They form no part of the combined work.
