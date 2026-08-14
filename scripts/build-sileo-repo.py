#!/usr/bin/env python3
"""Genera un mini-repo apt/Sileo a partire dai .deb in debs/."""
from __future__ import annotations

import hashlib
import io
import lzma
import tarfile
import zipfile
from pathlib import Path


def _read_ar_member(data: bytes, name: str) -> bytes:
    if not data.startswith(b"!<arch>\n"):
        raise ValueError("not an ar archive")
    off = 8
    while off + 60 <= len(data):
        header = data[off : off + 60]
        off += 60
        fname = header[0:16].decode("ascii", "replace").strip()
        size = int(header[48:58].decode("ascii").strip())
        payload = data[off : off + size]
        off += size
        if off % 2 == 1:
            off += 1
        if fname.rstrip("/") == name or fname.startswith(name):
            return payload
    raise KeyError(name)


def _control_from_deb(deb: Path) -> str:
    raw = deb.read_bytes()
    # Prefer data member names used by Theos
    for member in ("control.tar.gz", "control.tar.xz", "control.tar.lzma", "control.tar"):
        try:
            blob = _read_ar_member(raw, member)
            break
        except KeyError:
            continue
    else:
        raise RuntimeError(f"no control.tar* in {deb.name}")

    if member.endswith(".gz"):
        import gzip

        tar_bytes = gzip.decompress(blob)
    elif member.endswith(".xz"):
        tar_bytes = lzma.decompress(blob)
    elif member.endswith(".lzma"):
        tar_bytes = lzma.decompress(blob)
    else:
        tar_bytes = blob

    with tarfile.open(fileobj=io.BytesIO(tar_bytes), mode="r:") as tf:
        for m in tf.getmembers():
            base = Path(m.name).name
            if base == "control":
                f = tf.extractfile(m)
                assert f is not None
                return f.read().decode("utf-8", "replace")
    raise RuntimeError(f"control file missing in {deb.name}")


def _hashes(path: Path) -> tuple[str, str, str, int]:
    data = path.read_bytes()
    return (
        hashlib.md5(data).hexdigest(),
        hashlib.sha1(data).hexdigest(),
        hashlib.sha256(data).hexdigest(),
        len(data),
    )


def build_repo(repo_root: Path, deb_glob: str = "debs/*.deb") -> None:
    repo_root.mkdir(parents=True, exist_ok=True)
    debs_dir = repo_root / "debs"
    debs_dir.mkdir(parents=True, exist_ok=True)

    entries: list[str] = []
    for deb in sorted(repo_root.glob(deb_glob)):
        control = _control_from_deb(deb).strip() + "\n"
        md5, sha1, sha256, size = _hashes(deb)
        rel = f"debs/{deb.name}"
        # Drop fields Theos may add that confuse some clients; keep essential + hashes
        lines = []
        for line in control.splitlines():
            if line.startswith("Installed-Size:"):
                continue
            lines.append(line)
        block = "\n".join(lines)
        block += f"\nFilename: {rel}"
        block += f"\nSize: {size}"
        block += f"\nMD5sum: {md5}"
        block += f"\nSHA1: {sha1}"
        block += f"\nSHA256: {sha256}"
        entries.append(block)

    packages = "\n\n".join(entries) + ("\n" if entries else "")
    (repo_root / "Packages").write_text(packages, encoding="utf-8")

    import bz2
    import gzip

    (repo_root / "Packages.gz").write_bytes(gzip.compress(packages.encode("utf-8")))
    (repo_root / "Packages.bz2").write_bytes(bz2.compress(packages.encode("utf-8")))

    release = """Origin: Miao
Label: Miao
Suite: stable
Version: 1.0
Codename: stable
Architectures: iphoneos-arm64
Components: main
Description: Miao rootless tweaks for Dopamine (auto-built)
"""
    (repo_root / "Release").write_text(release, encoding="utf-8")

    # Alcuni client Sileo/apt leggono anche ./Packages senza compressione
    # e preferiscono un "flat repo" esplicito.
    (repo_root / "CydiaIcon.png").write_bytes(b"")  # placeholder opzionale ignorato se vuoto
    try:
        (repo_root / "CydiaIcon.png").unlink(missing_ok=True)
    except TypeError:
        p = repo_root / "CydiaIcon.png"
        if p.exists():
            p.unlink()

    index = """<!DOCTYPE html>
<html lang="it">
<head>
  <meta charset="utf-8" />
  <meta name="viewport" content="width=device-width, initial-scale=1" />
  <title>Miao repo</title>
  <style>
    body { font-family: system-ui, sans-serif; max-width: 40rem; margin: 2rem auto; padding: 0 1rem; line-height: 1.45; }
    code { background: #f2f2f2; padding: 0.1rem 0.35rem; border-radius: 4px; }
  </style>
</head>
<body>
  <h1>Miao</h1>
  <p>Repo Sileo / Dopamine rootless.</p>
  <ol>
    <li>Sileo → Sources → +</li>
    <li>Aggiungi: <code>https://b20893513-star.github.io/miao/</code></li>
    <li>Cerca <strong>Miao</strong> → Installa / Upgrade</li>
    <li>Dopamine → Userspace Reboot</li>
  </ol>
</body>
</html>
"""
    (repo_root / "index.html").write_text(index, encoding="utf-8")
    print(f"Repo OK: {len(entries)} package(s) in {repo_root}")


if __name__ == "__main__":
    import sys

    root = Path(sys.argv[1] if len(sys.argv) > 1 else "sileo-repo")
    build_repo(root)
