"""Mount a DMG read-only, verify its allowlisted payload, and compare it byte-for-byte with its staged app."""
from __future__ import annotations

import argparse
import importlib.util
import json
import os
from pathlib import Path
import plistlib
import re
import subprocess
import tempfile

spec = importlib.util.spec_from_file_location("earmark_release_verifier", Path(__file__).with_name("verify-release.py"))
assert spec is not None and spec.loader is not None
verification = importlib.util.module_from_spec(spec)
spec.loader.exec_module(verification)


INSTALLER_METADATA = {".DS_Store", ".background.tiff", ".VolumeIcon.icns"}


def metadata_file(path: Path, maximum_size: int, magic: tuple[bytes, ...]) -> bytes:
    verification.require(path.is_file() and not path.is_symlink(), f"invalid installer metadata file: {path.name}")
    verification.require(0 < path.stat().st_size <= maximum_size, f"invalid installer metadata size: {path.name}")
    verification.require(path.stat().st_mode & 0o111 == 0, f"installer metadata is executable: {path.name}")
    data = path.read_bytes()
    verification.require(any(data.startswith(prefix) for prefix in magic), f"invalid installer metadata format: {path.name}")
    return data


def verify_installer_metadata(mount: Path, layout_assets: Path) -> dict[str, object]:
    """Verify the exact authored images and Finder layout; no arbitrary hidden content is accepted."""
    assets = layout_assets.resolve(strict=True)
    verification.require(assets.is_dir(), "layout assets must be a directory")
    tiff_magic = (b"II\x2a\x00", b"MM\x00\x2a")
    metadata_file(mount / ".background.tiff", 16 * 1024 * 1024, tiff_magic)
    icon = metadata_file(mount / ".VolumeIcon.icns", 16 * 1024 * 1024, (b"icns",))
    verification.require(len(icon) >= 8 and int.from_bytes(icon[4:8], "big") == len(icon), "invalid volume icon length")
    metadata_file(mount / ".DS_Store", 1024 * 1024, (b"\x00\x00\x00\x01Bud1",))
    for mounted, authored in [(".background.tiff", "background.tiff"), (".VolumeIcon.icns", "volume.icns")]:
        expected = assets / authored
        verification.require(expected.is_file() and not expected.is_symlink(), f"missing authored layout asset: {authored}")
        verification.require(verification.sha256(mount / mounted) == verification.sha256(expected), f"installer artwork differs: {mounted}")
    try:
        from ds_store import DSStore
        from mac_alias import Alias
    except ImportError as error:
        raise verification.VerificationError("branded DMG verification requires the pinned dmgbuild tool environment") from error
    expected_records = {
        (".", b"vSrn"), (".", b"bwsp"), (".", b"icvp"), (".", b"icvl"),
        ("Earmark.app", b"Iloc"), ("Applications", b"Iloc"),
    }
    try:
        with (mount / ".DS_Store").open("rb") as stream, DSStore.open(stream, "r") as store:
            records: set[tuple[str, bytes]] = set()
            for entry in store:
                key = (entry.filename, entry.code)
                verification.require(key in expected_records and key not in records, f"unexpected Finder metadata record: {key}")
                records.add(key)
            verification.require(records == expected_records, "Finder metadata is incomplete")
            window = store["."]["bwsp"]
            icons = store["."]["icvp"]
            verification.require(store["."]["vSrn"] == (b"long", 1), "invalid Finder metadata version")
            verification.require(store["."]["icvl"] == (b"type", b"icnv"), "installer must open in icon view")
            expected_window_keys = {
                "ShowStatusBar", "WindowBounds", "ContainerShowSidebar", "PreviewPaneVisibility", "SidebarWidth",
                "ShowTabView", "ShowToolbar", "ShowPathbar", "ShowSidebar",
            }
            verification.require(isinstance(window, dict) and set(window) == expected_window_keys, "unexpected Finder window settings")
            bounds = re.fullmatch(r"\{\{(-?\d+), (-?\d+)\}, \{(\d+), (\d+)\}\}", window["WindowBounds"])
            verification.require(bounds and tuple(map(int, bounds.groups()[2:])) == (660, 420), "installer window must be 660 by 420 points")
            for key in expected_window_keys - {"WindowBounds", "SidebarWidth"}:
                verification.require(window[key] is False, f"installer chrome must be hidden: {key}")
            verification.require(window["SidebarWidth"] == 180, "unexpected Finder sidebar width")
            expected_icon_values = {
                "viewOptionsVersion": 1, "backgroundType": 2, "backgroundColorRed": 1.0, "backgroundColorGreen": 1.0,
                "backgroundColorBlue": 1.0, "gridOffsetX": 0.0, "gridOffsetY": 0.0, "gridSpacing": 80.0,
                "arrangeBy": "none", "showIconPreview": False, "showItemInfo": False, "labelOnBottom": True,
                "textSize": 13.0, "iconSize": 128.0, "scrollPositionX": 0.0, "scrollPositionY": 0.0,
            }
            verification.require(isinstance(icons, dict) and set(icons) == set(expected_icon_values) | {"backgroundImageAlias"},
                                 "unexpected Finder icon settings")
            for key, value in expected_icon_values.items():
                verification.require(icons[key] == value, f"incorrect Finder icon setting: {key}")
            alias = Alias.from_bytes(icons["backgroundImageAlias"])
            verification.require(alias.target.filename == ".background.tiff" and alias.target.kind == 0 and
                                 alias.target.posix_path.lstrip("/") == ".background.tiff", "Finder background alias points outside the authored image")
            for name, position in [("Earmark.app", (170, 200)), ("Applications", (490, 200))]:
                verification.require(store[name]["Iloc"] == position, f"incorrect installer icon position: {name}")
    except verification.VerificationError:
        raise
    except Exception as error:
        raise verification.VerificationError(f"invalid Finder layout metadata: {error}") from error
    return {
        "windowSize": [660, 420], "iconSize": 128, "textSize": 13,
        "iconPositions": {"Earmark.app": [170, 200], "Applications": [490, 200]},
        "artworkMatches": True,
        "metadataSHA256": {name: verification.sha256(mount / name) for name in sorted(INSTALLER_METADATA)},
    }


