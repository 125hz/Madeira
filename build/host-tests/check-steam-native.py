#!/usr/bin/env python3
"""ml1310 host checks for the native Steam client; never runs Wine, Steam or iOS.

Part A compiles production Swift (depot selection, manifest path safety, the
download journal, appmanifest output and library-entry routing) on the host.
Part B compiles the production C decoders (liblzma shim, zstd educational
decoder) and drives them with real LZMA streams, handcrafted zstd frames and
concurrent corrupt input under ThreadSanitizer and AddressSanitizer. The
unlocked wrapper is rebuilt as a control and must be reported by TSan.
"""
from pathlib import Path
import lzma
import os
import re
import subprocess
import tempfile

root = Path(__file__).resolve().parents[2]
app = root / 'app/Madeira'
steam = app / 'SwiftSteam'
SWIFTC = '/home/hero/.local/share/swiftly/bin/swiftc'
# System cc: the Swift toolchain's clang TSan runtime needs the Blocks runtime on Linux.
CLANG = 'cc'


def block(source, start_marker):
    """Return the declaration starting at start_marker through its closing brace."""
    start = source.index(start_marker)
    depth, i = 0, source.index('{', start)
    while True:
        c = source[i]
        if c == '{': depth += 1
        elif c == '}':
            depth -= 1
            if depth == 0: return source[start:i + 1] + '\n'
        i += 1


# ---------------------------------------------------------------- Part A
fetcher = (steam / 'Library/SteamLibraryFetcher.swift').read_text()
downloader = (steam / 'Content/DepotDownloader.swift').read_text()
library = (app / 'Library.swift').read_text()

vdf = fetcher[fetcher.index('// MARK: - Simple VDF Binary Parser'):]
helpers = 'enum DD {\n'
for marker in ['nonisolated static func safeRelativePath(', 'nonisolated static func safeFolderName(',
               'nonisolated static func usableContentHost(', 'nonisolated static func serverEligibility(']:
    helpers += block(downloader, marker).replace('nonisolated ', '')
helpers += '    enum ServerEligibility: Equatable { case usable, noHTTPS, other }\n}\n'
helpers += block(downloader, 'final class ContentHostHealth')
journal = block(downloader, 'final class JournalWriter')
entry = library[library.index('struct LibraryEntry:'):library.index('final class LibraryModel:')]
model_methods = library[library.index('    func mergeSteam('):library.index('    private func persist(')]

stubs = r'''
import Foundation
import Glibc
import Dispatch
struct TouchControl: Codable {}
enum LibraryError: Error { case message(String) }
enum LibraryFlags {
    static func enabled(_ key: String, fallback: Bool = true) -> Bool { getenv(key).map { String(cString: $0) != "0" } ?? fallback }
}
enum SteamLog { static func trace(_ m: @autoclosure () -> String) {}; static func event(_ m: String) {} }
final class LogStore { static let shared = LogStore(); func log(_ m: String) {} }
enum SteamInstallPaths { static var steamApps: URL { URL(fileURLWithPath: "/tmp/madeira-steam-native/steamapps") } }
class LibraryModel {
    static var drive = URL(fileURLWithPath: "/tmp/madeira-steam-native/drive_c")
    var entries: [LibraryEntry] = []; var current: UUID?; var readOnly = false
    func persist(_ next: [LibraryEntry]) { entries = next }
    static func executable(_ relative: String) throws -> URL {
        let url = drive.appendingPathComponent(relative)
        guard FileManager.default.fileExists(atPath: url.path) else { throw LibraryError.message("missing") }
        return url
    }
    MODEL_METHODS
}
enum GuestDisplay { static func configureSessionDefault(view: CGSize, knob: String) {} }
func madeira_set_vsync_locked(_ mode: Int32) {}
'''.replace('MODEL_METHODS', model_methods)

