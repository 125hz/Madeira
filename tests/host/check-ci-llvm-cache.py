#!/usr/bin/env python3
"""Exercise the header-only LLVM cache that stopped the IPA builds."""
from pathlib import Path
import hashlib
import os
import subprocess
import tempfile

root = Path(__file__).resolve().parents[2]
helper = root / 'tools/build/build-llvm-ios.sh'
with tempfile.TemporaryDirectory(prefix='madeira-ci-llvm-') as tmp:
    fixture = Path(tmp)
    src = fixture / 'toolchains/llvm-project'
    build = fixture / 'toolchains/llvm-ios-build'
    for path in [src / 'llvm/include/llvm/IR/Module.h',
                 build / 'include/llvm/Config/llvm-config.h',
                 build / 'lib/libLLVMCore.a', build / 'lib/libLLVMSupport.a']:
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_bytes(b'cache fixture\n')
    manifest = build / '.madeira-cache.sha256'
    manifest.write_text(''.join(hashlib.sha256(p.read_bytes()).hexdigest() + '  ' +
                                str(p.relative_to(build)) + '\n'
                                for p in sorted((build / 'lib').glob('*.a'))))
    tools = fixture / 'bin'
    tools.mkdir()
    trace = fixture / 'called'
    for name in ['git', 'cmake', 'xcodebuild']:
        path = tools / name
        path.write_text('#!/bin/sh\necho unexpected-build >> "$TRACE"\nexit 86\n')
        path.chmod(0o755)
    env = dict(os.environ, ROOT=str(fixture), GITHUB_ACTIONS='true', JOBS='1',
               TRACE=str(trace), PATH=str(tools) + os.pathsep + os.environ['PATH'])

    def run():
        return subprocess.run(['bash', str(helper)], env=env, capture_output=True, text=True)

    result = run()
    assert result.returncode == 0, result.stdout + result.stderr
    assert not trace.exists(), 'a complete restored cache must not clone or rebuild LLVM'
    archive = build / 'lib/libLLVMCore.a'
    archive.write_bytes(b'corrupt cache\n')
    assert run().returncode != 0, 'a damaged archive must not count as a cache hit'
    archive.unlink()
    assert run().returncode != 0, 'an incomplete archive set must not count as a cache hit'
    assert (src / 'llvm/include/llvm/IR/Module.h').read_bytes() == b'cache fixture\n'
    assert not trace.exists(), 'an incomplete restored directory must not be overwritten'

    fex = fixture / 'FEX/build-ios'
    libraries = ['FEXCore/Source/libFEXCore.a', 'FEXCore/Source/libFEXCore_Base.a',
                 'FEXCore/Source/libJemallocLibs.a', 'External/fmt/libfmt.a',
                 'External/cephes/libcephes_128bit.a', 'External/SoftFloat-3e/libsoftfloat_3e.a',
                 'External/xxhash/cmake_unofficial/libxxhash.a']
    for name in libraries:
        path = fex / name
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_bytes(b'archive\n')
    fex_helper = root / 'tools/build/build-fex-ios.sh'
    result = subprocess.run(['bash', str(fex_helper)], env=env, capture_output=True)
    assert result.returncode == 0 and not trace.exists()
    (fex / libraries[-1]).unlink()
    assert subprocess.run(['bash', str(fex_helper)], env=env, capture_output=True).returncode != 0
    assert trace.exists(), 'a missing FEX archive must request a real build'
    trace.unlink()

    output = fixture / 'app/Madeira/libdxmt_combined.a'
    output.parent.mkdir(parents=True)
    output.write_bytes(b'archive\n')
    dxmt_helper = root / 'tools/build/build-dxmt-ios.sh'
    assert subprocess.run(['bash', str(dxmt_helper)], env=env, capture_output=True).returncode == 0
    assert not trace.exists()
    script = fixture / 'build/dxmt-ios/build.sh'
    script.parent.mkdir(parents=True)
    script.write_text('#!/bin/sh\necho build >> "$TRACE"\nexit 86\n')
    script.chmod(0o755)
    local_env = dict(env, GITHUB_ACTIONS='false')
    assert subprocess.run(['bash', str(dxmt_helper)], env=local_env, capture_output=True).returncode != 0
    assert trace.exists(), 'local builds must keep their existing rebuild path'
    trace.unlink()

    gnutls = fixture / 'build/gnutls-ios'
    (gnutls / 'obj').mkdir(parents=True)
    script = gnutls / 'build.sh'
    script.write_text((root / 'build/gnutls-ios/build.sh').read_text())
    for stage in ['gmp', 'nettle', 'gnutls']:
        (gnutls / 'obj' / (stage + '.done')).touch()
    prefix = fixture / 'toolchains/gnutls-ios/lib'
    prefix.mkdir(parents=True)
    for lib in ['gmp', 'nettle', 'hogweed', 'gnutls']:
        (prefix / ('lib' + lib + '.a')).write_bytes(b'archive\n')
    for name in ['xcrun', 'sysctl']:
        path = tools / name
        path.write_text('#!/bin/sh\necho 1\n')
        path.chmod(0o755)
    for name in ['tar', 'make']:
        path = tools / name
        path.write_text('#!/bin/sh\necho build >> "$TRACE"\nexit 86\n')
        path.chmod(0o755)
    assert subprocess.run(['bash', str(script)], env=env, capture_output=True).returncode == 0
    assert not trace.exists(), 'restored GnuTLS stage markers must prevent a rebuild'
    (gnutls / 'obj/gmp.done').unlink()
    assert subprocess.run(['bash', str(script)], env=env, capture_output=True).returncode != 0
    assert trace.exists(), 'missing stage markers must request a real build'
print('PASS: complete LLVM cache skips clone/build; damaged or missing archives are refused')
print('PASS: complete FEX/DXMT CI caches skip rebuilds; missing outputs and local builds do not')
print('PASS: GnuTLS output and stage-marker caches skip completed stages together')