def compare_payload(mount: Path, source_app: Path, developer_id: bool, layout_assets: Path | None = None) -> dict[str, object]:
    names = {path.name for path in mount.iterdir()}
    # These are filesystem service directories, not release content. No other hidden payload is accepted.
    system_directories = {".fseventsd", ".Spotlight-V100", ".Trashes"}
    unexpected = names - {"Earmark.app", "Applications"} - system_directories - INSTALLER_METADATA
    verification.require(not unexpected, f"unexpected DMG root entries: {sorted(unexpected)}")
    layout = None
    if names & INSTALLER_METADATA:
        verification.require(INSTALLER_METADATA <= names, "branded installer metadata is incomplete")
        verification.require(layout_assets is not None, "branded installer requires --layout-assets for artwork comparison")
        layout = verify_installer_metadata(mount, layout_assets)
    else:
        verification.require(layout_assets is None, "expected branded installer metadata is missing")
    for name in names & system_directories:
        directory = mount / name
        verification.require(directory.is_dir() and not directory.is_symlink(), f"invalid filesystem metadata entry: {name}")
        for path in directory.rglob("*"):
            verification.require(not path.is_symlink(), f"symlink hidden in filesystem metadata: {path.relative_to(mount)}")
            if path.is_file():
                allowed_uuid = name == ".fseventsd" and path.name == "fseventsd-uuid" and path.stat().st_size <= 40
                allowed_empty = name == ".fseventsd" and path.name == "no_log" and path.stat().st_size == 0
                verification.require(allowed_uuid or allowed_empty, f"unexpected data in filesystem metadata: {path.relative_to(mount)}")
    applications = mount / "Applications"
    verification.require(applications.is_symlink() and os.readlink(applications) == "/Applications", "Applications link is missing or incorrect")
    mounted_app = mount / "Earmark.app"
    verification.require(mounted_app.is_dir() and not mounted_app.is_symlink(), "DMG is missing its app bundle")
    source = verification.tree_manifest(source_app)
    actual = verification.tree_manifest(mounted_app)
    verification.require(actual == source, "DMG app differs from the staged source in bytes, modes or symlink targets")
    report = verification.verify_app(mounted_app, developer_id)
    result = {"payload": ["Earmark.app", "Applications -> /Applications"], "matchesStagedApp": True,
              "entriesCompared": len(actual), "version": report["version"], "build": report["build"]}
    if layout is not None:
        result["installerLayout"] = layout
    return result


def verify_image(dmg: Path, source_app: Path, developer_id: bool = False, layout_assets: Path | None = None) -> dict[str, object]:
    dmg = dmg.resolve(strict=True)
    source_app = source_app.resolve(strict=True)
    verification.command("/usr/bin/hdiutil", "verify", str(dmg))
    with tempfile.TemporaryDirectory(prefix="earmark-dmg-verify-") as temporary:
        mount = Path(temporary) / "mount"
        mount.mkdir()
        device = None
        try:
            result = subprocess.run(["/usr/bin/hdiutil", "attach", "-nobrowse", "-readonly", "-mountpoint", str(mount), "-plist", str(dmg)],
                                    capture_output=True, check=True)
            attachment = plistlib.loads(result.stdout)
            for entity in attachment.get("system-entities", []):
                if entity.get("mount-point") == str(mount):
                    device = entity.get("dev-entry")
                    break
            verification.require(bool(device), "hdiutil did not return the mounted volume's device")
            report = compare_payload(mount, source_app, developer_id, layout_assets)
        finally:
            # Only detach the private mount created by this invocation; never inspect or unmount other volumes.
            if device is not None:
                subprocess.run(["/usr/bin/hdiutil", "detach", device], check=True)
            elif os.path.ismount(mount):
                subprocess.run(["/usr/bin/hdiutil", "detach", str(mount)], check=True)
    if developer_id:
        signature = verification.command("/usr/bin/codesign", "-dv", "--verbose=4", str(dmg))
        verification.require("Authority=Developer ID Application:" in signature and "Timestamp=" in signature,
                             "DMG lacks Developer ID signing and a timestamp")
        verification.command("/usr/bin/codesign", "--verify", "--strict", str(dmg))
        verification.command("/usr/bin/xcrun", "stapler", "validate", str(dmg))
    report["sha256"] = verification.sha256(dmg)
    return report


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("dmg", type=Path)
    parser.add_argument("--source-app", required=True, type=Path)
    parser.add_argument("--require-developer-id", action="store_true")
    parser.add_argument("--layout-assets", type=Path, help="Authored installer-artwork directory containing background.tiff and volume.icns")
    parser.add_argument("--report", type=Path)
    args = parser.parse_args()
    try:
        report = verify_image(args.dmg, args.source_app, args.require_developer_id, args.layout_assets)
    except (verification.VerificationError, OSError, plistlib.InvalidFileException, subprocess.CalledProcessError) as error:
        parser.exit(1, f"DMG verification failed: {error}\n")
    if args.report:
        args.report.parent.mkdir(parents=True, exist_ok=True)
        args.report.write_text(json.dumps(report, indent=2) + "\n")
    print(f"Verified read-only DMG payload; {report['entriesCompared']} app entries match the staged source.")


if __name__ == "__main__":
    main()