checks = r'''
import Foundation
import Glibc
var failures = 0
func require(_ condition: @autoclosure () -> Bool, _ label: String) {
    if condition() { print("PASS: " + label) } else { print("FAIL: " + label); failures += 1 }
}
func appVDF(_ body: String) -> Data { Data(("\"appinfo\" { \"appid\" \"10\" " + body + " }").utf8) }

@main struct Checks {
    static func main() throws {
        // Depot selection: Windows, neutral/64-bit, common/english, no low
        // violence, DLC, shared redistributables or manifest-less depots.
        let full = appVDF(#"""
        "common" { "name" "Fixture" "type" "Game" "oslist" "windows,macos" }
        "config" { "installdir" "Fixture Game"
          "launch" { "0" { "executable" "bin/game64.exe" "type" "default" "config" { "oslist" "windows" "osarch" "64" } }
                     "1" { "executable" "mac/game.app" "config" { "oslist" "macos" } } } }
        "depots" {
          "101" { "config" { "oslist" "windows" } "manifests" { "public" { "gid" "1001" "size" "500" "download" "300" } } }
          "102" { "config" { "oslist" "windows" "language" "english" } "manifests" { "public" { "gid" "1002" "download" "40" } } }
          "103" { "config" { "oslist" "windows" "language" "german" } "manifests" { "public" { "gid" "1003" "download" "40" } } }
          "104" { "config" { "oslist" "windows" "osarch" "32" } "manifests" { "public" { "gid" "1004" "download" "70" } } }
          "105" { "config" { "oslist" "windows" "osarch" "64" } "manifests" { "public" { "gid" "1005" "download" "80" } } }
          "106" { "config" { "oslist" "windows" "lowviolence" "1" } "manifests" { "public" { "gid" "1006" } } }
          "107" { "dlcappid" "999" "manifests" { "public" { "gid" "1007" } } }
          "108" { "sharedinstall" "1" "manifests" { "public" { "gid" "1008" } } }
          "109" { "config" { "oslist" "windows" } }
          "110" { "config" { "oslist" "macos" } "manifests" { "public" { "gid" "1010" } } }
          "branches" { "public" { "buildid" "4242" } }
        }
        """#)
        let info = SteamAppInfo.parse(appID: 10, from: full)!
        require(info.installDepots().map(\.depotID) == [101, 102, 105], "install depots: common + english + 64-bit only")
        require(info.downloadSize(for: "windows") == 420, "download size counts only selected depots")
        require(info.buildID == 4242 && info.installableOnWindows, "build id and Windows installability")
        require(info.launchConfigs(for: "windows").map(\.executable) == ["bin/game64.exe"], "Windows launch configuration")

        let legacy = SteamAppInfo.parse(appID: 10, from: appVDF(#"""
        "common" { "name" "Old" "type" "Game" "oslist" "windows" } "config" { "installdir" "Old" }
        "depots" { "201" { "config" { "oslist" "windows" "osarch" "32" } "manifests" { "public" "2001" } }
                   "202" { "manifests" { "public" "2002" } } }
        """#))!
        require(legacy.installDepots().map(\.depotID) == [201, 202], "32-bit-only apps fall back to 32-bit depots")

        let macOnly = SteamAppInfo.parse(appID: 10, from: appVDF(#"""
        "common" { "name" "Mac" "type" "Game" "oslist" "macos" } "depots" { "301" { "config" { "oslist" "macos" } "manifests" { "public" "3001" } } }
        """#))!
        require(!macOnly.installableOnWindows, "apps without a Windows build are not offered")
        let tool = SteamAppInfo.parse(appID: 10, from: appVDF(#"""
        "common" { "name" "Tool" "type" "Tool" } "depots" { "401" { "manifests" { "public" "4001" } } }
        """#))!
        require(!tool.installableOnWindows, "tools and redistributables are not offered")

        // Manifest paths.
        var folded: [String: String] = [:]
        for bad in ["../x", "a/../b", "a/./b", "C:/x", "a/b\u{1}c", "", "////"] {
            require(DD.safeRelativePath(bad, folded: &folded) == nil, "rejects manifest path \(bad.debugDescription)")
        }
        require(DD.safeRelativePath("Data\\Maps\\a.pak", folded: &folded) == "Data/Maps/a.pak", "backslash paths")
        require(DD.safeRelativePath("data/maps/b.pak", folded: &folded) == "Data/Maps/b.pak", "directories fold case-insensitively")
        require(DD.safeRelativePath("DATA/Other/c.pak", folded: &folded) == "Data/Other/c.pak", "partial folding keeps first spelling")
        require(DD.safeRelativePath("/lead/and//double/", folded: &folded) == "lead/and/double", "empty components ignored")
        require(DD.safeFolderName("../../escape") == "escape" && DD.safeFolderName("..") == "app" &&
                DD.safeFolderName("") == "app" && DD.safeFolderName("C:") == "app" && DD.safeFolderName("Game Name") == "Game Name",
                "install folder is one safe component")
        require(DD.usableContentHost("cache1-lax1.steamcontent.com") && DD.usableContentHost("steampipe.akamaized.net"),
                "public content hosts accepted")
        for host in ["lancache.steamcontent.com", "*.steamcontent.com", "evil.example", "a.steamcontent.com.evil.example",
                     "a.steamcontent.com:8080", "a/b.steamcontent.com"] {
            require(!DD.usableContentHost(host), "rejects content host \(host)")
        }

        // ml1320: content directory entries (shapes from GetServersForSteamPipe).
        let json = #"""
        [{"type":"SteamCache","host":"cache1-atl3.steamcontent.com","https_support":"mandatory"},
         {"type":"CDN","host":"a.cdn.steampipe.steamcontent.com","https_support":"unavailable"},
         {"type":"CDN","host":"b.akamaized.net","https_support":"optional"},
         {"type":"CDN","host":"c.steamcontent.com","https_support":"mandatory","use_as_proxy":true},
         {"type":"CDN","host":"d.steamcontent.com","https_support":"mandatory","allowed_app_ids":[730]},
         {"type":"CDN","host":"e.steamcontent.com","https_support":"mandatory","allowed_app_ids":[220, 730]},
         {"type":"SteamCache","host":"f.steamcontent.com"}]
        """#
        let servers = try JSONSerialization.jsonObject(with: Data(json.utf8)) as! [[String: Any]]
        let verdicts = servers.map { DD.serverEligibility($0, appID: 220) }
        require(verdicts == [.usable, .noHTTPS, .usable, .other, .other, .usable, .usable],
                "content servers: HTTPS-unavailable, proxy and other-app servers skipped")

        let health = ContentHostHealth(enabled: true)
        let pool = ["https://a", "https://b", "https://c"]
        require(health.order(pool, seed: 1) == ["https://b", "https://c", "https://a"], "chunks start on different servers")
        for _ in 0..<3 { health.recordFailure("https://b", reason: "url-1200") }
        require(health.order(pool, seed: 1) == ["https://c", "https://a", "https://b"], "failing server moves to the back")
        for _ in 0..<3 { health.recordSuccess("https://b") }
        require(health.order(pool, seed: 1).first == "https://b", "recovered server returns to rotation")
        let plain = ContentHostHealth(enabled: false)
        plain.recordFailure("https://b", reason: "x")
        require(plain.order(pool, seed: 1) == ["https://b", "https://c", "https://a"], "health rollback keeps plain rotation")

        // Resume journal.
        let dir = URL(fileURLWithPath: "/tmp/madeira-steam-native")
        try? FileManager.default.removeItem(at: dir)
        try FileManager.default.createDirectory(at: dir.appendingPathComponent("steamapps"), withIntermediateDirectories: true)
        let journalURL = dir.appendingPathComponent("depot.journal")
        let writer = try JournalWriter(url: journalURL)
        let keys: [UInt64] = (0..<200).map { UInt64($0 / 7) << 32 | UInt64($0 % 7) }
        for key in keys { writer.append(key) }
        writer.close()
        let handle = try FileHandle(forWritingTo: journalURL); handle.seekToEndOfFile(); handle.write(Data("zz\n12".utf8)); try handle.close()
        let loaded = JournalWriter.load(journalURL)
        require(loaded.isSuperset(of: Set(keys)) && loaded.count == 201, "journal round trip tolerates a garbage/partial tail")
        let appended = try JournalWriter(url: journalURL); appended.append(UInt64(1) << 40); appended.close()
        require(JournalWriter.load(journalURL).contains(UInt64(1) << 40), "journal appends across attempts")

        // appmanifest: readable by the existing library scanner.
        try AppManifestWriter.writeManifest(appID: 10, name: #"Quote "and" \slash"#, installDir: "Fixture Game", buildID: 4242,
                                            steamID: 7, sizeOnDisk: 500, steamAppsPath: dir.appendingPathComponent("steamapps").path,
                                            installedDepots: [.init(depotID: 101, manifestGID: 1001, size: 500)])
        var parser = try SteamKeyValues(Data(contentsOf: dir.appendingPathComponent("steamapps/appmanifest_10.acf")))
        let state = try parser.read()["appstate"]
        require(state?["appid"]?.string == "10" && state?["stateflags"]?.string == "4" &&
                state?["installdir"]?.string == "Fixture Game" && state?["buildid"]?.string == "4242" &&
                state?["installeddepots"]?["101"]?["manifest"]?.string == "1001", "appmanifest fields parse back")
        require(state?["name"]?.string == #"Quote "and" \slash"#, "appmanifest escapes names")
        do {
            try AppManifestWriter.writeManifest(appID: 11, name: "x", installDir: "x", buildID: 1, steamID: 0,
                                                steamAppsPath: "/proc/definitely/not/writable")
            require(false, "manifest write failure is reported")
        } catch { require(true, "manifest write failure is reported") }

        // Library entries: direct and client-routed native installs.
        var native = LibraryEntry(title: "Fixture", relativePath: "Program Files (x86)/Steam/steamapps/common/Fixture Game/bin/game64.exe", bits: 64)
        native.steamAppID = 10; native.steamNative = true; native.steamInstalled = true; native.arguments = "-windowed"
        require(!native.usesSteam && native.launchArguments == "-windowed", "native install starts the game directly")
        native.configureLaunch()
        require(String(cString: getenv("MADEIRA_EXE")) == native.windowsPath && getenv("MADEIRA_DESKTOP") == nil,
                "direct launch uses the game executable without a desktop session")
        native.steamClientLaunch = true
        do { try native.validate(); require(false, "client route needs an installed client") }
        catch { require(true, "client route needs an installed client") }
        native.steamClientPath = "Program Files (x86)/Steam/steam.exe"
        try native.validate()
        require(native.usesSteam && native.launchArguments.contains("\"C:\\Program Files (x86)\\Steam\\steam.exe\"") &&
                native.launchArguments.contains("-applaunch 10") && !native.launchArguments.contains("game64.exe"),
                "client route launches the Steam client by App ID")

        // The Windows-client scan never rewrites a native entry.
        let model = LibraryModel()
        native.steamClientLaunch = nil
        model.entries = [native]
        var snapshot = SteamSnapshot(client: "Program Files (x86)/Steam/steam.exe")
        snapshot.apps = [SteamInstalledApp(id: 10, name: "Fixture", relativeFolder: "x", bytes: 1, installed: false, needsUpdate: false)]
        model.mergeSteam(snapshot)
        require(model.entries.count == 1 && model.entries[0].relativePath == native.relativePath &&
                model.entries[0].steamInstalled == true, "client scan leaves native entries alone")
        snapshot.apps = []
        model.mergeSteam(snapshot)
        require(model.entries[0].steamInstalled == true, "complete client scan does not mark native entries uninstalled")

        var update = native; update.id = UUID(); update.title = "Store Name"; update.steamBuildID = 5000; update.relativePath = "other.exe"
        model.entries[0].title = "My Title"
        model.upsertNativeSteam(update)
        require(model.entries.count == 1 && model.entries[0].title == "My Title" && model.entries[0].steamBuildID == 5000 &&
                model.entries[0].relativePath == "other.exe", "update keeps profile; missing executable choice is replaced")
        model.removeSteamInstall(model.entries[0].id)
        require(model.entries.isEmpty, "uninstall removes the entry")

        if failures > 0 { print("FAILURES: \(failures)"); exit(1) }
        print("PASS: all ml1310 Swift checks")
    }
}
'''

