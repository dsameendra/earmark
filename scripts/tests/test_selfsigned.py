"""Fixture checks for the self-signed release mode. Standard library only; no keys, builds, mounts or network.

Run: python3 -m unittest discover -s scripts/tests
"""
from __future__ import annotations

import base64
import importlib.util
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest

SCRIPTS = Path(__file__).resolve().parents[1]


def load(name: str, filename: str):
    spec = importlib.util.spec_from_file_location(name, SCRIPTS / filename)
    assert spec is not None and spec.loader is not None
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


release = load("earmark_release", "verify-release.py")
appcast = load("earmark_appcast", "verify-appcast.py")
GOOD_KEY = base64.b64encode(bytes(range(32))).decode()
NAME = "Earmark Release Signing"
LISTING = f'  1) ABCDEF0123456789ABCDEF0123456789ABCDEF01 "{NAME}"\n     1 valid identities found\n'
LEAF = "0123456789abcdef0123456789abcdef01234567"


class IdentityTests(unittest.TestCase):
    def check(self, identity=NAME, listing=LISTING, names=lambda _: ("CN=Earmark", "CN=Earmark")):
        release.validate_selfsigned_identity(identity, listing, names)

    def rejects(self, phrase: str, **kwargs) -> None:
        with self.assertRaisesRegex(release.VerificationError, phrase):
            self.check(**kwargs)

    def test_valid_self_signed_identity_is_accepted(self) -> None:
        self.check()

    def test_adhoc_and_empty_identities_are_rejected(self) -> None:
        for identity in ["-", ""]:
            self.rejects("named signing identity", identity=identity)

    def test_apple_issued_identities_are_rejected(self) -> None:
        for identity in ["Developer ID Application: A (TEAM)", "Apple Development: A (TEAM)", "Apple Distribution: A (TEAM)"]:
            self.rejects("not an Apple-issued", identity=identity, listing=f'"{identity}"')

    def test_identity_absent_from_keychain_is_rejected(self) -> None:
        self.rejects("not available in Keychain", listing="     0 valid identities found\n")
        self.rejects("not available in Keychain", listing=LISTING.replace(NAME, NAME + " Old"))

    def test_certificate_must_be_self_signed(self) -> None:
        self.rejects("not self-signed", names=lambda _: ("CN=Earmark", "CN=Some CA"))
        self.rejects("not self-signed", names=lambda _: ("", ""))

    def test_certificate_is_not_read_for_rejected_names(self) -> None:
        def fail(_):
            raise AssertionError("keychain certificate must not be consulted")
        self.rejects("named signing identity", identity="-", names=fail)


class SignatureTests(unittest.TestCase):
    def test_designated_requirement_must_pin_certificate(self) -> None:
        good = f'designated => identifier "lk.dumindu.earmark.Earmark" and certificate leaf = H"{LEAF.upper()}"\n'
        self.assertEqual(release.designated_requirement_leaf(good, "lk.dumindu.earmark.Earmark"), LEAF)
        self.assertEqual(release.designated_requirement_leaf(good.replace("lk.dumindu.earmark.Earmark", "EarmarkNLLBWorker"), None), LEAF)

    def test_self_signed_certificate_is_described_as_root(self) -> None:
        # A one-certificate chain is reported by codesign as `certificate root = H"..."` (observed on a real build).
        text = f'designated => identifier "lk.dumindu.earmark.Earmark" and certificate root = H"{LEAF.upper()}"\n'
        self.assertEqual(release.designated_requirement_leaf(text, "lk.dumindu.earmark.Earmark"), LEAF)

    def test_unstable_requirements_are_rejected(self) -> None:
        for text, phrase in [
            ('designated => cdhash H"0123456789abcdef0123456789abcdef01234567"\n', "not anchored|identifier"),
            ('designated => identifier "lk.dumindu.earmark.Earmark"\n', "not anchored"),
            ('designated => identifier "other" and certificate leaf = H"%s"\n' % LEAF, "bundle identifier|code identifier"),
            ("", "no designated requirement"),
        ]:
            with self.subTest(text=text), self.assertRaisesRegex(release.VerificationError, phrase):
                release.designated_requirement_leaf(text, "lk.dumindu.earmark.Earmark")

    def test_signature_authority_rules(self) -> None:
        self.assertEqual(release.check_selfsigned_signature(f"Authority={NAME}\n", "app"), NAME)
        for text, phrase in [("Signature=adhoc\n", "ad-hoc"), ("Authority=Developer ID Application: A (T)\n", "Developer ID"), ("Identifier=x\n", "no certificate")]:
            with self.subTest(text=text), self.assertRaisesRegex(release.VerificationError, phrase):
                release.check_selfsigned_signature(text, "app")

    def test_update_configuration_is_required(self) -> None:
        release.validate_update_configuration("https://example.com/appcast.xml", GOOD_KEY)
        for feed, key in [("http://example.com/a.xml", GOOD_KEY), ("https://example.com/a.xml", ""), ("https://u:p@example.com/a.xml", GOOD_KEY),
                          ("https://example.com/a.xml", base64.b64encode(b"short").decode())]:
            with self.subTest(feed=feed), self.assertRaises(release.VerificationError):
                release.validate_update_configuration(feed, key)

    def test_developer_id_and_self_signed_are_mutually_exclusive(self) -> None:
        with self.assertRaisesRegex(release.VerificationError, "either"):
            release.verify_app(Path("/nonexistent.app"), True, True)


