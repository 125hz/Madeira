#!/usr/bin/env python3
import os
import io
from pathlib import Path
import shutil
import subprocess
import sys
import tarfile
import tempfile

root = Path(__file__).resolve().parents[2]
script = root / "tools" / "backup-saves.sh"
ok = True


def check(what, cond):
    global ok
    print(("ok   " if cond else "FAIL ") + what)
    ok &= bool(cond)


check("backup-saves.sh exists", script.is_file())

sh_bin = shutil.which("sh")
if not sh_bin and os.name == "nt":
    for p in [r"C:\Program Files\Git\bin\sh.exe", r"C:\Program Files\Git\usr\bin\sh.exe"]:
        if Path(p).exists():
            sh_bin = p
            break
if not sh_bin:
    sh_bin = "sh"

# 1. Test -h exits 0
res_h = subprocess.run([sh_bin, str(script), "-h"], capture_output=True, text=True)
check("script -h exits with 0", res_h.returncode == 0 and "Usage:" in res_h.stdout)

# 2. Test missing args exits 1
res_err = subprocess.run([sh_bin, str(script)], capture_output=True, text=True)
check("script without args exits with 1", res_err.returncode == 1)

# 3. Test backup and restore with a mock Wine prefix
with tempfile.TemporaryDirectory() as tmpdir:
    tmp = Path(tmpdir)
    src_prefix = tmp / "prefix"
    dst_prefix = tmp / "dst_prefix"
    archive = tmp / "saves.tar.gz"

    user_dir = src_prefix / "drive_c" / "users" / "madeira"
    saved_games = user_dir / "Saved Games" / "GameA"
    docs = user_dir / "Documents" / "My Games"
    appdata_local = user_dir / "AppData" / "Local" / "GameA"
    temp_dir = user_dir / "AppData" / "Local" / "Temp"

    saved_games.mkdir(parents=True)
    docs.mkdir(parents=True)
    appdata_local.mkdir(parents=True)
    temp_dir.mkdir(parents=True)

    (saved_games / "slot1.sav").write_text("SAVE_DATA", encoding="utf-8")
    (docs / "config.ini").write_text("CONFIG_DATA", encoding="utf-8")
    (appdata_local / "profile.bin").write_text("PROFILE_DATA", encoding="utf-8")
    (temp_dir / "junk.tmp").write_text("TEMP_DATA", encoding="utf-8")
    (src_prefix / "user.reg").write_text("SRC_REGISTRY", encoding="utf-8")

    # Run backup
    res_b = subprocess.run(
        [sh_bin, str(script), "backup", str(src_prefix), str(archive)],
        capture_output=True,
        text=True
    )
    check("backup command succeeds", res_b.returncode == 0 and archive.is_file())

    # Check tar archive contents
    with tarfile.open(archive, "r:gz") as tar:
        names = tar.getnames()

    has_save = any("slot1.sav" in n for n in names)
    has_doc = any("config.ini" in n for n in names)
    has_appdata = any("profile.bin" in n for n in names)
    has_temp = any("junk.tmp" in n or "Temp" in n for n in names)
    has_reg = any("user.reg" in n for n in names)

    check("archive contains Saved Games", has_save)
    check("archive contains Documents", has_doc)
    check("archive contains AppData", has_appdata)
    check("archive excludes Temp files", not has_temp)
    check("archive excludes user.reg", not has_reg)

    # 4. Test restore into a separate prefix with an existing user.reg
    dst_prefix.mkdir(parents=True)
    (dst_prefix / "user.reg").write_text("DST_REGISTRY", encoding="utf-8")

    res_r = subprocess.run(
        [sh_bin, str(script), "restore", str(dst_prefix), str(archive)],
        capture_output=True,
        text=True
    )
    check("restore command succeeds", res_r.returncode == 0)

    restored_save = dst_prefix / "drive_c" / "users" / "madeira" / "Saved Games" / "GameA" / "slot1.sav"
    restored_doc = dst_prefix / "drive_c" / "users" / "madeira" / "Documents" / "My Games" / "config.ini"
    restored_reg = dst_prefix / "user.reg"

    check("restored save file exists and matches", restored_save.is_file() and restored_save.read_text(encoding="utf-8") == "SAVE_DATA")
    check("restored doc exists and matches", restored_doc.is_file() and restored_doc.read_text(encoding="utf-8") == "CONFIG_DATA")
    check("target user.reg was not overwritten", restored_reg.is_file() and restored_reg.read_text(encoding="utf-8") == "DST_REGISTRY")

# Reject the complete archive before a valid earlier entry can overwrite a save.
with tempfile.TemporaryDirectory() as directory:
    base = Path(directory)
    prefix, archive = base / 'prefix', base / 'bad.tar.gz'
    prefix.mkdir()
    target = prefix / 'drive_c/users/test/Documents/first.sav'
    for bad_name, kind in [('../escape', 'file'), ('user.reg', 'file'),
                           ('drive_c/users/test/Documents/link', 'symlink'),
                           ('drive_c/users/test/Documents/hard', 'hardlink')]:
        with tarfile.open(archive, 'w:gz') as tar:
            good = tarfile.TarInfo('drive_c/users/test/Documents/first.sav')
            good.size = 3
            tar.addfile(good, io.BytesIO(b'new'))
            bad = tarfile.TarInfo(bad_name)
            if kind != 'file':
                bad.type = tarfile.SYMTYPE if kind == 'symlink' else tarfile.LNKTYPE
                bad.linkname = str(base / 'outside')
            tar.addfile(bad)
        result = subprocess.run([sh_bin, str(script), 'restore', str(prefix), str(archive)], capture_output=True)
        check('reject ' + kind + ' ' + bad_name + ' before any write', result.returncode != 0 and not target.exists())
    outside = base / 'outside'
    outside.mkdir()
    (prefix / 'drive_c/users/test').mkdir(parents=True)
    (prefix / 'drive_c/users/test/Documents').symlink_to(outside, target_is_directory=True)
    with tarfile.open(archive, 'w:gz') as tar:
        member = tarfile.TarInfo('drive_c/users/test/Documents/escape.sav')
        member.size = 3
        tar.addfile(member, io.BytesIO(b'bad'))
    result = subprocess.run([sh_bin, str(script), 'restore', str(prefix), str(archive)], capture_output=True)
    check('reject an existing destination symlink', result.returncode != 0 and not list(outside.iterdir()))

sys.exit(0 if ok else 1)
