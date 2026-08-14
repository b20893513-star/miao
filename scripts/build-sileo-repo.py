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

    def _rel_hashes(name: str, data: bytes) -> str:
        return (
            f" {hashlib.md5(data).hexdigest()} {len(data)} {name}\n"
            f"SHA1: {hashlib.sha1(data).hexdigest()} {len(data)} {name}\n"
            f"SHA256: {hashlib.sha256(data).hexdigest()} {len(data)} {name}\n"
        )

    # Release con checksum (meglio per Sileo/apt)
    release = (
        "Origin: Miao\n"
        "Label: Miao\n"
        "Suite: stable\n"
        "Version: 1.0\n"
        "Codename: stable\n"
        "Architectures: iphoneos-arm64\n"
        "Components: main\n"
        "Description: Miao rootless for Dopamine — aggiorna da Sileo\n"
        "MD5Sum:\n"
        f" {hashlib.md5(packages.encode()).hexdigest()} {len(packages.encode())} Packages\n"
        f" {hashlib.md5(gz).hexdigest()} {len(gz)} Packages.gz\n"
        f" {hashlib.md5(bz).hexdigest()} {len(bz)} Packages.bz2\n"
        "SHA256:\n"
        f" {hashlib.sha256(packages.encode()).hexdigest()} {len(packages.encode())} Packages\n"
        f" {hashlib.sha256(gz).hexdigest()} {len(gz)} Packages.gz\n"
        f" {hashlib.sha256(bz).hexdigest()} {len(bz)} Packages.bz2\n"
    )
    (repo_root / "Release").write_text(release, encoding="utf-8")

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
  </style>
</head>
<body>
  <h1>Miao</h1>
  <p>Ultima versione: <strong>{ver}</strong></p>

  <div class="box">
    <h2>Flusso giusto (poi non scarichi piu nulla)</h2>
    <ol>
      <li>Sileo → Sources → + → <code>https://b20893513-star.github.io/miao/</code></li>
      <li><strong>Una volta:</strong> Cerca <em>Miao</em> → Installa <strong>da Sileo</strong> (non da Filza)</li>
      <li>Dopamine → Userspace Reboot</li>
      <li><strong>Dopo:</strong> solo scheda Aggiornamenti / Upgrade in Sileo</li>
    </ol>
    <p>Se l&apos;avevi messo con Filza, Sileo non propone gli upgrade: disinstalla e reinstalla <em>dal source</em>.</p>
  </div>

  <p>URL fisso ultimo deb (solo emergenza):<br/>
  <code>https://b20893513-star.github.io/miao/miao-latest.deb</code></p>
</body>
</html>
"""
    (repo_root / "index.html").write_text(index, encoding="utf-8")
    print(f"Repo OK: latest={latest.name} version={ver}")


if __name__ == "__main__":
    import sys

    root = Path(sys.argv[1] if len(sys.argv) > 1 else "sileo-repo")
    build_repo(root)