@unittest.skipUnless(sys.platform == "darwin", "release.sh needs the macOS toolchain (xcodegen, security, codesign)")
class ReleaseScriptTests(unittest.TestCase):
    """The shell front end must fail before building anything when inputs are wrong."""

    def run_release(self, mode: str, **environment: str) -> subprocess.CompletedProcess[str]:
        env = {key: value for key, value in os.environ.items() if not key.startswith("EARMARK_")}
        env.update(environment, EARMARK_RELEASE_DRY_RUN="1")
        return subprocess.run(["/bin/bash", str(SCRIPTS / "release.sh"), mode], text=True, capture_output=True, env=env, check=False)

    def test_unknown_mode_is_rejected(self) -> None:
        result = self.run_release("bogus")
        self.assertEqual(result.returncode, 64)
        self.assertIn("local|selfsigned|distribution", result.stderr)

    def test_each_required_input_is_enforced(self) -> None:
        complete = {"EARMARK_SIGN_IDENTITY": NAME, "EARMARK_UPDATE_FEED_URL": "https://example.com/appcast.xml", "EARMARK_SPARKLE_PUBLIC_KEY": GOOD_KEY}
        for missing in complete:
            with self.subTest(missing=missing):
                result = self.run_release("selfsigned", **{key: value for key, value in complete.items() if key != missing})
                self.assertNotEqual(result.returncode, 0)
                self.assertIn(missing, result.stderr)

    def test_selfsigned_does_not_require_notary_profile(self) -> None:
        result = self.run_release("selfsigned", EARMARK_SIGN_IDENTITY="Developer ID Application: X (T)",
                                  EARMARK_UPDATE_FEED_URL="https://example.com/appcast.xml", EARMARK_SPARKLE_PUBLIC_KEY=GOOD_KEY)
        self.assertNotIn("EARMARK_NOTARY_PROFILE", result.stderr)
        self.assertIn("not an Apple-issued", result.stderr)

    def test_insecure_feed_and_bad_key_are_rejected(self) -> None:
        for feed, key in [("http://example.com/appcast.xml", GOOD_KEY), ("https://example.com/appcast.xml", "not-a-key")]:
            with self.subTest(feed=feed):
                result = self.run_release("selfsigned", EARMARK_SIGN_IDENTITY=NAME, EARMARK_UPDATE_FEED_URL=feed, EARMARK_SPARKLE_PUBLIC_KEY=key)
                self.assertNotEqual(result.returncode, 0)
                self.assertIn("update", result.stderr)

    def test_missing_keychain_identity_is_rejected(self) -> None:
        result = self.run_release("selfsigned", EARMARK_SIGN_IDENTITY="Earmark Nonexistent Identity 0000",
                                  EARMARK_UPDATE_FEED_URL="https://example.com/appcast.xml", EARMARK_SPARKLE_PUBLIC_KEY=GOOD_KEY)
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("not available in Keychain", result.stderr)


