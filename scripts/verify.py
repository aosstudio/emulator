import hashlib
import json
import os
from pathlib import Path
import shutil
import signal
import subprocess
import sys
import tarfile
from tempfile import TemporaryDirectory, mkdtemp
from typing import TypedDict
from xml.etree import ElementTree as ET
from zipfile import ZipFile

from inputs import ROOT, Input, download, fetch
from package import ASSET, VERSION

OUT = ROOT / "out"
CACHE = OUT / "verify-inputs"


class Verification(TypedDict):
    sdk_source: Input
    sdk: str
    jdk: str
    guest_kernel: str


def nightly(repo: str, name: str) -> Path:
    path = CACHE / name
    if not path.is_file():
        with TemporaryDirectory(dir=CACHE) as work:
            candidate = Path(work) / name
            download(
                f"https://github.com/aosstudio/{repo}/releases/download/latest/{name}",
                candidate,
            )
            candidate.replace(path)
    return path


def add_emulator(feed: Path, archive: Path) -> None:
    (feed / archive.name).hardlink_to(archive)
    with archive.open("rb") as stream:
        digest = hashlib.file_digest(stream, "sha1").hexdigest()
    xsi = "http://www.w3.org/2001/XMLSchema-instance"
    ET.register_namespace("xsi", xsi)
    for index in sorted(feed.glob("repository2-*.xml")):
        tree = ET.parse(index)
        root = tree.getroot()
        ET.register_namespace("s", root.tag.partition("}")[0][1:])
        root.set("xmlns:g", "http://schemas.android.com/repository/android/generic/02")
        previous = root.find("./remotePackage[@path='emulator']")
        if previous is not None:
            root.remove(previous)
        package = ET.SubElement(root, "remotePackage", path="emulator")
        ET.SubElement(
            package, "type-details", {f"{{{xsi}}}type": "g:genericDetailsType"}
        )
        version = ET.SubElement(package, "revision")
        for key, value in zip(
            ("major", "minor", "micro"), VERSION.split("."), strict=True
        ):
            ET.SubElement(version, key).text = value
        ET.SubElement(package, "display-name").text = "AOSStudio Emulator"
        choice = ET.SubElement(ET.SubElement(package, "archives"), "archive")
        complete = ET.SubElement(choice, "complete")
        ET.SubElement(complete, "size").text = str(archive.stat().st_size)
        ET.SubElement(complete, "checksum", type="sha1").text = digest
        ET.SubElement(complete, "url").text = archive.name
        ET.SubElement(choice, "host-os").text = "linux"
        ET.SubElement(choice, "host-arch").text = "x64"
        tree.write(index, encoding="utf-8", xml_declaration=True)


def install(work: Path, archive: Path, inputs: Verification) -> Path:
    source_archive = CACHE / "sdk-source.tar.gz"
    fetch(source_archive, inputs["sdk_source"])
    with tarfile.open(source_archive) as bundle:
        bundle.extractall(work, filter="data")
    (source,) = work.glob("sdk-*")
    for repo, filename in (("sdk", inputs["sdk"]), ("jdk", inputs["jdk"])):
        with tarfile.open(nightly(repo, filename)) as bundle:
            bundle.extractall(work / repo, filter="data")
    feed = work / "sdk/feed"
    add_emulator(feed, archive)
    release = json.loads((source / "locks/release.json").read_text())
    manager_asset = release["components"]["cmdline-tools"]["name"]
    with ZipFile(feed / manager_asset) as bundle:
        bundle.extractall(work / "bootstrap")
    manager = work / "bootstrap/cmdline-tools"
    (manager / "bin/sdkmanager").chmod(0o755)
    destination = work / "installed"
    subprocess.run(
        [
            sys.executable,
            source / "scripts/install_sdk.py",
            "--feed",
            feed,
            "--destination",
            destination,
            "--jdk",
            work / "jdk",
            "--manager",
            manager,
            "--",
            "emulator",
        ],
        check=True,
    )
    emulator = destination / "emulator"
    package = ET.parse(emulator / "package.xml").getroot().find("localPackage")
    if package is None or package.attrib["path"] != "emulator":
        raise ValueError("SDK Manager did not register the emulator")
    print("SDK Manager installed the emulator.", flush=True)
    return emulator


def make_ramdisk(work: Path) -> Path:
    busybox = shutil.which("busybox")
    if busybox is None:
        raise ValueError("Install busybox-static to test the emulator boot")
    content = work / "initramfs"
    for directory in ("bin", "binder", "proc"):
        (content / directory).mkdir(parents=True)
    shutil.copyfile(busybox, content / "bin/busybox").chmod(0o755)
    shutil.copyfile(ROOT / "tests/init", content / "init").chmod(0o755)
    initramfs = work / "boot.cpio"
    with initramfs.open("wb") as output:
        subprocess.run(
            ["cpio", "--quiet", "--create", "--format=newc", "--null"],
            input=b"bin\0bin/busybox\0binder\0proc\0init\0",
            cwd=content,
            stdout=output,
            check=True,
        )
    subprocess.run(["gzip", "-n", initramfs], check=True)
    return initramfs.with_suffix(".cpio.gz")


