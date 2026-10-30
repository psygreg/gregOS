# gregOS

**psygreg**'s custom built Bazzite-based system. Niri with Noctalia setup, including `noctalia-greeter`, and rechunked, so it's lightweight and clean, without other desktop leftovers. Comes with all applicable optimization patches from *[LinuxToys](https://linux.toys)* on top of Bazzite's out-of-the-box, and replaces *Bazaar* and *Bold Brew* with ***LinuxToys*** for app and package management. 

## Usage

Choose one of the available variants:
- `gregos`: for AMD and Intel graphics cards and integrated graphics
- `gregos-nvidia`:  for Nvidia Maxwell/Pascal (GT/X 9xx/10xx), GTX 750 and 750Ti series cards
- `gregos-nvidia-open`: for Nvidia Turing (GTX 16xx and RTX 20xx) series and newer cards

To install it, from any running `bootc`-based Fedora immutable system (recommended *Bazzite*):
```bash
sudo bootc switch ghcr.io/psygreg/<variant>:latest
```
Then, after a reboot, switch to the signed version of the image:
```bash
sudo bootc switch --enforce-container-sigpolicy ghcr.io/psygreg/<variant>:latest
```

Then run the quick post-install setup steps by simply launching *LinuxToys* and following any prompts that show up from it. It will perform all necessary final touch-ups at first launch.

# What this image ships

This image is based on `ghcr.io/ublue-os/bazzite:stable` and replaces the traditional desktop
environment with a tiling-compositor setup:

- **[niri](https://github.com/YaLTeu/niri)** - scrollable-tiling Wayland compositor (Fedora package) and all 
  fixes and tweaks needed for it to work as you would expect.
- **[Noctalia](https://github.com/noctalia-dev/noctalia)** - the desktop shell layered on top of niri: bar,
  launcher, control center, notifications, lock screen, wallpaper, OSDs, clipboard, tray, and its own polkit
  agent.
- **[Noctalia Greeter](https://github.com/noctalia-dev/noctalia-greeter)** + **greetd** - the login screen.
  Sourced from the [Terra](https://terrapkg.com) repository; the repo is used at build time and left disabled
  afterwards, matching how Bazzite itself consumes Terra. The greeter runs as the `greeter` system account
  (declared via `system_files/usr/lib/sysusers.d/gregos-niri.conf`, with `video`/`input`/`render` device
  access). greetd launches it through gregOS's own `noctalia-greeter-render` wrapper, which makes the
  greeter's bundled wlroots compositor start reliably on any GPU — see
  [Why a render wrapper](#why-a-render-wrapper). A setup service (`gregos-noctalia-greeter-setup.service`)
  verifies device access and initializes Noctalia's persistent state before greetd starts.
- **GTK theming** - `adw-gtk3-theme` (Fedora repos) applied with `nwg-look` (Terra), the GTK look-and-feel
  editor for Wayland; Qt apps are themed with `qt6ct`.
- KDE Plasma and GNOME desktop environments are **removed** at build time, along with most of their
  desktop-specific applications (see `REMOVE_PATTERNS` in [build_files/build.sh](./build_files/build.sh)).
  Everything else Bazzite ships is untouched: Steam, gamescope, drivers, ujust, Bazzite Portal, Waydroid,
  Cockpit, the audio stack, and so on. **Bazaar** and **Bold Brew** are removed as well — software and system management is
  centered on LinuxToys instead.
- **Selected cross-desktop apps** — Nautilus (`nautilus`), GNOME Keyring (`gnome-keyring` with its
  `gnome-keyring-pam` greetd integration and `seahorse` to manage it), GNOME Disks
  (`gnome-disk-utility`), Showtime (`showtime`), and KDE Connect (`kde-connect`). Nautilus thumbnails
  images via the `glycin-loaders` thumbnailers shipped by the base image (kept through the desktop
  cleanup) and videos via `ffmpegthumbnailer`.
- **Heroic Games Launcher instead of Lutris** — Lutris is removed; [Heroic](https://heroicgameslauncher.com)
  is installed at build time from the `.rpm` asset of its latest GitHub release — so every image
  build automatically picks up the newest version.
- **[`latencydevil`](https://github.com/psygreg/latencydevil) launcher wrapper** — the low-latency helper
  for competitive gaming is built in and installed on the system `PATH` (`/usr/bin/latencydevil`,
  fetched at build time from its latest GitHub release, so image builds automatically pick up new
  versions). Prefix any game with `latencydevil -- %command%` in *Steam* launch options — or any terminal
  or Flatpak command with `latencydevil -- …` — to inject GPU-aware low-latency environment variables in
  front of it; the wrapper `exec`s into the game, leaving nothing extra in the process tree. Run
  `latencydevil --print` to see the variables it would apply on this system.
- **[LinuxToys](https://github.com/psygreg/linuxtoys)** is layered on top, installed at build time from the
  `.rpm` asset of its latest GitHub release — so every image build automatically picks up the newest
  version. It replaces Bazaar and Bold Brew as the image's software and system manager. Its well-known optimization tweaks are also baked into the image.
- **zswap instead of zram** — the `zram-generator` packages are removed. Swapped pages are compressed by the
  kernel with `zstd` into a `zsmalloc` pool capped at 25% of RAM (with the shrinker enabled), backed by
  whatever swap device you provide yourself. See [Swap: zswap instead of zram](#swap-zswap-instead-of-zram).
- **Snap packages (snapd)** — `snapd`, `snapd-selinux` and `squashfuse` are built in, with the immutable
  system adaptations described in [Snap packages](#snap-packages). Strictly confined and classic-confined
  snaps both work out of the box.
- **FlatPark pre-enabled** — the [FlatPark](https://flatpark.org) community Flatpak hub ships as a system
  remote for every user (`system_files/etc/flatpak/remotes.d/flatpark.flatpakrepo`, the same file-based
  mechanism the base image uses to pre-enable Flathub).
- **Simpler printer configuration** through `system-config-printer`.
- **Friendlier terminal shell** and several `zsh` features while remaining on `bash` with a fully implemented
  *[sloth-bash](https://github.com/psygreg/sloth-bash)* - another project of mine.

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
- **Displays are detected at login.** `gregos-niri-display-setup` (started by `spawn-at-startup`) asks niri for
  each output's modes and sets it to its native resolution at the highest refresh rate it supports, so a 144 Hz
  monitor runs at 144 Hz without any configuration. Every connected output is handled this way, so multi-monitor
  setups work too. The result is written to `~/.config/niri/gregos-display.kdl`, which is regenerated on every
  login and only rewritten when it changes. To override a display, declare `output "NAME" { mode "WIDTHxHEIGHT@REFRESH"; }`
  in your `~/.config/niri/config.kdl`; the setup script leaves that output alone.
- The Noctalia settings window opens floating at a proportion of the screen it appears on (1080x920 on a
  2560x1440 display), so it is correctly sized at any resolution and on any display of a multi-monitor setup.
  To change its size, add a `window-rule` below the `include` line in your `config.kdl`.
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
- **Dead keys (compose/accented characters) work consistently in all apps** (GTK2/3/4 and Qt) with layouts
  like `us-intl`, through **fcitx5**. Since GTK 4.20 (GNOME 49+), GTK no longer handles dead-key and
  X11-style compose sequences itself on Wayland — it delegates to an input-method framework, and Qt's Wayland
  text-input path likewise does no composing. Without a running input method, layouts like `us-intl` type
  accents that never appear, and toolkit-builtin workarounds (`GTK_IM_MODULE=simple`, `QT_IM_MODULE=compose`)
  behave inconsistently across apps. The image ships the full fcitx5 stack (`fcitx5`, `fcitx5-gtk`,
  `fcitx5-qt`, `fcitx5-configtool`) and the niri session starts it and exports
  `GTK_IM_MODULE=fcitx`, `QT_IM_MODULE=fcitx`, `XMODIFIERS=@im=fcitx`, so every toolkit composes through
  fcitx5. Keyboard layout / input-method engines are configured with `fcitx5-config-qt`.
  **One rule to keep in mind:** fcitx5's layout has to match niri's. fcitx5 re-maps keys through its own
  keymap, and only skips that when its layout equals the compositor's — so if niri's
  `input { keyboard { xkb { layout … } } }` says one thing and fcitx5's profile says another, the accents
  come out wrong or not at all. Set both to the same layout (e.g. `us-intl` in niri and *Keyboard - English
  (US, intl., with dead keys)* in `fcitx5-config-qt`). This is also why the shipped niri config leaves the
  layout unset: it is a per-user choice, and fcitx5's own default (`keyboard-us`) has no dead keys to speak
  of.
- **Full input-method (IME) input is ready out of the box.** The engine set for the locales that need real
  IME is pre-installed — Japanese (`fcitx5-mozc`, with `fcitx5-anthy` as a lighter fallback),
  Simplified/Traditional Chinese (`fcitx5-chinese-addons`), Korean (`fcitx5-hangul`), Thai
  (`fcitx5-libthai`), plus the generic `fcitx5-m17n` and `fcitx5-table-extra` wrappers (Vietnamese, Indic,
  Cantonese, …). They are inactive by default: fcitx5's default profile contains only keyboard engines, so
  plain Latin/dead-key input keeps working for everyone until the user adds an IME — open
  `fcitx5-config-qt`, add the wanted engine (e.g. "Mozc" or "Pinyin"), and switch engines with the default
  toggle (usually `Ctrl+Space`).
  Flatpak support is automatic: the image ships a system-wide override (`/etc/flatpak/overrides/global`)
  that injects the same IM environment into every Flatpak. It only selects which input-context module the
  toolkits load, and how much it helps depends on the app's runtime — the fcitx module has to be *inside*
  the sandbox, and runtimes differ: the GNOME runtime ships it for GTK3 **and** GTK4, the freedesktop
  runtime only for GTK3. So GTK4 apps on the freedesktop runtime, and Qt apps in general, have no fcitx
  module to load and get their default input handling back (a warning in the log, plain Latin input still
  fine). For such an app where dead keys specifically matter, override it alone with GTK's built-in
  composer, which is compiled into every GTK build:
  `flatpak override --user --env=GTK_IM_MODULE=simple <app-id>`.
  One known gap: Chromium/Electron apps need `--enable-wayland-ime` on their command line (e.g. via
  `~/.config/chromium-flags.conf` or the app's own flags file) to take part in the Wayland input-method path.
  Note that existing homes with a user-modified niri `config.kdl` keep that file, so those users need to
  apply the same `environment` and `spawn-at-startup` changes by hand.

## Keyboard shortcuts

`Mod` is the Super (Windows) key. The bindings below are defined in `dotfiles/niri/config.kdl`.

**Shell and launchers**

| Shortcut | Action |
|---|---|
| `Mod+Space` | Noctalia app launcher |
| `Mod+P` | Noctalia control center |
| `Mod+Comma` | Noctalia settings |
| `Mod+T` | Open terminal (BlackBox) |
| `Alt+Tab` / `Mod+Tab` | Window switcher (hold to browse) |

**Windows and columns**

| Shortcut | Action |
|---|---|
| `Mod+A` / `Mod+D` | Focus column left / right |
| `Mod+W` / `Mod+S` | Focus window, or workspace, up / down |
| `Mod+Shift+A` / `Mod+Shift+D` | Move column left / right |
| `Mod+Shift+W` / `Mod+Shift+S` | Move window to workspace up / down |
| `Mod+F` | Maximize column |
| `Mod+F11` | Fullscreen window |
| `Mod+Q` | Close window |

**Mouse wheel**

| Shortcut | Action |
|---|---|
| `Mod` + wheel up / down | Focus workspace up / down |
| `Mod+Alt` + wheel up / down | Focus column left / right |
| `Mod+Shift` + wheel up / down | Volume up / down |

**Screenshots**

| Shortcut | Action |
|---|---|
| `Print` | Region screenshot (Noctalia) |
| `Mod+Print` | Window screenshot (niri built-in: clipboard and `~/Pictures/Screenshots`) |

**Media and brightness** (these also work on the lock screen)

| Key | Action |
|---|---|
| Volume up / down / mute | Noctalia volume and mute |
| Brightness up / down | Noctalia brightness |

The mouse-wheel binds use a 150 ms cooldown so one scroll step doesn't move several places at once.

# Credential storage: one supervised GNOME Keyring

Applications such as Zed keep their tokens in the freedesktop Secret Service (libsecret), so two things
have to hold for them to stay quiet: `org.freedesktop.secrets` must be served by **GNOME Keyring**, and
the daemon serving it has to be the one that got your login password — the one `pam_gnome_keyring` starts
and unlocks while the greetd PAM session runs.

On a stock image that second part breaks, and it breaks the way you described: the login is typed, then
later an app asks for a keyring password anyway. The sequence is:

1. `pam_gnome_keyring` starts `gnome-keyring-daemon --daemonize` and unlocks the login keyring. That
   daemon is an unsupervised child of the PAM session — the packaged `gnome-keyring-daemon.service` is
   disabled — so when it exits, the unlock state goes with it and nothing brings it back.
2. The next app touches the Secret Service, which D-Bus-activates `org.freedesktop.secrets` and starts a
   **fresh** daemon with no password. A new daemon cannot know your login password, so the login keyring
   stays locked and every app that needs a secret prompts for one.

The daemon also crashes outright in that path (`gkd_secret_service_get_pkcs11_session: assertion 'client'
failed`, `aes_negotiate: assertion 'session' failed`, `SIGABRT`), which is what kills the first daemon in
the middle of a session. Fedora ships `gnome-keyring` 50.x; upstream 51.0 contains fixes for exactly these
crashes.

gregOS therefore runs the keyring as a **supervised session service**:

- `gnome-keyring-daemon.socket` is enabled for the user session (image-pinned in
  `build_files/build.sh`). The daemon then runs under the systemd user manager with
  `--control-directory=%t/keyring` and `Restart=on-failure`, so a crash brings it back instead of leaving
  a dead control socket and a locked keyring behind.
- `gcr3` is pinned for `gcr-prompter`, the dialog gnome-keyring uses when a prompt really is needed.
  (Fedora ships the gcr-3 prompter as `gcr3`; `gcr4` does not provide it.)
- `seahorse` is installed as the keyring's management UI — the place to inspect the `login` keyring,
  change its password, or fix a wrong one.

# Why a render wrapper

The Noctalia Greeter is not just a UI — it ships its own bundled [wlroots](https://gitlab.freedesktop.org/wlroots/wlroots)
compositor that draws the login screen. wlroots picks a renderer with `wlr_renderer_autocreate()`, which
tries them in this order:

1. `gles2` (EGL / DRI2)
2. `vulkan` (needs the DRM↔Vulkan device match to succeed)
3. `pixman` (software) — **only** used when the backend has **no render node**

The catch is step 3: on real hardware there **is** a render node, so if `gles2` and `vulkan` both fail,
wlroots returns `NULL` instead of falling back to software, the compositor prints
`failed to create wlroots renderer` and exits, and greetd restart-loops onto a blank screen with no useful
error. That is exactly what happened on this Bazzite base (EGL: `DRI2: failed to create screen`, then
Vulkan: `Could not match drm and vulkan device`).

A login greeter must never be able to fail to draw. So greetd does **not** run `noctalia-greeter-session`
directly — it runs gregOS's `noctalia-greeter-render` wrapper
(`system_files/usr/libexec/gregos/noctalia-greeter-render`), which:

- first lets wlroots pick a hardware renderer (`auto` → `gles2`/`vulkan`/`pixman`);
- if the compositor cannot get through startup (renderer creation fails immediately), retries pinned to the
  software `pixman` renderer, which always works regardless of GPU, driver, or render-node quirks;
- treats a compositor that survives a short grace period as healthy and simply waits for it.

The desktop session you log into afterwards is unaffected — niri (via smithay) does its own renderer
selection and uses hardware acceleration. The wrapper only guarantees that the **login screen** always
appears. It can be tuned or pinned for debugging through environment variables documented at the top of the
wrapper (e.g. `GREGOS_GREETER_RENDERER=gles2` to force hardware, or `GREGOS_GREETER_MAX_ATTEMPTS`).


# Swap: zswap instead of zram

`zram` swaps can be great if you have a large amount of RAM available and won't typically put it under pressure, otherwise, end up causing unwanted out-of-memory events - while those won't freeze the system, instead just crashing whatever process was the *memory hog*, it's clearly desirable to avoid them as much as possible, hence why the choice for `zswap`.

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

# Snap packages

`snapd` is layered on top of Bazzite so snaps can be used alongside Flatpaks, Homebrew and the RPM
base. On an immutable bootc/ostree system a plain `dnf install snapd` is not enough, so the image handles
the immutable-specific parts at build time:

## What the image provides

- **`snapd`, `snapd-selinux` and `squashfuse`** (`build_files/build.sh`). `snapd-selinux` ships the `snappy`
  SELinux policy module and the file contexts for `/var/lib/snapd`, `/var/snap` and the snapd binaries —
  required because Bazzite runs SELinux in enforcing mode. `squashfuse` is the fallback for mounting `.snap`
  squashfs images whenever the `squashfs` kernel module is not available (snapd itself requires
  `((squashfuse and fuse) or kmod(squashfs.ko))`).
- **`/snap -> var/lib/snapd/snap`**, created in the image. snapd accepts exactly two layouts for its mount
  directory (`dirs.SupportsClassicConfinement` in the snapd source):
  `/snap` as a real directory (the Ubuntu default) or `/snap` as a symlink to `/var/lib/snapd/snap` (the
  Fedora/Arch convention). Fedora's `snapd` uses the second layout and deliberately does **not** ship the
  link — on a mutable Fedora you create it yourself with `sudo ln -s /var/lib/snapd/snap /snap`. On this
  image the root filesystem is read-only, so the link is baked into the image instead (relative target, so
  it resolves the same in the build container, in the image, and on every deployed system). Without it,
  strictly confined snaps still run, but classic snaps are refused with
  *"classic confinement requires snaps under /snap or symlink from /snap to /var/lib/snapd/snap"*.
- **snapd's runtime state under `/var`** (`system_files/usr/lib/tmpfiles.d/gregos-snapd.conf`). The RPM ships
  those directories, but the image's `/var` content is not carried onto deployed hosts (ostree keeps the
  host's `/var` and only seeds it at first install), and `bootc container lint` warns about image `/var`
  content without matching tmpfiles.d entries. The tmpfiles snippet recreates the whole tree on every boot.
- **`var-lib-snapd-snap.mount` and `var-snap.mount`**
  (`system_files/usr/lib/systemd/system/`), enabled in the image. Upstream snapd ships these self-bind
  `rbind,private,shared` mount units; Fedora's package drops them along with the `/snap` symlink. They make
  the snap mount directories mount points with shared mount propagation, which snapd needs for snap
  refreshes (LP: #1668759) and for parallel-installed classic snaps. Their upstream `Condition`s skip them
  when snapd has already preserved a mount namespace, so enabling them unconditionally is safe.
- **`snapd.socket`** is enabled (socket activation), matching Fedora defaults — `snapd.service` itself is
  started on first use.

## Using snaps

```bash
snap version                      # snapd should answer after the first invocation
snap find vlc
snap install vlc                  # strictly confined snap
snap install code --classic       # classic snap - needs the /snap link, which the image ships
```

The first `snap` invocation may take a few seconds while snapd seeds the device
(`sudo snap wait system seed.loaded` waits for it explicitly). Desktop entries of installed snaps land in
`/var/lib/snapd/desktop`, which is already added to `XDG_DATA_DIRS` by snapd's own `environment.d` and
`profile.d` snippets, so they appear in the Noctalia launcher after a re-login.

## Known limits

- **Confinement is weaker than on Ubuntu.** Fedora has no AppArmor, so snaps run without AppArmor
  confinement (seccomp and the per-snap mount namespaces still apply). This is a Fedora-wide property of
  snapd, not something this image changes.
- **Classic snaps see the host filesystem**, as everywhere — they are unconfined by design.
- **Home directories** must be under `/home` (they are on this image: `/home` is `/var/home`), since snapd
  requires `$HOME` to live under `/home`.
- Snap refreshes and installs update `/var/lib/snapd`, never `/usr`, so they survive image updates and
  rollbacks untouched.

# GnuPG: keyboxd stays disabled

gpg 2.4.1 and newer write `~/.gnupg/common.conf` with an active `use-keyboxd` the first time they run without an existing `~/.gnupg` directory. That moves public keys into keyboxd's own database instead of `pubring.kbx`, and distroboxes, which share `$HOME` with the host, could not verify signing keys from it. gregOS ships `#use-keyboxd` as the content of `common.conf` instead, so gpg keeps the classic keyring:

- `/etc/skel/.gnupg/common.conf` covers new accounts.
- `gregos-gnupg-config-seed.service` covers existing homes, for root and every regular user, on every boot. It creates a missing `common.conf` and comments out an active `use-keyboxd` line in an existing one. The rest of the file is left alone. Because it runs on every boot, keyboxd cannot stay enabled through `common.conf` on this image.

If you keep keys in keyboxd's database (`~/.gnupg/public-keys.d/pubring.db`), gpg cannot see them once keyboxd is disabled, and it does not migrate them. Export them while `use-keyboxd` is still enabled, then import the file with it disabled. On an image that already disabled it, uncomment the line only for the export:

```bash
gpg --export --export-options backup > all-keys.gpg    # use-keyboxd enabled
gpg --import --import-options restore < all-keys.gpg   # use-keyboxd disabled
```

# image-template README

This repository is meant to be a template for building your own custom [bootc](https://github.com/bootc-dev/bootc) image. This template is the recommended way to make customizations to any image published by the Universal Blue Project.

# Community

If you have questions about this template after following the instructions, try the following spaces:
- [Universal Blue Forums](https://universal-blue.discourse.group/)
- [Universal Blue Discord](https://discord.gg/WEu6BdFEtp)
- [bootc discussion forums](https://github.com/bootc-dev/bootc/discussions) - This is not an Universal Blue managed space, but is an excellent resource if you run into issues with building bootc images.

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

### NVIDIA variants

Besides the standard image, this repository also builds two NVIDIA variants from Bazzite's NVIDIA bases, published alongside it by the `build.yml` workflow matrix:

- `ghcr.io/psygreg/gregos-nvidia:stable` — from `ghcr.io/ublue-os/bazzite-nvidia:stable` (proprietary driver)
- `ghcr.io/psygreg/gregos-nvidia-open:stable` — from `ghcr.io/ublue-os/bazzite-nvidia-open:stable` (open kernel modules)

Both use the same build procedure; when the base image name includes `nvidia`, `build_files/build.sh` swaps Mesa's `MESA_SHADER_CACHE_MAX_SIZE` default for the NVIDIA driver's `__GL_SHADER_DISK_CACHE_SIZE` and installs the "Limit Free Buffer Pool On Wayland Compositors" application profile for niri under `/etc/nvidia/nvidia-application-profiles-rc.d/`. The workflow sets `IMAGE_NAME` and `BASE_IMAGE` per matrix entry; for local builds, export `BASE_IMAGE` before calling `just build`, e.g. `BASE_IMAGE=ghcr.io/ublue-os/bazzite-nvidia:stable just build gregos-nvidia latest`.


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
