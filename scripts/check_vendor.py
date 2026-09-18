#!/usr/bin/env python3
"""Offline verification of the complete delivered vendor inventory."""
import hashlib
import pathlib

root = pathlib.Path("lib")
expected = {}
for line in pathlib.Path("docs/vendor.sha256").read_text().splitlines():
    digest, path = line.split("  ", 1)
    expected[path] = digest
actual = {str(p): hashlib.sha256(p.read_bytes()).hexdigest() for p in sorted(root.rglob("*")) if p.is_file()}
assert actual == expected, "Vendor file inventory or contents differ"
assert not any(p.is_symlink() for p in root.rglob("*")), "Vendor symlink"
print(f"Vendor inventory verified: {len(actual)} files")
