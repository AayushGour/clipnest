# Prebuilt Clipnest 0.9.3 for Ubuntu

**Temporary, and now superseded.** These binaries were hand-built and
checked into git only so they were easy to grab for testing before
`.github/workflows/release-linux.yml` could produce them itself. That gap is
closed: the workflow's `build-tarball` job now builds both
`clipnest-$VERSION-linux-amd64.tar.gz` and `...-arm64.tar.gz` on every
release (via `packaging/linux/dist/build-tarball.sh`, the same recipe that
built the files in this directory) and attaches them to the GitHub Release
alongside the per-series `.deb`s. **Get them from the
[GitHub Release](https://github.com/AayushGour/clipnest/releases/latest)
going forward, not from this directory.** The pair checked in here should
be deleted from git once 0.9.3 has a real tagged Release carrying the
CI-built equivalents -- history already carries the cost either way: each
pair adds ~85-90 MB permanently, replacing one pair does not reclaim the
last one, and 0.9.1's and 0.9.2's pairs are both still in history too,
putting this at roughly 255-260 MB total across the three pairs. Do not
add a fourth pair here; that cost does not go away by adding more, only
by removing this directory once CI's copies exist.

    clipnest-0.9.3-linux-amd64.tar.gz    Intel/AMD PCs, cloud VMs  (most machines)
    clipnest-0.9.3-linux-arm64.tar.gz    Raspberry Pi, Graviton, Ubuntu on Apple Silicon

Not sure which? Run `uname -m` on the target machine: `x86_64` -> amd64,
`aarch64` -> arm64.

## Install

    tar xzf clipnest-0.9.3-linux-amd64.tar.gz
    cd clipnest-0.9.3-linux-amd64
    ./install.sh

The installer refuses to run if the package architecture does not match the
machine, so a wrong download fails clearly rather than confusingly.

Each tarball contains the three .deb packages, a SHA256SUMS file, an install
script, and a README covering first-run steps and known limitations. **Read that
README** — in particular the Ubuntu 22.04 GTK note and the auto-paste permission,
which needs a logout to take effect.
