"""Generate bundle metadata from the Swift branding constants."""
from pathlib import Path
import plistlib
import re
import sys

source = Path("Sources/ClearlineCore/Models.swift").read_text()


def constant(name):
    return re.search(r'public static let ' + name + r' = "([^"]+)"', source).group(1)


name = constant("name")
info = {
    "CFBundleExecutable": name,
    "CFBundleIdentifier": constant("bundleID"),
    "CFBundleName": name,
    "CFBundleDisplayName": name,
    "CFBundleIconFile": "AppIcon",
    "CFBundlePackageType": "APPL",
    "CFBundleShortVersionString": constant("version"),
    "CFBundleVersion": "1",
    "LSMinimumSystemVersion": "14.0",
    "NSHighResolutionCapable": True,
    "NSPrincipalClass": "NSApplication",
    "NSHumanReadableCopyright": name,
}
Path(sys.argv[1]).write_bytes(plistlib.dumps(info))
