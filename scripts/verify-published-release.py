#!/usr/bin/env python3
"""Verify a published GitHub release: asset names, appcast enclosure, checksum and version agree.

Usage: python3 scripts/verify-published-release.py TAG [--repo OWNER/NAME]   (needs the gh CLI, authenticated)
"""
from __future__ import annotations

import argparse
import hashlib
import json
import subprocess
import sys
import tempfile
import xml.etree.ElementTree as ET
from pathlib import Path
from urllib.parse import unquote, urlsplit

SPARKLE = "{http://www.andymatuschak.org/xml-namespaces/sparkle}"


def fail(message: str) -> None:
    print(f"release check failed: {message}", file=sys.stderr)
    sys.exit(1)


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("tag")
    parser.add_argument("--repo", default="dsameendra/earmark")
    args = parser.parse_args()
    if not args.tag.startswith("v"):
        fail("tag must look like v1.2.3")
    version = args.tag[1:]
    info = json.loads(subprocess.check_output(
        ["gh", "release", "view", args.tag, "--repo", args.repo, "--json", "assets,isDraft,isPrerelease,tagName"], text=True))
    names = {asset["name"] for asset in info["assets"]}
    dmg_name, sha_name = f"Earmark-{version}.dmg", f"Earmark-{version}.dmg.sha256"
    for needed in (dmg_name, sha_name, "appcast.xml"):
        if needed not in names:
            fail(f"asset {needed} is missing (found {sorted(names)})")
    with tempfile.TemporaryDirectory() as work:
        subprocess.check_call(["gh", "release", "download", args.tag, "--repo", args.repo, "--dir", work,
                               "--pattern", dmg_name, "--pattern", sha_name, "--pattern", "appcast.xml"])
        dmg = Path(work) / dmg_name
        digest = hashlib.sha256(dmg.read_bytes()).hexdigest()
        recorded = (Path(work) / sha_name).read_text().split()[0]
        if digest != recorded:
            fail(f"checksum file says {recorded}, the DMG is {digest}")
        items = ET.parse(Path(work) / "appcast.xml").getroot().findall("./channel/item")
        matched = False
        for item in items:
            enclosure = item.find("enclosure")
            if enclosure is None:
                continue
            if Path(unquote(urlsplit(enclosure.get("url", "")).path)).name != dmg_name:
                continue
            matched = True
            if int(enclosure.get("length", "-1")) != dmg.stat().st_size:
                fail("appcast length does not match the DMG size")
            if (item.findtext(f"{SPARKLE}shortVersionString") or "") != version:
                fail("appcast version does not match the tag")
            if not enclosure.get(f"{SPARKLE}edSignature"):
                fail("appcast item has no EdDSA signature")
        if not matched:
            fail(f"no appcast item points at {dmg_name}: the update feed would 404")
    print(f"release {args.tag} is consistent: assets, appcast, checksum and version agree")


if __name__ == "__main__":
    main()
