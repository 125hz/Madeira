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
setup and status. First-run setup offers the same choice: **Upload Pairing
File** selects Built-in StikJIT, **Use StikDebug** selects StikDebug, and
**I'll do this later** leaves the current method unchanged.

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
is unavailable in the simulator and inside LiveContainer.

1. Create a pairing file for this iPhone by following the
   [StikDebug pairing-file guide](https://github.com/StikDebug/StikDebug-Guide/blob/main/pairing_file.md).
2. Tap **Upload Pairing File** during first-run setup, or open
   **Settings → JIT → JIT setup** and tap **Import pairing file**.
3. Install and connect LocalDevVPN.
4. Tap **Check setup**. Madeira checks VPN reachability and downloads, mounts,
   and verifies the matching Developer Disk Image when needed.
5. Tap **Enable JIT**.

The pairing file is copied to
`Documents/StikJIT/pairingFile.plist`, which is visible through Finder/iTunes
file sharing. Treat it as device-sensitive data and do not share it. Madeira
sends its bytes only to its bundled helper process for the current request.

The helper is an iOS 26 ExtensionFoundation process. A separate process is
required because a process cannot synchronously debug itself. The app sends its
PID, pairing data, and script over XPC; the helper uses StikJIT with
`forceScript` enabled and stays alive while Madeira's script services debugger
requests.

If setup reports stale Developer Disk Image data after an iOS update, use
**Reset Developer Disk Image**, then **Check setup** again.

## Signing and installation

The app and `MadeiraJITHelper` extension must be signed together. Sideloaders
must preserve and provision the embedded ExtensionKit extension. If an
installer cannot do that, select StikDebug instead.

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
