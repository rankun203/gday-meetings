"""Download and verify the pinned macOS arm64 benchmark extension."""

import hashlib
import io
import sys
import tarfile
import urllib.request
from pathlib import Path

VERSION = "0.1.10-alpha.4"
NAME = f"sqlite-vec-{VERSION}-loadable-macos-aarch64.tar.gz"
SHA256 = "9c4c3c9fee1cd68d07028f90c9e31b67f13ca1a1737435ae569e8fe7a17b5a91"
out = Path(sys.argv[1])
out.mkdir(parents=True, exist_ok=True)
data = urllib.request.urlopen(
    f"https://github.com/asg017/sqlite-vec/releases/download/v{VERSION}/{NAME}"
).read()
assert hashlib.sha256(data).hexdigest() == SHA256, "Release checksum mismatch"
with tarfile.open(fileobj=io.BytesIO(data), mode="r:gz") as archive:
    members = [
        m
        for m in archive.getmembers()
        if Path(m.name).name == "vec0.dylib" and m.isfile()
    ]
    assert len(members) == 1
    (out / "vec0.dylib").write_bytes(archive.extractfile(members[0]).read())
print(out / "vec0.dylib")
