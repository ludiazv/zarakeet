#!/usr/bin/env python3
"""Download the zarakeet test models into this directory and verify their SHA-256.

Models come from https://huggingface.co/mudler/parakeet-cpp-gguf.
Each file's SHA-256 is checked against the lfs.oid reported by the repo's
tree API, so a corrupted or incomplete download fails instead of passing.
Files that are already present and valid are left untouched.

Usage: python3 example/download_models.py
"""

import hashlib
import json
import sys
import urllib.request
from pathlib import Path

REPO = "mudler/parakeet-cpp-gguf"
TREE_API = f"https://huggingface.co/api/models/{REPO}/tree/main"
RESOLVE = f"https://huggingface.co/{REPO}/resolve/main/"

# The four models the tests in src/root.zig need (doc/WORKER_PLAN.md, section 1.3).
MODELS = (
    "tdt-1.1b-q4_k.gguf",
    "tdt-0.6b-v3-q4_k.gguf",
    "nemotron-3.5-asr-streaming-0.6b-q4_k.gguf",
    "ctc-0.6b-q4_k.gguf",
)


def expected_oids():
    """Map file name -> expected SHA-256 (lfs.oid) from the HF tree API."""
    with urllib.request.urlopen(TREE_API) as r:
        tree = json.load(r)
    return {e["path"]: e.get("lfs", {}).get("oid") for e in tree}


def sha256_file(path):
    h = hashlib.sha256()
    with open(path, "rb") as f:
        for chunk in iter(lambda: f.read(1 << 20), b""):
            h.update(chunk)
    return h.hexdigest()


def download(url, dest, want):
    """Stream url to dest (via a .part file) and replace dest if the hash matches."""
    tmp = dest.with_name(dest.name + ".part")
    h = hashlib.sha256()
    with urllib.request.urlopen(url) as r, open(tmp, "wb") as f:
        while chunk := r.read(1 << 20):
            f.write(chunk)
            h.update(chunk)
    got = h.hexdigest()
    if got != want:
        tmp.unlink()
        sys.exit(f"error: sha256 mismatch for {dest.name}: got {got}, want {want}")
    tmp.replace(dest)


def main():
    dest_dir = Path(__file__).resolve().parent
    oids = expected_oids()
    for name in MODELS:
        want = oids.get(name)
        if not want:
            sys.exit(f"error: {name} not found in {REPO}")
        path = dest_dir / name
        if path.is_file() and sha256_file(path) == want:
            print(f"ok   {name} (already present)")
            continue
        print(f"downloading {name} ...")
        download(RESOLVE + name, path, want)
        print(f"ok   {name} ({path.stat().st_size / 1e6:.0f} MB)")


if __name__ == "__main__":
    main()