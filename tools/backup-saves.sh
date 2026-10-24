#!/bin/sh
# Host-side tool to backup and restore game saves from a Wine prefix.
# (On iOS devices, save backup/restore is handled in-app under Settings > Saves).
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

case "$archive_path" in
    *:*) tar_flags="--force-local" ;;
    *)   tar_flags="" ;;
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
            save_list=""
            for u in drive_c/users/*; do
                [ -d "$u" ] || continue
                uname="$(basename "$u")"
                case "$uname" in
                    Public|Default|"All Users") continue ;;
                esac
                for sub in "Saved Games" "Documents" "AppData/Roaming" "AppData/LocalLow" "AppData/Local"; do
                    if [ -d "$u/$sub" ]; then
                        save_list="${save_list}${u}/${sub}\n"
                    fi
                done
            done

            if [ -n "$save_list" ]; then
                printf "%b" "$save_list" | tar $tar_flags -czf "$archive_path" \
                    --exclude='*/AppData/Local/Temp' \
                    --exclude='*/cache' \
                    --exclude='*/Cache' \
                    --exclude='*/caches' \
                    --exclude='*/crashdumps' \
                    --exclude='*/logs' \
                    --exclude='*/webcache' \
                    --exclude='*/htmlcache' \
                    -T -
            else
                echo "warning: no save directories found under drive_c/users" >&2
                tar $tar_flags -czf "$archive_path" \
                    --exclude='*/AppData/Local/Temp' \
                    --exclude='*/cache' \
                    --exclude='*/logs' \
                    drive_c/users
            fi
        )
        echo "backup written to $archive"
        ;;

    restore)
        if [ ! -f "$archive" ]; then
            echo "error: archive file not found: $archive" >&2
            exit 1
        fi

        echo "restoring saves from $archive to $prefix..."
        (
            cd "$prefix"
            tar $tar_flags -xzf "$archive_path"
        )
        echo "restore finished"
        ;;

    *)
        echo "error: unknown action '$action' (expected 'backup' or 'restore')" >&2
        exit 1
        ;;
esac
