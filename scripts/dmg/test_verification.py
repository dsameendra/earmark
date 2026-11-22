"""Temporary-fixture checks for branded DMG metadata; no mounting, signing or app launch."""
from __future__ import annotations

import datetime
import importlib.util
import os
from pathlib import Path
import shutil
import tempfile
import unittest
from unittest.mock import patch

from ds_store import DSStore
from mac_alias import Alias, TargetInfo, VolumeInfo

spec = importlib.util.spec_from_file_location("earmark_dmg_verifier", Path(__file__).parents[1] / "verify-dmg.py")
assert spec is not None and spec.loader is not None
verifier = importlib.util.module_from_spec(spec)
spec.loader.exec_module(verifier)


def background_alias(target: bytes = b".background.tiff") -> bytes:
    date = datetime.datetime(2026, 1, 1, tzinfo=datetime.timezone.utc)
    volume = VolumeInfo(b"Earmark", date, b"H+", 0, 0, b"\0\0", posix_path=b"/Volumes/Earmark")
    file = TargetInfo(0, target, 2, 3, date, b"\0" * 4, b"\0" * 4,
                      folder_name=b"Earmark", posix_path=b"/" + target)
    return Alias(volume=volume, target=file).to_bytes()


class DMGMetadataTests(unittest.TestCase):
    def setUp(self) -> None:
        self.temporary = tempfile.TemporaryDirectory(prefix="earmark-dmg-fixture-")
        self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name)
        self.mount = self.root / "mount"
        self.assets = self.root / "artwork"
        self.source = self.root / "source" / "Earmark.app"
        self.mount.mkdir()
        self.assets.mkdir()
        self.source.mkdir(parents=True)
        (self.source / "fixture.txt").write_text("unchanged application payload\n")
        shutil.copytree(self.source, self.mount / "Earmark.app")
        (self.mount / "Applications").symlink_to("/Applications")
        self.addCleanup(patch.stopall)
        patch.object(verifier.verification, "verify_app", return_value={"version": "0.1.0", "build": "1"}).start()

    def styled(self) -> None:
        tiff = b"II\x2a\x00" + b"fixture-retina-background"
        icns = b"icns" + (8).to_bytes(4, "big")
        (self.assets / "background.tiff").write_bytes(tiff)
        (self.assets / "volume.icns").write_bytes(icns)
        (self.mount / ".background.tiff").write_bytes(tiff)
        (self.mount / ".VolumeIcon.icns").write_bytes(icns)
        with DSStore.open(str(self.mount / ".DS_Store"), "w+") as store:
            store["."]["vSrn"] = ("long", 1)
            store["."]["icvl"] = ("type", b"icnv")
            store["."]["bwsp"] = {
                "WindowBounds": "{{200, 140}, {660, 420}}", "ShowStatusBar": False,
                "ContainerShowSidebar": False, "PreviewPaneVisibility": False, "SidebarWidth": 180,
                "ShowTabView": False, "ShowToolbar": False, "ShowPathbar": False, "ShowSidebar": False,
            }
            store["."]["icvp"] = {
                "viewOptionsVersion": 1, "backgroundType": 2, "backgroundColorRed": 1.0,
                "backgroundColorGreen": 1.0, "backgroundColorBlue": 1.0, "gridOffsetX": 0.0, "gridOffsetY": 0.0,
                "gridSpacing": 80.0, "arrangeBy": "none", "showIconPreview": False, "showItemInfo": False,
                "labelOnBottom": True, "textSize": 13.0, "iconSize": 128.0,
                "scrollPositionX": 0.0, "scrollPositionY": 0.0, "backgroundImageAlias": background_alias(),
            }
            store["Earmark.app"]["Iloc"] = (170, 200)
            store["Applications"]["Iloc"] = (490, 200)

    def verify(self, assets: bool = True) -> dict:
        return verifier.compare_payload(self.mount, self.source, False, self.assets if assets else None)

    def rejects(self, phrase: str, assets: bool = True) -> None:
        with self.assertRaisesRegex(verifier.verification.VerificationError, phrase):
            self.verify(assets)

    def change_record(self, code: str, key: str, value) -> None:
        with DSStore.open(str(self.mount / ".DS_Store"), "r+") as store:
            record = store["."][code]
            record[key] = value
            store["."][code] = record

    def test_plain_payload_remains_supported(self) -> None:
        report = self.verify(False)
        self.assertTrue(report["matchesStagedApp"])
        self.assertNotIn("installerLayout", report)

    def test_mount_point_matches_equivalent_alias_paths(self) -> None:
        alias = self.root / "mount-alias"
        alias.symlink_to(self.mount, target_is_directory=True)
        self.assertTrue(verifier.matches_mount_point(str(alias), self.mount))
        self.assertTrue(verifier.matches_mount_point(str(self.mount), alias))
        self.assertFalse(verifier.matches_mount_point(str(self.assets), self.mount))

    def test_mount_point_rejects_missing_and_invalid_values(self) -> None:
        for value in [None, "", 123, {}, "\0invalid"]:
            with self.subTest(value=value):
                self.assertFalse(verifier.matches_mount_point(value, self.mount))

    def test_branded_payload_matches_authored_artwork_and_layout(self) -> None:
        self.styled()
        report = self.verify()
        self.assertEqual(report["installerLayout"]["windowSize"], [660, 420])
        self.assertEqual(report["installerLayout"]["iconPositions"]["Applications"], [490, 200])
        self.assertEqual(set(report["installerLayout"]["metadataSHA256"]), verifier.INSTALLER_METADATA)

    def test_artwork_tampering_is_rejected(self) -> None:
        self.styled()
        (self.mount / ".background.tiff").write_bytes(b"II\x2a\x00tampered")
        self.rejects("artwork differs")

    def test_icon_tampering_is_rejected(self) -> None:
        self.styled()
        (self.mount / ".VolumeIcon.icns").write_bytes(b"icns" + (9).to_bytes(4, "big") + b"x")
        self.rejects("artwork differs")

    def test_unknown_hidden_payload_is_rejected(self) -> None:
        self.styled()
        (self.mount / ".credentials").write_text("not installer metadata")
        self.rejects("unexpected DMG root entries")

    def test_unexpected_background_directory_is_rejected(self) -> None:
        self.styled()
        (self.mount / ".background").mkdir()
        self.rejects("unexpected DMG root entries")

    def test_metadata_symlinks_are_rejected(self) -> None:
        self.styled()
        for name in verifier.INSTALLER_METADATA:
            with self.subTest(name=name):
                path = self.mount / name
                data = path.read_bytes()
                outside = self.root / "outside-metadata"
                outside.write_bytes(data)
                path.unlink()
                path.symlink_to(outside)
                self.rejects("invalid installer metadata file")
                path.unlink()
                path.write_bytes(data)

    def test_executable_metadata_is_rejected(self) -> None:
        self.styled()
        os.chmod(self.mount / ".DS_Store", 0o755)
        self.rejects("metadata is executable")

    def test_malformed_dsstore_is_rejected(self) -> None:
        self.styled()
        (self.mount / ".DS_Store").write_bytes(b"\0\0\0\1Bud1invalid")
        self.rejects("invalid Finder layout metadata")

    def test_wrong_icon_positions_are_rejected(self) -> None:
        self.styled()
        with DSStore.open(str(self.mount / ".DS_Store"), "r+") as store:
            store["Earmark.app"]["Iloc"] = (170, 250)
        self.rejects("incorrect installer icon position")

    def test_wrong_window_size_is_rejected(self) -> None:
        self.styled()
        self.change_record("bwsp", "WindowBounds", "{{200, 140}, {800, 600}}")
        self.rejects("window must be 660 by 420")

    def test_visible_chrome_is_rejected(self) -> None:
        self.styled()
        self.change_record("bwsp", "ShowToolbar", True)
        self.rejects("chrome must be hidden")

    def test_wrong_label_size_is_rejected(self) -> None:
        self.styled()
        self.change_record("icvp", "textSize", 9.0)
        self.rejects("incorrect Finder icon setting")

    def test_escaping_background_alias_is_rejected(self) -> None:
        self.styled()
        self.change_record("icvp", "backgroundImageAlias", background_alias(b"../../outside.tiff"))
        self.rejects("background alias points outside")

    def test_unknown_finder_record_is_rejected(self) -> None:
        self.styled()
        with DSStore.open(str(self.mount / ".DS_Store"), "r+") as store:
            store["private-file"]["Iloc"] = (1, 2)
        self.rejects("unexpected Finder metadata record")

    def test_styled_metadata_requires_authored_assets(self) -> None:
        self.styled()
        self.rejects("requires --layout-assets", False)

    def test_expected_styled_metadata_cannot_be_missing(self) -> None:
        self.rejects("branded installer metadata is missing")

    def test_partial_metadata_is_rejected(self) -> None:
        self.styled()
        (self.mount / ".VolumeIcon.icns").unlink()
        self.rejects("metadata is incomplete")

    def test_app_byte_changes_remain_rejected(self) -> None:
        self.styled()
        (self.mount / "Earmark.app" / "fixture.txt").write_text("different bytes")
        self.rejects("DMG app differs")

    def test_app_mode_changes_remain_rejected(self) -> None:
        self.styled()
        os.chmod(self.mount / "Earmark.app" / "fixture.txt", 0o755)
        self.rejects("DMG app differs")

    def test_applications_link_cannot_escape_to_other_destination(self) -> None:
        self.styled()
        (self.mount / "Applications").unlink()
        (self.mount / "Applications").symlink_to("/tmp")
        self.rejects("Applications link is missing or incorrect")


if __name__ == "__main__":
    unittest.main()
