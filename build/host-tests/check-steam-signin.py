# SPDX-License-Identifier: GPL-3.0-or-later
# Copyright 2026 125hz
# Madeira Converter Exception: see LICENSE-EXCEPTION.md

"""Compile production sign-in core with Swift 6. Synthetic inputs only; no network/login.

Run from WSL/Linux: python3 build/host-tests/check-steam-signin.py
Optional SWIFTC overrides the Swift compiler. All temporary files contain test fixtures,
never developer credentials. The Security backend is replaced by an in-memory backend.
"""

import os
from pathlib import Path
import re
import shutil
import subprocess
import tempfile


ROOT = Path(__file__).resolve().parents[2]
MODULE = ROOT / "app/Madeira/SteamSignIn"
SOURCES = [MODULE / "SteamSignIn.swift", MODULE / "SteamSignInVault.swift"]
SWIFTC = os.environ.get("SWIFTC") or shutil.which("swiftc") or os.path.expanduser("~/.local/share/swiftly/bin/swiftc")

# Only literal, coarse state messages may reach any log sink in this module. This is
# a regression guard, not a proof that an arbitrary program cannot exfiltrate secrets.
for source in (*SOURCES, MODULE / "SteamSignInView.swift"):
    text = source.read_text(encoding="utf-8")
    assert text.startswith("// SPDX-License-Identifier: GPL-3.0-or-later\n")
    for line in text.splitlines():
        if re.search(r"\b(?:print|debugPrint|dump|NSLog|os_log|log|debug|info|warning|error|notice|fault)\s*\(", line):
            assert re.search(r'print\("\[steam-signin\] ml2011 state=[a-z-]+"\)', line), "Nonliteral log sink"
            assert "\\(" not in line, "Interpolated diagnostic"
    assert not re.search(r"UserDefaults|write\(to:|String\(contentsOf:|Data\(contentsOf:|FileHandle|FileManager", text)
    assert not re.search(r"SteamKit|SwiftSteam|SteamAccount|SteamLibrary|SteamRuntime", text)

vault_source = SOURCES[1].read_text(encoding="utf-8")
for required in ("kSecClassGenericPassword", '"madeira.steam.signin"', '"credentials"',
                 "kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly", "kSecAttrSynchronizable as String: false",
                 "SecItemCopyMatching", "SecItemUpdate", "SecItemAdd", "SecItemDelete"):
    assert required in vault_source, required

project = (ROOT / "app/Madeira.xcodeproj/project.pbxproj").read_text(encoding="utf-8")
for index, name in enumerate(("SteamSignIn", "SteamSignInVault", "SteamSignInView")):
    assert project.count(f"A100050{index}") == 2
    assert project.count(f"A200050{index}") == 3
    assert f'path = "SteamSignIn/{name}.swift"' in project

