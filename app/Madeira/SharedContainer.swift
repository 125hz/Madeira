// SPDX-License-Identifier: GPL-3.0-or-later
// Madeira Converter Exception: see LICENSE-EXCEPTION.md
//
// ml1331 shared container (docs/PROCESS_HOST.md, "Prerequisites"). The app and its
// MadeiraProcessHost extension declare one app group, group.<app bundle id>, in
// Madeira.entitlements and ProcessHost.entitlements. A sideloader registers the
// group for its own team and may rewrite the id (SideStore and AltStore append the
// team id; others use their own), the same way for the app and its extensions, so
// no id is hard-coded here: the candidates are the groups the embedded provisioning
// profile grants, then the groups the signed binary carries, then the SideStore and
// AltStore groups. The first one iOS resolves to a container is used.
//
// The answer is computed once per app run and logged once:
//   [ext-proc] ml1331 shared container: <path> (group <id>)
//   [ext-proc] ml1331 shared container: none (profile groups: [...])
// The ProcessHostClient.m entry points below are only reached once a container
// exists, so its own per-call lookup and log line no longer repeat on every launch.
import Foundation

enum SharedContainer {
    struct Resolution {
        let url: URL?
        let group: String?
        let profileGroups: [String]
        let signedGroups: [String]
    }

    static let groupsEntitlement = "com.apple.security.application-groups"
    /// Tried after the profile's and the binary's own groups.
    static let fallbackGroups = ["group.com.SideStore.SideStore", "group.com.rileytestut.AltStore"]

    /// Resolved on first use (thread-safe lazy static), then kept for the app run.
    static let resolution: Resolution = resolve()
    static var url: URL? { resolution.url }
    static var group: String? { resolution.group }

    /// The app groups the embedded provisioning profile grants (what the sideloader
    /// registered for this install, after any rewrite of the ids).
    static var profileGroups: [String] {
        let entitlements = embeddedProvisioningProfile()?["Entitlements"] as? [String: Any]
        return entitlements?[groupsEntitlement] as? [String] ?? []
    }

    private static func resolve() -> Resolution {
        let profile = profileGroups
        let signed = appEntitlementStrings(groupsEntitlement)
        var candidates: [String] = []
        for id in profile + signed + fallbackGroups where !id.isEmpty && !candidates.contains(id) { candidates.append(id) }
        for id in candidates {
            if let container = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: id) {
                LogStore.shared.log("[ext-proc] ml1331 shared container: \(container.path) (group \(id))")
                return Resolution(url: container, group: id, profileGroups: profile, signedGroups: signed)
            }
        }
        LogStore.shared.log("[ext-proc] ml1331 shared container: none (profile groups: [\(profile.joined(separator: ", "))]"
            + " signed groups: [\(signed.joined(separator: ", "))]). Install a build whose app and extension"
            + " declare com.apple.security.application-groups, with a sideloader that registers app groups;"
            + " shared drive and remote processes stay off")
        return Resolution(url: nil, group: nil, profileGroups: profile, signedGroups: signed)
    }

    // The same switches ProcessHostClient.m reads (madeira.cfg env.NAME, else the
    // process environment; any value but 0 is on; both default off).
    static var driveEnabled: Bool { MadeiraConfig.flag("MADEIRA_SHARED_DRIVE", fallback: false) }
    static var remoteEnabled: Bool { MadeiraConfig.flag("MADEIRA_EXT_PROCESS", fallback: false) }

    /// madeira_process_host_shared_drive, once a container exists (else nil, as before).
    static func drive(prefix: String) -> String? {
        guard driveEnabled, url != nil else { return nil }
        return madeira_process_host_shared_drive(prefix)
    }

    /// madeira_process_host_shared_prefix, once a container exists (else nil, as before).
    static func sharedPrefix(_ prefix: String) -> String? {
        guard remoteEnabled, driveEnabled, url != nil else { return nil }
        return madeira_process_host_shared_prefix(prefix)
    }

    /// madeira_process_host_active_prefix, once a container exists (else the private prefix).
    static func activePrefix(_ prefix: String) -> String {
        guard remoteEnabled, driveEnabled, url != nil else { return prefix }
        return madeira_process_host_active_prefix(prefix)
    }
}
