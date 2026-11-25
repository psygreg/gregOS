#!/bin/bash

# Build the Determinate Nix seed for gregOS.
#
# This script runs in the Containerfile's nix-seed stage, which uses the same
# base image as the final image. It installs Determinate Nix directly into the
# stage's /nix (the build container is mutable), preinstalls the FlakeHub CLI
# fh into the system profile, and builds the graphics driver environment that
# Nix applications will use at /run/opengl-driver.
#
# The finished /nix tree is copied into the final image as an image-owned
# seed. On first boot gregos-nix-seed.service copies it onto the persistent
# backing store (/var/home/nix) and nix.mount bind-mounts that over /nix.
# Keeping the installation in the build stage avoids the old Determinate
# ostree installer failure ("Device or resource busy" / read-only receipts)
# and makes first boot fully offline.

set -euxo pipefail

# Determinate Nix installer release. Pinned so a rebuild does not silently
# change the Nix version; bump it deliberately (and refresh the SELinux policy
# files in system_files/usr/share/gregos/nix/selinux from the same tag).
nix_installer_version="v3.22.2"

# Read the nixpkgs revision from the graphics expression so the seed version
# stamp can never drift from the driver set it describes.
nixpkgs_rev="$(sed -n 's/.*nixpkgsRev = "\([a-f0-9]*\)".*/\1/p' /ctx/nix/graphics.nix | head -n1)"
if [[ -z "${nixpkgs_rev}" ]]; then
    echo "could not read nixpkgsRev from /ctx/nix/graphics.nix" >&2
    exit 1
fi

arch="$(uname -m)"
if [[ "${arch}" != "x86_64" ]]; then
    echo "Determinate Nix seed build currently supports x86_64 only (got ${arch})" >&2
    exit 1
fi

# The installer expects a writable HOME. The Bazzite build container has no
# real /root (it is a dangling symlink to /var/roothome), so use /tmp.
export HOME=/tmp
export XDG_CACHE_HOME=/tmp/.cache
export XDG_CONFIG_HOME=/tmp/.config
export XDG_DATA_HOME=/tmp/.local/share
export XDG_STATE_HOME=/tmp/.local/state

# /usr/local is a symlink to ../var/usrlocal in this base image. The installer
# writes determinate-nixd there; create the target so its create_dir_all call
# does not fail on the dangling link.
mkdir -p /var/usrlocal/bin

installer=/tmp/nix-installer
curl --proto '=https' --tlsv1.2 -fsSL --retry 3 --retry-delay 5 \
    "https://install.determinate.systems/nix/tag/${nix_installer_version}/nix-installer-x86_64-linux" \
    -o "${installer}"
chmod 0755 "${installer}"

if ! "${installer}" --version | grep -q "${nix_installer_version#v}"; then
    echo "downloaded nix-installer does not report version ${nix_installer_version}" >&2
    "${installer}" --version >&2 || true
    exit 1
fi

# --init none is deliberate: no systemd is running in the build container.
# The image ships the Determinate Nix systemd units itself
# (system_files/usr/lib/systemd/system/nix-daemon.*). --no-modify-profile is
# deliberate too: the image ships /etc/profile.d/10-gregos-nix.sh.
"${installer}" install linux \
    --init none \
    --no-confirm \
    --no-modify-profile \
    --diagnostic-endpoint ""

nix_bin=/nix/var/nix/profiles/default/bin/nix
if [[ ! -x "${nix_bin}" ]]; then
    echo "Determinate Nix installation did not create ${nix_bin}" >&2
    exit 1
fi

export PATH="/nix/var/nix/profiles/default/bin:${PATH}"

# FlakeHub CLI. This is the fh command users expect on a Determinate Nix
# system; install it into the system profile so it is available to every user
# through /nix/var/nix/profiles/default/bin (and /usr/local/bin/fh, created by
# the first-boot seed). Users can still shadow it in their own profile.
nix profile add \
    --profile /nix/var/nix/profiles/default \
    "https://flakehub.com/f/DeterminateSystems/fh/0"

fh_bin="$(readlink -f /nix/var/nix/profiles/default/bin/fh)"
if [[ ! -x "${fh_bin}" ]]; then
    echo "fh was not installed into the system profile" >&2
    exit 1
fi
fh_store="$(dirname "$(dirname "${fh_bin}")")"

