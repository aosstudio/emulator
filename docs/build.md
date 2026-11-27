# Build the Linux x86_64 emulator

The build uses a disk-backed workspace and writes downloaded inputs, intermediates and the SDK Manager archive under `out/`. Use Ubuntu 26.04 and Python 3.14. The package contains GUI and headless emulator executables. The verification needs a published AOSStudio SDK, JDK and guest kernel.

Each component can run in a separate checkout. Install only the host dependencies required for its target, then run the matching Make target.

```bash
sudo bash ci/host-deps.sh qt
make qt JOBS="$(nproc)"
```

Repeat for `netsim`, `graphics` and `firmware`. Bring the four `out/components/*.tar.zst` archives into one checkout for assembly.

```bash
sudo bash ci/host-deps.sh package
make package JOBS="$(nproc)"
```

The emulator ZIP is under `out/dist/`. Install it through an isolated SDK Manager repository and boot the guest kernel with the packaged headless executable.

```bash
sudo bash ci/host-deps.sh verify
make verify
```
