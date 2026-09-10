#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
# --ad-hoc is equivalent to CLEARLINE_SIGN_IDENTITY=- (no certificate needed).
if [[ "${1:-}" == "--ad-hoc" ]]; then
    export CLEARLINE_SIGN_IDENTITY="-"
    shift
fi
configuration="${1:-debug}"
# Keep the same certificate-backed identity across builds so macOS can track
# Keychain and Accessibility approvals. Never silently fall back to ad-hoc.
sign_identity="${CLEARLINE_SIGN_IDENTITY:-}"
if [[ -z "$sign_identity" ]]; then
    identities=()
    while IFS= read -r identity; do
        [[ -n "$identity" ]] && identities+=("$identity")
    done < <(/usr/bin/security find-identity -v -p codesigning | /usr/bin/awk '/"Apple Development:/ {print $2}')
    if [[ ${#identities[@]} -ne 1 ]]; then
        printf 'Expected one valid Apple Development identity; found %s.\n' "${#identities[@]}" >&2
        printf 'Set CLEARLINE_SIGN_IDENTITY to a signing certificate fingerprint, or create one in Xcode Settings > Accounts > Manage Certificates.\n' >&2
        printf 'If running in a sandbox, allow Keychain access and retry. For an intentional ad-hoc build only, set CLEARLINE_SIGN_IDENTITY=-.\n' >&2
        exit 1
    fi
    sign_identity="${identities[0]}"
fi
if [[ "$sign_identity" == "-" ]]; then
    printf 'Ad-hoc signing requested: permission prompts may recur after rebuilds.\n' >&2
fi
export CLANG_MODULE_CACHE_PATH="$PWD/.build/ModuleCache"
swift build --disable-sandbox -c "$configuration" --scratch-path .build
bin_path="$(swift build --disable-sandbox -c "$configuration" --show-bin-path)"
app="$PWD/dist/Clearline.app"
mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources/agent-service"
cp "$bin_path/Clearline" "$app/Contents/MacOS/Clearline.next"
mv "$app/Contents/MacOS/Clearline.next" "$app/Contents/MacOS/Clearline"
cp agent-service/agent.py "$app/Contents/Resources/agent-service/agent.py"
python3 scripts/package-info.py "$app/Contents/Info.plist"
swift scripts/make-icon.swift .build/AppIcon.iconset
iconutil -c icns .build/AppIcon.iconset -o "$app/Contents/Resources/AppIcon.icns"
codesign --force --sign "$sign_identity" "$app"
codesign --verify --deep --strict "$app"
printf 'Built %s\n' "$app"
