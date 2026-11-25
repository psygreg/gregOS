# Base Image ARG — MUST come before any FROM instruction. An ARG placed after
# a FROM is scoped to that stage only and would be invisible to the FROM below
# (this failed in CI with "no FROM statement found").
##
## Selected with the BASE_IMAGE build argument. The default is the standard
## AMD/Intel image; the NVIDIA variants come from the same Bazzite project:
##   ghcr.io/ublue-os/bazzite-nvidia:stable       (proprietary driver)
##   ghcr.io/ublue-os/bazzite-nvidia-open:stable  (open kernel modules)
## build.sh reads BASE_IMAGE and applies the NVIDIA-specific configuration
## (shader cache variable, wayland compositor application profile) when the
## base is an NVIDIA image.
ARG BASE_IMAGE=ghcr.io/ublue-os/bazzite:stable

# Allow build scripts to be referenced without being copied into the final image
##
## Declared BEFORE the base stage on purpose: stages build in declaration
## order, and the base stage's build.sh step bind-mounts this ctx stage
## (type=bind,from=ctx). A stage referenced by a mount must already exist.
FROM scratch AS ctx
COPY build_files /
COPY system_files /system_files
COPY dotfiles /dotfiles

# Determinate Nix seed
##
## Determinate Nix cannot be layered as an RPM: its store lives in /nix, which
## bootc does not carry from the image into a deployment's writable state. This
## stage installs Determinate Nix into the build container's /nix, preinstalls
## the FlakeHub CLI fh into the system profile, and builds the graphics driver
## environment for Nix applications. The final image copies the finished /nix
## tree as an image-owned seed; gregos-nix-seed.service copies it onto the
## persistent /var/home/nix on first boot, and nix.mount bind-mounts that over
## /nix. See build_files/nix-seed.sh and the README's Determinate Nix section.
FROM ${BASE_IMAGE} AS nix-seed
ARG BASE_IMAGE
COPY build_files /ctx
RUN BASE_IMAGE="${BASE_IMAGE}" /ctx/nix-seed.sh

# Base Image
FROM ${BASE_IMAGE}
## Other possible base images include:
# FROM ghcr.io/ublue-os/bazzite:testing
# FROM ghcr.io/ublue-os/aurora:stable
# FROM ghcr.io/ublue-os/bluefin-nvidia-open:stable
#
# ... and so on, here are more base images
# Universal Blue Images: https://github.com/orgs/ublue-os/packages
# Fedora base image: quay.io/fedora/fedora-bootc:44
# CentOS base images: quay.io/centos-bootc/centos-bootc:stream10

### [IM]MUTABLE /opt
## Some bootable images, like Fedora, have /opt symlinked to /var/opt, in order to
## make it mutable/writable for users. However, some packages write files to this directory,
## thus its contents might be wiped out when bootc deploys an image, making it troublesome for
## some packages. Eg, google-chrome, docker-desktop.
##
## Uncomment the following line if one desires to make /opt immutable and be able to be used
## by the package manager.

# RUN rm /opt && mkdir /opt

### MODIFICATIONS
## make modifications desired in your image and install packages by modifying the build.sh script
## the following RUN directive does all the things required to run "build.sh" as recommended.

# Re-declare BASE_IMAGE so it is visible past the FROM above, and hand it to
# build.sh as an environment variable so it can apply GPU-variant tweaks.
ARG BASE_IMAGE=ghcr.io/ublue-os/bazzite:stable

# The Determinate Nix seed built above. /usr/share/gregos/nix-seed holds the
# complete /nix tree (store, profiles, database); the first-boot seed service
# copies it to /var/home/nix and nix.mount bind-mounts that over /nix.
# determinate-nixd lives outside the store and is copied into place by the same
# service. /etc/nix/nix.conf is the Determinate-managed configuration; the
# image ships /etc/nix/nix.custom.conf alongside it.
COPY --from=nix-seed /nix /usr/share/gregos/nix-seed
COPY --from=nix-seed /usr/share/gregos/nix/determinate-nixd /usr/share/gregos/nix/determinate-nixd
COPY --from=nix-seed /etc/nix/nix.conf /etc/nix/nix.conf

RUN --mount=type=bind,from=ctx,source=/,target=/ctx \
    --mount=type=cache,dst=/var/cache \
    --mount=type=cache,dst=/var/log \
    --mount=type=secret,id=GITHUB_TOKEN \
    --mount=type=tmpfs,dst=/tmp \
    BASE_IMAGE="${BASE_IMAGE}" /ctx/build.sh

### LINTING
## Verify final image and contents are correct.
RUN bootc container lint
