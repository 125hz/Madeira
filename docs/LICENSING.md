# Madeira licensing: the assembled iOS app (DRAFT 2026-09-16, for review)

This is a working document by the Madeira author, not legal advice. It
records what the shipped app contains, under which terms, and which
obligations follow. It must be reviewed by an open-source licensing lawyer
before any public release.

## What one built app contains

Statically linked into the main executable (`Madeira` / `Madeira.debug.dylib`):

| Component | Upstream licence | Madeira changes | Notes |
|---|---|---|---|
| Wine unix side (ntdll, wineserver, win32u, wineios.drv) from the `wine` fork and `build/*-unix` | LGPL-2.1-or-later | GPL-3.0-or-later in the current fork (LGPL s.3 conversion); LGPL branch being prepared, see `docs/wine-lgpl-provenance.md` | statically linked |
| FEXCore and helpers (`FEX/build-ios/*.a`), including the rpmalloc fork under FEX/External | MIT (rpmalloc: 0BSD) | GPL-3.0-or-later + draft additional permission (Will Faust commits; Ryan Houdek rpmalloc commits stay 0BSD) | statically linked |
| DXMT unix side + airconv (`libdxmt_combined.a`) | MIT | GPL-3.0-or-later + draft additional permission | statically linked |
| LLVM (inside `libdxmt_combined.a`) | Apache-2.0 with LLVM exception | none | statically linked |
| gnutls, nettle, hogweed, gmp | LGPL-2.1+ / LGPL-3+ or GPL-2+ (dual) / LGPL-3+ or GPL-2+ | none | statically linked; LGPL obligations apply |
| Madeira app (Swift/ObjC), native D3D12 runtime (`madeira_d3d12.dll`, PE) | GPL-3.0-or-later + draft additional permission | author-owned | |

Dynamically loaded at runtime (dlopen; this is NOT a GPL-compatibility
exemption, the combination is still a combined work, see the GNU FAQ on
plugins):

| Component | Licence | Notes |
|---|---|---|
| `libmetalirconverter.dylib` (Apple Metal Shader Converter) | Apple proprietary; agreement s.2.B permits distribution solely for shader conversion; tracked in the repository (decision 2026-09-16) with the agreement and NOTICE beside it | loaded with dlopen by the DXMT/Madeira unix side; used only to convert DXIL to Metal libraries |
| Apple system frameworks (Metal, Foundation, UIKit, ...) | Apple OS components | GPL-3 "System Library" |
| PE DLLs in `arm64ec-windows/` (Wine builtins, FEX `libarm64ecfex.dll`, `d3d12.dll`, `winemetal.dll`) | as their sources above | separate files in the bundle |

## Obligations that follow

1. **GPL-3.0 code combined with the proprietary converter.** Allowed only
   where the copyright holder grants an additional permission. Proposed
   for author-owned code in `LICENSE-EXCEPTION.md`; not effective until
   adopted in a tagged release. NOT grantable for upstream
   Wine code in the GPL-converted fork; hence the LGPL branch.
2. **LGPL components statically linked (Wine on the LGPL branch, gnutls,
   nettle, hogweed, gmp).** LGPL-2.1 s.6 / LGPL-3 s.4 require, for the
   combined work: prominent notice that the library is used and covered by
   the LGPL; a copy of the LGPL; the complete corresponding source of the
   library and the means to relink the application with a modified library
   (source of the app can suffice ONLY if a recipient can actually rebuild,
   re-sign and install it; UNVERIFIED: this needs a clean-machine test
   covering dependencies, the converter fetch, free-Apple-ID signing,
   entitlements and installation, and its result recorded here. For the
   LGPL-3 components (nettle, hogweed, gmp if elected under LGPL-3),
   LGPL-3 s.4(e) requires "Installation Information" only under the
   conditions of GPL-3 s.6, i.e. when the combined work is conveyed in or
   with a User Product and installation in that product is otherwise
   possible; whether a sideloaded iOS app meets those conditions is a
   question for the legal review, not assumed either way here. The
   LGPL-2.1 s.6 relink requirement applies to Wine and gnutls; object
   files of the app are the alternative to source); and permission to
   reverse engineer the combination for debugging modifications.
   Madeira's licence must not restrict that.
3. **Apple agreement s.2.D**: the converter may not be used on non-Apple
   devices or offered as a service. Madeira runs only on Apple devices.
4. **Notices**: keep upstream copyright and licence notices in every fork;
   ship `app/Madeira/d3d12/NOTICE.txt`, the Apple agreement text, the
   Apache text for the headers, `COPYING`, `LICENSE-EXCEPTION.md`.

## Open items before public release

- Adopt the LGPL Wine branch in the superproject (review
  `docs/wine-lgpl-provenance.md`).
- Confirm every downstream Wine patch is author-owned (git authorship is
  evidence, not proof); note any patch adapted from third-party code.
- Decide the gnutls/nettle/gmp dual-licence election and record it.
- Clean-machine rebuild/relink/install test (see obligation 2).
- The effective exception text must ship inside the IPA (app/Madeira/d3d12 is bundled; `build/madeira-d3d12/fetch-converter.sh` stages COPYING and the exception there).
- Lawyer review of this arrangement.
