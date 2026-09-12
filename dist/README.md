# Prebuilt Clipnest 0.9.2 for Ubuntu

**Temporary.** These binaries live in git only so they are easy to grab for
testing; they are meant to be removed once testing is done, and replaced by a
GitHub Release. They add ~84 MB to history permanently, so do not treat this as
the pattern for future builds.

    clipnest-0.9.2-linux-amd64.tar.gz    Intel/AMD PCs, cloud VMs  (most machines)
    clipnest-0.9.2-linux-arm64.tar.gz    Raspberry Pi, Graviton, Ubuntu on Apple Silicon

Not sure which? Run `uname -m` on the target machine: `x86_64` -> amd64,
`aarch64` -> arm64.

## Install

    tar xzf clipnest-0.9.2-linux-amd64.tar.gz
    cd clipnest-0.9.2-linux-amd64
    ./install.sh

The installer refuses to run if the package architecture does not match the
machine, so a wrong download fails clearly rather than confusingly.

Each tarball contains the three .deb packages, a SHA256SUMS file, an install
script, and a README covering first-run steps and known limitations. **Read that
README** — in particular the Ubuntu 22.04 GTK note and the auto-paste permission,
which needs a logout to take effect.
