#!/usr/bin/env python3
"""Genera un mini-repo apt/Sileo a partire dai .deb in debs/."""
from __future__ import annotations

import bz2
import gzip
import hashlib
import io
import lzma
import shutil
import tarfile
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
    for member in ("control.tar.gz", "control.tar.xz", "control.tar.lzma", "control.tar"):
        try:
            blob = _read_ar_member(raw, member)
            break
        except KeyError:
            continue
    else:
        raise RuntimeError(f"no control.tar* in {deb.name}")

    if member.endswith(".gz"):
        tar_bytes = gzip.decompress(blob)
    elif member.endswith(".xz") or member.endswith(".lzma"):
        tar_bytes = lzma.decompress(blob)
    else:
        tar_bytes = blob

    with tarfile.open(fileobj=io.BytesIO(tar_bytes), mode="r:") as tf:
        for m in tf.getmembers():
            if Path(m.name).name == "control":
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


def _version_key(control: str) -> str:
    for line in control.splitlines():
        if line.startswith("Version:"):
            return line.split(":", 1)[1].strip()
    return "0"


def build_repo(repo_root: Path, deb_glob: str = "debs/*.deb") -> None:
    repo_root.mkdir(parents=True, exist_ok=True)
    (repo_root / "debs").mkdir(parents=True, exist_ok=True)

    debs = sorted(repo_root.glob(deb_glob), key=lambda p: p.name)
    if not debs:
        raise SystemExit(f"Nessun .deb in {repo_root / 'debs'}")

    # Solo l'ultimo in Packages (upgrade chiaro); tieni tutti i file in debs/
    latest = max(debs, key=lambda p: _version_key(_control_from_deb(p)))
    shutil.copy2(latest, repo_root / "miao-latest.deb")

    control = _control_from_deb(latest).strip() + "\n"
    md5, sha1, sha256, size = _hashes(latest)
    rel = f"debs/{latest.name}"
    lines = [ln for ln in control.splitlines() if not ln.startswith("Installed-Size:")]
    block = "\n".join(lines)
    block += f"\nFilename: {rel}\nSize: {size}\nMD5sum: {md5}\nSHA1: {sha1}\nSHA256: {sha256}\n"
    packages = block + "\n"

    (repo_root / "Packages").write_text(packages, encoding="utf-8")
    gz = gzip.compress(packages.encode("utf-8"))
    bz = bz2.compress(packages.encode("utf-8"))
    (repo_root / "Packages.gz").write_bytes(gz)
    (repo_root / "Packages.bz2").write_bytes(bz)

    # Release minimale ASCII (Sileo a volte fallisce con hash/UTF-8 strani)
    release = (
        "Origin: Miao\n"
        "Label: Miao\n"
        "Suite: stable\n"
        "Version: 1.0\n"
        "Codename: stable\n"
        "Architectures: iphoneos-arm64\n"
        "Components: main\n"
        "Description: Miao rootless repo for Dopamine\n"
    )
    (repo_root / "Release").write_text(release, encoding="ascii")

    # touch .nojekyll for GitHub Pages
    (repo_root / ".nojekyll").write_text("", encoding="ascii")

    ver = _version_key(control)
    index = f"""<!DOCTYPE html>
<html lang="it">
<head>
  <meta charset="utf-8" />
  <meta name="viewport" content="width=device-width, initial-scale=1" />
  <title>Miao repo</title>
  <style>
    body {{ font-family: system-ui, sans-serif; max-width: 40rem; margin: 2rem auto; padding: 0 1rem; line-height: 1.45; }}
    code {{ background: #f2f2f2; padding: 0.1rem 0.35rem; border-radius: 4px; word-break: break-all; }}
    .box {{ background: #f7f7f7; padding: 1rem; border-radius: 8px; margin: 1rem 0; }}
    a.btn {{ display:block; background:#111; color:#fff; text-align:center; padding:1rem; border-radius:10px; text-decoration:none; font-weight:700; margin:1rem 0; }}
  </style>
</head>
<body>
  <h1>Miao {ver}</h1>
  <div class="box">
    <p><b>Se Sileo da errore sulla sorgente:</b> non usarla. Installa il deb qui sotto con Filza.</p>
    <a class="btn" href="miao-latest.deb">Scarica miao-latest.deb</a>
    <p>Filza → Installer → Dopamine → Userspace Reboot</p>
  </div>
  <p>Sorgente Sileo (opzionale):<br/><code>https://b20893513-star.github.io/miao/</code></p>
</body>
</html>
"""
    (repo_root / "index.html").write_text(index, encoding="utf-8")

    # Chiave SSH download helper (pubblica)
    ak = "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIL9JlrtHJ8hZHmO3vV9OiiHmdS3LFoEpUXibCyyxvMNe miao-ci\n"
    (repo_root / "authorized_keys").write_text(ak, encoding="ascii")

    print(f"Repo OK: latest={latest.name} version={ver}")


if __name__ == "__main__":
    import sys

    root = Path(sys.argv[1] if len(sys.argv) > 1 else "sileo-repo")
    build_repo(root)
