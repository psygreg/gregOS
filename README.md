# gregOS

**psygreg**'s custom built Bazzite-based system. Niri with Noctalia setup, including `noctalia-greeter`, and rechunked, so it's lightweight and clean, without other desktop leftovers. Comes with all applicable optimization patches from *[LinuxToys](https://linux.toys)* on top of Bazzite's out-of-the-box, and replaces *Bazaar* and *Bold Brew* with ***LinuxToys*** for app and package management. 

## Usage

Choose one of the available variants:
- `gregos`: for AMD and Intel graphics cards and integrated graphics
- `gregos-nvidia`:  for Nvidia Maxwell/Pascal (GT/X 9xx/10xx), GTX 750 and 750Ti series cards
- `gregos-nvidia-open`: for Nvidia Turing (GTX 16xx and RTX 20xx) series and newer cards
- `gregos-nova`: for Nvidia Turing (GTX 16xx and RTX 20xx) series and newer cards, using the fully
  open-source Nouveau/NVK stack (see [NVIDIA variants](#nvidia-variants))

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
- **[`niri-resume`](https://github.com/psygreg/niri-resume) session resume** — the apps open when a session
  ends come back at the next login, with their workspace, size, maximized/fullscreen state and position.
  Noctalia's Log out / Shut down / Reboot actions (`dotfiles/noctalia/15-gregos-session-actions.toml`) run
  the tool's `save-quit` / `save-shutdown` / `save-reboot` commands instead of the plain action: the
  snapshot is written before the action fires, so there is no race between saving and exiting. niri then
  runs `niri-resume restore` as the last `spawn-at-startup` entry on the next login, relaunching the
  recorded apps with their original command lines and re-placing their windows. The binary is installed
  on the system `PATH` (`/usr/bin/niri-resume`, fetched at build time from its latest GitHub release, so
  image builds automatically pick up new versions); see [Using the desktop](#using-the-desktop) for the
  details.
- **[LinuxToys](https://github.com/psygreg/linuxtoys)** is layered on top, installed at build time from the
  `.rpm` asset of its latest GitHub release — so every image build automatically picks up the newest
  version. It replaces Bazaar and Bold Brew as the image's software and system manager. Its well-known optimization tweaks are also baked into the image.
- **zswap instead of zram** — the `zram-generator` packages are removed. Swapped pages are compressed by the
  kernel with `zstd` into a `zsmalloc` pool capped at 25% of RAM (with the shrinker enabled), backed by
  whatever swap device you provide yourself. See [Swap: zswap instead of zram](#swap-zswap-instead-of-zram).
- **Snap packages (snapd)** — `snapd`, `snapd-selinux` and `squashfuse` are built in, with the immutable
  system adaptations described in [Snap packages](#snap-packages). Strictly confined and classic-confined
  snaps both work out of the box.
- **Nix (official Fedora packages)** — Nix 2.35.6 runs as a system-level multi-user daemon, with the
  host GPU drivers bind-mounted at `/run/opengl-driver` (OpenGL/Vulkan, CUDA, ROCm/OpenCL/Level Zero),
  so Nix apps get hardware acceleration on this non-NixOS system. The store lives in persistent
  `/var/home/nix` and is bind-mounted at `/nix`; packages themselves stay user-level through flakes,
  `nix profile` and Home Manager. See [Nix](#nix).
- **A fully open-source NVIDIA option (`gregos-nova`)** — built from the standard Bazzite base with
  Nouveau + GSP firmware and Mesa NVK/Zink, and no proprietary NVIDIA driver. The Nix GPU bundle exposes
  NVK to Nix applications the same way the other variants expose their host drivers. See
  [NVIDIA variants](#nvidia-variants).
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
- **Session resume** ([`niri-resume`](https://github.com/psygreg/niri-resume), see the built-in list above):
  `niri-resume restore` is the last `spawn-at-startup` entry, so the apps that were open at the end of the
  previous session are relaunched and re-placed after the shell, portals and display setup are already
  coming up. It picks the snapshot up from the previous session's end, which happens through every
  session-ending path the image wires:
  - **Log out** runs `niri-resume save-quit`: the session snapshot is written first, then niri quits.
  - **Reboot** runs `niri-resume save-reboot`: snapshot first, then `systemctl reboot`.
  - **Shut down** runs `niri-resume save-shutdown`: snapshot first, then `systemctl poweroff`.
  - **Lock** and **Lock & Suspend** keep their built-in implementations — suspending and locking do not
    end the session, so there is nothing to record.
  - The same overridden actions are used everywhere Noctalia exposes them: the session panel, the
    launcher's `/session` provider, `noctalia msg session …` and the lock screen buttons.
  - The compositor's own session-ending keys are wired the same way: `Mod+Shift+E` and `Ctrl+Alt+Delete`
    (niri's default-config quit binds, not present in this standalone config until now) save and quit,
    and the **physical power button** saves and shuts down. For the button, niri's built-in power-key
    handling (it takes a logind inhibitor and suspends on every press) is disabled
    (`disable-power-key-handling`), and systemd-logind ignores short presses through
    `/etc/systemd/logind.conf.d/10-gregos-power-button.conf` — otherwise the plain poweroff would fire
    before anything could save. The button works while the session is locked too. **Long-pressing** the
    button outside a niri session (greeter, TTY console) still powers off through logind; inside a
    session the press-time shutdown wins first.
  - Every one of these carries a `||` fallback (`niri msg action quit` / `systemctl poweroff` /
    `systemctl reboot`): if the save itself fails (broken IPC, unwritable state file), the session still
    ends the plain way, it just skips the snapshot — the next restore then replays the last successful
    one.
  - Only crashes and firmware-level long-press force-offs skip the snapshot.
  - Restore can be skipped once with `niri-resume clear` (e.g. before logging out of a throwaway
    session), and `niri-resume list` shows what a save would record right now.
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
  like `us-intl`, through **ibus**. Since GTK 4.20 (GNOME 49+), GTK no longer handles dead-key and
  X11-style compose sequences itself on Wayland — it delegates to an input-method framework, and Qt's Wayland
  text-input path likewise does no composing. Without a running input method, layouts like `us-intl` type
  accents that never appear, and toolkit-builtin workarounds (`GTK_IM_MODULE=simple`, `QT_IM_MODULE=compose`)
  behave inconsistently across apps. The image ships the full ibus stack (`ibus`, `ibus-gtk3`, `ibus-gtk4`,
  plus Qt's ibus plugin from `qt6-qtbase-gui`) and the niri session starts `ibus-daemon -drx` and exports
  `GTK_IM_MODULE=ibus`, `QT_IM_MODULE=ibus`, `XMODIFIERS=@im=ibus`, so every toolkit composes through ibus.
  The ibus keyboard engine for this layout (`xkb:us:intl`) is preloaded as a dconf system default, so dead
  keys work with no first-run setup. Engines/config is at `ibus-setup`.

  Apps launched through D-Bus/systemd activation (the GNOME apps, e.g. the Text Editor opened via
  "Open with…" in the file manager) are spawned by the systemd user manager instead of the session, with
  the manager's environment rather than the caller's, so the niri session variables above never reached
  them and they loaded no ibus module. The image therefore also ships the same variables as an
  `environment.d` drop-in (`/usr/lib/environment.d/10-gregos-ibus.conf`), which the user manager reads at
  startup: apps launched that way get the same IM environment and compose identically.
  **One rule to keep in mind:** an ibus keyboard engine mirrors its own layout. With the preloaded
  `xkb:us:intl` engine, accents match a `us-intl` XKB layout set in niri
  (`input { keyboard { xkb { layout … } } }`); if niri's layout says something else, set the matching
  ibus keyboard engine in `ibus-setup` (or change the engine). This is also why the shipped niri config
  leaves the layout unset: it is a per-user choice.
- **Full input-method (IME) input is ready out of the box.** The engine set for the locales that need real
  IME is pre-installed — Japanese (`ibus-anthy`), Simplified Chinese (`ibus-libpinyin`), Traditional
  Chinese (`ibus-chewing`, plus `xkb:us…` Bopomofo alternatives), Korean (`ibus-hangul`), Thai and the
  wider catalogue through `ibus-m17n`, and the predictive `ibus-typing-booster` (emoji/unicode). The IME
  engines sit inactive next to the preloaded keyboard engine: plain Latin/dead-key input keeps working for
  everyone until the user adds an IME — open `ibus-setup`, add the wanted engine (e.g. "Anthy" or
  "Intelligent Pinyin"), and switch engines with the default
  toggle (usually `Ctrl+Space`).
  Flatpak support is automatic: the image ships a system-wide override (`/etc/flatpak/overrides/global`)
  that injects the same IM environment into every Flatpak. It only selects which input-context module the
  toolkits load, and how much it helps depends on the app's runtime — the ibus module has to be *inside*
  the sandbox, and runtimes differ: the GNOME runtime ships it for GTK3 **and** GTK4, the freedesktop
  runtime only for GTK3. So GTK4 apps on the freedesktop runtime, and Qt apps in general, have no ibus
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
| `Mod+V` | Toggle floating mode for focused window |
| `Mod+C` | Center focused window on display |
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

**Session** (Noctalia session panel: the bar's Session widget, the Control Center, or `/session` in the
launcher — each action also has its numbered shortcut while the panel is open)

| Key | Action |
|---|---|
| `1` | Lock |
| `2` | Log out (saves the session, then quits niri) |
| `3` | Lock & Suspend |
| `4` | Reboot (saves the session, then reboots) |
| `5` | Shut down (saves the session, then powers off) |

**Session resume** (compositor-side paths through the same niri-resume save)

| Key | Action |
|---|---|
| `Mod+Shift+E` | Save the session, then quit niri |
| `Ctrl+Alt+Delete` | Save the session, then quit niri |
| Power button | Save the session, then shut down (works while locked; a long press outside a niri session powers off through logind) |

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

# Nix

Nix is the image's package manager for user-level software. gregOS uses Fedora's packaging of the
official [Nix](https://nixos.org/) implementation: the `nix` CLI, the stock multi-user `nix-daemon`
and the `nix-store`/`nix-env` legacy commands (Nix 2.35.6). Determinate-specific pieces (`fh`,
`determinate-nixd`, FlakeHub Cache) are not included; `fh` can still be installed in a user profile
from its upstream flake if wanted.

Nix still needs custom wiring on an immutable bootc system, because it writes to `/nix`, which cannot
live on the read-only deployment root. The image installs the Fedora packages and bind-mounts a
persistent store into place. After that, only the daemon, the store and the host graphics/compute
bundle are system-level; packages and development environments are user-level flakes.

## What the image provides

- **Nix 2.35.6 from Fedora** — `nix`, `nix-daemon` and `nix-legacy` (pulling in `nix-core`,
  `nix-system`, `nix-filesystem` and `nix-libs`). The binaries and daemon live in `/usr` and are updated
  with the image; no Nix store paths are baked into the image at build time.
- **A Home Manager launcher** — `/usr/bin/home-manager`, tracking Home Manager's `master` branch and
  locking the flake inputs on the first switch, with a default configuration seeded automatically for
  the machine's architecture and with unfree packages allowed. See [Home Manager](#home-manager).
- **Persistent store at `/var/home/nix`**, bind-mounted at `/nix` by `nix.mount`. The backing directory
  survives image updates and rollbacks; `/nix` itself is only the mount point.
- **First-boot store initialisation** — `gregos-nix-store.service` runs `nix-store --init` on the
  mounted store before `nix-daemon.service` starts, creating `/nix/store`, `/nix/var/nix` and the local
  database. The command is idempotent, so later boots are a no-op and an existing store is reused.
- **The stock daemon** — `nix-daemon.service` is enabled and creates the daemon socket itself.
  Fedora's `nix-daemon.socket` is masked: systemd creates socket files in the confined `init_t` domain
  and SELinux does not allow that inside the store, while the daemon service runs unconfined.
- **Build users** — Fedora's `nix-system` package creates the `nixbld` group and `nixbld-1` …
  `nixbld-10` through `sysusers.d/nix.conf`.
- **Sandbox shell** — Fedora's Nix uses `/usr/bin/busybox` as the sandbox `/bin/sh`; the image installs
  `busybox` so builds that are not available from the binary cache still work.
- **NixOS-compatible timezone path** — `/etc/zoneinfo` is a symlink to `/usr/share/zoneinfo`. Nix packages
  and their bubblewrap wrappers expect the NixOS timezone location `/etc/zoneinfo`; without the link,
  wrapped packages fail at startup with `bwrap: Can't find source path /etc/zoneinfo: No such file or
  directory`.
- **Flakes out of the box** — Fedora's `/etc/nix/nix.conf` sets
  `experimental-features = nix-command flakes`, `extra-nix-path = nixpkgs=flake:nixpkgs` and the Fedora
  CA bundle.
- **Configuration** — gregOS settings live in `/etc/nix/nix.custom.conf`, which the packaged nix.conf
  includes: `trusted-users = root @wheel`, `auto-optimise-store = true` (hard-link identical store
  files), and the `nix-community.cachix.org` binary cache with its verified signing key.
- **Shell and session wiring** — Fedora's `/etc/profile.d/nix.sh` and `nix-daemon.sh` add the user and
  system profiles to `PATH` and `XDG_DATA_DIRS`; `/etc/environment` and
  `/usr/lib/environment.d/10-gregos-nix.conf` point `NIX_SSL_CERT_FILE` at the Fedora CA bundle because
  the packaged fallback path (`/etc/pki/tls/certs/ca-bundle.crt`) does not exist on this image.
- **Graphics acceleration**, described below.

## Using Nix

```bash
nix --version                 # nix (Nix) 2.35.6
nix search nixpkgs hello
nix shell nixpkgs#hello       # run without installing
nix profile add nixpkgs#hello # user-level package, no image rebuild
nix develop                   # per-project development shell
```

`nixpkgs` resolves through Nix's built-in flake registry to `github:NixOS/nixpkgs/nixpkgs-unstable`, so
`nix shell nixpkgs#…` and `nix profile add nixpkgs#…` work without adding a channel. Pin a revision in
your own flake when you need reproducibility.

Non-free software is allowed by default. The image exports `NIXPKGS_ALLOW_UNFREE=1`, and the shipped
Home Manager flake imports nixpkgs with `allowUnfree = true`. Flake evaluation is pure, so ad-hoc
imperative commands need `--impure` for the variable to apply:

```bash
nix profile install --impure nixpkgs#slack
```

### Binary caches and store maintenance

`cache.nixos.org` stays the primary substituter. The image also trusts the `nix-community.cachix.org`
Cachix cache, which carries Home Manager and other community builds that Nixpkgs' cache does not.
Wheel members can add another Cachix cache system-wide in `/etc/nix/nix.custom.conf`:

```ini
extra-substituters = https://my-cache.cachix.org
extra-trusted-public-keys = my-cache.cachix.org-1:...
```

The signing key is shown on the cache's Cachix page (or returned by
`https://my-cache.cachix.org/api/v1/cache/my-cache`).

`auto-optimise-store` is enabled, so the daemon hard-links identical files between store paths as
builds finish; old generations then cost little beyond their profile symlink. The default Home Manager
configuration also runs a weekly `nix-collect-garbage --delete-older-than 14d` to remove old
generations and the store paths they keep alive.

Home Manager and flakes use the same system daemon. The image ships a `home-manager` launcher and a
default configuration; see [Home Manager](#home-manager) below.

Only the Nix daemon, the store and the host graphics/compute bundle ship in the image. Everything else
is installed by the user through `nix profile`, `nix develop` or Home Manager, which is why image
updates never fight user packages.

## Home Manager

`/usr/bin/home-manager` is a launcher tracking Home Manager's `master` branch. Home Manager itself is
not baked into the image: it is fetched into the shared Nix store on first use through the daemon, so a
normal user can use it without root and later users reuse the cached copy. The first `home-manager
switch` writes a `flake.lock` that pins the exact Home Manager and nixpkgs revisions.

The first `home-manager switch` also seeds `~/.config/home-manager` from `/usr/share/gregos/home-manager`
with the current user and home directory filled in:

- `flake.nix` follows `nixpkgs-unstable` and Home Manager `master`, so package versions and glibc match
  the `nixpkgs` the image exposes through the flake registry (and the host drivers built against it);
  it also targets the machine's detected Nix system and imports nixpkgs with `allowUnfree = true`;
- `home.nix` enables `targets.genericLinux`, `programs.home-manager` and starts with an empty
  `home.packages` list.

The setup helper maps `uname -m` to the matching Nix system string (`x86_64-linux`, `aarch64-linux`,
`i686-linux`, `armv7l-linux`, `powerpc64le-linux`, `riscv64-linux`, `s390x-linux`) and fills it into the
flake. `GREGOS_NIX_SYSTEM` overrides the detection for unusual setups. Existing configurations are never
rewritten: if yours still has a hard-coded `system = "x86_64-linux";` from an older image, change it to
your architecture or remove `~/.config/home-manager/flake.nix` and let the next switch recreate it.

Non-free software is allowed by default: the generated flake imports nixpkgs with
`config.allowUnfree = true`, and the image exports `NIXPKGS_ALLOW_UNFREE=1`. Flake evaluation is pure, so
ad-hoc imperative commands need `--impure` for that variable to take effect:

```bash
nix profile install --impure nixpkgs#slack   # unfree package outside Home Manager
```

Packages declared under `home.packages` need no flag.

`nix flake update` in that directory moves the locked revisions; `home-manager switch` applies them.

Add packages under `home.packages` and run `home-manager switch`; remove a line and switch again to
remove the package. Builds run through the daemon as the unprivileged `nixbld` users, so no root is
involved. Generations live in `~/.local/state/nix/profiles`:

```bash
home-manager switch                  # build and activate ~/.config/home-manager
home-manager generations             # list generations
home-manager switch --rollback       # return to the previous generation
```

The default configuration enables `nix.gc` (weekly, deleting generations older than 14 days) so old
package sets and the store paths they keep alive are reclaimed; adjust `nix.gc.options` or
`nix.gc.dates` to keep more history.

`targets.genericLinux.gpu` is deliberately disabled in the default configuration. gregOS already
bind-mounts the host GPU stack at `/run/opengl-driver` and exports the loader variables system-wide;
Home Manager's `gpu` module would instead build a second, Nix-owned driver set and require `sudo` to
activate it, which would replace the kernel-matched host drivers until the next boot. Nix
applications, including those installed by Home Manager, use the host bundle unchanged.

`nix profile add nixpkgs#…` and `nix profile remove …` also work without root, for imperative use.
Home Manager and `nix profile` both manage `~/.nix-profile`; use one of them for a given profile. If
packages were already added imperatively, remove them before the first `home-manager switch` (or use a
separate `nix profile --profile`), otherwise activation stops on a file conflict.

## Graphics and compute acceleration

Nixpkgs builds its `libglvnd` and Vulkan loader to look for drivers in `/run/opengl-driver` (the NixOS
convention). On a non-NixOS system that directory does not exist by default. gregOS fills it with the
**host** GPU stack rather than a Nix-built copy, so the driver ABI always matches the running kernel and
out-of-tree driver (including CUDA and ROCm).

The image build runs `build_files/nix-host-graphics.sh`, which builds two bundles:

- `/usr/lib/gregos/nix-graphics` for 64-bit Nix applications at `/run/opengl-driver`;
- `/usr/lib/gregos/nix-graphics-32` for 32-bit Nix applications at `/run/opengl-driver-32` on x86_64.

Each bundle:

- collects the host OpenGL/EGL/GLES vendor libraries, DRI drivers, Vulkan ICDs, VA-API/VDPAU drivers,
  NVIDIA userspace libraries (or Mesa NVK on `gregos-nova`), CUDA interfaces (`libcuda`, NVML,
  NVDEC/NVENC, OptiX), and whichever ROCm/HSA/HIP, Level Zero and OpenCL vendor libraries the base
  image provides for that architecture;
- copies their complete ELF dependency closure, excluding glibc itself, and patches every copied ELF
  with an RPATH pointing at the matching runtime bundle;
- rewrites Vulkan ICD, EGL vendor, EGL external-platform and OpenCL descriptors to the runtime paths;
- fails the build if a required `DT_NEEDED` library is missing, or if a host driver needs a newer
  `GLIBC_2.x` symbol version than the image provides.

The build is vendor-agnostic: Mesa/AMD/Intel libraries, NVIDIA's userspace libraries and (on
`gregos-nova`) Mesa NVK are selected by what the host provides. Proprietary NVIDIA images install the
i686 NVIDIA userspace alongside the 64-bit one, and the standard/nova images install the i686 Mesa
packages, so switching the GPU vendor only requires the matching driver packages (or image variant).

Nix applications load these drivers with their own glibc from nixpkgs. Current nixpkgs is at least as
new as this Fedora base, so the host drivers load cleanly; a very old nixpkgs pin may predate the
symbols a current host driver uses.

`gregos-nix-graphics.service` bind-mounts both bundles on every boot. The bundles stay trees of regular
files in the image, so the OCI chunker never sees the symlink/xattr corruption pattern, and the
read-only mounts are visible inside Nix's `buildFHSEnv` wrappers (umu-launcher, Faugus, Steam). Those
wrappers bind `/run` but replace `/usr`, so a symlink farm into `/usr/lib/gregos/nix-graphics` would go
dead inside them and Proton could not load an EGL/Vulkan driver.

- **OpenGL / Vulkan / video**: host Mesa DRI, Vulkan, VA-API and VDPAU on AMD/Intel; the host NVIDIA
  userspace stack on the proprietary NVIDIA variants; and host Mesa NVK + Zink on `gregos-nova`.
  `LD_LIBRARY_PATH`, `LIBGL_DRIVERS_PATH`, `LIBVA_DRIVERS_PATH`, `VDPAU_DRIVER_PATH`,
  `VK_DRIVER_FILES`/`VK_ICD_FILENAMES`, `__EGL_VENDOR_LIBRARY_FILENAMES` and
  `__EGL_EXTERNAL_PLATFORM_CONFIG_DIRS` include both `/run/opengl-driver` and
  `/run/opengl-driver-32`, so 32-bit and 64-bit Nix applications use the bundles without a `nixGL`
  wrapper. Vulkan layers are not bundled: the loader also scans the host layer directories, and
  duplicating them would load every layer twice. Nix-installed layers are found through the
  `XDG_DATA_DIRS` that `nix shell` sets.
- **NVIDIA CUDA**: `libcuda.so.1`, NVML, NVDEC/NVENC, OptiX and the other host NVIDIA compute libraries
  are exposed in both runtime trees, where Nix CUDA packages expect them.
  `__GLX_VENDOR_LIBRARY_NAME=nvidia` is set system-wide on the proprietary NVIDIA variants so Nix
  Xwayland applications select the NVIDIA vendor; Wayland EGL picks `10_nvidia.json`. `gregos-nova` has
  no CUDA or NVML: the open stack does not implement them, so the bundles carry NVK and Mesa's DRI
  drivers only.
- **Other compute**: the host ROCm/HSA/HIP libraries and `/opt/rocm/lib` (when present), Level Zero
  drivers, and OpenCL ICDs (Mesa Rusticl, Intel, NVIDIA) are included where the corresponding
  architecture provides them. `OCL_ICD_VENDORS` points Nix OpenCL clients at the bundles.
- **Device access**: a udev rule adds logind `uaccess` ACLs for the active seat user on DRM card/render
  nodes, `/dev/kfd` and `/dev/nvidia*`. Existing modes and group ownership are not changed; users who
  log in through a seat (the normal desktop case) get access without being added to additional groups.
  Compute nodes therefore work for Nix applications as they do for host ones.

On `gregos-nova`, the bundles are built from the same host Mesa that runs the desktop:
`libvulkan_nouveau.so` (the NVK ICD) plus `nouveau_dri`/`zink_dri`. The build verifies that all three
are present in both architectures and fails if a `libnvidia-*` library appears, so a Nix application
cannot silently pick up the proprietary stack on this variant.

Verify acceleration with Nix applications:

```bash
nix shell nixpkgs#mesa-demos --command glxgears
nix shell nixpkgs#vulkan-tools --command vulkaninfo
nix shell nixpkgs#clinfo --command clinfo       # OpenCL, when a host ICD exists
```

32-bit Nix applications (Wine/Proton, Battle.net and other 32-bit launchers) now find their drivers in
`/run/opengl-driver-32`; 32-bit host applications continue to use the host stack directly.

## Updates, persistence and limits

- `/var/home/nix` survives image updates and rollbacks. `/nix` is only the bind mount, never a directory
  on the immutable root.
- Nix itself is upgraded with the image through Fedora's packages; there is no separate vendor daemon
  to upgrade. User packages are upgraded with `nix profile upgrade --all` or by Home Manager, and
  `nix profile rollback`/generations handle package-level rollbacks. An image rollback reverts the Nix
  binaries but not the shared store or its database.
- Home Manager generations live per-user under `~/.local/state/nix/profiles` and are unaffected by image
  updates. `auto-optimise-store` hard-links identical store files, and the default weekly
  `nix-collect-garbage --delete-older-than 14d` removes older generations and their unreferenced paths.
- Image updates replace the host graphics/compute bundle under `/usr/lib/gregos/nix-graphics`;
  `gregos-nix-graphics.service` binds `/run/opengl-driver` to the new tree on the next boot. This does
  not touch `/nix` at all.
- The first boot initialises the store in `/var/home/nix`; later boots are effectively free. An existing
  store at that path — including one created by an earlier Determinate-based gregOS image — is reused
  as is, so user-installed packages keep working. A store at a different path is not adopted, and `/nix`
  is never re-seeded.

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

Besides the standard image, this repository publishes three NVIDIA-targeted variants through the
`build.yml` workflow matrix:

| Variant | Base image | NVIDIA stack |
| --- | --- | --- |
| `ghcr.io/psygreg/gregos-nvidia:latest` | `ghcr.io/ublue-os/bazzite-nvidia:stable` | proprietary driver |
| `ghcr.io/psygreg/gregos-nvidia-open:latest` | `ghcr.io/ublue-os/bazzite-nvidia-open:stable` | open kernel modules, proprietary userspace |
| `ghcr.io/psygreg/gregos-nova:latest` | `ghcr.io/ublue-os/bazzite:stable` | fully open: Nouveau GSP + Mesa NVK |

The first two use Bazzite's NVIDIA bases. When the base image name includes `nvidia`,
`build_files/build.sh` swaps Mesa's `MESA_SHADER_CACHE_MAX_SIZE` default for the NVIDIA driver's
`__GL_SHADER_DISK_CACHE_SIZE` and installs the "Limit Free Buffer Pool On Wayland Compositors"
application profile for niri under `/etc/nvidia/nvidia-application-profiles-rc.d/`. The workflow sets
`IMAGE_NAME`, `BASE_IMAGE` and `IMAGE_VARIANT` per matrix entry; for local builds, export the base and
the variant before calling `just build`, e.g.
`IMAGE_VARIANT=nvidia BASE_IMAGE=ghcr.io/ublue-os/bazzite-nvidia:stable just build gregos-nvidia latest`.

#### `gregos-nova`: open-source NVIDIA

`gregos-nova` is for users who want the NVIDIA stack to be open source end to end. It is built from the
standard Bazzite base (the same one as `gregos`) and contains no NVIDIA proprietary kernel module or
userspace driver. The stack is:

- **nouveau + GSP firmware** — the open kernel driver for Turing (GTX 16xx / RTX 20xx) and newer GPUs.
  GSP firmware is required for reclocking and for the interface NVK uses. The firmware itself is an
  NVIDIA-provided binary blob (as on every driver stack), loaded by the open kernel driver. The image
  installs `nvidia-gpu-firmware`, pins `nouveau.config=NvGspRm=1` through
  `/usr/lib/bootc/kargs.d/40-gregos-nova-gsp.toml`, and fails the build if the firmware or the
  userspace pieces are missing.
- **Mesa NVK** — the [conformant open-source Vulkan 1.4 driver](https://docs.mesa3d.org/drivers/nvk.html)
  for NVIDIA GPUs, exposed as the host Vulkan ICD and in the Nix host-graphics bundle.
- **Mesa Zink** — OpenGL 4.6 layered over NVK. Mesa uses NVK+Zink by default for Turing and newer since
  Mesa 25.1.

The build also fails if a proprietary NVIDIA package is installed or if a `libnvidia-*` library appears in
the Nix GPU bundle, so the variant cannot silently become a copy of `gregos-nvidia`.

**NOVA status.** [NOVA](https://docs.kernel.org/gpu/nova/index.html) (`nova-core` + `nova-drm`) is
NVIDIA's new upstream Rust driver intended to replace nouveau on GSP hardware. `nova-core` is upstream,
but `nova-drm` is still a work-in-progress skeleton — its Kconfig says it "is work in progress and may
not be functional" — and Fedora's kernel does not build the modules at the time of writing (Fedora 45).
It therefore cannot drive a display or accelerate applications yet. `gregos-nova` ships the open stack
that works today, which is also the kernel and userspace interface NOVA is being built to serve. When
`nova-drm` becomes functional and Fedora enables it, this variant picks it up through the kernel without
a userspace change; the name records that target, not a driver that is already active.

**What works, and what does not.** Vulkan and OpenGL applications, Wayland/Xwayland compositing, video
decode through Mesa, and the Nix GPU bundle work. The open stack does not provide CUDA, NVENC, NVML,
OptiX, or the NVIDIA control panel, and performance is generally below the proprietary driver. Some
games and anti-cheat systems may refuse to run or may be unstable, and power management on hybrid
laptops is less mature. If you need CUDA or maximum performance, use `gregos-nvidia` or
`gregos-nvidia-open`.

When rebasing from one of the proprietary variants, check `/etc/environment`: if it still contains
`__GLX_VENDOR_LIBRARY_NAME=nvidia`, remove that line and reboot. The nova image does not set it, but a
locally modified `/etc/environment` survives a `bootc switch` and would keep pointing libglvnd at the
proprietary GLX vendor that is no longer installed.

Verify the stack with:

```bash
vulkaninfo --summary   # the NVIDIA GPU should be listed with driverName "NVK"
glxinfo -B             # the renderer should be "zink (NVK ...)"
```

Nix applications use the same bundle:

```bash
nix shell nixpkgs#vulkan-tools --command vulkaninfo --summary
```


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
- `BASE_IMAGE`: The base container image (default: `ghcr.io/ublue-os/bazzite:stable`).
- `IMAGE_VARIANT`: The userspace GPU stack: `standard`, `nvidia`, `nvidia-open` or `nova`
  (default: `standard`). `gregos-nova` needs `nova` because it shares its base image with `gregos`.

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
