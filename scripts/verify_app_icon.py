"""Check the App Store icon source and its registration in an app or IPA."""

import json
import plistlib
import struct
import sys
from pathlib import Path, PurePosixPath
from zipfile import ZipFile


def verify_source():
    catalog = Path(__file__).resolve().parents[1] / "Sources/Assets.xcassets/AppIcon.appiconset"
    contents = json.loads((catalog / "Contents.json").read_text())
    icon = next(
        item for item in contents["images"]
        if item.get("platform") == "ios" and item.get("size") == "1024x1024"
    )
    with (catalog / icon["filename"]).open("rb") as png:
        header = png.read(26)
    if header[:16] != b"\x89PNG\r\n\x1a\n\x00\x00\x00\rIHDR":
        raise ValueError("The App Store icon must be a PNG")
    if struct.unpack(">IIBB", header[16:]) != (1024, 1024, 8, 2):
        raise ValueError("The App Store icon must be 1024 × 1024 RGB with no alpha channel")
    print("Verified 1024 × 1024 RGB App Store icon.")


def verify_bundle(info, has_assets):
    name = info.get("CFBundleIcons", {}).get("CFBundlePrimaryIcon", {}).get("CFBundleIconName")
    if name != "AppIcon" or not has_assets:
        raise ValueError("The app bundle must register AppIcon and contain the compiled asset catalog")
    print("Verified AppIcon registration and Assets.car in the app bundle.")


def verify_product(product):
    if product.suffix == ".ipa":
        with ZipFile(product) as archive:
            names = set(archive.namelist())
            [info_path] = [
                path for name in names
                if len((path := PurePosixPath(name)).parts) == 3
                and path.parts[0] == "Payload"
                and path.parent.suffix == ".app" and path.name == "Info.plist"
            ]
            has_assets = str(info_path.parent / "Assets.car") in names
            verify_bundle(plistlib.loads(archive.read(str(info_path))), has_assets)
    else:
        verify_bundle(plistlib.loads((product / "Info.plist").read_bytes()), (product / "Assets.car").is_file())


if __name__ == "__main__":
    verify_source()
    if len(sys.argv) == 2:
        verify_product(Path(sys.argv[1]))
