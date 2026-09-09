#!/bin/bash
set -euo pipefail

usage() {
    printf 'Usage: %s [release|debug] [applications-directory]\n' "$0"
    printf 'Defaults: release /Applications\n'
}

if [[ "${1:-}" == "--help" || "${1:-}" == "-h" ]]; then usage; exit 0; fi
configuration="${1:-release}"
applications_dir="${2:-/Applications}"
if [[ $# -gt 2 || ! "$configuration" =~ ^(release|debug)$ || "$applications_dir" != /* ]]; then
    usage >&2
    exit 2
fi
if [[ "$EUID" -eq 0 ]]; then
    printf 'Run this script as your normal user; it requests sudo only for installation if needed.\n' >&2
    exit 1
fi
if [[ ! -d "$applications_dir" ]]; then
    printf 'Applications directory does not exist: %s\n' "$applications_dir" >&2
    exit 1
fi
applications_dir="$(cd "$applications_dir" && pwd -P)"
repo_dir="$(cd "$(dirname "$0")/.." && pwd -P)"
source_app="$repo_dir/dist/Clearline.app"
target_app="$applications_dir/Clearline.app"
if [[ "$source_app" == "$target_app" ]]; then
    printf 'The installation directory must differ from the build directory.\n' >&2
    exit 1
fi

"$repo_dir/scripts/build.sh" "$configuration"
/usr/bin/codesign --verify --deep --strict "$source_app"

# Build as the current user; elevate only the filesystem operations if needed.
use_sudo=false
if [[ ! -w "$applications_dir" ]]; then
    sudo -v
    use_sudo=true
fi
install_run() {
    if [[ "$use_sudo" == true ]]; then sudo "$@"; else "$@"; fi
}
if [[ -e "$target_app" || -L "$target_app" ]]; then
    if [[ -L "$target_app" || ! -d "$target_app" ]] ||
       [[ "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$target_app/Contents/Info.plist" 2>/dev/null || true)" != "com.clearline.desktop" ]]; then
        printf 'Refusing to replace an unrelated app or symlink: %s\n' "$target_app" >&2
        exit 1
    fi
fi

# Stage on the destination volume before replacing an existing installation.
stage_dir="$(install_run /usr/bin/mktemp -d "$applications_dir/.clearline-install.XXXXXX")"
cleanup() {
    status=$?
    trap - EXIT
    if [[ -d "$stage_dir/previous.app" && ! -e "$target_app" ]]; then
        if ! install_run /bin/mv "$stage_dir/previous.app" "$target_app"; then
            printf 'Restore the previous installation from: %s/previous.app\n' "$stage_dir" >&2
            exit 1
        fi
    fi
    install_run /bin/rm -rf "$stage_dir"
    exit "$status"
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM
install_run /bin/chmod 755 "$stage_dir"
install_run /usr/bin/ditto "$source_app" "$stage_dir/Clearline.app"
/usr/bin/codesign --verify --deep --strict "$stage_dir/Clearline.app"
if [[ -d "$target_app" ]]; then
    install_run /bin/mv "$target_app" "$stage_dir/previous.app"
fi
install_run /bin/mv "$stage_dir/Clearline.app" "$target_app"
printf 'Installed %s (%s). Quit any running Clearline instance, then open this app.\n' "$target_app" "$configuration"