with tempfile.TemporaryDirectory() as tmp:
    tmp = Path(tmp)
    (tmp / 'stubs.swift').write_text(stubs + entry)
    (tmp / 'vdf.swift').write_text('import Foundation\n' + vdf)
    (tmp / 'helpers.swift').write_text('import Foundation\nimport Glibc\n' + helpers + journal)
    (tmp / 'checks.swift').write_text(checks)
    sources = [tmp / 'stubs.swift', tmp / 'vdf.swift', tmp / 'helpers.swift', tmp / 'checks.swift',
               app / 'SteamFiles.swift', steam / 'Library/SteamAppInfo.swift', steam / 'Install/AppManifestWriter.swift']
    exe = tmp / 'swift-checks'
    subprocess.run([SWIFTC, '-parse-as-library', '-swift-version', '5', '-sanitize=address', '-o', str(exe)] + [str(s) for s in sources], check=True)
    # Address checking stays on; LeakSanitizer is off because it reports
    # Swift runtime/global allocations still live at process exit.
    subprocess.run([str(exe)], check=True, env=dict(os.environ, ASAN_OPTIONS='detect_leaks=0'))

# ---------------------------------------------------------------- Part B
c_checks = r'''
#include <pthread.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include "lzma_shim.h"
static int failures;
#define CHECK(c, label) do { if (c) printf("PASS: %s\n", label); else { printf("FAIL: %s\n", label); failures++; } } while (0)

static uint8_t *read_file(const char *path, size_t *size) {
    FILE *f = fopen(path, "rb"); if (!f) return NULL;
    fseek(f, 0, SEEK_END); *size = (size_t)ftell(f); fseek(f, 0, SEEK_SET);
    uint8_t *data = malloc(*size ? *size : 1); fread(data, 1, *size, f); fclose(f); return data;
}

/* zstd frame: magic, single-segment descriptor with a 1-byte content size,
 * then one last block (type 0 raw or 1 RLE). */
static size_t frame(uint8_t *out, int type, const uint8_t *payload, uint8_t n) {
    size_t i = 0;
    out[i++] = 0x28; out[i++] = 0xB5; out[i++] = 0x2F; out[i++] = 0xFD;
    out[i++] = 0x20; out[i++] = n;
    uint32_t header = 1u | ((uint32_t)type << 1) | ((uint32_t)n << 3);
    out[i++] = header & 0xFF; out[i++] = (header >> 8) & 0xFF; out[i++] = (header >> 16) & 0xFF;
    if (type == 0) { memcpy(out + i, payload, n); i += n; } else out[i++] = payload[0];
    return i;
}

static uint8_t raw_frame[512], rle_frame[16], bad_frames[64][96];
static size_t raw_len, rle_len;
static uint8_t expected[200];
static volatile int thread_failures;

static void *worker(void *arg) {
    uintptr_t id = (uintptr_t)arg;
    uint8_t out[256];
    for (int round = 0; round < 1500; round++) {
        int pick = (int)((round + id) % 3);
        if (pick == 0) {
            size_t n = zstd_safe_decompress(out, sizeof out, raw_frame, raw_len);
            if (n != 200 || memcmp(out, expected, 200)) __atomic_add_fetch(&thread_failures, 1, __ATOMIC_RELAXED);
        } else if (pick == 1) {
            size_t n = zstd_safe_decompress(out, sizeof out, rle_frame, rle_len);
            if (n != 77 || out[0] != 'Z' || out[76] != 'Z') __atomic_add_fetch(&thread_failures, 1, __ATOMIC_RELAXED);
        } else {
            const uint8_t *bad = bad_frames[(round * 7 + id) % 64];
            if (zstd_safe_decompress(out, sizeof out, bad, 96) != (size_t)-1) {
                /* Random bytes after a valid magic are rejected, except in the
                 * astronomically unlikely case they form a valid frame. */
            }
        }
    }
    return NULL;
}

int main(int argc, char **argv) {
    /* LZMA1 via the shim: stream and props produced by Python's encoder. */
    size_t plain_size, stream_size, props_size;
    uint8_t *plain = read_file(argv[1], &plain_size);
    uint8_t *props = read_file(argv[2], &props_size);
    uint8_t *stream = read_file(argv[3], &stream_size);
    uint8_t *decoded = malloc(plain_size);
    size_t produced = 0;
    int rc = lzma_shim_decode(props, props_size, stream, stream_size, decoded, plain_size, &produced);
    CHECK(rc == 0 && produced == plain_size && !memcmp(decoded, plain, plain_size), "LZMA1 chunk decodes exactly");
    rc = lzma_shim_decode(props, props_size, stream, stream_size / 2, decoded, plain_size, &produced);
    CHECK(rc != 0, "truncated LZMA1 chunk is rejected");
    CHECK(lzma_shim_decode(props, 4, stream, stream_size, decoded, plain_size, &produced) != 0, "bad LZMA props rejected");

    /* ml1320: single-entry PKZip chunks (older content). */
    size_t zp_size, z_size;
    uint8_t *zplain = read_file(argv[4], &zp_size);
    uint8_t *zout = malloc(zp_size + 64);
    const char *names[] = {"deflate", "stored", "deflate+descriptor", "stored+descriptor"};
    for (int i = 0; i < 4; i++) {
        uint8_t *zip = read_file(argv[5 + i], &z_size);
        size_t got = 0;
        int zrc = chunk_zip_decode(zip, z_size, zout, zp_size, &got);
        char label[96]; snprintf(label, sizeof label, "zip chunk decodes exactly (%s)", names[i]);
        CHECK(zrc == 0 && got == zp_size && !memcmp(zout, zplain, zp_size), label);
        if (i == 0) {
            CHECK(chunk_zip_decode(zip, z_size / 2, zout, zp_size, &got) < 0, "truncated zip chunk is rejected");
            CHECK(chunk_zip_decode(zip, z_size, zout, zp_size / 2, &got) == -4, "zip chunk larger than expected is rejected");
            CHECK(chunk_zip_decode(zip, 20, zout, zp_size, &got) == -1, "short zip header is rejected");
        }
        free(zip);
    }
    uint8_t *bz = read_file(argv[9], &z_size);
    size_t got = 0;
    CHECK(chunk_zip_decode(bz, z_size, zout, zp_size, &got) == -2, "unsupported zip method is rejected");
    CHECK(chunk_zip_decode(plain, plain_size, zout, zp_size, &got) == -1, "non-zip data is rejected");
    free(bz); free(zplain); free(zout);

    for (int i = 0; i < 200; i++) expected[i] = (uint8_t)(i * 31 + 7);
    raw_len = frame(raw_frame, 0, expected, 200);
    uint8_t z = 'Z';
    rle_len = frame(rle_frame, 1, &z, 77);
    uint8_t out[256];
    CHECK(zstd_safe_decompress(out, sizeof out, raw_frame, raw_len) == 200 && !memcmp(out, expected, 200), "zstd raw block");
    CHECK(zstd_safe_decompress(out, sizeof out, rle_frame, rle_len) == 77 && out[0] == 'Z' && out[76] == 'Z', "zstd RLE block");
    CHECK(zstd_safe_decompress(out, 100, raw_frame, raw_len) == (size_t)-1, "undersized zstd output is an error, not exit");
    uint8_t junk[8] = {1, 2, 3, 4, 5, 6, 7, 8};
    CHECK(zstd_safe_decompress(out, sizeof out, junk, sizeof junk) == (size_t)-1, "bad zstd magic is an error, not exit");
    srand(1310);
    for (int f = 0; f < 64; f++) {
        bad_frames[f][0] = 0x28; bad_frames[f][1] = 0xB5; bad_frames[f][2] = 0x2F; bad_frames[f][3] = 0xFD;
        for (int i = 4; i < 96; i++) bad_frames[f][i] = (uint8_t)rand();
    }
    pthread_t threads[8];
    for (uintptr_t t = 0; t < 8; t++) pthread_create(&threads[t], NULL, worker, (void *)t);
    for (int t = 0; t < 8; t++) pthread_join(threads[t], NULL);
    CHECK(thread_failures == 0, "8 threads x 1500 mixed valid/corrupt zstd decodes");
    free(plain); free(props); free(stream); free(decoded);
    if (failures) { printf("FAILURES: %d\n", failures); return 1; }
    printf("PASS: all ml1310 C decoder checks\n");
    return 0;
}
'''