# Build the graphics driver environment. The NVIDIA variants need the exact
# userspace driver version used by the host base, so detect it from the
# installed RPM payload and pass its download hash into the expression.
nvidia_version=""
if [[ "${BASE_IMAGE:-}" == *nvidia* ]]; then
    nvidia_version="$(find /usr/lib64 -maxdepth 1 -name 'libnvidia-glcore.so.*' -printf '%f\n' 2>/dev/null \
        | sed -e 's/^libnvidia-glcore\.so\.//' \
        | sort -V \
        | tail -n1 || true)"

    if [[ -z "${nvidia_version}" ]]; then
        nvidia_version="$(rpm -qa --qf '%{NAME}\t%{VERSION}\n' 2>/dev/null \
            | awk -F'\t' '$1 ~ /^(nvidia-driver|nvidia-driver-libs|nvidia-kmod-common|akmod-nvidia|kmod-nvidia)$/ { print $2 }' \
            | sort -V \
            | tail -n1 || true)"
    fi

    if [[ -z "${nvidia_version}" ]]; then
        echo "NVIDIA base image detected but its driver version could not be determined" >&2
        exit 1
    fi

    nvidia_url="https://download.nvidia.com/XFree86/Linux-x86_64/${nvidia_version}/NVIDIA-Linux-x86_64-${nvidia_version}.run"
    nvidia_hash="$(nix store prefetch-file --json "${nvidia_url}" | jq -r .hash)"
    if [[ -z "${nvidia_hash}" || "${nvidia_hash}" == "null" ]]; then
        echo "could not determine the hash of ${nvidia_url}" >&2
        exit 1
    fi

    export GREGOS_NVIDIA_VERSION="${nvidia_version}"
    export GREGOS_NVIDIA_HASH="${nvidia_hash}"
    echo "Building Nix graphics drivers for NVIDIA ${nvidia_version}"
else
    echo "Building Nix graphics drivers for Mesa (AMD/Intel)"
fi

graphics_path="$(nix build --impure --no-link --print-out-paths \
    -f /ctx/nix/graphics.nix graphics)"
if [[ -z "${graphics_path}" || ! -d "${graphics_path}" ]]; then
    echo "graphics driver environment was not built" >&2
    exit 1
fi

# Keep the graphics environment and fh alive across nix store gc. The gcroot
# symlinks are part of the seed and are re-created by the first-boot sync.
mkdir -p /nix/gregos /nix/var/nix/gcroots /nix/var/determinate

printf '%s\n' "${graphics_path}" > /nix/gregos/graphics-drivers-path
printf '%s\n' "${fh_bin}" > /nix/gregos/fh-path
ln -sfn "${graphics_path}" /nix/var/nix/gcroots/gregos-nix-graphics
ln -sfn "${fh_store}" /nix/var/nix/gcroots/gregos-nix-fh

# Drop build-only store paths (Rust toolchain for fh, Mesa build inputs,
# downloaded NVIDIA .run, ...). The default profile and the two gregos
# gcroots above keep everything the runtime needs.
nix store gc

# The receipt and installer copy are build-stage artefacts. They describe an
# install that cannot be uninstalled from the final image and would only
# confuse users (and add ~72 MB to the seed).
rm -f /nix/nix-installer /nix/receipt.json

# A version stamp lets gregos-nix-seed.service distinguish a first-boot seed
# from a later image update. On an update it copies missing store paths and
# refreshes the graphics metadata without touching the user's Nix database.
# The graphics expression hash makes an expression change (not just a nixpkgs
# bump) trigger that refresh as well.
graphics_rev="$(sha256sum /ctx/nix/graphics.nix | cut -d' ' -f1)"
seed_version="determinate-nix-${nix_installer_version#v}-nixpkgs-${nixpkgs_rev}-graphics-${graphics_rev:0:12}"
if [[ -n "${nvidia_version}" ]]; then
    seed_version+="-nvidia-${nvidia_version}"
fi
printf '%s\n' "${seed_version}" > /nix/gregos/seed-version

# The daemon binary lives outside the Nix store (upstream installs it at
# /usr/local/bin). Keep the image-owned copy for the first-boot seed; upgrades
# through determinate-nixd replace /usr/local/bin/determinate-nixd and are not
# overwritten by later boots.
install -D -m 0555 /var/usrlocal/bin/determinate-nixd \
    /usr/share/gregos/nix/determinate-nixd

echo "Determinate Nix seed built:"
/usr/share/gregos/nix/determinate-nixd version 2>/dev/null || true
nix --version
fh --version
du -sh /nix
