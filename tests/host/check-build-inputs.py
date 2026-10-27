#!/usr/bin/env python3
"""Run the workflow's cache fingerprint with changed SDK and flag inputs."""
from pathlib import Path
import os
import re
import subprocess
import tempfile
import textwrap
import zipfile
import shutil
from itertools import product

root = Path(__file__).resolve().parents[2]
workflow = (root / '.github/workflows/build.yml').read_text()
assert 'scripts/' not in workflow and 'research/dxmt' not in workflow
assert workflow.count('key: ${{ steps.key.outputs.key }}\n    steps:') == 2
assert workflow.count('key: plan19-${{ steps.sdk.outputs.key }}-${{ steps.key.outputs.key }}') == 2
assert workflow.count('key: plan19-${{ steps.sdk.outputs.key }}-${{ needs.') == 2
script = (root / 'tools/build/ci-input-key.sh').read_text()
assert workflow.count('run: bash tools/build/ci-input-key.sh') == 5
assert workflow.count('MADEIRA_PLANNED_SDK: ${{ needs.plan.outputs.sdk }}') == 4
assert "'.github/workflows/build.yml')" not in workflow, 'workflow-only edits must not rebuild LLVM/FEX'
assert 'toolchains/llvm-ios-build/.madeira-cache.sha256' in workflow
assert 'toolchains/gnutls-ios' in workflow and 'build/gnutls-ios/obj/*.done' in workflow
with tempfile.TemporaryDirectory(prefix='madeira-build-inputs-') as folder:
    folder = Path(folder)
    for name, content in {
        'xcodebuild': '#!/bin/sh\necho Xcode-test\n',
        'xcrun': '#!/bin/sh\nif [ "$1" = --sdk ]; then cat "$SDK_INPUT"; else cat "$CLANG_INPUT"; fi\n',
        'rustc': '#!/bin/sh\ncat "$RUST_INPUT"\n',
        'git': '#!/bin/sh\nif [ "$1 $2" = "rev-parse --show-toplevel" ]; then echo "$REPO_INPUT"; else exec "$GIT_INPUT" "$@"; fi\n',
    }.items():
        p = folder / name
        p.write_text(content)
        p.chmod(0o755)
    sdk = folder / 'sdk'
    sdk.write_text('27.1\n')
    clang = folder / 'clang-input'
    clang.write_text('clang-test\n')
    rust = folder / 'rust-input'
    rust.write_text('rust-test\n')
    output = folder / 'output'
    env = dict(os.environ, PATH=str(folder) + os.pathsep + os.environ['PATH'],
               SDK_INPUT=str(sdk), CLANG_INPUT=str(clang), RUST_INPUT=str(rust), GITHUB_OUTPUT=str(output),
               REPO_INPUT=str(root), GIT_INPUT=shutil.which('git'))
    native_flags = ('CC', 'CXX', 'AR', 'RANLIB', 'CFLAGS', 'CXXFLAGS', 'CPPFLAGS', 'LDFLAGS',
                    'SDKROOT', 'MACOSX_DEPLOYMENT_TARGET', 'IPHONEOS_DEPLOYMENT_TARGET', 'ImageOS', 'ImageVersion')
    rust_flags = ('RUSTFLAGS', 'CARGO_ENCODED_RUSTFLAGS', 'RUSTUP_TOOLCHAIN')
    graphics_flags = ('DXMT_METAL_STD', 'MADEIRA_ONLY', 'MADEIRA_MSC_ROOT')
    app_flags = ('CONFIGURATION', 'MADEIRA_MOLTENVK')
    for key in (*native_flags, *rust_flags, *graphics_flags, *app_flags, 'MADEIRA_PLANNED_SDK', 'MADEIRA_PLANNED_IPA'):
        env.pop(key, None)
    def fingerprint(extra=None):
        output.unlink(missing_ok=True)
        subprocess.run(['bash', '-euo', 'pipefail', '-c', script], cwd=root, env=dict(env, **(extra or {})), check=True)
        return dict(line.split('=', 1) for line in output.read_text().splitlines())
    first = fingerprint()
    assert first == fingerprint()
    assert first == fingerprint({'JOBS': '3'})
    sdk.write_text('27.2\n')
    assert first != fingerprint()
    sdk.write_text('27.1\n')
    all_keys = {'key', 'rust', 'graphics', 'ipa'}
    for flags, changed in [(native_flags, all_keys), (rust_flags, {'rust', 'ipa'}),
                           (graphics_flags, {'graphics', 'ipa'}), (app_flags, {'ipa'})]:
        for key in flags:
            result = fingerprint({key: 'changed'})
            assert {name for name in first if first[name] != result[name]} == changed, key
    for file, changed in [(clang, all_keys), (rust, {'rust', 'ipa'})]:
        original = file.read_text()
        file.write_text('changed\n')
        result = fingerprint()
        assert {name for name in first if first[name] != result[name]} == changed
        file.write_text(original)
    dimensions = [('CFLAGS', all_keys), ('RUSTFLAGS', {'rust', 'ipa'}),
                  ('DXMT_METAL_STD', {'graphics', 'ipa'}), ('CONFIGURATION', {'ipa'})]
    for selected in product([False, True], repeat=len(dimensions)):
        result = fingerprint({name: 'changed' for (name, _), enabled in zip(dimensions, selected) if enabled})
        expected = set().union(*(changed for (_, changed), enabled in zip(dimensions, selected) if enabled))
        assert {name for name in first if first[name] != result[name]} == expected
    for name, expected in [('MADEIRA_PLANNED_SDK', first['key']), ('MADEIRA_PLANNED_IPA', first['ipa'])]:
        assert fingerprint({name: expected}) == first
        mismatch = subprocess.run(['bash', '-euo', 'pipefail', '-c', script],
                                  cwd=root, env=dict(env, **{name: 'wrong'}), capture_output=True)
        assert mismatch.returncode != 0, 'a mismatched runner must not publish under the planned key'

    key_step = re.search(r'        run: (echo "ipa=.+)\n', workflow)
    assert key_step
    key_script = key_step[1].replace('${{ runner.os }}', 'macOS').replace('${{ runner.arch }}', 'ARM64')
    key_script = key_script.replace('${{ steps.sdk.outputs.ipa }}', first['ipa'])
    tree = folder / 'repo'
    tree.mkdir()
    def git(*args):
        return subprocess.check_output(['git', '-C', str(tree), *args], text=True).strip()
    git('init', '-q')
    git('config', 'user.name', 'Cache fixture')
    git('config', 'user.email', 'cache@example.invalid')
    source = tree / 'source.c'
    source.write_text('first\n')
    git('add', '.')
    git('commit', '-qm', 'first')
    producer = git('rev-parse', 'HEAD')
    def ipa_key():
        output.unlink(missing_ok=True)
        subprocess.run(['bash', '-euo', 'pipefail', '-c', key_script], cwd=tree, env=env, check=True)
        return output.read_text()
    first_ipa = ipa_key()
    git('commit', '--allow-empty', '-qm', 'same tree, new commit')
    assert ipa_key() == first_ipa, 'commit metadata must not invalidate an identical build tree'
    source.write_text('changed\n')
    git('add', '.')
    git('commit', '-qm', 'source changed')
    assert ipa_key() != first_ipa, 'changed source must not reuse an old IPA'
    git('update-index', '--add', '--cacheinfo', '160000,' + producer + ',FEX')
    git('commit', '-qm', 'component pin')
    component_key = ipa_key()
    git('update-index', '--cacheinfo', '160000,' + git('rev-parse', 'HEAD') + ',FEX')
    git('commit', '-qm', 'component changed')
    assert ipa_key() != component_key, 'changed submodule pins must not reuse an old IPA'

    validation = re.search(r'      - name: Validate cached IPA\n        run: \|\n((?:          .+\n)+)', workflow)
    assert validation
    validation = textwrap.dedent(validation[1])
    dist = folder / 'dist'
    dist.mkdir()
    ipa = dist / 'Madeira.ipa'
    def valid_ipa():
        return subprocess.run(['bash', '-euo', 'pipefail', '-c', validation], cwd=folder,
                              capture_output=True).returncode == 0
    with zipfile.ZipFile(ipa, 'w') as archive:
        archive.writestr('Payload/Madeira.app/Madeira', b'fixture')
    assert valid_ipa()
    with zipfile.ZipFile(ipa, 'w') as archive:
        archive.writestr('wrong-layout/Madeira', b'fixture')
    assert not valid_ipa(), 'a ZIP with the wrong bundle layout must not be reused'
    ipa.write_bytes(b'damaged ZIP')
    assert not valid_ipa(), 'a corrupt completed IPA must not be reused'
for p in [root / 'tools/build-ipa.sh', *(root / 'tools/build').glob('*.sh')]:
    assert '$ROOT/scripts/' not in p.read_text(), p
    subprocess.run(['bash', '-n', str(p)], check=True)
print('PASS SDK/flag invalidation, stable keys, matching restore keys and build script syntax')
print('PASS isolated Rust/graphics/app inputs and all 16 combinations of build-setting changes')
print('PASS identical-tree IPA reuse, source/component invalidation and cached IPA rejection')
