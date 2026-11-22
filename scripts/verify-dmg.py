"""Mount a DMG read-only, verify its allowlisted payload, and compare it byte-for-byte with its staged app."""
from __future__ import annotations

import argparse
import importlib.util
import json
import os
from pathlib import Path
import plistlib
import subprocess
import tempfile

spec = importlib.util.spec_from_file_location("earmark_release_verifier", Path(__file__).with_name("verify-release.py"))
assert spec is not None and spec.loader is not None
verification = importlib.util.module_from_spec(spec)
spec.loader.exec_module(verification)


def compare_payload(mount: Path, source_app: Path, developer_id: bool) -> dict[str, object]:
    names = {path.name for path in mount.iterdir()}
    # These are filesystem service directories, not release content. No other hidden payload is accepted.
    system_directories = {".fseventsd", ".Spotlight-V100", ".Trashes"}
    unexpected = names - {"Earmark.app", "Applications"} - system_directories
    verification.require(not unexpected, f"unexpected DMG root entries: {sorted(unexpected)}")
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
    return {"payload": ["Earmark.app", "Applications -> /Applications"], "matchesStagedApp": True,
            "entriesCompared": len(actual), "version": report["version"], "build": report["build"]}


def verify_image(dmg: Path, source_app: Path, developer_id: bool = False) -> dict[str, object]:
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
            report = compare_payload(mount, source_app, developer_id)
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
    parser.add_argument("--report", type=Path)
    args = parser.parse_args()
    try:
        report = verify_image(args.dmg, args.source_app, args.require_developer_id)
    except (verification.VerificationError, OSError, plistlib.InvalidFileException, subprocess.CalledProcessError) as error:
        parser.exit(1, f"DMG verification failed: {error}\n")
    if args.report:
        args.report.parent.mkdir(parents=True, exist_ok=True)
        args.report.write_text(json.dumps(report, indent=2) + "\n")
    print(f"Verified read-only DMG payload; {report['entriesCompared']} app entries match the staged source.")


if __name__ == "__main__":
    main()
