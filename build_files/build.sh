#!/bin/bash

set -ouex pipefail

### Install packages

# Packages can be installed from any enabled yum repo on the image.
# RPMfusion repos are available by default in ublue main images
# List of rpmfusion packages can be found here:
# https://mirrors.rpmfusion.org/mirrorlist?path=free/fedora/updates/43/x86_64/repoview/index.html&protocol=https&redirect=1

### niri + Noctalia desktop
##
## The desktop experience of this image is the niri Wayland compositor with
## the Noctalia shell on top, and the Noctalia greeter as the login screen,
## instead of a traditional desktop environment.
##
## Package sources:
##   - niri, greetd, portals, cursor/icon themes, adw-gtk3 theme: Fedora repos
##   - noctalia (the shell): Fedora repos (Fedora 44+)
##   - noctalia-greeter, nwg-look: Terra community repo. Bazzite already ships
##     terra-release with the Terra repos disabled, so install through the
##     repo and leave it disabled again afterwards (the same way Bazzite
##     itself consumes Terra packages).

dnf5 install -y \
    greetd \
    niri \
    noctalia \
    qt6ct \
    adw-gtk3-theme \
    adwaita-cursor-theme \
    adwaita-icon-theme \
    xdg-desktop-portal-gnome \
    xdg-desktop-portal-gtk \
    google-noto-sans-cjk-fonts \
    system-config-printer \
    system-config-printer-udev

### Install noctalia-greeter and nwg-look from the Terra repository
##
## Neither is in Fedora's own repos yet. Bazzite carries Terra but disables
## it. These packages are both in Terra's main repo, so enable only that repo
## for this transaction (--enable-repo does not change repo files on disk).
##
## Bazzite's DNF config sets skip_if_unavailable=1, and DNF5 5.4.6 can then
## silently skip Terra when it cannot load the repomd signing key. Disable only
## Terra's repomd check for this transaction; RPM signature checking remains
## enabled. Make Terra failures fatal instead of reporting misleading "no
## match" errors.

dnf5 install -y --refresh \
    --setopt=terra.repo_gpgcheck=0 \
    --setopt=terra.skip_if_unavailable=false \
    --enable-repo=terra \
    noctalia-greeter nwg-look

### Install LinuxToys from its latest GitHub release
##
## The RPM asset name embeds the version, so resolve the current asset from
## the GitHub API. The GITHUB_TOKEN build secret (wired up in build.yml and
## the Justfile) authenticates the request in CI to avoid unauthenticated
## API rate limits; local builds fall back to anonymous access. Daily image
## builds therefore automatically pick up every new LinuxToys release.

linuxtoys_url="$(/ctx/ghcurl https://api.github.com/repos/psygreg/linuxtoys/releases/latest \
    | jq -r '.assets[] | select(.name | test("linuxtoys-.*\\.x86_64\\.rpm$")).browser_download_url')"
echo "Fetching LinuxToys: ${linuxtoys_url}"
/ctx/ghcurl "${linuxtoys_url}" -o /tmp/linuxtoys.rpm
dnf5 install -y /tmp/linuxtoys.rpm
rm -f /tmp/linuxtoys.rpm

### Replace Lutris with Heroic Games Launcher
##
## Lutris (shipped by Bazzite) is removed in favor of Heroic Games
## Launcher, installed from its latest GitHub release the same way
## LinuxToys is: resolve the current RPM asset through the GitHub API and
## install it. The GITHUB_TOKEN build secret (wired up in build.yml and
## the Justfile) authenticates the request in CI to avoid unauthenticated
## API rate limits; local builds fall back to anonymous access. Daily
## image builds therefore automatically pick up every new Heroic release.
##
## Heroic's RPM unpacks into /opt/Heroic, but on bootc systems /opt is a
## symlink into /var (which the deployment does not take from the image),
## so the packaged tree could not be created during the build and would
## also be missing on deployed systems. Making /opt a regular image-owned
## directory instead keeps the application tree with the image; this is
## the workaround documented in the Containerfile's "[IM]MUTABLE /opt"
## note.