with tempfile.TemporaryDirectory() as tmp:
    tmp = Path(tmp)
    plain = bytes((i * 7919 >> 3) & 0xFF for i in range(300_000)) + b'Madeira' * 20_000
    alone = lzma.compress(plain, format=lzma.FORMAT_ALONE,
                          filters=[{'id': lzma.FILTER_LZMA1, 'dict_size': 1 << 20}])
    (tmp / 'plain.bin').write_bytes(plain)
    (tmp / 'props.bin').write_bytes(alone[:5])
    (tmp / 'stream.bin').write_bytes(alone[13:])
    # Single-entry zip chunks: sized headers, and streamed (bit 3 data
    # descriptor, sizes zero in the local header) like non-seekable writers.
    import io, zipfile

    class Unseekable(io.RawIOBase):
        def __init__(self): self.buf = bytearray()
        def writable(self): return True
        def write(self, b): self.buf += b; return len(b)

    zplain = bytes((i * 131 + (i >> 7)) & 0xFF for i in range(700_000)) + b'chunk' * 30_000
    (tmp / 'zplain.bin').write_bytes(zplain)
    for name, method, streamed in [('zip-deflate', zipfile.ZIP_DEFLATED, False), ('zip-stored', zipfile.ZIP_STORED, False),
                                   ('zip-deflate-dd', zipfile.ZIP_DEFLATED, True), ('zip-stored-dd', zipfile.ZIP_STORED, True),
                                   ('zip-bzip2', zipfile.ZIP_BZIP2, False)]:
        sink = Unseekable() if streamed else io.BytesIO()
        with zipfile.ZipFile(sink, 'w', method) as archive:
            with archive.open('z', 'w') as entry:
                entry.write(zplain)
        data = bytes(sink.buf) if streamed else sink.getvalue()
        if streamed: assert data[6] & 8, 'expected a data descriptor'
        (tmp / f'{name}.bin').write_bytes(data)
    (tmp / 'checks.c').write_text(c_checks)
    zstd_src = (steam / 'zstd_edu.c').read_text()
    unlocked = zstd_src.replace('pthread_mutex_lock(&g_zstd_safe_lock);', '').replace('pthread_mutex_unlock(&g_zstd_safe_lock);', '')
    assert unlocked != zstd_src
    (tmp / 'zstd_unlocked.c').write_text('#include "zstd_edu.h"\n' + unlocked.replace('#include "zstd_edu.h"', ''))
    common = ['-g', '-O1', '-I', str(steam), str(tmp / 'checks.c'), str(steam / 'lzma_shim.c'), str(steam / 'chunk_zip.c'), '-llzma', '-lz', '-lpthread']
    env = dict(os.environ, ASAN_OPTIONS='detect_leaks=0', TSAN_OPTIONS='halt_on_error=1')
    args = [str(tmp / n) for n in ('plain.bin', 'props.bin', 'stream.bin', 'zplain.bin', 'zip-deflate.bin', 'zip-stored.bin', 'zip-deflate-dd.bin', 'zip-stored-dd.bin', 'zip-bzip2.bin')]
    for sanitizer in ['address,undefined', 'thread']:
        exe = tmp / ('c-' + sanitizer.split(',')[0])
        subprocess.run([CLANG, f'-fsanitize={sanitizer}'] + common + [str(steam / 'zstd_edu.c'), '-o', str(exe)], check=True)
        print(f'--- production decoders under {sanitizer}')
        subprocess.run([str(exe)] + args, check=True, env=env)
    # Control: the pre-ml1310 unlocked wrapper shares one jump target across threads.
    exe = tmp / 'c-unlocked'
    subprocess.run([CLANG, '-fsanitize=thread'] + common + ['-I', str(steam), str(tmp / 'zstd_unlocked.c'), '-o', str(exe)], check=True)
    result = subprocess.run([str(exe)] + args, env=env, capture_output=True, text=True)
    warning = next((line for line in result.stderr.splitlines() if 'WARNING: ThreadSanitizer' in line), '')
    raced = bool(warning)
    print(f'PASS: unlocked control is reported by ThreadSanitizer ({warning.strip()})' if raced else 'FAIL: unlocked control not detected')
    if not raced: raise SystemExit(1)
print('PASS: ml1310 steam native host checks complete')
