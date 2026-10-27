#!/usr/bin/env python3
"""Exercise profile copy and registry rewrite on temporary files only."""
from pathlib import Path
import subprocess
import tempfile
root=Path(__file__).resolve().parents[2]
s=(root/'app/Madeira/SteamCloud.swift').read_text()
profile=s[s.index('enum ProfileUnification {'):s.index('// MARK: - Comparison')]
assert profile.index('try merge(') < profile.index('rewrite(url, from: old, to: user)')
assert profile.index('try fm.removeItem(at: support)') < profile.index('try merge(')
assert 'removeItem(at: source)' not in profile
helpers=profile[profile.index('    private static func rewrite('):]
code='import Foundation\nenum ProfileUnification {\n'+helpers+r'''
extension ProfileUnification {
    static func check(_ root: URL) throws {
        let fm=FileManager.default
        let source=root.appendingPathComponent("old"), target=root.appendingPathComponent("new")
        let backup=root.appendingPathComponent("backup")
        try fm.createDirectory(at: source, withIntermediateDirectories:true)
        try fm.createDirectory(at: target, withIntermediateDirectories:true)
        func write(_ folder: URL,_ name:String,_ text:String,_ seconds:Double) throws {
            let url=folder.appendingPathComponent(name)
            try text.write(to:url,atomically:true,encoding:.utf8)
            try fm.setAttributes([.modificationDate:Date(timeIntervalSince1970:seconds)],ofItemAtPath:url.path)
        }
        func read(_ folder:URL,_ name:String) throws -> String { try String(contentsOf:folder.appendingPathComponent(name),encoding:.utf8) }
        try write(source,"save1","source-new",200)
        try write(target,"save1","target-old",100)
        try write(source,"save2","source-old",100)
        try write(target,"save2","target-new",200)
        var copied=0, collisions=0
        try merge(source,into:target,backup:backup,depth:24,moved:&copied,collisions:&collisions)
        assert(copied==1 && collisions==2)
        assert(try read(target,"save1")=="source-new")
        assert(try read(target,"save2")=="target-new")
        assert(try read(backup,"save1")=="target-old")
        assert(try read(backup,"save2")=="source-old")
        assert(try read(source,"save1")=="source-new")
        assert(try read(source,"save2")=="source-old")
        // A failed backup must stop before replacing either file.
        try write(source,"save1","later",300)
        let blocked=root.appendingPathComponent("blocked")
        try "file".write(to:blocked,atomically:true,encoding:.utf8)
        do { try merge(source,into:target,backup:blocked,depth:24,moved:&copied,collisions:&collisions); assertionFailure("backup failure ignored") }
        catch { }
        assert(try read(target,"save1")=="source-new")
        assert(try read(source,"save1")=="later")
        // A junction collision must not modify files outside the profile.
        let outside=root.appendingPathComponent("outside")
        try fm.createDirectory(at:outside,withIntermediateDirectories:true)
        try write(outside,"keep","outside",100)
        try fm.createSymbolicLink(at:source.appendingPathComponent("linked"),withDestinationURL:outside)
        try fm.createDirectory(at:target.appendingPathComponent("linked"),withIntermediateDirectories:true)
        do { try merge(source,into:target,backup:root.appendingPathComponent("backup2"),depth:24,moved:&copied,collisions:&collisions); assertionFailure("link followed") }
        catch { }
        assert(try read(outside,"keep")=="outside")
        let reg=root.appendingPathComponent("system.reg")
        try #""ProfileImagePath"="C:\\users\\mythic" "Other"="C:\\users\\mythical""#.write(to:reg,atomically:true,encoding:.utf8)
        assert(rewrite(reg,from:"mythic",to:"mobile")==1)
        let updated=try String(contentsOf:reg,encoding:.utf8)
        assert(updated.contains(#"users\\mobile"#) && updated.contains(#"users\\mythical"#))
        assert(rewrite(reg,from:"mythic",to:"mobile")==0)
        print("PASS: newer saves, older backups, retained source, failed backup, junction guard and registry boundaries")
    }
}
let root=URL(fileURLWithPath:CommandLine.arguments[1])
try ProfileUnification.check(root)
'''
# Swift assert uses a nonthrowing autoclosure.
import re
code=re.sub(r'assert\(try read\(([^\n]+?)\)==("[^\n]+?")\)',r'assert((try? read(\1))==\2)',code)
with tempfile.TemporaryDirectory() as d:
    c,exe=Path(d)/'main.swift',Path(d)/'profile'
    c.write_text(code)
    subprocess.run(['swiftc',str(c),'-o',str(exe)],check=True)
    data=Path(d)/'data';data.mkdir()
    subprocess.run([str(exe),str(data)],check=True)
