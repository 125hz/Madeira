#!/usr/bin/env python3
"""Run the workflow's cache fingerprint with changed SDK and flag inputs."""
from pathlib import Path
import os
import re
import subprocess
import tempfile
import textwrap

root = Path(__file__).resolve().parents[2]
workflow = (root / '.github/workflows/build.yml').read_text()
assert 'scripts/' not in workflow and 'research/dxmt' not in workflow
assert workflow.count('key: ${{ steps.key.outputs.key }}\n    steps:') == 2
assert workflow.count('key: plan19-${{ steps.sdk.outputs.key }}-${{ steps.key.outputs.key }}') == 2
assert workflow.count('key: plan19-${{ steps.sdk.outputs.key }}-${{ needs.') == 2
block = re.search(r'      - id: sdk\n        shell: bash\n        run: \|\n((?:          .+\n)+)', workflow)
assert block
script = textwrap.dedent(block[1])
with tempfile.TemporaryDirectory(prefix='madeira-build-inputs-') as folder:
    folder = Path(folder)
    for name, content in {
        'xcodebuild': '#!/bin/sh\necho Xcode-test\n',
        'xcrun': '#!/bin/sh\nif [ "$1" = --sdk ]; then cat "$SDK_INPUT"; else echo clang-test; fi\n',
    }.items():
        p = folder / name
        p.write_text(content)
        p.chmod(0o755)
    sdk = folder / 'sdk'
    sdk.write_text('27.1\n')
    output = folder / 'output'
    env = dict(os.environ, PATH=str(folder) + os.pathsep + os.environ['PATH'],
               SDK_INPUT=str(sdk), GITHUB_OUTPUT=str(output))
    for key in ('CFLAGS', 'CXXFLAGS', 'LDFLAGS', 'CONFIGURATION', 'MADEIRA_MOLTENVK'):
        env.pop(key, None)
    def fingerprint(extra=None):
        output.unlink(missing_ok=True)
        subprocess.run(['bash', '-euo', 'pipefail', '-c', script], env=dict(env, **(extra or {})), check=True)
        return output.read_text().strip()
    first = fingerprint()
    assert first == fingerprint()
    assert first == fingerprint({'JOBS': '3'})
    sdk.write_text('27.2\n')
    assert first != fingerprint()
    sdk.write_text('27.1\n')
    for key in ('CFLAGS', 'CXXFLAGS', 'LDFLAGS', 'CONFIGURATION', 'MADEIRA_MOLTENVK'):
        assert first != fingerprint({key: 'changed'}), key
for p in [root / 'tools/build-ipa.sh', *(root / 'tools/build').glob('*.sh')]:
    assert '$ROOT/scripts/' not in p.read_text(), p
    subprocess.run(['bash', '-n', str(p)], check=True)
print('PASS SDK/flag invalidation, stable keys, matching restore keys and build script syntax')
