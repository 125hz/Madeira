from pathlib import Path
import subprocess
r=Path.cwd();s=(r/'app/Madeira/Library.swift').read_text()
def function(name):
 p=s.index('func '+name+'(');a=s.index('{',p);n=1;b=a+1
 while n:
  n+=(s[b]=='{')-(s[b]=='}');b+=1
 return s[p:b]
source='import Foundation\nstruct LibraryModel { static '+function('apiNames')+'}\nstruct Scanner { '+function('dynamicAPIs')+'}\n'
source+=r'''
let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
defer { try? FileManager.default.removeItem(at: folder) }
func scan(_ bytes: Data, budget: Int = 32 * 1024 * 1024) throws -> (Set<String>, Int) {
 let url = folder.appendingPathComponent("fixture.exe")
 try bytes.write(to: url)
 var left = budget
 return (Scanner().dynamicAPIs(url, budget: &left), left)
}
assert(try scan(Data("MZpayload D3D9.DLL\0".utf8)).0 == ["D3D9"])
assert(try scan(Data("MZ d3d11.dll.backup\0".utf8)).0.isEmpty)
assert(try scan(Data("not a PE d3d9.dll\0".utf8)).0.isEmpty)
let wide = Data("D3D11.DLL\0".utf16.flatMap { [UInt8($0 & 255), UInt8($0 >> 8)] })
assert(try scan(Data([0x4d,0x5a]) + wide).0 == ["D3D11"])
var large = Data(repeating: 0, count: 10 * 1024 * 1024)
large[0] = 0x4d; large[1] = 0x5a
large.append(Data("OPENGL32.DLL\0".utf8))
let tail = try scan(large)
assert(tail.0 == ["OpenGL"] && tail.1 == 24 * 1024 * 1024)
assert(try scan(large, budget: 2).0.isEmpty)
assert(try scan(large, budget: 0).1 == 0)
print("PASS: dynamic renderer detection, ASCII/UTF16/case folding, terminated names, tail lookup and read budget")
'''
# Throwing expressions cannot appear in Swift's assert autoclosure.
source=source.replace('assert(try scan(', 'assert(try! scan(')
p=r/'.xtool/ml1250-metadata.swift';p.write_text(source)
subprocess.run(['swift',str(p)],check=True)
