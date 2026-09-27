<!-- SPDX-License-Identifier: GPL-3.0-or-later -->
<!-- Copyright 2026 125hz -->
<!-- Madeira Converter Exception: see LICENSE-EXCEPTION.md -->

# Steam sign-in

This standalone module obtains a Steam refresh token and account name for Madeira
Dock. It offers account/password sign-in, Steam Guard email and mobile codes,
approval in the Steam mobile app, and QR sign-in. The main screen's **Steam
sign-in** button opens the sheet. It does not browse libraries, download content,
install Steam, create a Dock handoff file, or launch games.

Madeira Dock is an open-source host for Valve's unmodified client. The sign-in
module does not grant ownership or replace game DRM. The genuine client must
authenticate the user's token and verify entitlement during a Dock launch.

## Source and protocol

The implementation uses Foundation, Security, SwiftUI and CoreImage, without a
third-party Steam library. It was written for this task without opening or
copying the excluded Steam implementation files. This is not a formal clean-room
provenance certification: the authoring conversation also contained earlier
Steam integration work. Reviewers should assess that limitation before making
a stronger provenance claim.

Protocol references:

- [Valve's Web API Overview](https://partner.steamgames.com/doc/webapi_overview),
  especially **Request Format** and **Service Interfaces**, specifies URL-encoded
  `input_json` for service requests.
- [Valve's live method catalogue](https://api.steampowered.com/ISteamWebAPIUtil/GetSupportedAPIList/v1/)
  declares the `IAuthenticationService` methods and request fields used here.
  Its descriptions do not fully document the response schema or enum values;
  those compatibility assumptions are isolated in the module and require live
  device validation. Unknown confirmation methods fail visibly when no supported
  sign-in path is available.
- [Apple's RSA PKCS#1 encryption algorithm](https://developer.apple.com/documentation/security/seckeyalgorithm/rsaencryptionpkcs1)
  supplies encryption and random padding through Security.framework. The module
  only constructs the public key's ASN.1 DER container; it implements no RSA
  arithmetic or padding itself.
- [Apple's device-only Keychain accessibility](https://developer.apple.com/documentation/security/ksecattraccessibleafterfirstunlockthisdeviceonly)
  describes the storage protection used here.

All requests target `https://api.steampowered.com/IAuthenticationService/`:

| Method (version 1) | HTTP | Purpose |
| --- | --- | --- |
| `GetPasswordRSAPublicKey` | GET | Obtain the RSA public key and encryption timestamp for the entered account. |
| `BeginAuthSessionViaCredentials` | POST | Submit account name and RSA-encrypted password; request a persistent client-platform session. |
| `BeginAuthSessionViaQR` | POST | Obtain a QR challenge for approval in the official Steam app. |
| `UpdateAuthSessionWithSteamGuardCode` | POST | Submit the user's email or mobile-app code for the pending session. |
| `PollAuthSessionStatus` | POST | Wait for approval, follow client-ID/QR rotation, and receive credentials. |

There is no embedded publisher API key. The client-platform request value is `1`,
persistence is `1`, and confirmation values handled are `1` (none), `2` (email
code), `3` (mobile code), `4` (mobile approval), and `5` (email approval). QR
responses may advertise a code method without providing a SteamID; that method
is not offered for such a session. Users can cancel QR and use account/password.

Network sessions are ephemeral, have no cookie jar, URL cache or credential
store, and reject HTTP redirects. HTTP response bodies are capped at 64 KiB
while streaming. TLS uses the system's normal certificate validation. Requests
time out; polling respects the server interval with a one-second floor and a
five-minute polling deadline. Begin responses with intervals outside `(0, 60]`
are rejected. Codes and polling run sequentially so a rotated client ID also
applies to the next code submission. There is no automatic repeated password
submission after an error or rate limit.

QR challenges must use HTTPS on `s.team`, under `/q/`, without credentials or a
custom port. They are rendered locally and held only in memory. No web view,
browser history or image file is created. Scanning requires the Steam app on
another device; account/password supports approval in the Steam app on the same
device. Switching to that app does not cancel the pending sheet. Dismissing the
sheet or pressing Cancel cancels the attempt.

## Storage and privacy

Only `{accountName, refreshToken}` is persisted, in one generic-password Keychain
item with service `madeira.steam.signin`, constant account key `credentials`,
`kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly`, and synchronization disabled.
The user's account name is inside the protected value, not Keychain metadata.
Updates replace that value atomically without first deleting the old item.
There is no file, UserDefaults, cookie or iCloud fallback.

Passwords and Guard codes are used in memory only. Input fields clear when
submitted, cancelled or dismissed; the password-bearing operation is released
before polling. Access tokens and guard-machine data are not decoded or stored.
Swift strings/network buffers cannot promise cryptographic memory erasure; the
module makes no such claim.

Sign out deletes the Keychain item. A revision guard prevents a late response
from saving credentials after sign-out or after a newer attempt begins. A
Keychain error is reported by the sheet rather than pretending deletion or
storage succeeded. The public `signOut()` signature returns no error; callers
that need confirmation should check `isSignedIn` again and present the sheet
if deletion is unavailable. An unreadable Keychain also yields no credentials.

No account names, passwords, Guard codes, tokens, request URLs, response bodies,
QR challenges or raw error descriptions are logged. The only application log
messages are fixed, coarse states prefixed `[steam-signin] ml2011`. This policy
does not control an explicitly enabled system network debugger or a user's
screenshots. No developer credential is included in this source or its tests.

## API for Dock

```swift
SteamSignIn.isSignedIn
SteamSignIn.accountName
SteamSignIn.credentialsForDock() // (accountName: String, refreshToken: String)?
SteamSignIn.signOut()
```

Before saving or returning a credential, the module requires a 1–64-byte account
name containing ASCII bytes 33–126 and a refresh token no longer than 8192 bytes,
using only the JWT base64url alphabet and dots. Its three nonempty JWT parts must
decode, the header must identify RS256, and the payload's string `sub` must be an
individual public-universe SteamID64 (universe 1, type 1, instance 1, nonzero
account ID). Password-based sessions additionally require the token's subject
to match the SteamID returned when authentication began.

These are structural checks only. They do **not** verify a JWT signature,
expiry, token audience, current authentication or ownership. `isSignedIn` means
that a structurally valid saved credential can be read. The Dock adapter must
pass it to Valve's genuine client and fail closed if authentication or ownership
checks fail. It must never convert this local check into an entitlement result.

The integration intentionally ends at `credentialsForDock()`. The separate Dock
adapter creates and consumes its protected one-use handoff; this module does not
read existing Steam installations or their cached sign-in state.

## Disable and test

Set the process environment variable `MADEIRA_STEAM_SIGNIN=0` to hide the new
button and disable starting sign-in. Existing credentials remain readable and
can still be deleted by the API. No other app action changes. This standalone
module does not parse Madeira's configuration file; the caller must export the
environment before presenting it if configuration-file integration is desired.

Run the offline host regression from the repository root in WSL/Linux:

```sh
python3 build/host-tests/check-steam-signin.py
```

It compiles the actual core and vault with Swift 6 and complete concurrency
checking, injecting a memory-only storage backend and scripted HTTP replies.
Tests cover hand-computed form/DER bytes, exact uint64 parsing, Dock-compatible
credential bounds, invalid JWT subjects, Keychain API shape and failures, code
retry, both code types, QR rotation, cancellation/sign-out races, unsupported
confirmation, sanitized errors, project registration and literal-only logging.
The synthetic JWTs have no valid signature and cannot authenticate to Valve.
Linux production networking and Security fallbacks fail; the suite never signs
in or uses a developer account.

Validation on 2026-09-27:

- Offline Swift 6 host suite passed.
- All three module files passed strict Swift 6 type-checking with warnings as
  errors for arm64 iOS 17 using the available iPhoneOS SDK.
- The whole app passed arm64 iOS 17 type-checking with its existing Swift 5
  language mode. This is not a full link, IPA build or device test.
- One separate anonymous QR-begin protocol probe returned HTTP 200 / EResult 1,
  the expected response field names, `s.team` challenge host, five-second poll
  interval and confirmation types 4/3 for client platform 1. The pending
  challenge was not displayed, approved or saved; no account authenticated.
  Only field names and these non-secret protocol facts were printed.

Before shipping, test on device: password without Guard where supported, email
code including an incorrect code, mobile code, same-device app approval, QR
approval from another device, cancelled/expired attempts, airplane mode, locked
Keychain, sign-out/reopen, and refresh-token acceptance by the genuine Dock
client. Successful authentication and client-token audience compatibility have
not been established by the offline suite or the anonymous QR probe.
