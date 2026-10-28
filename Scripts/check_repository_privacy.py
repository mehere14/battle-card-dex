#!/usr/bin/env python3
"""Check current or staged files without echoing sensitive values."""
import argparse
import io
import struct
import zipfile
import zlib
import pathlib
import plistlib
import re
import subprocess
import sys

RULES = {
    "Google API key": rb"AIza[0-9A-Za-z_-]{25,}",
    "private key": rb"-----BEGIN (?:[A-Z ]*PRIVATE KEY)-----",
    "access token": rb"(?:gh[pousr]_[A-Za-z0-9]{20,}|github_pat_[A-Za-z0-9_]{20,}|xox[baprs]-[A-Za-z0-9-]+|sk-[A-Za-z0-9_-]{20,}|AKIA[0-9A-Z]{16})",
    "personal filesystem path": rb"/Users/[A-Za-z0-9_.-]+/|[A-Za-z]:\\Users\\[A-Za-z0-9_.-]+\\",
    "literal signing team": rb"DEVELOPMENT_TEAM\s*=\s*\"?[A-Z0-9]{10}\"?\s*;",
    "personal author header": rb"//\s*Created by [A-Za-z]",
    "non-example cloud container": rb"iCloud\.(?!com\.example\.)[A-Za-z0-9][A-Za-z0-9.-]+",
    "Firebase project address": rb"[A-Za-z0-9-]+\.(?:firebaseapp\.com|firebaseio\.com|firebasestorage\.app)",
}
EMAIL = re.compile(rb"[A-Za-z0-9._%+-]+@([A-Za-z0-9.-]+\.[A-Za-z]{2,})")


def private_local_values(root):
    """Also detect exact local backend identifiers, including inside binary files."""
    values = []
    firebase = root / "BattleCardDex/GoogleService-Info.plist"
    if firebase.exists():
        config = plistlib.loads(firebase.read_bytes())
        for key in ("API_KEY", "PROJECT_ID", "STORAGE_BUCKET", "GOOGLE_APP_ID", "GCM_SENDER_ID", "BUNDLE_ID", "CLIENT_ID", "REVERSED_CLIENT_ID"):
            value = config.get(key)
            if isinstance(value, str) and len(value) >= 8:
                values.append(value.encode())
    local = root / "Configuration/Local.xcconfig"
    if local.exists():
        for line in local.read_text().splitlines():
            if " = " in line and not line.lstrip().startswith("//"):
                value = line.split(" = ", 1)[1].strip()
                if len(value) >= 8:
                    values.append(value.encode())
    return values


def issues(path, data, local_values=()):
    found = set()
    parts = pathlib.PurePosixPath(path).parts
    if any(part in ("secrets", "credentials", ".loader-state", ".loader-cache") for part in parts) or pathlib.PurePosixPath(path).suffix in (".p8", ".pem", ".key", ".credentials"):
        found.add("private credential or local-data file")
    if "xcuserdata" in parts or path.endswith(".xcuserstate"):
        found.add("Xcode user state")
    if re.search(r"(?:^|/)GoogleService-Info(?:-[^/]*)?\.plist$", path):
        found.add("private Firebase configuration")
    if path == "Configuration/Local.xcconfig" or pathlib.PurePosixPath(path).name.startswith(".env") and path != ".env.example":
        found.add("private local configuration")
    for category, pattern in RULES.items():
        if re.search(pattern, data):
            found.add(category)
    try:
        data.decode("utf-8")
        text_data = data if b"\0" not in data else b""
    except UnicodeDecodeError:
        text_data = b""
    for match in EMAIL.finditer(text_data):
        domain = match.group(1).lower()
        if not (domain.endswith(b".invalid") or domain in (b"example.com", b"example.org", b"example.net") or domain.endswith(b".example")):
            found.add("email address")
    if any(value in data for value in local_values):
        found.add("local backend/signing identifier")
    for metadata in image_metadata(data):
        for match in EMAIL.finditer(metadata):
            if not match.group(1).lower().endswith((b".invalid", b".example")):
                found.add("email address in image metadata")
        if any(value in metadata for value in local_values):
            found.add("local identifier in image metadata")
    if data.startswith(b"PK\x03\x04"):
        with zipfile.ZipFile(io.BytesIO(data)) as archive:
            for item in archive.infolist():
                if item.is_dir() or item.file_size > 20_000_000:
                    continue
                if item.filename.endswith((".swift", ".md", ".txt", ".json", ".plist", ".js", ".html", ".xml", ".svelte")):
                    nested = issues(item.filename, archive.read(item), local_values)
                    if nested:
                        found.add("archive contains: " + ", ".join(nested))
    return sorted(found)


def image_metadata(data):
    """Inspect metadata, avoiding email-like random bytes in compressed pixels."""
    if data.startswith(b"\x89PNG\r\n\x1a\n"):
        offset = 8
        while offset + 12 <= len(data):
            length = struct.unpack_from(">I", data, offset)[0]
            kind = data[offset + 4:offset + 8]
            chunk = data[offset + 8:offset + 8 + length]
            if kind in (b"tEXt", b"iTXt", b"eXIf"):
                yield chunk
            elif kind == b"zTXt":
                try:
                    yield zlib.decompress(chunk.split(b"\0", 1)[1][1:])
                except (ValueError, IndexError, zlib.error):
                    pass
            offset += length + 12
    elif data.startswith(b"\xff\xd8"):
        offset = 2
        while offset + 4 <= len(data) and data[offset] == 255:
            marker = data[offset + 1]
            if marker in (0xDA, 0xD9):
                break
            length = struct.unpack_from(">H", data, offset + 2)[0]
            if length < 2:
                break
            if marker in (0xE1, 0xED, 0xFE):
                yield data[offset + 4:offset + 2 + length]
            offset += 2 + length


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--staged", action="store_true", help="Read complete staged blobs rather than working files")
    args = parser.parse_args()
    root = pathlib.Path(subprocess.check_output(["git", "rev-parse", "--show-toplevel"], text=True).strip())
    if args.staged:
        names = subprocess.check_output(["git", "diff", "--cached", "--name-only", "--diff-filter=ACMR", "-z"], cwd=root)
    else:
        names = subprocess.check_output(["git", "ls-files", "--cached", "--others", "--exclude-standard", "-z"], cwd=root)
    values = private_local_values(root)
    checked = 0
    failures = 0
    for raw in sorted(set(names.split(b"\0")) - {b""}):
        name = raw.decode()
        if args.staged:
            data = subprocess.check_output(["git", "show", ":" + name], cwd=root)
        else:
            path = root / name
            if not path.is_file():
                continue
            data = path.read_bytes()
        checked += 1
        found = issues(name, data, values)
        if found:
            failures += 1
            # A removed tracked pathname can itself contain an identifier. Avoid
            # displaying user-state paths or any matched content.
            label = "[Xcode user-state file]" if "xcuserdata" in pathlib.PurePosixPath(name).parts else name
            print(label + ": " + ", ".join(found))
    print(f"Checked {checked} files; {failures} flagged. Matched values are never displayed.")
    return 1 if failures else 0


if __name__ == "__main__":
    sys.exit(main())
