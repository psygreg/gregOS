# image-template

This repository is meant to be a template for building your own custom [bootc](https://github.com/bootc-dev/bootc) image. This template is the recommended way to make customizations to any image published by the Universal Blue Project.

# Community

If you have questions about this template after following the instructions, try the following spaces:
- [Universal Blue Forums](https://universal-blue.discourse.group/)
- [Universal Blue Discord](https://discord.gg/WEu6BdFEtp)
- [bootc discussion forums](https://github.com/bootc-dev/bootc/discussions) - This is not an Universal Blue managed space, but is an excellent resource if you run into issues with building bootc images.

# What this image ships

This image is based on `ghcr.io/ublue-os/bazzite:stable` (Fedora 44) and replaces the traditional desktop
environment with a tiling-compositor setup:

- **[niri](https://github.com/YaLTeu/niri)** - scrollable-tiling Wayland compositor (Fedora package).
- **[Noctalia](https://github.com/noctalia-dev/noctalia)** - the desktop shell layered on top of niri: bar,
  launcher, control center, notifications, lock screen, wallpaper, OSDs, clipboard, tray, and its own polkit
  agent (Fedora package, F44+).
- **[Noctalia Greeter](https://github.com/noctalia-dev/noctalia-greeter)** + **greetd** - the login screen.
  Sourced from the [Terra](https://terrapkg.com) repository; the repo is used at build time and left disabled
  afterwards, matching how Bazzite itself consumes Terra. The greeter runs as the `greeter` system account
  (declared via `system_files/usr/lib/sysusers.d/gregos-niri.conf`); its setup service provides device access,
  a separate writable home, and persistent state before greetd starts.
- **GTK theming** - `adw-gtk3-theme` (Fedora repos) applied with `nwg-look` (Terra), the GTK look-and-feel
  editor for Wayland; Qt apps are themed with `qt6ct`.
- KDE Plasma and GNOME desktop environments are **removed** at build time, along with most of their
  desktop-specific applications (see `REMOVE_PATTERNS` in [build_files/build.sh](./build_files/build.sh)).
  Everything else Bazzite ships is untouched: Steam, gamescope, drivers, ujust, Bazzite Portal, Waydroid,
  Cockpit, the audio stack, and so on. **Bazaar** is removed as well — software and system management is
  centered on LinuxToys instead.
- **Selected cross-desktop apps** — Nautilus (`nautilus`), GNOME Keyring (`gnome-keyring` with its
  `gnome-keyring-pam` greetd integration), GNOME Disks (`gnome-disk-utility`), Showtime (`showtime`), and
  KDE Connect (`kde-connect`).
- **Heroic Games Launcher instead of Lutris** — Lutris is removed; [Heroic](https://heroicgameslauncher.com)
  is installed at build time from the `.rpm` asset of its latest GitHub release — so every (daily) image
  build automatically picks up the newest version.
- **[LinuxToys](https://github.com/psygreg/linuxtoys)** is layered on top, installed at build time from the
  `.rpm` asset of its latest GitHub release — so every (daily) image build automatically picks up the newest
  version. It replaces Bazaar as the image's software and system manager.
- **zswap instead of zram** — the `zram-generator` packages are removed. Swapped pages are compressed by the
  kernel with `zstd` into a `zsmalloc` pool capped at 25% of RAM (with the shrinker enabled), backed by
  whatever swap device you provide yourself. See [Swap: zswap instead of zram](#swap-zswap-instead-of-zram).
- **[bun](https://bun.sh) + [OpenCode](https://opencode.ai)** are intentionally **not** baked into the image:
  on an atomic system, anything in `/usr` can only be updated with a new image deployment, so the
  self-contained agent tooling works better installed at user level, where it can be updated at any time.
  See [Installing OpenCode](#installing-opencode-optional-user-level).

Configuration lives in `dotfiles/`. The Niri files are installed under `/etc/niri/`; the package's
`/usr/share/niri/defaults/config.kdl` becomes a small wrapper that includes the system config. The
wrapper is copied into `/etc/skel` for new accounts and seeded into existing homes by the boot service.
Noctalia's TOML defaults are seeded only when a user has no existing copy.

`/etc/skel/.config/` covers new accounts. `gregos-niri-config-seed.service` handles existing homes on rebase:
it adds missing defaults and migrates the old Niri config only when both it and its Noctalia include still
match the shipped files, leaving user edits untouched.

## Using the desktop

- The `dotfiles/niri/config.kdl` contains the recommended niri settings from the
  [Noctalia niri guide](https://docs.noctalia.dev/noctalia/compositor-settings/niri/): rounded corners,
  Noctalia IPC keybinds (`Mod+Space` launcher, `Mod+P` control center, `Mod+Comma` settings, `Alt+Tab`
  window switcher), volume/brightness keys, screenshot binds, and the `noctalia-backdrop` layer rule.
- Noctalia starts automatically with the session (`spawn-at-startup "noctalia"`).
- Portals: `xdg-desktop-portal-gtk` + `xdg-desktop-portal-gnome` (niri's screencast path), per niri/Noctalia
  recommendations. Xwayland apps run through `xwayland-satellite`, which is a dependency of the Fedora niri
  package.
- Qt apps use `qt6ct`, and GTK apps can be themed with `nwg-look` + `adw-gtk3-theme` (run `nwg-look` once to
  apply). The cursor theme is Adwaita (`adwaita-cursor-theme`), since the DMZ cursor themes referenced in
  earlier iterations are no longer packaged in Fedora.
- The greeter remembers the last session and user picked; niri is the default session. Noctalia's settings
  app (`Mod+Comma`) manages the shell, and its polkit agent is pre-enabled via
  `~/.config/noctalia/10-gregos-defaults.toml`.


# Installing OpenCode (optional, user-level)

OpenCode (and its bun runtime) are not part of the image by design: on this atomic system only image updates
change `/usr`, so keeping agent tooling user-installed lets it update at any time, independent of image
deployments:

1. Install bun the usual way (lands in `~/.bun/bin`; the official installer also adds it to PATH):
   ```bash
   curl -fsSL https://bun.sh/install | bash
   ```
2. Install OpenCode from its official npm package:
   ```bash
   bun install -g --trust @opencode/cli
   ```
3. Optionally, install the [agent-reflex](https://github.com/psygreg/agent-reflex) skill and let OpenCode
   itself install the plugin on first use:
   ```bash
   bunx skills add psygreg/agent-reflex --skill agent-reflex -a opencode -g
   ```
   Start `opencode`, invoke the agent-reflex skill (e.g. "install agent-reflex") and answer the classifier
   prompts in chat — the plugin then guards shell commands, compacts history, and tunes effort for your
   System One decision model.


# Swap: zswap instead of zram

Bazzite's swap-on-zram (`zram-generator`) is removed. Swapped pages are compressed by the kernel's
[zswap](https://docs.kernel.org/admin-guide/mm/zswap.html) with `zstd` into a `zsmalloc` pool of up to 25% of
RAM (shrinker enabled), spilling over to whatever swap device is present.

The configuration ships in two independent places so it applies on every path:

- `/usr/lib/bootc/kargs.d/20-gregos-zswap.toml` — kernel command line arguments, applied by bootc when it
  creates this image's deployment.
- `gregos-zswap-setup.service` — mirrors any parameter not already set on the kernel command line to
  `/sys/kernel/zswap` early at boot. If you set your own `zswap.*=` arguments, those win and the service
  skips them.

No swap device ships with the image: create your own swap file or partition (see
[the Bazzite swapfile guide](https://docs.bazzite.gg/Advanced/swapfile/)); zswap compresses in front of it
either way. The live state is visible (and tunable) under `/sys/kernel/zswap/`, e.g.
`cat /sys/kernel/zswap/current_pool_size`.


# How to Use

To get started on your first bootc image, simply read and follow the steps in the next few headings.
If you prefer instructions in video form, TesterTech created an excellent tutorial, embedded below.

[![Video Tutorial](https://img.youtube.com/vi/IxBl11Zmq5w/0.jpg)](https://www.youtube.com/watch?v=IxBl11Zmq5wE)

## Step 0: Prerequisites

These steps assume you have the following:
- A Github Account
- A machine running a bootc image (e.g. Bazzite, Bluefin, Aurora, or Fedora Atomic)
- Experience installing and using CLI programs

## Step 1: Preparing the Template

### Step 1a: Copying the Template

Select `Use this Template` on this page. You can set the name and description of your repository to whatever you would like, but all other settings should be left untouched.

Once you have finished copying the template, you need to enable the Github Actions workflows for your new repository.
To enable the workflows, go to the `Actions` tab of the new repository and click the button to enable workflows.

### Step 1b: Cloning the New Repository

Here I will defer to the much superior GitHub documentation on the matter. You can use whichever method is easiest.
[GitHub Documentation](https://docs.github.com/en/repositories/creating-and-managing-repositories/cloning-a-repository)

Once you have the repository on your local drive, proceed to the next step.

## Step 2: Initial Setup

### Step 2a: Creating a Cosign Key

Container signing is important for end-user security and is enabled on all Universal Blue images. By default the image builds *will fail* if you don't.

First, install the [cosign CLI tool](https://edu.chainguard.dev/open-source/sigstore/cosign/how-to-install-cosign/#installing-cosign-with-the-cosign-binary)
With the cosign tool installed, run inside your repo folder:

```bash
COSIGN_PASSWORD="" cosign generate-key-pair
```

The signing key will be used in GitHub Actions and will not work if it is password protected.

> [!WARNING]
> Be careful to *never* accidentally commit `cosign.key` into your git repo. If this key goes out to the public, the security of your repository is compromised.

Next, you need to add the key to GitHub. This makes use of GitHub's secret signing system.

<details>
    <summary>Using the Github Web Interface (preferred)</summary>

Go to your repository settings, under `Secrets and Variables` -> `Actions`
![image](https://user-images.githubusercontent.com/1264109/216735595-0ecf1b66-b9ee-439e-87d7-c8cc43c2110a.png)
Add a new secret and name it `SIGNING_SECRET`, then paste the contents of `cosign.key` into the secret and save it. Make sure it's the .key file and not the .pub file. Once done, it should look like this:
![image](https://user-images.githubusercontent.com/1264109/216735690-2d19271f-cee2-45ac-a039-23e6a4c16b34.png)
</details>
<details>
<summary>Using the Github CLI</summary>

If you have the `github-cli` installed, run:

```bash
gh secret set SIGNING_SECRET < cosign.key
```
</details>

### Step 2b: Choosing Your Base Image

To choose a base image, simply modify the line in the container file starting with `FROM`. This will be the image your image derives from, and is your starting point for modifications.
For a base image, you can choose any of the Universal Blue images or start from a Fedora Atomic system. Below this paragraph is a dropdown with a non-exhaustive list of potential base images.

<details>
    <summary>Base Images</summary>

- Bazzite: `ghcr.io/ublue-os/bazzite:stable`
- Aurora: `ghcr.io/ublue-os/aurora:stable`
- Bluefin: `ghcr.io/ublue-os/bluefin:stable`
- Universal Blue Base: `ghcr.io/ublue-os/base-main:latest`
- Fedora: `quay.io/fedora/fedora-bootc:44`

You can find more Universal Blue images on the [packages page](https://github.com/orgs/ublue-os/packages).
</details>

If you don't know which image to pick, choosing the one your system is currently on is the best bet for a smooth transition. To find out what image your system currently uses, run the following command:
```bash
sudo bootc status
```
This will show you all the info you need to know about your current image. The image you are currently on is displayed after `Booted image:`. Paste that information after the `FROM` statement in the Containerfile to set it as your base image.

### Step 2c: Changing Names

Change the `IMAGE_NAME` and `REPO_ORGANIZATION` variable inside the `image-template.env`

To commit and push all the files changed and added in step 2 into your Github repository:
```bash
git add Containerfile image-template.env cosign.pub
git commit -m "Initial Setup"
git push
```
Once pushed, go look at the Actions tab on your Github repository's page.  The green checkmark should be showing on the top commit, which means your new image is ready!

## Step 3: Switch to Your Image

From your bootc system, run the following command substituting in your Github username and image name where noted.
```bash
sudo bootc switch ghcr.io/<username>/<image_name>
```
This should queue your image for the next reboot, which you can do immediately after the command finishes. You have officially set up your custom image! See the following section for an explanation of the important parts of the template for customization.

# Repository Contents

## Containerfile

The [Containerfile](./Containerfile) defines the operations used to customize the selected image.This file is the entrypoint for your image build, and works exactly like a regular podman Containerfile. For reference, please see the [Podman Documentation](https://docs.podman.io/en/latest/Introduction.html).

## build.sh

The [build.sh](./build_files/build.sh) file is called from your Containerfile. It is the best place to install new packages or make any other customization to your system. There are customization examples contained within it for your perusal.

## build.yml

The [build.yml](./.github/workflows/build.yml) Github Actions workflow creates your custom OCI image and publishes it to the Github Container Registry (GHCR). By default, the image name will match the Github repository name.

# Building Disk Images

This template provides an out of the box workflow for creating disk images (ISO, qcow, raw) for your custom OCI image which can be used to directly install onto your machines.

This template provides a way to upload the disk images that is generated from the workflow to a S3 bucket. The disk images will also be available as an artifact from the job, if you wish to use an alternate provider. To upload to S3 we use [rclone](https://rclone.org/) which is able to use [many S3 providers](https://rclone.org/s3/).

## Setting Up ISO Builds

The [build-disk.yml](./.github/workflows/build-disk.yml) Github Actions workflow creates a disk image from your OCI image by utilizing the [bootc-image-builder](https://osbuild.org/docs/bootc/). In order to use this workflow you must complete the following steps:

1. Modify `disk_config/iso.toml` to point to your custom container image before generating an ISO image.
2. If you changed your image name from the default in `build.yml` then in the `build-disk.yml` file edit the `IMAGE_REGISTRY`, `IMAGE_NAME` and `DEFAULT_TAG` environment variables with the correct values. If you did not make changes, skip this step.
3. Finally, if you want to upload your disk images to S3 then you will need to add your S3 configuration to the repository's Action secrets. This can be found by going to your repository settings, under `Secrets and Variables` -> `Actions`. You will need to add the following
  - `S3_PROVIDER` - Must match one of the values from the [supported list](https://rclone.org/s3/)
  - `S3_BUCKET_NAME` - Your unique bucket name
  - `S3_ACCESS_KEY_ID` - It is recommended that you make a separate key just for this workflow
  - `S3_SECRET_ACCESS_KEY` - See above.
  - `S3_REGION` - The region your bucket lives in. If you do not know then set this value to `auto`.
  - `S3_ENDPOINT` - This value will be specific to the bucket as well.

Once the workflow is done, you'll find the disk images either in your S3 bucket or as part of the summary under `Artifacts` after the workflow is completed.

# Artifacthub

This template comes with the necessary tooling to index your image on [artifacthub.io](https://artifacthub.io). Use the `artifacthub-repo.yml` file at the root to verify yourself as the publisher. This is important to you for a few reasons:

- The value of artifacthub is it's one place for people to index their custom images, and since we depend on each other to learn, it helps grow the community. 
- You get to see your pet project listed with the other cool projects in Cloud Native.
- Since the site puts your README front and center, it's a good way to learn how to write a good README, learn some marketing, finding your audience, etc. 

[Discussion Thread](https://universal-blue.discourse.group/t/listing-your-custom-image-on-artifacthub/6446)

# Justfile Documentation

The `Justfile` contains various commands and configurations for building and managing container images and virtual machine images using Podman and other utilities. It is also used inside Github Actions.

## Required Utilities

Container build:
- [just](https://just.systems/man/en/introduction.html)
- [podman](https://docs.podman.io/en/latest)
- [jq](https://jqlang.org)

These are usually preinstalled on Universal Blue's Bootc Images.

Linting:
- shfmt
- shellcheck

## Environment Variables

These are all sourced from the `image-template.env` file.

- `image_name`: The name of the image (default: "image-template").
- `default_tag`: The default tag for the image (default: "latest").
- `bib_image`: The Bootc Image Builder (BIB) image (default: "quay.io/centos-bootc/bootc-image-builder:latest").

## Building The Image

All these recipes will work (with default values) without supplying any arguments to them, e.g. `just build`

### `just build`

Builds a container image using Podman.

```bash
just build $target_image $tag
```

Arguments:
- `$target_image`: The tag you want to apply to the image (default: `$image_name`).
- `$tag`: The tag for the image (default: `$default_tag`).

### Rechunking
We can flatten the layers of container images to make sure there isn't a single huge layer when your image gets published.
This does not make your image faster to download, just provides better resumability.

#### `just ostree-rechunk`
Rechunks the existing Image with [rpm-ostree](https://coreos.github.io/rpm-ostree/build-chunked-oci/)

```bash
just ostree-rechunk $target_image $tag
```

#### `just rechunk`
Rechunks the existing Image with [chunkah](https://github.com/coreos/chunkah), this is probably gonna be the default here at some point, try it out, it's cool.

```bash
just rechunk $target_image $tag
```

### Switching to the locally built image for testing

The image has to be in the containers-storage owned by root, to be able to rebase to it, see the `_rootful_load_image` recipe.

`sudo just build` and `sudo just ostree-rechunk` builds directly as root and allows you to skip the transfer to the root containers-storage.

You can rebase to all the images that are in your containers-storage:

```
sudo podman image list --filter=label=containers.bootc=1
```

See [man bootc switch](https://bootc.dev/bootc/man/bootc-switch.8.html) for more info.

```
sudo bootc switch --transport containers-storage localhost/myimage:latest
```

and reboot your system!

## Building and Running Virtual Machines and ISOs

The below commands all build QCOW2 images. To produce or use a different type of image, substitute in the command with that type in the place of `qcow2`. The available types are `qcow2`, `iso`, and `raw`.

### `just build-qcow2`

Builds a QCOW2 virtual machine image.

```bash
just build-qcow2 $target_image $tag
```

### `just rebuild-qcow2`

Rebuilds a QCOW2 virtual machine image.

```bash
just rebuild-vm $target_image $tag
```

### `just run-vm-qcow2`

Runs a virtual machine from a QCOW2 image.

```bash
just run-vm-qcow2 $target_image $tag
```

### `just spawn-vm`

Runs a virtual machine using systemd-vmspawn.

```bash
just spawn-vm rebuild="0" type="qcow2" ram="6G"
```

## File Management

### `just check`

Checks the syntax of all `.just` files and the `Justfile`.

### `just fix`

Fixes the syntax of all `.just` files and the `Justfile`.

### `just clean`

Cleans the repository by removing build artifacts.

### `just lint`

Runs shell check on all Bash scripts.

### `just format`

Runs shfmt on all Bash scripts.

## Additional resources

For additional driver support, ublue maintains a set of scripts and container images available at [ublue-akmod](https://github.com/ublue-os/akmods). These images include the necessary scripts to install multiple kernel drivers within the container (Nvidia, OpenRazer, Framework...). The documentation provides guidance on how to properly integrate these drivers into your container image.

## Community Examples

These are images derived from this template (or similar enough to this template). Reference them when building your image!

- [m2Giles' OS](https://github.com/m2giles/m2os)
- [bOS](https://github.com/bsherman/bos)
- [Homer](https://github.com/bketelsen/homer/)
- [Amy OS](https://github.com/astrovm/amyos)
- [VeneOS](https://github.com/Venefilyn/veneos)
