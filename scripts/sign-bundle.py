"""Sign Earmark's nested code from the inside out. Keys stay in macOS Keychain."""
from __future__ import annotations

import argparse
import json
from pathlib import Path
import plistlib
import subprocess
import sys

MACHO_MAGIC = {
    b"\xcf\xfa\xed\xfe", b"\xfe\xed\xfa\xcf", b"\xce\xfa\xed\xfe", b"\xfe\xed\xfa\xce",
    b"\xca\xfe\xba\xbe", b"\xbe\xba\xfe\xca", b"\xca\xfe\xba\xbf", b"\xbf\xba\xfe\xca",
}
CODE_BUNDLES = {".app", ".xpc", ".framework"}


def is_macho(path: Path) -> bool:
    if path.is_symlink() or not path.is_file():
        return False
    with path.open("rb") as stream:
        return stream.read(4) in MACHO_MAGIC


def bundle_executable(bundle: Path) -> Path | None:
    for relative in ["Contents/Info.plist", "Resources/Info.plist", "Versions/Current/Resources/Info.plist", "Info.plist"]:
        info = bundle / relative
        if not info.is_file():
            continue
        executable = plistlib.loads(info.read_bytes()).get("CFBundleExecutable")
        if not isinstance(executable, str) or Path(executable).name != executable:
            raise ValueError(f"invalid executable name in {info}")
        for candidate in [bundle / "Contents/MacOS" / executable, bundle / executable, bundle / "Versions/Current" / executable]:
            if candidate.is_file():
                return candidate.resolve()
        raise ValueError(f"missing executable in {bundle}")
    return None


def signing_plan(app: Path) -> list[Path]:
    app = app.resolve(strict=True)
    if app.suffix != ".app" or not (app / "Contents/Info.plist").is_file():
        raise ValueError("expected a complete .app bundle")
    paths = list(app.rglob("*"))
    for path in paths:
        if path.is_symlink() and (not path.resolve().is_relative_to(app) or not path.exists()):
            raise ValueError(f"escaping or broken symlink in app: {path.relative_to(app)}")
    bundles = [path for path in paths if not path.is_symlink() and path.is_dir() and path.suffix in CODE_BUNDLES]
    declared_executables = {executable for bundle in [*bundles, app] if (executable := bundle_executable(bundle)) is not None}
    loose_code = [path for path in paths if is_macho(path) and path.resolve() not in declared_executables]
    # Leaf executables/dylibs first, then their containing frameworks/XPC/apps, with the outer app always last.
    return sorted(set(bundles + loose_code), key=lambda path: (-len(path.parts), path.as_posix())) + [app]


def existing_entitlements(path: Path) -> bytes | None:
    result = subprocess.run(["/usr/bin/codesign", "-d", "--entitlements", ":-", str(path)], capture_output=True, check=False)
    if result.returncode != 0 or not result.stdout.strip():
        return None
    try:
        value = plistlib.loads(result.stdout)
    except plistlib.InvalidFileException:
        return None
    if not isinstance(value, dict):
        raise ValueError(f"invalid existing entitlements on {path}")
    if value.get("com.apple.security.get-task-allow") is True:
        raise ValueError(f"debugger entitlement on nested release code: {path}")
    return result.stdout


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("app", type=Path)
    parser.add_argument("--identity", required=True)
    parser.add_argument("--entitlements", type=Path, required=True)
    parser.add_argument("--self-signed", action="store_true",
                        help="sign with a named self-signed certificate (no notarization): stable certificate-anchored requirement, no hardened runtime")
    parser.add_argument("--dry-run", action="store_true", help="print signing order without invoking codesign")
    args = parser.parse_args()
    try:
        app = args.app.resolve(strict=True)
        entitlement_file = args.entitlements.resolve(strict=True)
        entitlements = plistlib.loads(entitlement_file.read_bytes())
        if not isinstance(entitlements, dict) or entitlements.get("com.apple.security.get-task-allow"):
            raise ValueError("release entitlements must be a dictionary without debugger access")
        developer_id = args.identity.startswith("Developer ID Application:")
        if args.self_signed:
            if args.identity == "-" or developer_id:
                raise ValueError("--self-signed needs a named self-signed certificate, not '-' or Developer ID")
        elif args.identity != "-" and not developer_id:
            raise ValueError("use '-' for a local build, a Developer ID Application identity for distribution, or --self-signed")
        plan = signing_plan(app)
        if args.dry_run:
            print(json.dumps([str(path.relative_to(app)) if path != app else "." for path in plan], indent=2))
            return
        base = ["/usr/bin/codesign", "--force", "--sign", args.identity]
        # Self-signed code skips the Apple timestamp service and hardened runtime: library validation would refuse
        # the embedded Sparkle/helper because a self-signed certificate has no Team ID, and nothing is notarized.
        base += ["--timestamp=none"] if args.identity == "-" or args.self_signed else ["--timestamp", "--options", "runtime"]
        for path in plan:
            options = list(base)
            if path == app:
                options += ["--entitlements", str(entitlement_file)]
            elif existing_entitlements(path) is not None:
                options += ["--preserve-metadata=entitlements"]
            subprocess.run([*options, str(path)], check=True)
        subprocess.run(["/usr/bin/codesign", "--verify", "--deep", "--strict", str(app)], check=True)
    except (OSError, ValueError, plistlib.InvalidFileException, subprocess.CalledProcessError) as error:
        parser.exit(1, f"Bundle signing failed: {error}\n")


if __name__ == "__main__":
    main()
