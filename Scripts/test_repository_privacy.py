import io
import pathlib
import struct
import unittest
import zipfile

from check_repository_privacy import issues


class RepositoryPrivacyTests(unittest.TestCase):
    def test_credentials_and_local_identifiers_are_rejected(self):
        key = b"AIza" + b"A" * 35
        self.assertIn("Google API key", issues("config.txt", key))
        self.assertIn("local backend/signing identifier", issues("config.txt", b"private-project", [b"private-project"]))
        self.assertIn("private Firebase configuration", issues("GoogleService-Info.plist", b""))

    def test_personal_paths_emails_and_headers_are_rejected(self):
        data = b"/Users/" + b"example/profile\n" + b"person" + b"@" + b"private.test\n" + b"// Created " + b"by Example Person"
        found = issues("source.swift", data)
        self.assertIn("email address", found)
        self.assertIn("personal filesystem path", found)
        self.assertIn("personal author header", found)

    def test_examples_and_build_variables_are_allowed(self):
        data = b'iCloud.com.example.App\nDEVELOPMENT_TEAM = "$(APP_DEVELOPMENT_TEAM)";\nmaintainer@example.invalid'
        self.assertEqual(issues("template.txt", data), [])

    def test_compressed_pixels_do_not_produce_email_false_positives(self):
        data = b"\x89PNG\r\n\x1a\n" + b"\0person" + b"@" + b"private.test\xff"
        self.assertNotIn("email address", issues("image.png", data))

    def test_image_metadata_is_checked(self):
        payload = b"Author\0person" + b"@" + b"private.test"
        png = b"\x89PNG\r\n\x1a\n" + struct.pack(">I", len(payload)) + b"tEXt" + payload + b"\0" * 4
        self.assertIn("email address in image metadata", issues("image.png", png))

    def test_archived_source_is_checked(self):
        output = io.BytesIO()
        with zipfile.ZipFile(output, "w", compression=zipfile.ZIP_DEFLATED) as archive:
            archive.writestr("config.json", b"AIza" + b"A" * 35)
        self.assertTrue(any(item.startswith("archive contains:") for item in issues("source.zip", output.getvalue())))


if __name__ == "__main__":
    unittest.main()
