"""Load the public Dock protocol for Linux host checks (no iOS file APIs)."""
def source(app):
    text = (app / 'MadeiraDock.swift').read_text()
    start = text.index('enum MadeiraDock {')
    private_file = text.index('    @MainActor private static var lastReport =')
    configure = text.index('    static func configure(')
    report = text.index('    @MainActor static func finishReport(')
    return 'import Foundation\nimport Glibc\n' + text[start:private_file] + text[configure:report] + '}\n'
