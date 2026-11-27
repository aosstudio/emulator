import argparse
from pathlib import Path
import shutil
import stat
from tempfile import TemporaryDirectory
from zipfile import ZIP_DEFLATED, ZipFile, ZipInfo

from inputs import ROOT

VERSION = "37.3.10"
ASSET = f"aosstudio-emulator-{VERSION}-linux-x86_64.zip"


def package(source: Path) -> Path:
    source = source.resolve(strict=True)
    properties = (source / "source.properties").read_text().splitlines()
    if f"Pkg.Revision={VERSION}" not in properties:
        raise ValueError(f"Expected emulator version {VERSION}")
    dist = ROOT / "out/dist"
    dist.mkdir(exist_ok=True)
    with TemporaryDirectory(dir=dist, prefix=".emulator-") as directory:
        output = Path(directory) / ASSET
        with ZipFile(output, "x") as archive:
            for path in sorted(source.rglob("*")):
                target = path.resolve(strict=True)
                if not target.is_relative_to(source):
                    raise ValueError(
                        f"Package member resolves outside the package: {path}"
                    )
                if path.is_dir():
                    continue
                mode = target.stat().st_mode
                if not stat.S_ISREG(mode):
                    raise ValueError(f"Expected a regular file: {path}")
                entry = ZipInfo(
                    (Path("emulator") / path.relative_to(source)).as_posix(),
                    date_time=(2025, 1, 1, 0, 0, 0),
                )
                entry.compress_type = ZIP_DEFLATED
                entry.compress_level = 4
                entry.external_attr = mode << 16
                entry.file_size = target.stat().st_size
                with target.open("rb") as payload, archive.open(entry, "w") as member:
                    shutil.copyfileobj(payload, member, 1024 * 1024)
        return output.replace(dist / ASSET)


def main() -> None:
    parser = argparse.ArgumentParser(description="Package the source-built emulator.")
    parser.add_argument("source", type=Path)
    args = parser.parse_args()
    print(package(args.source))


if __name__ == "__main__":
    main()