rm -rf /opt && mkdir /opt
dnf5 remove -y lutris

heroic_url="$(/ctx/ghcurl https://api.github.com/repos/Heroic-Games-Launcher/HeroicGamesLauncher/releases/latest \
    | jq -r '.assets[] | select((.name | endswith(".rpm")) and (.name | contains("linux-x86_64"))) | .browser_download_url')"
echo "Fetching Heroic: ${heroic_url}"
/ctx/ghcurl "${heroic_url}" -o /tmp/heroic.rpm
dnf5 install -y /tmp/heroic.rpm
rm -f /tmp/heroic.rpm

### Replace zram-generator with zswap
##
## Swap-on-zram is removed in favor of zswap: the kernel compresses swapped
## pages in RAM, backed by whatever swap device the user provides (swap file
## or partition, created outside of the image). The kernel is compiled with
## CONFIG_ZSWAP=y but disabled by default and with lzo as the default
## compressor, so the arguments in /usr/lib/bootc/kargs.d/20-gregos-zswap.toml
## apply the wanted configuration when bootc creates this image's deployment.
## For deployments that do not pick up bootc kernel arguments,
## gregos-zswap-setup.service mirrors the same values to /sys/kernel/zswap
## early on every boot (skipping any parameter already set on the kernel
## command line, so explicit overrides win). No swap device is shipped.

dnf5 remove -y zram-generator zram-generator-defaults
# The defaults ship an unowned fallback at /etc/systemd/zram-generator.conf
# that survives package removal; drop it explicitly.
rm -f /etc/systemd/zram-generator.conf

### Remove KDE Plasma and GNOME desktops and their tied applications
##
## The base image is Bazzite (Kinoite-based) and ships KDE Plasma. niri +
## Noctalia replaces it as the only desktop. Everything not tied to the
## desktop environments is kept: Steam, gamescope, drivers, ujust, Bazzite
## Portal, Waydroid, Cockpit, the audio stack, and so on. Bazaar is removed
## too: software and system management is centered on LinuxToys instead.
## Packages that depend on the removed ones are dropped automatically as
## well (krunner-bazaar is caught by the krunner pattern below).

REMOVE_PATTERNS='^(bazaar|xwaylandvideobridge|plasma-|kwin|kde|kf5-|kf6-|kio|kded|kinit|konsole|dolphin|kate|kwrite|ark|gwenview|okular|spectacle|kcalc|kfind|kdialog|kmenuedit|kinfocenter|ksystemlog|ksystemstats|kcharselect|kcolorchooser|skanpage|svgpart|kamera|print-manager|drkonqi|milou|kactivity|kwayland|kpipewire|kdecoration|breeze|oxygen|sddm|polkit-kde|xdg-desktop-portal-kde|layer-shell-qt|qqc2|libplasma|libkworkspace|libkdcraw|libkexiv2|libksane|kimageformat|khelpcenter|kfilemetadata|baloo|ksshaskpass|kwallet|krunner|kscreen|khotkeys|kuserfeedback|gnome-shell|gnome-session|gnome-settings-daemon|gnome-control-center|gnome-tour|gnome-initial-setup|gnome-software|gnome-classic-session|gnome-text-editor|gnome-calculator|gnome-font-viewer|gnome-logs|gnome-weather|gnome-maps|gnome-characters|gnome-clocks|gnome-contacts|gnome-connections|gnome-photos|gnome-screenshot|gnome-system-monitor)'

# Nautilus thumbnailing depends on this: see "Keep image thumbnailers" below.
KEEP_THUMBNAILERS='^(glycin-loaders|glycin-thumbnailer|ffmpegthumbnailer)$'

desktop_pkgs="$(rpm -qa --qf '%{NAME}\n' | grep -E "${REMOVE_PATTERNS}" | grep -Ev "${KEEP_THUMBNAILERS}" | sort -u || true)"
if [[ -n "${desktop_pkgs}" ]]; then
    echo "Removing desktop environment packages:"
    printf '%s\n' "${desktop_pkgs}"
    printf '%s\n' "${desktop_pkgs}" | xargs -r dnf5 -y remove
