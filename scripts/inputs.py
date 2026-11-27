import argparse
from base64 import b64decode
from concurrent.futures import ThreadPoolExecutor
import hashlib
import json
from pathlib import Path
import shutil
import subprocess
import tarfile
from tempfile import TemporaryDirectory
from typing import TypedDict

ROOT = Path(__file__).resolve().parents[1]
CACHE = ROOT / "out/inputs"


class Input(TypedDict, total=False):
    url: str
    sha256: str
    tree_sha256: str
    encoding: str
    archive: str
    tree_root: str
    directory: str
    file: str
    overlay: bool
    members: list[str]
    license: str


def sha256(path: Path) -> str:
    with path.open("rb") as source:
        return hashlib.file_digest(source, "sha256").hexdigest()


def tree_sha256(path: Path) -> str:
    # Gitiles repacks archives with variable tar and gzip metadata.
    members: dict[str, tuple[str, int, str]] = {}
    with tarfile.open(path) as archive:
        for member in archive:
            if member.isdir():
                continue
            name = member.name.removeprefix("./")
            if name in members:
                raise ValueError(f"Repeated path in {path.name}: {name}")
            if member.isfile():
                source = archive.extractfile(member)
                if source is None:
                    raise ValueError(f"Unreadable member: {name}")
                with source:
                    content = hashlib.sha256(source.read()).hexdigest()
            elif member.issym():
                content = member.linkname
            else:
                raise ValueError(f"Unexpected source archive member: {name}")
            members[name] = (member.type.decode("ascii"), member.mode & 0o777, content)
    return hashlib.sha256(
        json.dumps(members, sort_keys=True).encode("utf-8")
    ).hexdigest()


def download(url: str, path: Path) -> None:
    subprocess.run(
        [
            "curl",
            "--fail",
            "--silent",
            "--show-error",
            "--location",
            "--retry",
            "3",
            "--connect-timeout",
            "30",
            "--proto",
            "=https",
            "--proto-redir",
            "=https",
            "--output",
            str(path),
            url,
        ],
        check=True,
    )


def fetch(destination: Path, entry: Input) -> None:
    if "tree_sha256" in entry:
        digest, expected = tree_sha256, entry["tree_sha256"]
    else:
        digest, expected = sha256, entry["sha256"]
    if destination.is_file() and digest(destination) == expected:
        return
    destination.parent.mkdir(parents=True, exist_ok=True)
    with TemporaryDirectory(prefix=".fetch-", dir=destination.parent) as work:
        candidate = Path(work) / "download"
        download(entry["url"], candidate)
        if entry.get("encoding") == "base64":
            candidate.write_bytes(b64decode(candidate.read_bytes()))
        if digest(candidate) != expected:
            raise ValueError(f"SHA-256 mismatch for {entry['url']}")
        candidate.replace(destination)
        print(f"Fetched {destination.name}", flush=True)


def fetch_all(downloads: list[tuple[Path, Input]]) -> None:
    with ThreadPoolExecutor(max_workers=8) as executor:
        for job in [executor.submit(fetch, dest, spec) for dest, spec in downloads]:
            job.result()


def stage(component: str, destination: Path) -> None:
    inputs: dict[str, Input]
    if component in {"graphics", "firmware"}:
        inputs = json.loads(
            (ROOT / f"locks/{component}.json").read_text(encoding="utf-8")
        )
    else:
        records: dict[str, dict[str, Input]] = json.loads(
            (ROOT / "locks/sources.json").read_text(encoding="utf-8")
        )
        inputs = records[component]
    fetch_all([(CACHE / entry["archive"], entry) for entry in inputs.values()])
    destination.mkdir(parents=True, exist_ok=True)
    for entry in inputs.values():
        if "file" in entry:
            target = destination / entry["file"]
            target.parent.mkdir(parents=True, exist_ok=True)
            shutil.copyfile(CACHE / entry["archive"], target)
            continue
        target = destination / entry["directory"]
        if target.exists() and not entry.get("overlay", False):
            raise FileExistsError(target)
        with tarfile.open(CACHE / entry["archive"]) as archive:
            members = entry.get("members")
            selected = (
                (
                    member
                    for member in archive
                    if any(
                        member.name == name or member.name.startswith(f"{name}/")
                        for name in members
                    )
                )
                if members is not None
                else None
            )
            if "tree_root" in entry:
                with TemporaryDirectory(dir=destination) as temporary:
                    work = Path(temporary)
                    archive.extractall(work, members=selected, filter="data")
                    target.parent.mkdir(parents=True, exist_ok=True)
                    extracted = work / entry["tree_root"]
                    if target.exists():
                        shutil.copytree(
                            extracted, target, dirs_exist_ok=True, symlinks=True
                        )
                    else:
                        extracted.rename(target)
            else:

                def in_project(
                    member: tarfile.TarInfo, path: str
                ) -> tarfile.TarInfo | None:
                    name = Path(member.name)
                    if name.is_absolute() or ".." in name.parts:
                        raise ValueError(f"Unexpected member path: {member.name}")
                    prefix = Path(entry["directory"])
                    link = (
                        str(prefix / member.linkname)
                        if member.islnk()
                        else member.linkname
                    )
                    relocated = member.replace(name=str(prefix / name), linkname=link)
                    return tarfile.data_filter(relocated, path)

                archive.extractall(destination, members=selected, filter=in_project)


def main() -> None:
    parser = argparse.ArgumentParser(
        description="Fetch and extract locked build inputs."
    )
    parser.add_argument("component")
    parser.add_argument("destination", type=Path)
    args = parser.parse_args()
    stage(args.component, args.destination)


if __name__ == "__main__":
    main()
