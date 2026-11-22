"""Check a generated Sparkle appcast against the DMG and verification manifest it describes. Never touches the network."""
from __future__ import annotations

import argparse
import base64
import json
from pathlib import Path
import sys
from urllib.parse import unquote, urlsplit
import xml.etree.ElementTree as ET

SPARKLE = "{http://www.andymatuschak.org/xml-namespaces/sparkle}"


class AppcastError(RuntimeError):
    pass


def require(condition: object, message: str) -> None:
    if not condition:
        raise AppcastError(message)


def verify_appcast(appcast: Path, dmg: Path, version: str, build: str, url_prefix: str | None = None) -> dict[str, str]:
    try:
        root = ET.fromstring(appcast.read_text())
    except (ET.ParseError, OSError) as error:
        raise AppcastError(f"appcast is not readable XML: {error}") from error
    matches = []
    for item in root.iter("item"):
        enclosure = item.find("enclosure")
        if enclosure is not None and Path(unquote(urlsplit(enclosure.get("url", "")).path)).name == dmg.name:
            matches.append((item, enclosure))
    require(len(matches) == 1, f"expected exactly one appcast item for {dmg.name}, found {len(matches)}")
    item, enclosure = matches[0]
    url = urlsplit(enclosure.get("url", ""))
    require(url.scheme == "https" and bool(url.hostname) and not url.username and not url.password, "enclosure URL must be absolute HTTPS without credentials")
    if url_prefix:
        require(enclosure.get("url", "").startswith(url_prefix), "enclosure URL is outside the expected release location")
    require(enclosure.get("length") == str(dmg.stat().st_size), "enclosure length differs from the DMG size")
    signature = enclosure.get(f"{SPARKLE}edSignature", "")
    try:
        require(len(base64.b64decode(signature, validate=True)) == 64, "EdDSA signature must decode to 64 bytes")
    except ValueError as error:
        raise AppcastError(f"missing or malformed EdDSA signature: {error}") from error
    require((item.findtext(f"{SPARKLE}version") or enclosure.get(f"{SPARKLE}version")) == build, "appcast build number differs from the app")
    require((item.findtext(f"{SPARKLE}shortVersionString") or enclosure.get(f"{SPARKLE}shortVersionString")) == version, "appcast version differs from the app")
    return {"url": enclosure.get("url", ""), "version": version, "build": build}


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("appcast", type=Path)
    parser.add_argument("--dmg", required=True, type=Path)
    parser.add_argument("--manifest", required=True, type=Path, help="app-manifest.json written by verify-release.py")
    parser.add_argument("--url-prefix")
    args = parser.parse_args()
    try:
        manifest = json.loads(args.manifest.read_text())
        result = verify_appcast(args.appcast, args.dmg, str(manifest["version"]), str(manifest["build"]), args.url_prefix)
    except (AppcastError, OSError, KeyError, ValueError) as error:
        sys.exit(f"Appcast verification failed: {error}")
    print(f"Appcast item verified: {result['version']} ({result['build']}) -> {result['url']}")


if __name__ == "__main__":
    main()
