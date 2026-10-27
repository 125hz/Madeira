#!/bin/sh
# Host-side tool to backup and restore game saves from a Wine prefix.
#
# Backs up user Documents, Saved Games, and AppData from drive_c/users.
# Excludes caches, temporary files, and never touches registry files (user.reg).

set -eu

if [ "${1:-}" = "-h" ] || [ "${1:-}" = "--help" ]; then
    echo "Usage: $0 <backup|restore> <prefix_dir> [archive_file]"
    echo "  backup  : archive save data from prefix into a tar.gz"
    echo "  restore : extract save archive back into prefix"
    exit 0
fi

if [ $# -lt 2 ]; then
    echo "Usage: $0 <backup|restore> <prefix_dir> [archive_file]" >&2
    exit 1
fi

action="$1"
prefix="$2"
archive="${3:-saves-backup.tar.gz}"

if [ ! -d "$prefix" ]; then
    echo "error: prefix directory not found: $prefix" >&2
    exit 1
fi

# Resolve archive path relative to working directory before changing into prefix
case "$archive" in
    /*|[A-Za-z]:*) archive_path="$archive" ;;
    *)             archive_path="$(pwd)/$archive" ;;
esac


case "$action" in
    backup)
        if [ ! -d "$prefix/drive_c/users" ]; then
            echo "error: no drive_c/users in prefix: $prefix" >&2
            exit 1
        fi

        echo "backing up saves from $prefix to $archive..."
        (
            cd "$prefix"
            save_list="$(mktemp)"
            trap 'rm -f "$save_list"' EXIT HUP INT TERM
            python3 - "$archive_path" > "$save_list" <<'PY_LIST'
from pathlib import Path
import os
import sys

output = Path(sys.argv[1]).resolve()
ignored = {"cache", "caches", "crashdumps", "logs", "webcache", "htmlcache"}
for user in Path("drive_c/users").iterdir():
    if user.is_symlink() or not user.is_dir() or user.name in ("Public", "Default", "All Users"):
        continue
    for sub in ("Saved Games", "Documents", "AppData/Roaming", "AppData/LocalLow", "AppData/Local"):
        base = user / sub
        if not base.is_dir() or any(p.is_symlink() for p in (base, *base.parents)):
            continue
        for current, dirs, files in os.walk(base):
            folder = Path(current)
            dirs[:] = [d for d in dirs if d.lower() not in ignored and not (folder / d).is_symlink()
                       and not (folder == user / "AppData/Local" and d == "Temp")]
            for entry in [folder, *(folder / f for f in files)]:
                if entry.is_symlink() or entry.resolve() == output or not (entry.is_file() or entry.is_dir()):
                    continue
                sys.stdout.buffer.write(os.fsencode(entry) + b"\0")
PY_LIST
            COPYFILE_DISABLE=1 tar -cz --null --no-recursion \
                --exclude='*/AppData/Local/Temp' \
                --exclude='*/cache' --exclude='*/Cache' --exclude='*/caches' \
                --exclude='*/crashdumps' --exclude='*/logs' \
                --exclude='*/webcache' --exclude='*/htmlcache' \
                -T "$save_list" > "$archive_path"

        )
        echo "backup written to $archive"
        ;;

    restore)
        if [ ! -f "$archive" ]; then
            echo "error: archive file not found: $archive" >&2
            exit 1
        fi

        # Check every entry before tar can write any of them.
        python3 - "$prefix" "$archive_path" <<'PY_CHECK'
from pathlib import Path, PurePosixPath
import sys
import tarfile

root = Path(sys.argv[1]).resolve()
with tarfile.open(sys.argv[2], "r:gz") as archive:
    for entry in archive.getmembers():
        parts = PurePosixPath(entry.name).parts
        safe = (not entry.name.startswith("/") and ".." not in parts and "\\" not in entry.name
                and len(parts) >= 4 and parts[:2] == ("drive_c", "users")
                and parts[2] not in ("Public", "Default", "All Users")
                and (parts[3] in ("Documents", "Saved Games") or
                     len(parts) >= 5 and parts[3] == "AppData" and parts[4] in ("Local", "LocalLow", "Roaming"))
                and (entry.isdir() or entry.isfile()))
        if not safe:
            sys.exit("error: unsafe save archive entry: " + repr(entry.name))
        target = root
        for part in parts:
            target = target / part
            if target.is_symlink():
                sys.exit("error: save path contains a symlink: " + str(target))
PY_CHECK
        echo "restoring saves from $archive to $prefix..."
        (
            cd "$prefix"
            COPYFILE_DISABLE=1 tar -xz --no-same-owner --no-same-permissions < "$archive_path"
        )
        echo "restore finished"
        ;;

    *)
        echo "error: unknown action '$action' (expected 'backup' or 'restore')" >&2
        exit 1
        ;;
esac
