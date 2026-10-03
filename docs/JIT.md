# JIT setup

Madeira needs an attached debugger to create executable memory on iOS. It can
use either the StikDebug app or its built-in StikJIT helper. Both methods send
the same bundled `madeira-jit.js` debugger script to the current Madeira
process.

## Automatic selection

The default **Automatic** method uses StikDebug when iOS reports that its
`stikdebug://` URL scheme is installed. Otherwise, it uses Built-in StikJIT.
Madeira does not silently switch methods after a failed attempt; the error is
shown so the pairing, VPN, or Developer Disk Image problem can be fixed.

Choose a method under **Settings → JIT**, or open **JIT setup** for its guided
setup and status. First-run setup offers three ways in, each with its own
numbered steps: **On-device** (pair this iPhone with Madeira, iOS 27 and
later) and **On-device with pairing file** both select Built-in StikJIT,
**StikDebug** selects StikDebug, and setting it up later leaves the current
method unchanged.

## StikDebug

1. Install [StikDebug](https://github.com/StikDebug/StikDebug/releases/latest).
2. Import this iPhone's pairing file into StikDebug.
3. Install and connect
   [LocalDevVPN](https://apps.apple.com/us/app/localdevvpn/id6755608044).
4. In Madeira, tap **Enable JIT**.

Madeira opens StikDebug's canonical `stikdebug://enable-jit` URL with Madeira's
bundle identifier, current process ID, and custom script. It waits up to 90
seconds for both the `CS_DEBUGGED` flag and a live debugger connection. Enabling
Madeira from StikDebug's own app list is not equivalent because that flow can
detach before Madeira creates its JIT pool.

## Built-in StikJIT

Built-in JIT requires iOS 26 or later and a normal sideloaded installation. It
is unavailable in the simulator and inside LiveContainer. It needs this
iPhone's remote pairing file, which Madeira can make itself on iOS 27, or
import.

### On-device pairing (iOS 27 and later)

iOS 27 can pair with a computer it finds on the local network, started from
the iPhone. Madeira plays that computer for its own iPhone, so no computer is
needed.

1. Turn on Wi-Fi. Tap **On-device**, then **Start pairing**, during first-run setup, or
   **Pair on this device** in **Settings → JIT → JIT setup**, and allow Local
   Network access when iOS asks.
2. Open **Settings → Privacy & Security → Developer Mode**, scroll down and
   tap **Pair with Madeira**.
3. Enter the code Madeira shows. It appears in iOS's background-task banner
   and as a notification, and in Madeira when you return.
4. Back in Madeira, continue with LocalDevVPN, **Check setup** and
   **Enable JIT** as below.

Madeira keeps running in the background while you are in Settings through an
iOS continued-processing task (`<bundle id>.pairing.session`). If iOS refuses
it, typically because the sideloader changed the bundle identifier, Madeira
only gets the usual ~30 seconds in the background and says so; go to Settings
straight away. A pairing that has not finished after five minutes is stopped.

Every pairing makes a new host key. The identifier stays the same, so the
iPhone replaces its earlier record for Madeira, and only the newest pairing
file works.

The pairing runs in `libmadeira_rppairing.a` (`build/rppairing-ios`), a small
wrapper around [idevice](https://github.com/jkcoxson/idevice)'s pairable-host
implementation. `app/Madeira/JITPairing.swift` advertises it as a
`_remotepairing-pairable-host._tcp` Bonjour service through mDNSResponder, so
only the Local Network permission is needed.

### Pairing file from a computer

1. Create a pairing file for this iPhone by following the
   [StikDebug pairing-file guide](https://github.com/StikDebug/StikDebug-Guide/blob/main/pairing_file.md).
2. Tap **On-device with pairing file**, then **Choose pairing file**, during first-run setup, or open
   **Settings → JIT → JIT setup** and tap **Import pairing file**.

### Enabling JIT

1. Install and connect LocalDevVPN.
2. Tap **Check setup**. Madeira checks VPN reachability and downloads, mounts,
   and verifies the matching Developer Disk Image when needed.
3. Tap **Enable JIT**.

Either way, the pairing file is kept in the Keychain, for this device only and
readable while it is unlocked, as the Steam sign-in token is. It is a credential
for the iPhone itself, so it is never stored in `Documents`, where the Files app
and every Windows program in Madeira could read it. Madeira sends its bytes only
to its bundled helper process for the current request. A copy an earlier build
left at `Documents/StikJIT/pairingFile.plist` is moved into the Keychain and
deleted the first time Madeira reads it.

The helper is an iOS 26 ExtensionFoundation process. A separate process is
required because a process cannot synchronously debug itself. The app sends its
PID, pairing data, and script over XPC; the helper uses StikJIT with
`forceScript` enabled and stays alive while Madeira's script services debugger
requests.

If setup reports stale Developer Disk Image data after an iOS update, use
**Reset Developer Disk Image**, then **Check setup** again.

If the device resets the connection, it no longer accepts the pairing (each
on-device pairing replaces the last), so Madeira offers **Pair Again**. If the
device can't be reached, it offers **Connect LocalDevVPN**, or **Get
LocalDevVPN** when the app isn't installed; LocalDevVPN returns to Madeira
through its `madeira://` URL scheme once connected.

## Signing and installation

The app and `MadeiraJITHelper` extension must be signed together. Sideloaders
must preserve and provision the embedded ExtensionKit extension. If an
installer cannot do that, select StikDebug instead.

To build Madeira under another bundle identifier, set the
`MADEIRA_BUNDLE_IDENTIFIER` build setting (for example in an `.xcconfig`
passed with `-xcconfig`). The app, the helper (`<id>.JITHelper`) and the
helper's extension point (`<id>.MadeiraJITHelper`) all follow it; changing only
`PRODUCT_BUNDLE_IDENTIFIER` leaves the helper unfindable.

JIT also requires Madeira's executable to be signed as debuggable. Madeira
reports a signing error before attempting either method when that entitlement
is missing.

## Licensing

The bundled StikJIT 1.9.0 XCFramework is from
[StikDebug/StikJIT](https://github.com/StikDebug/StikJIT/releases/tag/1.9.0)
(`StikJIT.xcframework.zip` SHA-256
`806664393770c68e75f2b6429955bfdd88cfaad09fec2ba70f8ed615ff90c060`)
and is licensed under MPL-2.0. It includes the
[idevice](https://github.com/jkcoxson/idevice) library, licensed under MIT.
Corresponding source and license links are recorded in
[`THIRD-PARTY-NOTICES.md`](../THIRD-PARTY-NOTICES.md).

On-device pairing links idevice 0.1.68 and its Rust dependencies (MIT,
Apache-2.0, BSD-3-Clause or ISC) into the app from crates.io, pinned by
`build/rppairing-ios/Cargo.lock`; their notices are bundled as
`legal/LICENSES-rppairing-crates.txt`.
