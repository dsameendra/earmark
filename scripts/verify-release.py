"""Verify an Earmark app without launching it, capture engines, or the updater."""
from __future__ import annotations

import argparse
import base64
import hashlib
import json
import os
from pathlib import Path
import plistlib
import re
import stat
import subprocess
import sys
from urllib.parse import urlsplit

MACHO_MAGIC = {
    b"\xcf\xfa\xed\xfe", b"\xfe\xed\xfa\xcf", b"\xce\xfa\xed\xfe", b"\xfe\xed\xfa\xce",
    b"\xca\xfe\xba\xbe", b"\xbe\xba\xfe\xca", b"\xca\xfe\xba\xbf", b"\xbf\xba\xfe\xca",
}
FORBIDDEN_SUFFIXES = {".safetensors", ".onnx", ".gguf", ".py", ".pyc", ".sqlite", ".sqlite3", ".pem", ".p12", ".pfx", ".key"}
FORBIDDEN_COMPONENTS = {".git", ".venv", ".model-cache", "__pycache__", "Python.framework", ".build"}


class VerificationError(RuntimeError):
    pass


def require(condition: object, message: str) -> None:
    if not condition:
        raise VerificationError(message)


def command(*arguments: str) -> str:
    result = subprocess.run(arguments, text=True, capture_output=True, check=False)
    require(result.returncode == 0, f"{Path(arguments[0]).name} failed for {arguments[-1]}: {result.stderr.strip() or result.stdout.strip()}")
    return result.stdout + result.stderr


def validate_update_configuration(feed: str, public_key: str) -> None:
    try:
        url = urlsplit(feed)
        require(url.scheme == "https" and bool(url.hostname), "update feed must be an absolute HTTPS URL")
        require(not url.username and not url.password and not url.fragment, "update feed cannot contain credentials or a fragment")
        _ = url.port  # Also rejects malformed ports before a build or notarization submission.
        key = base64.b64decode(public_key, validate=True)
        require(len(key) == 32, "Sparkle public key must decode to 32 bytes")
    except (TypeError, ValueError) as error:
        raise VerificationError(f"invalid update configuration: {error}") from error


def validate_selfsigned_identity(identity: str, listing: str, certificate_names) -> None:
    """Accept only a named, valid, self-signed (subject == issuer) identity; never Developer ID, ad-hoc or Apple-issued."""
    require(bool(identity) and identity != "-", "selfsigned mode requires a named signing identity, not ad-hoc '-'")
    require(not identity.startswith(("Developer ID Application:", "Apple Development:", "Apple Distribution:", "Mac Developer:")),
            "selfsigned mode requires a self-signed certificate, not an Apple-issued identity (use distribution mode for Developer ID)")
    require('"' + identity + '"' in listing, "the requested valid self-signed identity is not available in Keychain "
            "(run scripts/make-signing-identity.sh; an untrusted certificate is not listed as valid)")
    subject, issuer = certificate_names(identity)
    require(bool(subject.strip()) and subject.strip() == issuer.strip(), "the signing certificate is not self-signed (issuer differs from subject)")


def certificate_name_lines(identity: str) -> tuple[str, str]:
    """Return the (subject, issuer) lines of the Keychain certificate with this common name."""
    pem = command("/usr/bin/security", "find-certificate", "-c", identity, "-p")
    result = subprocess.run(["/usr/bin/openssl", "x509", "-noout", "-subject", "-issuer"], input=pem, text=True, capture_output=True, check=False)
    require(result.returncode == 0, "could not read the signing certificate")
    values = dict(line.split("=", 1) for line in result.stdout.splitlines() if "=" in line and line.split("=", 1)[0] in {"subject", "issuer"})
    return values.get("subject", ""), values.get("issuer", "")


def designated_requirement_leaf(requirement_output: str, bundle_identifier: str | None) -> str:
    """Return the pinned leaf-certificate SHA-1 from `codesign -d -r-` output, requiring the stable identifier+leaf form."""
    match = re.search(r"^designated => (.+)$", requirement_output, re.M)
    require(match is not None, "no designated requirement is present")
    text = match[1]
    require('identifier "' in text and (bundle_identifier is None or f'identifier "{bundle_identifier}"' in text),
            "designated requirement does not name the code identifier")
    # A self-signed certificate is its own chain, so macOS describes it as the "root"; a longer chain names the "leaf".
    leaf = re.search(r'certificate (?:leaf|root) = H"([0-9a-fA-F]{40})"', text)
    require(leaf is not None and "cdhash" not in text,
            "designated requirement is not anchored to the signing certificate; permissions and updates would not survive a new build")
    return leaf[1].lower()


def check_selfsigned_signature(signature: str, name: str) -> str:
    """Validate one `codesign -dv` description and return the signing authority."""
    require("Signature=adhoc" not in signature, f"ad-hoc signed: {name}")
    require("Authority=Developer ID Application:" not in signature, f"unexpected Developer ID signature in selfsigned mode: {name}")
    authority = re.search(r"^Authority=(.+)$", signature, re.M)
    require(authority is not None, f"no certificate authority in signature: {name}")
    return authority[1]


