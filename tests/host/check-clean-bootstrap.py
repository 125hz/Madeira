#!/usr/bin/env python3
"""Check source bootstrap selection and source preservation without building iOS libraries."""
from pathlib import Path
import os
import shlex
import shutil
import subprocess
import tempfile

root = Path(__file__).resolve().parents[2]
server = (root / 'build/wineserver/build.sh').read_text()
selection = server[server.index('PATCHED_FILES=('):server.index('echo "=== Building kill wrapper')]

with tempfile.TemporaryDirectory(prefix='madeira-bootstrap-') as t:
    fixture = Path(t)
    wine = fixture / 'wine/server'
    wine.mkdir(parents=True)
    makefile = wine / 'Makefile.in'
    makefile.write_text('SOURCES = \\\n    atom.c \\\n    new_server_source.c \\\n    object.c \\\n    thread.c\n')
    obj, app, trace = fixture / 'obj', fixture / 'app.a', fixture / 'compiled'
    obj.mkdir()
    pre = '\n'.join(f'{k}={shlex.quote(str(v))}' for k, v in {
        'BUILD_DIR': fixture, 'WINE_SRC': wine.parent, 'REPO_ROOT': fixture,
        'OBJ_DIR': obj, 'APP_LIB': app, 'TRACE': trace,
    }.items()) + r'''
compile_one() { echo "$2" >> "$TRACE"; }
ar() { touch "$2"; }
'''
    def run(*args):
        return subprocess.run(['bash', '-e', '-c', pre + selection, 'fixture', *args], capture_output=True, text=True)
    assert run().returncode == 0
    assert trace.read_text().splitlines() == ['atom', 'new_server_source']
    print('PASS: new upstream sources enter the base; replacement objects stay out')
    trace.unlink()
    assert run().returncode == 0 and not trace.exists()
    print('PASS: an existing base does not recompile unchanged sources')
    (obj / 'libwineserver.a').unlink()
    assert run('request').returncode != 0 and not trace.exists()
    print('PASS: a partial first build refuses an incomplete base')
    app.write_bytes(b'previous base')
    assert run().returncode == 0 and (obj / 'libwineserver.a').read_bytes() == app.read_bytes()
    print('PASS: the existing app archive remains a valid incremental source')
    app.unlink(); (obj / 'libwineserver.a').unlink()
    makefile.write_text('SOURCES =\n')
    assert run().returncode != 0 and not (obj / 'libwineserver.a').exists()
    print('PASS: an empty source list cannot publish an empty base')

    build = fixture / 'build/freetype-ios'
    build.mkdir(parents=True)
    script = build / 'build.sh'
    shutil.copyfile(root / 'build/freetype-ios/build.sh', script)
    source = fixture / 'research/freetype'
    source.mkdir(parents=True)
    keep = source / 'local-source.txt'
    keep.write_text('preserve this work')
    result = subprocess.run(['bash', str(script)], capture_output=True, text=True)
    assert result.returncode != 0 and keep.read_text() == 'preserve this work'
    print('PASS: an incomplete FreeType directory is preserved and reported')

for relative in ['build/wineserver/build.sh', 'build/dxmt-ios/build.sh', 'build/fex-ios/build.sh',
                 'build/fex-arm64ec/build.sh', 'build/freetype-ios/build.sh',
                 'build/llvm-ios/build.sh', 'build/wine-macos/configure.sh']:
    subprocess.run(['bash', '-n', str(root / relative)], check=True)
print('PASS: combined build scripts pass Bash syntax checks')