HARNESS = r'''
import Foundation
import FoundationNetworking

func expect(_ value: Bool, _ label: String) {
    if !value { fatalError("Failed: " + label) }
}

func rejects(_ label: String, _ body: () throws -> Void) {
    do { try body(); fatalError("Accepted: " + label) } catch {}
}

func b64(_ value: String) -> String {
    Data(value.utf8).base64EncodedString().replacingOccurrences(of: "+", with: "-")
        .replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
}

// Deliberately unsigned synthetic fixtures. No JWT signature verification is claimed.
func token(_ subject: String = "76561197960265729") -> String {
    b64(#"{"alg":"RS256"}"#) + "." + b64("{\"sub\":\"" + subject + "\"}") + ".AQID"
}

final class MemoryStorage: SteamSignInStorage, @unchecked Sendable {
    // Access occurs only under SteamSignInVault's lock (test setup precedes use).
    var bytes: Data?
    var unavailable = false
    func read() throws -> Data? { if unavailable { throw SteamSignInFailure.storage }; return bytes }
    func write(_ data: Data) throws { if unavailable { throw SteamSignInFailure.storage }; bytes = data }
    func delete() throws { if unavailable { throw SteamSignInFailure.storage }; bytes = nil }
}

struct Reply: Sendable {
    let method: SteamSignInClient.Method
    let body: String
    var result = "1"
    var status = 200
    var pause = false
}

actor Script: SteamSignInTransport {
    var steps: [Reply]
    var seen: [URLRequest] = []
    var pending: CheckedContinuation<Void, Never>?
    init(_ steps: [Reply]) { self.steps = steps }
    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        guard !steps.isEmpty else { throw SteamSignInFailure.network }
        let next = steps.removeFirst()
        expect(request.url?.path.contains(next.method.rawValue) == true, "method order")
        seen.append(request)
        if next.pause { await withCheckedContinuation { pending = $0 } }
        return (Data(next.body.utf8), HTTPURLResponse(url: request.url!, statusCode: next.status,
                 httpVersion: "HTTP/1.1", headerFields: ["X-eresult": next.result])!)
    }
    func release() { pending?.resume(); pending = nil }
    var paused: Bool { pending != nil }
    var requests: [URLRequest] { seen }
}

actor SleepGate {
    var pending: CheckedContinuation<Void, Never>?
    var intervals: [Double] = []
    func sleep(_ interval: Double) async { intervals.append(interval); await withCheckedContinuation { pending = $0 } }
    func release() { pending?.resume(); pending = nil }
    var paused: Bool { pending != nil }
}

let rsa = #"{"response":{"publickey_mod":"80","publickey_exp":"03","timestamp":"123"}}"#
let begin = #"{"response":{"client_id":"18446744073709551615","request_id":"AQI=","interval":0.5,"steamid":"76561197960265729","allowed_confirmations":[{"confirmation_type":2},{"confirmation_type":3},{"confirmation_type":4}]}}"#
let qr = #"{"response":{"client_id":"111","request_id":"AQI=","interval":5,"challenge_url":"https://s.team/q/1/fixture","allowed_confirmations":[{"confirmation_type":4},{"confirmation_type":3}]}}"#
let done = "{\"response\":{\"account_name\":\"fixture-account\",\"refresh_token\":\"" + token() + "\",\"access_token\":\"discard-this-fixture\"}}"

func fields(_ request: URLRequest) -> [String: Any] {
    let encoded = request.httpBody.map { String(decoding: $0, as: UTF8.self) } ?? URLComponents(url: request.url!, resolvingAgainstBaseURL: false)!.percentEncodedQuery!
    expect(encoded.hasPrefix("input_json="), "JSON form field")
    let json = String(encoded.dropFirst(11)).removingPercentEncoding!
    return try! JSONSerialization.jsonObject(with: Data(json.utf8)) as! [String: Any]
}

@MainActor
func eventually(_ label: String, _ condition: () async -> Bool) async {
    for _ in 0..<20_000 { if await condition() { return }; await Task.yield() }
    fatalError("Timed out: " + label)
}

@main
struct Tests {
    @MainActor
    static func main() async throws {
        // These assignments compile-check the exact API consumed by the future Dock adapter.
        let _: Bool = SteamSignIn.isSignedIn
        let _: String? = SteamSignIn.accountName
        let _: () -> (accountName: String, refreshToken: String)? = SteamSignIn.credentialsForDock
        let _: () -> Void = SteamSignIn.signOut

        let encoded = try SteamSignInWire.form(["a": .text("x +&é"), "b": .number(1)])
        expect(String(decoding: encoded, as: UTF8.self) == "input_json=%7B%22a%22%3A%22x%20%2B%26%C3%A9%22%2C%22b%22%3A1%7D", "hand-computed form bytes")
        expect(try SteamSignInWire.rsaDER(modulus: "80", exponent: "03") == Data([0x30,7,2,2,0,0x80,2,1,3]), "DER signed-positive integer")
        expect(try SteamSignInWire.rsaDER(modulus: "0007", exponent: "010001") == Data([0x30,8,2,1,7,2,3,1,0,1]), "DER leading zero normalization")
        expect(SteamSignInWire.derLength(128) == [0x81,0x80] && SteamSignInWire.derLength(256) == [0x82,1,0], "DER long lengths")
        for bad in ["", "0", "xy", "00", String(repeating: "01", count: 1025)] {
            rejects("bad RSA component") { _ = try SteamSignInWire.rsaDER(modulus: bad, exponent: "03") }
        }
        for valid in ["a", "!~", String(repeating: "A", count: 64)] { expect(SteamSignInWire.validAccount(valid), "account accepted") }
        for bad in ["", "a b", "\t", "\n", "é", "\u{7f}", String(repeating: "a", count: 65)] { expect(!SteamSignInWire.validAccount(bad), "account rejected") }
        expect(SteamSignInWire.subject(token()) == 76561197960265729, "individual ID exact")
        let tokenPrefix = token().dropLast(4)
        let large = String(tokenPrefix) + String(repeating: "A", count: 8200)
        expect(SteamSignInWire.subject(large) == nil, "oversize otherwise well-formed JWT")
        for count in (8189...8192) where (count - tokenPrefix.count) % 4 != 1 {
            expect(SteamSignInWire.subject(String(tokenPrefix) + String(repeating: "A", count: count - tokenPrefix.count)) != nil, "valid token at byte limit")
        }
        for id in ["0", "76561197960265728", String(UInt64(0x0110_0000_0000_0001)), "103582791429521409", "148618791998193665", "-76561197960265729", " 76561197960265729", "18446744073709551616"] {
            expect(SteamSignInWire.subject(token(id)) == nil, "invalid individual ID")
        }
        for bad in ["", "..", token()+"=", token()+"\n", token()+"é", "."+token(), token()+".AQ", String(repeating: "a", count: 8193), b64(#"{"alg":"none"}"#)+"."+b64(#"{"sub":"76561197960265729"}"#)+".AQID", b64(#"{"alg":"RS256"}"#)+"."+b64(#"{"sub":76561197960265729}"#)+".AQID"] {
            expect(SteamSignInWire.subject(bad) == nil, "bad token rejected")
        }
        expect(SteamSignInWire.guardCode(" a1b2c ") == "A1B2C", "Guard normalization")
        for bad in ["", "1234", "123456", "a bcd", "é1234"] { expect(SteamSignInWire.guardCode(bad) == nil, "bad Guard code") }
        expect(SteamSignInWire.challengeURL("https://s.team/q/1/fixture"), "QR allowlist")
        for bad in ["http://s.team/q/1/fixture", "https://s.team.evil/q/1", "https://name" + "@s.team/q/1", "https://s.team:443/q/1", "https://s.team/other"] { expect(!SteamSignInWire.challengeURL(bad), "QR rejected") }

        let storage = MemoryStorage()
        let vault = SteamSignInVault(storage: storage)
        expect(try vault.read() == nil, "empty Keychain")
        let value = SteamSignInCredentials(accountName: "fixture-account", refreshToken: token())
        var revision = vault.begin()
        try vault.save(value, revision: revision)
        expect(try vault.read() == value, "vault round trip")
        let keys = try JSONSerialization.jsonObject(with: storage.bytes!) as! [String: Any]
        expect(Set(keys.keys) == ["accountName", "refreshToken"], "only two persisted fields")
        revision = vault.begin()
        try vault.delete()
        rejects("save after sign-out") { try vault.save(value, revision: revision) }
        expect(try vault.read() == nil, "sign-out deletes")
        revision = vault.begin()
        _ = vault.begin()
        rejects("save from superseded attempt") { try vault.save(value, revision: revision) }
        storage.unavailable = true
        rejects("Keychain save failure") { try vault.save(value, revision: vault.begin()) }
        rejects("Keychain read failure") { _ = try vault.read() }
        rejects("Keychain delete failure") { try vault.delete() }
        storage.unavailable = false
        storage.bytes = Data("invalid".utf8)
        rejects("corrupt Keychain entry") { _ = try vault.read() }
        try vault.delete()

        // Credential flow: error retry, client-ID rotation, email/device codes and token storage.
        let script = Script([
            Reply(method: .rsa, body: rsa), Reply(method: .credentials, body: begin),
            Reply(method: .poll, body: #"{"response":{"new_client_id":"222"}}"#),
            Reply(method: .guardCode, body: #"{"response":{}}"#, result: "65"),
            Reply(method: .poll, body: #"{"response":{}}"#),
            Reply(method: .guardCode, body: #"{"response":{}}"#), Reply(method: .poll, body: done)
        ])
        let sleeper = SleepGate()
        let client = SteamSignInClient(transport: script, encrypt: { _, _ in "fixture-encrypted" })
        let flow = SteamSignInFlow(client: client, vault: vault, sleep: { await sleeper.sleep($0) })
        flow.start(account: "fixture-account", password: "fixture-password")
        await eventually("first poll") { await sleeper.paused }
        expect(flow.state == .waiting && flow.methods.contains(.emailCode) && flow.methods.contains(.deviceConfirmation), "Guard choices")
        flow.submit(code: "12345", type: .emailCode)
        await sleeper.release()
        await eventually("wrong code retry") { await sleeper.paused }
        expect(flow.codeError == .incorrectCode && !flow.submittingCode, "wrong code remains recoverable")
        flow.submit(code: "ABCDE", type: .deviceCode)
        await sleeper.release()
        await eventually("signed in") { flow.state == .signedIn("fixture-account") }
        let requests = await script.requests
        expect(requests[0].httpMethod == "GET" && requests[0].httpBody == nil, "RSA GET")
        let credentials = fields(requests[1])
        expect(credentials["encrypted_password"] as? String == "fixture-encrypted" && credentials["password"] == nil, "no plaintext password on wire")
        expect(credentials["platform_type"] as? Int == 1 && credentials["persistence"] as? Int == 1, "client persistent token request")
        expect(fields(requests[3])["client_id"] as? String == "222", "rotated client used by code submission")
        expect(fields(requests[3])["code_type"] as? Int == 2 && fields(requests[5])["code_type"] as? Int == 3, "Guard type wire values")
        expect(fields(requests[2])["client_id"] as? String == "18446744073709551615", "uint64 precision preserved")
        expect(try vault.read() == value, "flow saves only returned credentials")
        expect(await sleeper.intervals == [1,1], "minimum poll interval")
        flow.signOut()
        expect(try vault.read() == nil && flow.state == .signedOut, "UI sign-out")

        // QR success and challenge rotation. No account/code form is fabricated for QR sessions.
        let qrScript = Script([Reply(method: .qr, body: qr),
            Reply(method: .poll, body: #"{"response":{"new_client_id":"333","new_challenge_url":"https://s.team/q/1/rotated"}}"#),
            Reply(method: .poll, body: done)])
        let qrSleep = SleepGate()
        let qrFlow = SteamSignInFlow(client: SteamSignInClient(transport: qrScript), vault: vault, sleep: { await qrSleep.sleep($0) })
        qrFlow.startQR()
        await eventually("QR waiting") { await qrSleep.paused }
        expect(qrFlow.qrURL == "https://s.team/q/1/rotated" && !qrFlow.methods.contains(.deviceCode), "QR rotation without invalid code entry")
        await qrSleep.release()
        await eventually("QR signed in") { qrFlow.state == .signedIn("fixture-account") }
        expect(fields((await qrScript.requests)[2])["client_id"] as? String == "333", "rotated QR poll")
        qrFlow.signOut()

        // Late responses after cancellation and after external sign-out must never save tokens.
        for external in [false, true] {
            let late = Script([Reply(method: .qr, body: qr), Reply(method: .poll, body: done, pause: true)])
            let lateFlow = SteamSignInFlow(client: SteamSignInClient(transport: late), vault: vault)
            lateFlow.startQR()
            await eventually("late poll pending") { await late.paused }
            if external { try vault.delete() } else { lateFlow.cancel() }
            await late.release()
            for _ in 0..<100 { await Task.yield() }
            expect(try vault.read() == nil, "late response cannot restore sign-in")
            lateFlow.cancel()
        }

        // No-code and email-link confirmations still use Valve's polling result.
        for confirmation in [1, 4, 5] {
            let noCode = begin.replacingOccurrences(of: "[{\"confirmation_type\":2},{\"confirmation_type\":3},{\"confirmation_type\":4}]", with: "[{\"confirmation_type\":" + String(confirmation) + "}]")
            let approved = SteamSignInFlow(client: SteamSignInClient(transport: Script([
                Reply(method: .rsa, body: rsa), Reply(method: .credentials, body: noCode), Reply(method: .poll, body: done)
            ]), encrypt: { _, _ in "fixture" }), vault: vault)
            approved.start(account: "fixture-account", password: "fixture-password")
            await eventually("approval without code") { approved.state == .signedIn("fixture-account") }
            approved.signOut()
        }

        let mismatch = done.replacingOccurrences(of: token(), with: token(String(UInt64(0x0110_0001_0000_0002))))
        let mismatchFlow = SteamSignInFlow(client: SteamSignInClient(transport: Script([
            Reply(method: .rsa, body: rsa), Reply(method: .credentials, body: begin), Reply(method: .poll, body: mismatch)
        ]), encrypt: { _, _ in "fixture" }), vault: vault)
        mismatchFlow.start(account: "fixture-account", password: "fixture-password")
        await eventually("subject mismatch") { mismatchFlow.state == .failed(.invalidResponse) }
        expect(try vault.read() == nil, "different session account rejected")
        mismatchFlow.cancel()

        setenv("MADEIRA_STEAM_SIGNIN", "0", 1)
        let disabled = SteamSignInFlow(client: SteamSignInClient(transport: Script([])), vault: vault)
        disabled.startQR()
        expect(disabled.state == .failed(.disabled), "kill switch prevents network start")
        setenv("MADEIRA_STEAM_SIGNIN", "1", 1)

        // Unknown confirmation, malformed response, expired/rate-limited HTTP, and storage failure.
        for (reply, expected) in [
            (Reply(method: .qr, body: "not JSON"), SteamSignInFailure.invalidResponse),
            (Reply(method: .qr, body: "{}", result: "27"), .expired),
            (Reply(method: .qr, body: "{}", result: "84"), .rateLimited),
            (Reply(method: .qr, body: "{}", status: 429), .rateLimited),
            (Reply(method: .qr, body: qr, status: 302), .network),
            (Reply(method: .qr, body: qr, result: "malformed"), .invalidResponse)
        ] {
            let failed = SteamSignInFlow(client: SteamSignInClient(transport: Script([reply])), vault: vault)
            failed.startQR()
            await eventually("sanitized failure") { failed.state == .failed(expected) }
            expect(try vault.read() == nil, "failed response not stored")
            failed.cancel()
        }
        let unknown = begin.replacingOccurrences(of: "[{\"confirmation_type\":2},{\"confirmation_type\":3},{\"confirmation_type\":4}]", with: "[{\"confirmation_type\":999}]")
        let unknownFlow = SteamSignInFlow(client: SteamSignInClient(transport: Script([Reply(method: .rsa, body: rsa), Reply(method: .credentials, body: unknown)]), encrypt: { _, _ in "fixture" }), vault: vault)
        unknownFlow.start(account: "fixture-account", password: "fixture-password")
        await eventually("unknown guard") { unknownFlow.state == .failed(.unsupportedGuard) }
        unknownFlow.cancel()
        storage.unavailable = true
        let storageFlow = SteamSignInFlow(client: SteamSignInClient(transport: Script([Reply(method: .qr, body: qr), Reply(method: .poll, body: done)])), vault: vault)
        storageFlow.startQR()
        await eventually("storage failed") { storageFlow.state == .failed(.storage) }
        storageFlow.cancel()
        storage.unavailable = false
        expect(try vault.read() == nil, "no fallback persistence")

        print("PASS: wire bytes, RSA DER, validation, vault, Guard/QR flows, rotation, cancellation and sanitized errors")
    }
}
'''

with tempfile.TemporaryDirectory(prefix="madeira-signin-test-") as temp:
    root = Path(temp)
    harness = root / "Tests.swift"
    harness.write_text(HARNESS, encoding="utf-8")
    binary = root / "steam-signin-tests"
    subprocess.run([SWIFTC, "-swift-version", "6", "-strict-concurrency=complete", "-warnings-as-errors",
                    "-parse-as-library", *map(str, SOURCES), str(harness), "-o", str(binary)], check=True)
    # The test process never uses the production network transport.
    env = dict(os.environ, MADEIRA_STEAM_SIGNIN="1")
    subprocess.run([str(binary)], check=True, env=env, timeout=45)

print("PASS: privacy/source registration checks; production core compiled and tested with Swift 6")
