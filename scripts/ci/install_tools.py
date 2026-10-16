#!/usr/bin/env python3
"""Install only checksum-pinned CI binaries into a caller-owned tools directory."""
import argparse
import hashlib
import io
import json
from pathlib import Path
import platform
import tarfile
from urllib.request import Request, urlopen


def install(name, config, destination):
    system = platform.system().lower()
    architecture = {"aarch64": "arm64", "arm64": "arm64", "x86_64": "amd64"}[platform.machine()]
    key = system + "_" + architecture
    expected = config["sha256"][key]
    asset_key = config.get("asset_names", {}).get(key, key)
    filename = f'{name}_{config["version"]}_{asset_key}.tar.gz'
    url = f'https://github.com/{config["repository"]}/releases/download/v{config["version"]}/{filename}'
    with urlopen(Request(url, headers={"User-Agent": "WeGit-CI"}), timeout=90) as response:
        data = response.read()
    if hashlib.sha256(data).hexdigest() != expected:
        raise ValueError("Checksum mismatch for " + name)
    with tarfile.open(fileobj=io.BytesIO(data), mode="r:gz") as archive:
        member = archive.getmember(name)
        if not member.isfile():
            raise ValueError("Expected a regular binary: " + name)
        output = destination / name
        output.write_bytes(archive.extractfile(member).read())
        output.chmod(0o755)
    print(f"Installed {name} {config['version']} ({key}) with verified SHA-256")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--destination", required=True, type=Path)
    parser.add_argument("tools", nargs="+", choices=["actionlint", "gitleaks"])
    args = parser.parse_args()
    args.destination.mkdir(parents=True, exist_ok=True)
    config = json.loads(Path(".github/ci-tools.json").read_text())
    for name in args.tools:
        install(name, config[name], args.destination)


if __name__ == "__main__":
    main()