def sha256(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as stream:
        for chunk in iter(lambda: stream.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def is_macho(path: Path) -> bool:
    if path.is_symlink() or not path.is_file():
        return False
    with path.open("rb") as stream:
        return stream.read(4) in MACHO_MAGIC


def tree_manifest(root: Path) -> list[dict[str, str]]:
    """Record bytes, permissions and literal symlink targets without following symlink directories."""
    root = root.resolve(strict=True)
    entries: list[dict[str, str]] = []
    for directory, directories, files in os.walk(root, followlinks=False):
        for name in sorted(directories + files):
            path = Path(directory) / name
            mode = path.lstat().st_mode
            entry = {"path": path.relative_to(root).as_posix(), "mode": oct(stat.S_IMODE(mode))}
            if stat.S_ISLNK(mode):
                entry.update(kind="symlink", target=os.readlink(path))
            elif stat.S_ISREG(mode):
                entry.update(kind="file", sha256=sha256(path))
            elif stat.S_ISDIR(mode):
                entry.update(kind="directory")
            else:
                raise VerificationError(f"unexpected special file: {entry['path']}")
            entries.append(entry)
    return sorted(entries, key=lambda entry: entry["path"])


def verify_payload(app: Path) -> list[dict[str, str]]:
    app = app.resolve(strict=True)
    entries = tree_manifest(app)
    for entry in entries:
        relative = Path(entry["path"])
        require(not (set(relative.parts) & FORBIDDEN_COMPONENTS), f"development/runtime dependency content: {relative}")
        require(relative.name not in {".env", ".DS_Store", "model.bin", "pytorch_model.bin", "__preview.dylib"}, f"unintended file: {relative}")
        require(not relative.name.endswith(".debug.dylib"), f"debug binary in release payload: {relative}")
        require(relative.suffix.lower() not in FORBIDDEN_SUFFIXES, f"unintended model, interpreter or credential file: {relative}")
        if entry["kind"] == "symlink":
            target = app / relative
            require(target.resolve().is_relative_to(app), f"symlink escapes the app: {relative}")
            require(target.exists(), f"broken app symlink: {relative}")
    return entries


def verify_app(app: Path, developer_id: bool = False, self_signed: bool = False) -> dict[str, object]:
    require(not (developer_id and self_signed), "choose either Developer ID or self-signed verification")
    app = app.resolve(strict=True)
    require(app.is_dir() and app.suffix == ".app", "expected an existing .app bundle")
    info = plistlib.loads((app / "Contents/Info.plist").read_bytes())
    require(info.get("CFBundleIdentifier") == "lk.dumindu.earmark.Earmark", "unexpected bundle identifier")
    require(info.get("LSMinimumSystemVersion") == "26.0", "unexpected minimum macOS version")
    require(re.fullmatch(r"\d+(?:\.\d+){0,2}", str(info.get("CFBundleShortVersionString", ""))), "missing/invalid marketing version")
    require(re.fullmatch(r"\d+(?:\.\d+){0,2}", str(info.get("CFBundleVersion", ""))), "missing/invalid build version")
    executable = info.get("CFBundleExecutable")
    require(isinstance(executable, str) and Path(executable).name == executable, "invalid executable name")
    main = app / "Contents/MacOS" / executable
    helper = app / "Contents/Helpers/EarmarkNLLBWorker"
    helpers = [helper]
    native_frameworks = []
    modern_text = tuple(int(part) for part in (info["CFBundleShortVersionString"].split(".") + ["0", "0"])[:3]) >= (1, 1, 0)
    if modern_text:
        helpers.append(app / "Contents/Helpers/EarmarkTextWorker")
        helpers.append(app / "Contents/Helpers/EarmarkSpeechWorker")
        native_frameworks.append(app / "Contents/Frameworks/EarmarkLlama.framework")
        native_frameworks.append(app / "Contents/Frameworks/CTranscribe.framework")
        require(all(framework.is_dir() for framework in native_frameworks), "a native model framework is absent")
        require((app / "Contents/Resources/NativeSpeechRuntimeLicences.txt").is_file(), "native speech licence notice is absent")
        require((app / "Contents/Resources/NativeTextRuntimeLicences.txt").is_file(), "native text licence notice is absent")
        main_dependencies = command("/usr/bin/otool", "-L", str(main))
        require("EarmarkLlama.framework" not in main_dependencies and "CTranscribe.framework" not in main_dependencies,
                "isolated native model libraries must not be linked into the app executable")
        require("@rpath/EarmarkLlama.framework/Versions/A/EarmarkLlama" in command("/usr/bin/otool", "-L", str(app / "Contents/Helpers/EarmarkTextWorker")),
                "native text helper does not link the reviewed text framework")
        require("@rpath/CTranscribe.framework/Versions/A/CTranscribe" in command("/usr/bin/otool", "-L", str(app / "Contents/Helpers/EarmarkSpeechWorker")),
                "native speech helper does not link the reviewed speech framework")
    for path in [main, *helpers]:
        require(is_macho(path), f"missing native executable: {path.relative_to(app)}")
        require(path.stat().st_mode & 0o111, f"native executable is not executable: {path.relative_to(app)}")
        require("arm64" in command("/usr/bin/lipo", "-archs", str(path)), f"not arm64: {path.relative_to(app)}")
    require((app / "Contents/Frameworks/Sparkle.framework").is_dir(), "Sparkle framework is absent")
    for notice in ["NativeRuntimeLicences.txt", "ThirdPartyNotices.txt"]:
        require((app / "Contents/Resources" / notice).is_file(), f"missing notice: {notice}")
    entries = verify_payload(app)
    macho = []
    for entry in entries:
        if entry["kind"] != "file":
            continue
        path = app / entry["path"]
        if not is_macho(path):
            continue
        macho.append(entry["path"])
        dependencies = command("/usr/bin/otool", "-L", str(path))
        for line in dependencies.splitlines():
            if not line.startswith("\t"):
                continue
            dependency = line.strip().split(" (", 1)[0]
            require(dependency.startswith(("/System/Library/", "/usr/lib/", "@rpath/", "@loader_path/", "@executable_path/")),
                    f"non-system dynamic dependency in {entry['path']}: {dependency}")
        load_commands = command("/usr/bin/otool", "-l", str(path))
        for rpath in re.findall(r"cmd LC_RPATH\s+cmdsize \d+\s+path (.*?) \(offset", load_commands):
            require(not rpath.startswith("/") or rpath.startswith(("/System/Library/", "/usr/lib/")),
                    f"non-system absolute runtime search path in {entry['path']}: {rpath}")
    command("/usr/bin/codesign", "--verify", "--deep", "--strict", str(app))
    signing = command("/usr/bin/codesign", "-dv", "--verbose=4", str(app))
    if developer_id:
        validate_update_configuration(info.get("SUFeedURL", ""), info.get("SUPublicEDKey", ""))
        for path in [app, *helpers, *native_frameworks]:
            signature = command("/usr/bin/codesign", "-dv", "--verbose=4", str(path))
            require("Authority=Developer ID Application:" in signature, f"not Developer ID signed: {path.name}")
            require("runtime" in signature, f"hardened runtime absent: {path.name}")
            require("Timestamp=" in signature, f"secure signing timestamp absent: {path.name}")
        app_team = re.search(r"^TeamIdentifier=(.+)$", signing, re.M)
        helper_team = re.search(r"^TeamIdentifier=(.+)$", command("/usr/bin/codesign", "-dv", "--verbose=4", str(helper)), re.M)
        require(app_team and helper_team and app_team[1] == helper_team[1], "app and native helper signing teams differ")
    if self_signed:
        validate_update_configuration(info.get("SUFeedURL", ""), info.get("SUPublicEDKey", ""))
        sparkle = app / "Contents/Frameworks/Sparkle.framework"
        authorities = {}
        leaves = {}
        for path in [app, *helpers, *native_frameworks, sparkle]:
            authorities[path.name] = check_selfsigned_signature(command("/usr/bin/codesign", "-dv", "--verbose=4", str(path)), path.name)
            if path != sparkle:
                leaves[path.name] = designated_requirement_leaf(command("/usr/bin/codesign", "-d", "-r-", str(path)),
                                                              "lk.dumindu.earmark.Earmark" if path == app else None)
        require(len(set(authorities.values())) == 1, "app, helper and Sparkle are not signed with one identity")
        require(len(set(leaves.values())) == 1, "app and helper designated requirements pin different certificates")
    return {
        "bundleIdentifier": info["CFBundleIdentifier"], "version": info["CFBundleShortVersionString"],
        "build": info["CFBundleVersion"], "minimumMacOS": info["LSMinimumSystemVersion"],
        "nativeHelper": True, "nativeHelpers": [p.name for p in helpers], "pythonRuntime": False, "machOBinaries": macho,
        "files": entries, "developerID": developer_id, "selfSigned": self_signed,
    }


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("app", type=Path)
    parser.add_argument("--require-developer-id", action="store_true")
    parser.add_argument("--require-self-signed", action="store_true", help="accept a stable self-signed identity; no notarization or Gatekeeper claims")
    parser.add_argument("--report", type=Path)
    args = parser.parse_args()
    try:
        report = verify_app(args.app, args.require_developer_id, args.require_self_signed)
    except (VerificationError, OSError, plistlib.InvalidFileException) as error:
        parser.exit(1, f"Release verification failed: {error}\n")
    if args.report:
        args.report.parent.mkdir(parents=True, exist_ok=True)
        args.report.write_text(json.dumps(report, indent=2) + "\n")
    print(f"Verified {len(report['files'])} payload entries and {len(report['machOBinaries'])} Mach-O binaries; native helper and Sparkle present.")


if __name__ == "__main__":
    main()
