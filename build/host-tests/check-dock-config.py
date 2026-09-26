#!/usr/bin/env python3
"""Exercise production configuration migration and UI flag lookup on disk."""
from pathlib import Path
import subprocess
import tempfile

root = Path(__file__).resolve().parents[2]
app = root / 'app/Madeira'
config = (app / 'MadeiraConfig.swift').read_text().replace(
    'FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first',
    'URL(fileURLWithPath: CommandLine.arguments[1])')
library = (app / 'Library.swift').read_text()
flags = library[library.index('enum LibraryFlags {'):library.index('// Shares the hardware sampler;')]
checks = r'''
import Foundation
import Glibc
enum LibraryModel { static var documents: URL { MadeiraConfig.documents! } }
func require(_ value: @autoclosure () -> Bool, _ label: String) {
    precondition(value(), label)
}
@main struct Checks {
    static func main() throws {
        let d = MadeiraConfig.documents!, cfg = MadeiraConfig.url!
        let legacy = d.appendingPathComponent("madeira-env.txt")
        func write(_ text: String, _ url: URL) throws { try text.write(to: url, atomically: true, encoding: .utf8) }
        // Exact log-58 failure: an existing canonical file and a newly supplied
        // Dock override, read once by the UI and again after worker cleanup.
        try write("# keep this comment\nenv.MADEIRA_STEAM_WEBHELPER_FREEZE = 1\npool = 7\n", cfg)
        try write("# trial\nMADEIRA_DOCK = 0\nMADEIRA_DOCK=1\nDXMT_TEST = a=b\nPATH=/bad\n", legacy)
        require(LibraryFlags.enabled("MADEIRA_DOCK", fallback: false), "UI sees trial override")
        MadeiraConfig.migrateLegacy(log: { _ in })
        MadeiraConfig.deleteLegacyFiles(log: { _ in })
        require(!FileManager.default.fileExists(atPath: legacy.path), "verified import allows cleanup")
        require(LibraryFlags.enabled("MADEIRA_DOCK", fallback: false), "worker and cold launch retain Dock")
        require(MadeiraConfig.all()["pool"] == "7", "unrelated config preserved")
        let saved = try String(contentsOf: cfg, encoding: .utf8)
        require(saved.contains("# keep this comment"), "comments preserved")
        require(MadeiraConfig.environmentValues()["DXMT_TEST"] == "a=b", "embedded equals preserved")
        require(MadeiraConfig.environmentValues()["PATH"] == nil, "loader environment excluded")
        MadeiraConfig.migrateLegacy(log: { _ in })
        let repeated = try String(contentsOf: cfg, encoding: .utf8)
        require(saved == repeated, "repeat migration is idempotent")
        try write("MADEIRA_DOCK=0\n", legacy)
        require(!LibraryFlags.enabled("MADEIRA_DOCK"), "explicit rollback before migration")
        MadeiraConfig.migrateLegacy(log: { _ in })
        MadeiraConfig.deleteLegacyFiles(log: { _ in })
        require(!LibraryFlags.enabled("MADEIRA_DOCK"), "explicit rollback after migration")
        try write("MADEIRA_DOCK=1\nMADEIRA_CONFIG_ENV_MERGE=0\n", legacy)
        MadeiraConfig.migrateLegacy(log: { _ in })
        MadeiraConfig.deleteLegacyFiles(log: { _ in })
        require(FileManager.default.fileExists(atPath: legacy.path), "unimported override is never deleted")
        require(LibraryFlags.enabled("MADEIRA_DOCK"), "retained override remains usable")
        try write("9", d.appendingPathComponent("madeira-pool.txt"))
        MadeiraConfig.deleteLegacyFiles(log: { _ in })
        require(FileManager.default.fileExists(atPath: d.appendingPathComponent("madeira-pool.txt").path), "unrelated conflicting legacy value retained")
        // A failed canonical read/import must not lose the only source of flags.
        try FileManager.default.removeItem(at: cfg)
        try FileManager.default.createDirectory(at: cfg, withIntermediateDirectories: false)
        try write("MADEIRA_DOCK=1\n", legacy)
        MadeiraConfig.migrateLegacy(log: { _ in })
        MadeiraConfig.deleteLegacyFiles(log: { _ in })
        require(FileManager.default.fileExists(atPath: legacy.path), "failed canonical import retains override")
        require(LibraryFlags.enabled("MADEIRA_DOCK"), "read failure preserves route")
        print("PASS: actual config + UI flags, migration, cleanup, cold read, rollback, failure retention")
    }
}
'''
with tempfile.TemporaryDirectory(prefix='madeira-config-check-') as directory:
    folder = Path(directory)
    source = folder / 'Checks.swift'
    source.write_text(config + '\n' + flags + '\n' + checks)
    docs = folder / 'Documents'
    docs.mkdir()
    executable = folder / 'check'
    subprocess.run(['/home/hero/.local/share/swiftly/bin/swiftc', '-parse-as-library',
                    str(source), '-o', str(executable)], check=True)
    subprocess.run([str(executable), str(docs)], check=True)