class AppcastTests(unittest.TestCase):
    def setUp(self) -> None:
        self.temporary = tempfile.TemporaryDirectory(prefix="earmark-appcast-fixture-")
        self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name)
        self.dmg = self.root / "Earmark-0.1.0.dmg"
        self.dmg.write_bytes(b"x" * 1234)
        self.signature = base64.b64encode(b"s" * 64).decode()

    def write(self, url="https://github.com/dsameendra/earmark/releases/download/v0.1.0/Earmark-0.1.0.dmg",
              length="1234", signature=None, version="0.1.0", build="1") -> Path:
        signature = self.signature if signature is None else signature
        path = self.root / "appcast.xml"
        path.write_text(f'''<?xml version="1.0"?>
<rss version="2.0" xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle"><channel><item>
<title>{version}</title><sparkle:version>{build}</sparkle:version><sparkle:shortVersionString>{version}</sparkle:shortVersionString>
<enclosure url="{url}" length="{length}" type="application/octet-stream" sparkle:edSignature="{signature}"/>
</item></channel></rss>''')
        return path

    def verify(self, path: Path, prefix=None) -> dict:
        return appcast.verify_appcast(path, self.dmg, "0.1.0", "1", prefix)

    def rejects(self, phrase: str, path: Path, prefix=None) -> None:
        with self.assertRaisesRegex(appcast.AppcastError, phrase):
            self.verify(path, prefix)

    def test_valid_appcast_is_accepted(self) -> None:
        self.assertEqual(self.verify(self.write(), "https://github.com/dsameendra/earmark/releases/download/v0.1.0/")["build"], "1")

    def test_insecure_or_unexpected_enclosure_is_rejected(self) -> None:
        self.rejects("HTTPS", self.write(url="http://example.com/Earmark-0.1.0.dmg"))
        self.rejects("outside", self.write(url="https://evil.example/Earmark-0.1.0.dmg"), "https://github.com/dsameendra/")

    def test_enclosure_name_must_match_the_published_dmg_name(self) -> None:
        # A renamed asset with a stale appcast URL would 404 every update check (this happened to v1.0.0's first appcast).
        self.rejects("exactly one appcast item", self.write(url="https://github.com/dsameendra/earmark/releases/download/v0.1.0/Earmark-0.1.0-1-selfsigned.dmg"))

    def test_length_signature_and_version_mismatches_are_rejected(self) -> None:
        self.rejects("length", self.write(length="1"))
        self.rejects("signature", self.write(signature=""))
        self.rejects("signature", self.write(signature=base64.b64encode(b"short").decode()))
        self.rejects("build number", self.write(build="2"))
        self.rejects("version differs", self.write(version="9.9"))

    def test_appcast_for_another_file_is_rejected(self) -> None:
        self.rejects("exactly one", self.write(url="https://example.com/Other.dmg"))


class ShellToolTests(unittest.TestCase):
    def test_scripts_parse(self) -> None:
        for name in ["release.sh", "make-dmg.sh", "make-signing-identity.sh", "make-appcast.sh"]:
            with self.subTest(name=name):
                self.assertEqual(subprocess.run(["/bin/bash", "-n", str(SCRIPTS / name)], capture_output=True, check=False).returncode, 0)

    def test_make_appcast_requires_sparkle_tools(self) -> None:
        env = {**os.environ, "EARMARK_SPARKLE_BIN": "/nonexistent", "EARMARK_BUILD_ROOT": "/nonexistent"}
        result = subprocess.run(["/bin/bash", str(SCRIPTS / "make-appcast.sh"), "keys"], text=True, capture_output=True, env=env, check=False)
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("EARMARK_SPARKLE_BIN", result.stderr)

    def test_make_appcast_usage(self) -> None:
        self.assertEqual(subprocess.run(["/bin/bash", str(SCRIPTS / "make-appcast.sh")], capture_output=True, check=False).returncode, 64)

    def test_identity_script_rejects_apple_like_names(self) -> None:
        env = {**os.environ, "EARMARK_SIGN_IDENTITY_NAME": "Developer ID Application: Fake"}
        result = subprocess.run(["/bin/bash", str(SCRIPTS / "make-signing-identity.sh"), "--dry-run"], capture_output=True, env=env, check=False)
        self.assertEqual(result.returncode, 64)


if __name__ == "__main__":
    unittest.main()