fi

# Bazaar's curated-flatpak configuration is baked into the base image (not
# owned by any RPM); remove it along with the app.
rm -rfv /usr/share/ublue-os/bazaar

### Remove Bold Brew (bbrew)
##
## Bazzite ships Bold Brew, a TUI front-end for managing Homebrew (and Flatpak)
## packages, as a convenience around `brew`. It is dead weight on this image:
## LinuxToys already covers package/software management and much more. Bold Brew
## is NOT an RPM - it arrives as image-owned files (a launcher .desktop entry, an
## icon, and a helper script that auto-installs the formula on first launch) plus
## a Homebrew formula. So:
##
##   1. remove the desktop integration files Bazzite ships for it,
##   2. strip any `ujust` recipe/references that surface it.
##
## Homebrew itself (and any formulae the user installed) is left untouched - only
## the Bold Brew wrapper/launcher is removed. `brew install bbrew` still works if
## it is ever wanted back.

for bbrew_file in \
    /usr/share/applications/bbrew.desktop \
    /usr/bin/bbrew-helper \
    /usr/share/ublue-os/bbrew.png \
    /usr/share/pixmaps/bbrew.png; do
    [[ -e "${bbrew_file}" ]] && rm -fv "${bbrew_file}"
done

# Surface removal: strip `bbrew` lines from Bazzite's ujust recipe files so the
# tool is not offered back through `ujust bbrew`. These are image-owned plain
# text files, so edit them in place where they mention bbrew.
shopt -s nullglob
for just_file in /usr/share/ublue-os/just/*.just; do
    if grep -q 'bbrew' "${just_file}"; then
        echo "Removing bbrew references from ${just_file}"
        sed -i '/bbrew/d' "${just_file}"
    fi
done
shopt -u nullglob

### Input method: fcitx5
##
## GTK 4.20 (GNOME 49+) no longer implements dead-key/X11-style compose
## sequences itself on Wayland: it delegates composing to an input-method
## framework via the text-input protocol, and Qt's Wayland text-input path
## likewise does no composing. Bazzite already ships fcitx5, but incompletely
## (no GUI configurator, no toolkit integration modules), which produced
## inconsistent dead-key behaviour across apps — some toolkits fell back to
## built-in compose handling (one reason BlackBox worked while e.g. GNOME
## Text Editor did not), others received dead keys as plain keysyms. Install
## the full stack so one framework handles composing everywhere:
##
##   fcitx5              core daemon + engine
##   fcitx5-gtk          input-context modules for GTK2/GTK3/GTK4
##   fcitx5-qt           input-context modules for Qt5/Qt6
##   fcitx5-configtool   config GUI (fcitx5-config-qt) + KCM page
##
## Engine packages are pre-installed so a shipped image covers the locales
## that need real IME input out of the box. They are inactive by default:
## fcitx5's default profile only has "keyboard"-type engines, so plain
## us-intl/other layouts keep composing dead keys by default and the
## engine only becomes active when the user selects it in fcitx5-config-qt.
##
##   fcitx5-mozc [...] Japanese (Mozc engine; GoogleNotoSansCJK is already
##                                       installed for its glyph needs)
##   fcitx5-chinese-addons [...] Simplified/Traditional Chinese
##                                       (Pinyin, Bopomofo, Cangjie, Wu)
##   fcitx5-hangul, fcitx5-libthai, fcitx5-m17n, fcitx5-table-extra [...]
##
## The niri session starts fcitx5 (spawn-at-startup) and exports
## GTK_IM_MODULE/QT_IM_MODULE/XMODIFIERS=fcitx (dotfiles/niri/config.kdl), so
## GTK and Qt apps compose dead keys and accents through fcitx5. Layout and
## engine settings are user-configurable with the fcitx5-config-qt GUI.
##
## Flatpak apps do not inherit session environment. system_files carries
## /etc/flatpak/overrides/global (the system-wide override Flatpak merges for
## every installed app) so Flatpaks get the same IM environment without any
## user action. Setting these env vars only switches which input-context
## module the toolkits load: with an fcitx5 module installed (present in the
## freedesktop runtimes) apps talk to fcitx5, and for apps whose module is
## missing GTK/Qt just log a warning and fall back to their default — the
## env override never breaks plain (Latin, dead-key) input.
##
## NOTE: this must stay AFTER the desktop-environment cleanup below. It is
## placed inside the cross-desktop applications transaction on purpose:
## fcitx5-configtool depends on KDE Frameworks (kf6-*) packages, which the
## cleanup's broad `kf6-`/`kde` removal patterns would otherwise strip again,
## leaving fcitx5-configtool broken.

### Install selected cross-desktop applications
##
## These applications are useful in the niri + Noctalia session without
## installing either full desktop environment. Install them after the desktop
## package cleanup above: its broad KDE prefix also matches kde-connect.
##
## Fedora's greetd PAM file already contains optional gnome-keyring auth and
## session hooks; the leading '-' only silences errors if a module is missing.
## gnome-keyring-pam supplies the module that makes those hooks work.

dnf5 install -y \
    nautilus \
    gnome-keyring \
    gnome-keyring-pam \
    gnome-disk-utility \
    gnome-calculator \
    gnome-text-editor \
    ffmpegthumbnailer \
    glycin-thumbnailer \
    glycin-loaders \
    loupe \
    blackbox-terminal \
    showtime \
    kde-connect \
    wlsunset \
    cava \
    fcitx5 \
    fcitx5-gtk \
    fcitx5-qt \
    fcitx5-configtool \
    fcitx5-mozc \
    fcitx5-chinese-addons \
    fcitx5-anthy \
    fcitx5-hangul \
    fcitx5-libthai \
    fcitx5-m17n \
    fcitx5-table-extra

### Keep image thumbnailers
##
## Nautilus thumbnails images and videos through the thumbnailer entries in
## /usr/share/thumbnailers. Images are covered by the glycin-* entries owned
## by glycin-loaders (JPEG/PNG/GIF/WebP/TIFF/BMP/SVG/... via glycin-image-rs,
## plus AVIF/HEIF, JXL), videos by ffmpegthumbnailer. Both ship with the base
## image already - ffmpegthumbnailer is listed with the apps below to pin it,
## and KEEP_THUMBNAILERS keeps any of them out of the desktop cleanup. So
## images need nothing extra on top of that.
##
## Fail the build if a base image ever stops shipping an image thumbnailer, so
## the regression is caught at build time instead of showing up as icons-only
## in the file manager.

if [[ ! -e /usr/share/thumbnailers/glycin-image-rs.thumbnailer ]] \
    || [[ ! -e /usr/bin/glycin-thumbnailer ]]; then
    echo "no image thumbnailer is installed (glycin-loaders missing)" >&2
    exit 1
fi

### Debloat: drop unused and duplicated packages
##
## Everything below is dead weight on a gaming/desktop image: either nothing
## uses it at runtime, or it duplicates a stack gregOS does not use. Verified
## leaves (no other installed package Requires them) and full clusters, so the
## removal is safe and self-contained. The base image (Bazzite) keeps drifting,
## so this section only removes what is actually present: a name that is not
## installed is skipped rather than failing the build.
##
## install_weak_deps=False on the removal keeps dnf from re-pulling anything the
## base image weakly Recommends into the gaps (e.g. mariadb Recommends
## mariadb-server, gtk3/qt weakly recommend the ibus input modules). Removing the
## whole cluster (rather than one member) means no leftover member is left to
## pull its siblings back in.
##
## --- MariaDB server (~~132 MB) ---
## A full MariaDB SERVER on a desktop. Nothing Requires it: it is an orphan of
## the KDE PIM/akonadi stack that the desktop cleanup above strips. The generic
## client library (mariadb-connector-c[-config]) is kept - it is a normal shared
## library other code can link against.
##
## --- ibus input-method framework (~~370 MB) ---
## gregOS standardises input on fcitx5 (installed above) with mozc / chinese /
## anthy / hangul / libthai / m17n engines. ibus is a second, redundant IM
## framework. Its engines' runtime libraries are NOT part of this removal and are
## kept because fcitx5 consumes them directly:
##   anthy, anthy-unicode, m17n-lib, m17n-db, libthai, libthai-data, libime*
## (fcitx5-anthy -> libanthy.so.0 from anthy; fcitx5-m17n -> m17n-lib;
##  fcitx5-libthai -> libthai). kasumi-unicode is the anthy dictionary EDITOR and
## is only held by ibus-anthy; it goes with ibus. unicode-ucd is large Unicode
## character data that only ibus-typing-booster consumed; glibc and the CJK/IME
## stacks do their own Unicode handling, so it is safe to drop.
##
## --- unused leaf applications (~~50 MB) ---
## makemkv (DVD/Blu-ray ripper), stress-ng (load tester),
## virtualbox-guest-additions (only useful inside a VirtualBox guest).
##
## --- vim: keep a bare vi, drop the full editor (~~43 MB) ---
## We keep the minimal `vi` (vim-minimal) as a rescue editor but drop the full
## `vim` editor and its GUI/runtime. IMPORTANT dependency detail: vim-minimal
## hard-Requires vim-data (its runtime syntax/indent files), and vim-data is in
## turn Requirs'd by vim-common. So keeping a working `vi` means keeping BOTH
## vim-minimal AND vim-data; removing vim-data would drag vim-minimal out with
## it and leave no `vi`. We therefore remove only:
##   vim-enhanced (the `vim` editor), vim-common (shared vimscript), vim-filesystem
## and KEEP:
##   vim-minimal (provides /usr/bin/vi and `vi`), vim-data (its runtime)
## nano is also installed as a second editor, so the image always has one.

# Remove only names that are actually installed. dnf5 is a no-op for names that
# are not present, but the rpm -q filter below keeps the build log honest about
# what this image really dropped (and tolerates base-image drift).
DEBLOAT_MARIADB='mariadb-server mariadb mariadb-backup mariadb-errmsg
    mariadb-common mariadb-gssapi-server mariadb-cracklib-password-check
    mysql-selinux qt6-qtbase-mysql'

# Full ibus cluster (framework + engines + panel + setup + python bindings +
# the pinyin lib/data and the typing-booster emoji data it dragged in).
DEBLOAT_IBUS='ibus ibus-libs ibus-gtk3 ibus-gtk4 ibus-panel ibus-setup
    python3-ibus ibus-anthy ibus-anthy-python ibus-hangul ibus-libpinyin
    ibus-m17n ibus-chewing ibus-typing-booster libpinyin libpinyin-data
    cldr-emoji-annotation cldr-emoji-annotation-dtd kasumi-unicode
    unicode-ucd'

DEBLOAT_APPS='makemkv stress-ng virtualbox-guest-additions'

# vim: drop the full editor, keep the bare `vi`. vim-minimal and vim-data are
# intentionally NOT listed (see the note above) - they provide /usr/bin/vi.
DEBLOAT_VIM='vim-enhanced vim-common vim-filesystem'

debloat_pkgs=""
for debloat_group in "${DEBLOAT_MARIADB}" "${DEBLOAT_IBUS}" "${DEBLOAT_APPS}" "${DEBLOAT_VIM}"; do
    # shellcheck disable=SC2086  # intentional word-splitting of the package lists
    for pkg in ${debloat_group}; do
        if rpm -q "${pkg}" >/dev/null 2>&1; then
            debloat_pkgs+=" ${pkg}"
        fi
    done
done

if [[ -n "${debloat_pkgs// /}" ]]; then
    echo "Debloat: removing unused/duplicated packages:${debloat_pkgs}"
    # shellcheck disable=SC2086  # intentional word-splitting
    dnf5 -y --setopt=install_weak_deps=False remove ${debloat_pkgs}
else
    echo "Debloat: nothing from the removal set is installed; skipping"
fi

# Fail the build if a future greetd package drops either existing PAM hook;
# installing the module alone would then no longer unlock/start the keyring.
if ! grep -Eq '^-?auth[[:space:]]+optional[[:space:]]+pam_gnome_keyring\.so([[:space:]]|$)' /etc/pam.d/greetd \
    || ! grep -Eq '^-?session[[:space:]]+optional[[:space:]]+pam_gnome_keyring\.so[[:space:]]+auto_start([[:space:]]|$)' /etc/pam.d/greetd; then
    echo "Fedora greetd PAM configuration is missing the GNOME Keyring hooks" >&2
    exit 1
fi

### Apply image-owned files after RPM transactions
##
## Package installs can create or replace files under /usr and /etc. Apply
## system_files afterwards so gregOS defaults and unit overrides win.

cp -avf "/ctx/system_files"/. /

### Deploy the shipped niri + Noctalia configuration
##
##  - /etc/niri/ holds the canonical, image-managed compositor configuration
##  - /usr/share/niri/defaults/config.kdl is the small per-user wrapper
##  - /etc/skel and the boot seeder put the wrapper in user homes; the seeder
##    migrates only unmodified configs from older gregOS images
##  - Noctalia's TOML defaults are seeded only when the user has no copy

mkdir -p /etc/niri /usr/share/gregos/niri /usr/share/gregos/noctalia
cp -avf /ctx/dotfiles/niri/. /usr/share/gregos/niri/
cp -avf /ctx/dotfiles/niri/. /etc/niri/
cp -avf /ctx/dotfiles/noctalia/. /usr/share/gregos/noctalia/

mkdir -p /etc/skel/.config/niri /etc/skel/.config/noctalia
cp -avf /usr/share/niri/defaults/config.kdl /etc/skel/.config/niri/config.kdl
cp -avf /ctx/dotfiles/niri/noctalia.kdl /etc/skel/.config/niri/noctalia.kdl
cp -avf /ctx/dotfiles/noctalia/. /etc/skel/.config/noctalia/

# Validate both the system config and the per-user wrapper, including includes.
niri validate -c /etc/niri/config.kdl
niri validate -c /usr/share/niri/defaults/config.kdl

### Login manager: greetd + Noctalia Greeter
##
## Replaces KDE's login manager (plasma-login-manager / SDDM). The greeter
## runs as the "greeter" system account and offers the niri session. Its
## setup service (gregos-noctalia-greeter-setup.service, pulled in by the
## greetd.service drop-in) grants the greeter DRM/input group access and
## initializes Noctalia's persistent state before greetd starts.
##
## The greeter command is gregOS's own wrapper, /usr/libexec/gregos/noctalia-greeter-render,
## NOT noctalia-greeter-session directly. The Noctalia greeter runs its own
## bundled wlroots compositor, and wlroots only falls back to the software
## (pixman) renderer when there is NO render node - on real hardware a renderer
## failure is fatal and blank-screens the login. The wrapper tries the hardware
## renderers first and retries pinned to pixman so the greeter always comes up.
## See the wrapper's header comment for details and override variables.

cat > /etc/greetd/config.toml <<'EOF'
# Managed by gregOS - greetd running the Noctalia greeter
[terminal]
vt = 1

[default_session]
command = "/usr/libexec/gregos/noctalia-greeter-render"
user = "greeter"
EOF

systemctl disable sddm.service 2>/dev/null || true
systemctl disable plasma-login-manager.service 2>/dev/null || true
systemctl disable gdm.service 2>/dev/null || true
systemctl enable greetd.service
ln -sfn /usr/lib/systemd/system/greetd.service /etc/systemd/system/display-manager.service

systemctl enable gregos-niri-config-seed.service
systemctl enable gregos-zswap-setup.service

#### Example for enabling a System Unit File

systemctl enable podman.socket

### Snap package support
##
## snapd is layered on so the system can install and run snaps in addition to
## Flatpaks. Getting this to work properly on an immutable bootc/ostree system
## takes more than just installing the RPMs, so the pieces are spelled out
## below.
##
## Packages:
##   snapd          - the daemon and the `snap` CLI. Pulls in snap-confine and
##                    (on Fedora) requires snapd-selinux.
##   snapd-selinux  - the SELinux policy module (snappy) for snapd and its
##                    state directories. Bazzite runs SELinux in enforcing mode,
##                    so this is not optional.
##   squashfuse     - fallback squashfs mounting for snap images when the
##                    squashfs kernel module is unavailable (containers, or a
##                    kernel built without it).
##
## snapd itself requires `((squashfuse and fuse) or kmod(squashfs.ko))`, so
## installing it here also verifies that the image can mount .snap squashfs
## images one way or another.

dnf5 install -y snapd snapd-selinux squashfuse

## /snap: the classic-confinement mount point
##
## snapd accepts exactly two layouts for where snaps live:
##   * /snap as a real directory (Ubuntu default), or
##   * /snap as a symlink to /var/lib/snapd/snap (Fedora/Arch convention).
##
## Fedora's snapd uses /var/lib/snapd/snap and does NOT ship the symlink - on a
## normal Fedora you create it by hand after installing snapd. Without it,
## strictly confined snaps still run, but anything needing classic confinement
## (`snap install code --classic` and friends) is rejected with "classic
## confinement requires snaps under /snap or symlink from /snap to
## /var/lib/snapd/snap".
##
## On bootc/ostree the root filesystem is read-only, so the link has to exist
## in the IMAGE, not be created on the installed system. It is created here
## (after the package transactions) as a relative symlink exactly like the one
## the snapd spec builds for Amazon Linux:
##
##   /snap -> var/lib/snapd/snap
##
## A relative target is used deliberately: /var/lib/snapd/snap is the
## persistent, writable state directory, so the link resolves correctly in the
## build container, in the image, and on every deployed system.
##
## system_files cannot carry this link: systemd-tmpfiles refuses to create
## paths that are symlinks pointing outside /var or /run.

if [[ -e /snap || -L /snap ]]; then
    echo "/snap already exists in the image; leaving it untouched" >&2
else
    ln -sr /var/lib/snapd/snap /snap
fi

# Fail the build if the link is wrong - this is the exact regression that makes
# classic snaps uninstallable.
if [[ ! -L /snap ]] || [[ "$(readlink /snap)" != "var/lib/snapd/snap" ]]; then
    echo "/snap is not a symlink to var/lib/snapd/snap (got: $(readlink /snap 2>/dev/null || echo 'not a symlink'))" >&2
    exit 1
fi

## snapd runtime state under /var
##
## The snapd RPM ships these directories, but on bootc/ostree the image's /var
## content is not carried onto deployed hosts (ostree keeps the host's /var and
## only seeds it at first install), and `bootc container lint` warns about image
## /var content without matching tmpfiles.d entries. gregos-snapd.conf declares
## every directory the package expects, so they are created on every boot with
## the right ownership.

## snapd.socket and the mount propagation units
##
## snapd is socket-activated on Fedora: only snapd.socket is enabled and the
## daemon starts on first use. Fedora's snapd does NOT ship
## var-lib-snapd-snap.mount / var-snap.mount (upstream snapd does, the Fedora
## spec drops them along with the /snap symlink), but snapd still wants those
## directories to be mount points with shared propagation so snap refreshes and
## mount namespaces propagate correctly (LP: #1668759) and parallel-installed
## classic snaps work at all.
##
## The units are therefore shipped as image-owned files (system_files) and
## enabled here. They are self-bind mounts with `rbind,private,shared` and are
## skipped by their Conditions when snapd has already preserved a mount
## namespace, so they are safe to enable unconditionally.

systemctl enable snapd.socket
systemctl enable var-lib-snapd-snap.mount var-snap.mount

# Verify the units we ship are the ones systemd will pick up. Fedora's snapd
# has no [Install] section on these units in some releases, so the enablement
# symlinks are created above; make sure that actually happened.
for unit in snapd.socket var-lib-snapd-snap.mount var-snap.mount; do
    if ! systemctl is-enabled "${unit}" >/dev/null 2>&1; then
        echo "systemd unit '${unit}' is not enabled after enablement" >&2
        exit 1
    fi
done