def boot(work: Path, emulator: Path, kernel_archive: Path) -> None:
    with tarfile.open(kernel_archive) as bundle:
        images = [
            m
            for m in bundle
            if m.isfile() and m.name == "prebuilts/qemu-kernel/x86_64/6.12/kernel-6.12"
        ]
        if len(images) != 1:
            raise ValueError("Expected one Linux x86-64 guest kernel")
        bundle.extractall(work / "guest", members=images, filter="data")
    kernel = work / "guest" / images[0].name
    ramdisk = make_ramdisk(work)
    disks = work / "images"
    for directory in (disks, work / "avd", work / "home", work / "tmp"):
        directory.mkdir()
    (work / "runtime").mkdir(mode=0o700)
    (disks / "source.properties").write_text(
        "AndroidVersion.ApiLevel=37\nSystemImage.Abi=x86_64\nSystemImage.TagId=default\n"
    )
    for name in ("system", "vendor", "userdata"):
        image = disks / f"{name}.img"
        with image.open("wb") as stream:
            stream.truncate(32 * 1024 * 1024)
        subprocess.run(["mke2fs", "-q", "-F", "-t", "ext4", image], check=True)
    shutil.copyfile(disks / "userdata.img", disks / "userdata-probe.img")

    log = work / "boot.log"
    mounts: tuple[tuple[str | Path, str | Path], ...] = (
        ("/usr", "/usr"),
        (emulator.parent, "/mnt/sdk"),
        (kernel, "/mnt/kernel"),
        (ramdisk, "/mnt/ramdisk.gz"),
    )
    settings = {
        "HOME": "/mnt/run/home",
        "PATH": "/usr/bin:/bin",
        "LC_ALL": "C.UTF-8",
        "ANDROID_AVD_HOME": "/mnt/run/avd",
        "ANDROID_PRODUCT_OUT": "/mnt/run/images",
        "ANDROID_BUILD_TOP": "/mnt/run",
        "ANDROID_HOME": "/mnt/sdk",
        "ANDROID_I_WANT_MY_TCG": "yes",
        "XDG_RUNTIME_DIR": "/mnt/run/runtime",
    }
    command: list[str | Path] = [
        "bwrap",
        "--unshare-all",
        "--die-with-parent",
        "--new-session",
        "--clearenv",
    ]
    for source, target in mounts:
        command.extend(["--ro-bind", source, target])
    for name in ("bin", "sbin", "lib", "lib64"):
        command.extend(["--symlink", f"usr/{name}", f"/{name}"])
    command += [
        "--proc",
        "/proc",
        "--dev",
        "/dev",
        "--ro-bind-try",
        "/etc/ld.so.cache",
        "/etc/ld.so.cache",
        "--bind",
        work,
        "/mnt/run",
        "--bind",
        work / "tmp",
        "/tmp",
        "--chdir",
        "/mnt/run",
    ]
    for key, value in settings.items():
        command.extend(["--setenv", key, value])
    command += [
        "--",
        "/mnt/sdk/emulator/emulator",
        "-no-window",
        "-no-audio",
        "-no-snapshot",
        "-no-boot-anim",
        "-accel",
        "off",
        "-gpu",
        "swiftshader",
        "-show-kernel",
        "-no-metrics",
        "-memory",
        "1024",
        "-sysdir",
        "/mnt/run/images",
        "-datadir",
        "/mnt/run/images",
        "-data",
        "/mnt/run/images/userdata-probe.img",
        "-kernel",
        "/mnt/kernel",
        "-ramdisk",
        "/mnt/ramdisk.gz",
        "-qemu",
        "-no-reboot",
        "-bios",
        "/mnt/sdk/emulator/lib/pc-bios/bios-256k.bin",
    ]
    with log.open("wb") as output:
        result = subprocess.run(
            command,
            stdout=output,
            stderr=subprocess.STDOUT,
            timeout=180,
        )
    # The headless window system can signal itself with SIGUSR1 on guest shutdown.
    console = log.read_text(errors="replace")
    if (
        result.returncode not in (0, 128 + signal.SIGUSR1)
        or "AOSSTUDIO_EMULATOR_BOOT_OK 6.12.96-aosstudio" not in console
        or "reboot: Power down" not in console
    ):
        print(console[-16000:], file=sys.stderr)
        raise ValueError(
            f"Expected BinderFS boot confirmation in {log} "
            f"(emulator exit status {result.returncode})"
        )
    print(f"Guest kernel booted with TCG. See {log}", flush=True)


def main() -> None:
    archive = OUT / "dist" / ASSET
    if not archive.is_file():
        raise FileNotFoundError(f"Build the emulator before verification: {archive}")
    inputs: Verification = json.loads((ROOT / "locks/verification.json").read_text())
    work = Path(mkdtemp(prefix="verify.", dir=OUT))
    print(f"Verification directory: {work}", flush=True)
    emulator = install(work, archive, inputs)
    environment = os.environ | {"HOME": str(work), "ANDROID_HOME": str(emulator.parent)}
    version = subprocess.check_output(
        [emulator / "emulator", "-version"],
        env=environment,
        text=True,
        stderr=subprocess.STDOUT,
    )
    if VERSION not in version:
        raise ValueError(f"Unexpected launcher version: {version}")
    print(version.splitlines()[0], flush=True)
    qemu_img = emulator / "qemu-img"
    image = work / "probe.qcow2"
    subprocess.run([qemu_img, "create", "-f", "qcow2", image, "8M"], check=True)
    subprocess.run([qemu_img, "check", image], check=True)
    boot(work, emulator, nightly("guest-kernel", inputs["guest_kernel"]))


if __name__ == "__main__":
    main()
