#!/bin/bash

set -ouex pipefail

# Userspace GPU stack this image targets. gregOS and gregOS-nova share the
# standard Bazzite base, so the variant cannot always be inferred from
# BASE_IMAGE; an explicit value also lets CI catch a mistyped matrix entry
# before the rest of the build runs.
image_variant="${IMAGE_VARIANT:-standard}"
case "${image_variant}" in
    standard|nvidia|nvidia-open|nova) ;;
    *)
        echo "unknown IMAGE_VARIANT '${image_variant}' (expected standard, nvidia, nvidia-open or nova)" >&2
        exit 1
        ;;
esac

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

## This transaction refreshes DNF's metadata (--refresh) on purpose: the base
## image carries the repo metadata from ITS OWN build, days older. Without a
## refresh installs resolve against that stale snapshot: a plain
## `dnf install noctalia` once resolved to the F45 GA's noctalia 5.3.0, which
## supports config_version 15, while config settings written by 5.4.x use
## config_version 16 — every user with an existing Noctalia state file then
## saw "config_version: version 16 is newer than supported version 15" at
## login. Resolving against live repo metadata keeps the image on the current
## updates version, in line with what Fedora supports for the user config.

dnf5 install -y --refresh \
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

### Remove game launchers and compatibility tools
##
## gregOS is a general-purpose image: it does not ship game launchers or game
## compatibility tools. Users install them at post-install time through
## LinuxToys or Nix; the host graphics stack (gamescope, GPU drivers, 32-bit
## libraries and the Nix graphics bundles) stays, so those packages work
## normally when installed.
##
## Bazzite ships Steam and Lutris as RPMs. Steam also comes with Bazzite-owned
## launcher wrappers and a per-user autostart entry that are not owned by the
## steam package, so removing the package alone would leave a Steam entry in
## the app launcher and start Steam at login. Remove the whole set explicitly.
## Steam's dependency chain is kept: steam-devices (controller udev rules) is
## hardware support, and gamescope/drivers are shared with Nix and Flatpak
## gaming software.
##
## Protontricks is not an RPM either: Bazzite ships two wrapper scripts that
## run its Flatpak. ProtonPlus is not installed in the container image at all;
## it is only offered by a ujust recipe and by Bazzite Portal (yafti). Remove
## those hooks so neither can offer or launch the apps. The Flatpak
## applications themselves, when present, live under /var and are user state:
## an installed system rebased from Bazzite keeps them until the user
## uninstalls them, and fresh deployments never get them from this image.
##
## Removing Heroic used to require making /opt an image-owned directory (its
## RPM unpacked into /opt/Heroic). With Heroic gone, /opt keeps Bazzite's
## default /var/opt symlink.

game_pkgs=""
for game_pkg in heroic lutris steam; do
    if rpm -q "${game_pkg}" >/dev/null 2>&1; then
        game_pkgs+=" ${game_pkg}"
    fi
done
if [[ -n "${game_pkgs// /}" ]]; then
    echo "Removing game launchers:${game_pkgs}"
    # shellcheck disable=SC2086  # intentional word-splitting of the list
    dnf5 -y --setopt=install_weak_deps=False remove ${game_pkgs}
else
    echo "No game launcher RPMs are installed; skipping"
fi

# Bazzite's Steam entry points, none of them owned by the steam RPM.
for steam_file in \
    /usr/bin/steam \
    /usr/bin/steamrestart \
    /usr/bin/bazzite-steam \
    /usr/bin/bazzite-steam-bpm \
    /usr/bin/bazzite-steam-firstrun \
    /usr/share/applications/steam.desktop \
    /usr/share/applications/bazzite-steam-bpm.desktop \
    /etc/skel/.config/autostart/steam.desktop; do
    rm -fv "${steam_file}"
done

# The steam RPM owns the empty /usr/lib/systemd/{system,user}.conf.d drop-in
# directories in the base image, and it also ships Bazzite's Proton/Wine esync
# file-descriptor limit there. Recreate the generic directories (the shader
# cache drop-in below writes into system.conf.d) and keep the limit as
# image-owned drop-ins, because games installed through Nix/Flatpak still hit
# it when Proton/Wine starts.
for systemd_conf_dir in /usr/lib/systemd/system.conf.d /usr/lib/systemd/user.conf.d; do
    install -d "${systemd_conf_dir}"
    cat > "${systemd_conf_dir}/10-gregos-nofile.conf" <<'EOF'
[Manager]
# Raise the file descriptor limit for Proton/Wine esync (Proton 5+ expects a
# hard limit of 1048576). Bazzite previously shipped this with the steam RPM.
DefaultLimitNOFILE=1024:1048576
EOF
done

# Protontricks' Flatpak wrappers.
rm -fv /usr/bin/protontricks /usr/bin/protontricks-launch

# Bazzite's Flatpak manager only carried a Protontricks override; drop the
# block so no Protontricks configuration is left in the image.
if [[ -e /usr/libexec/bazzite-flatpak-manager ]] \
    && grep -q 'com\.github\.Matoking\.protontricks' /usr/libexec/bazzite-flatpak-manager; then
    sed -i '/^# Fix permissions for Protontricks$/,/^  com\.github\.Matoking\.protontricks$/d' \
        /usr/libexec/bazzite-flatpak-manager
fi

# ProtonPlus: remove the ujust recipe and its import, then its Bazzite Portal
# entry (the list item runs until the next sibling action).
rm -fv /usr/share/ublue-os/just/94-bazzite-protonplus.just
if [[ -e /usr/share/ublue-os/justfile ]]; then
    sed -i '\#^import "/usr/share/ublue-os/just/94-bazzite-protonplus\.just"$#d' \
        /usr/share/ublue-os/justfile
fi
if [[ -e /usr/share/yafti/yafti.yml ]] \
    && grep -q '^      - id: "proton-plus"$' /usr/share/yafti/yafti.yml; then
    awk '
        /^      - id: "/ {
            if ($0 ~ /^      - id: "proton-plus"$/) { skip = 1; next }
            skip = 0
        }
        /^  - title:/ { skip = 0 }
        !skip
    ' /usr/share/yafti/yafti.yml > /usr/share/yafti/yafti.yml.new
    mv /usr/share/yafti/yafti.yml.new /usr/share/yafti/yafti.yml
fi

# Fail the build if a removed launcher, wrapper or offer comes back through a
# base-image update. Every path here is image-owned; user Flatpaks under /var
# are deliberately not checked.
for removed_bin in latencydevil protontricks protontricks-launch \
                   bazzite-steam bazzite-steam-bpm bazzite-steam-firstrun \
                   steam steamrestart; do
    if [[ -e "/usr/bin/${removed_bin}" ]]; then
        echo "'${removed_bin}' is still present in /usr/bin" >&2
        exit 1
    fi
done

for removed_file in \
    /usr/share/applications/bazzite-steam-bpm.desktop \
    /usr/share/applications/steam.desktop \
    /etc/skel/.config/autostart/steam.desktop \
    /usr/share/ublue-os/just/94-bazzite-protonplus.just; do
    if [[ -e "${removed_file}" ]]; then
        echo "'${removed_file}' is still present after the gaming cleanup" >&2
        exit 1
    fi
done

for game_pkg in heroic lutris steam; do
    if rpm -q "${game_pkg}" >/dev/null 2>&1; then
        echo "game launcher package '${game_pkg}' is still installed" >&2
        exit 1
    fi
done

if grep -q '94-bazzite-protonplus\.just' /usr/share/ublue-os/justfile 2>/dev/null; then
    echo "the ujust file still imports the ProtonPlus recipe" >&2
    exit 1
fi
if grep -q 'com\.github\.Matoking\.protontricks' /usr/libexec/bazzite-flatpak-manager 2>/dev/null; then
    echo "the Flatpak manager still configures Protontricks" >&2
    exit 1
fi
if grep -q 'id: "proton-plus"' /usr/share/yafti/yafti.yml 2>/dev/null; then
    echo "Bazzite Portal still offers ProtonPlus" >&2
    exit 1
fi

### Built-in: niri-resume session save/restore helper on PATH
##
## gregOS ships the niri-resume session save/restore helper
## (https://github.com/psygreg/niri-resume) as an image built-in, next to
## helpers like the niri display-setup script. niri has no
## end-of-session hook, so the session-ending actions themselves run the tool:
## Noctalia's Log out / Shut down / Reboot actions are overridden (see
## dotfiles/noctalia/15-gregos-session-actions.toml) to run
## "niri-resume save-quit" / "save-shutdown" / "save-reboot", the compositor's
## Mod+Shift+E / Ctrl+Alt+Delete quit binds and the physical power button
## (XF86PowerOff, with logind's short-press handling ignored through a
## logind.conf.d drop-in) run the same commands, and each of them writes a
## snapshot of the open apps (workspace, size, maximized/fullscreen state,
## position) before performing the action itself, so there is no race
## between saving and exiting. At the start of the next session niri's
## spawn-at-startup (the last entry in dotfiles/niri/config.kdl) runs
## "niri-resume restore", which relaunches the recorded apps with their
## original command lines and re-places their windows.
##
## It ships as a single self-contained binary named "niri-resume" with no
## package to install: download it from the latest release the same way
## LinuxToys above is fetched - resolve the current asset through the GitHub
## API. The GITHUB_TOKEN build secret (wired up in build.yml and the Justfile)
## authenticates the request in CI to avoid unauthenticated API rate limits;
## local builds fall back to anonymous access. Daily image builds therefore
## automatically pick up every new niri-resume release.

niri_resume_url="$(/ctx/ghcurl https://api.github.com/repos/psygreg/niri-resume/releases/latest \
    | jq -r '.assets[] | select(.name == "niri-resume") | .browser_download_url')"
echo "Fetching niri-resume: ${niri_resume_url}"
/ctx/ghcurl "${niri_resume_url}" -o /tmp/niri-resume
install -m 0755 /tmp/niri-resume /usr/bin/niri-resume
rm -f /tmp/niri-resume

# Fail the build if the binary did not land on PATH as an executable - nothing
# else ships it, and both the Noctalia session commands and the
# spawn-at-startup restore resolve "niri-resume" through PATH only.
if [[ ! -x /usr/bin/niri-resume ]]; then
    echo "niri-resume is missing from /usr/bin after installation" >&2
    exit 1
fi

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
## desktop environments is kept: gamescope, drivers, ujust, Bazzite Portal,
## Waydroid, Cockpit, the audio stack, and so on. Game launchers and
## compatibility tools were already removed by the gaming cleanup above.
## Bazaar is removed too: software and system management is centered on
## LinuxToys instead. Packages that depend on the removed ones are dropped
## automatically as well (krunner-bazaar is caught by the krunner pattern
## below).

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

### Input method: ibus
##
## GTK 4.20 (GNOME 49+) no longer implements dead-key/X11-style compose
## sequences itself on Wayland: it delegates composing to an input-method
## framework via the text-input protocol, and Qt's Wayland text-input path
## likewise does no composing. So dead keys only appear in an app when a real
## input method is RUNNING and the app is actually talking to it.
##
## gregOS previously standardised on fcitx5, but Bazzite dropped the fcitx5
## stack from its base image over packaging issues upstream. The image now
## standardises on ibus, which the base ships complete and Fedora maintains:
##
##   ibus                   core daemon + the XKB "keyboard" engines
##   ibus-gtk3 / ibus-gtk4  input-context modules for GTK3 / GTK4
##   (Qt5/Qt6 ship their own ibus input-context plugin inside qt6-qtbase)
##
## This section pins that stack explicitly so a future base image cannot
## silently drop it, and adds the language engines:
##
##   ibus-anthy           Japanese (GoogleNotoSansCJK is already installed
##                        for its glyph needs)
##   ibus-libpinyin       Simplified Chinese (Pinyin)
##   ibus-chewing         Traditional Chinese (Bopomofo/Zhuyin)
##   ibus-hangul          Korean
##   ibus-m17n            Thai, Vietnamese, Indic and the rest of the m17n
##                        catalogue
##   ibus-typing-booster  emoji/unicode prediction, works on any layout
##
## ibus can run without any IME configured: its XKB "keyboard" engines
## (xkb:us:intl:eng and friends, provided by ibus-engine-simple) compose dead
## keys through ibus itself, so plain us-intl and other Latin layouts keep
## working out of the box and the IME engines only become active when the
## user selects one in ibus-setup.
##
## The niri session starts ibus-daemon (spawn-at-startup, replace + XIM so
## Xwayland apps compose too) and exports
## GTK_IM_MODULE/QT_IM_MODULE/XMODIFIERS=ibus (dotfiles/niri/config.kdl), so
## GTK and Qt apps compose dead keys and accents through ibus. Engines are
## user-configurable with the ibus-setup GUI.
##
## To keep dead-key composing identical for every fresh account, system_files
## carries a dconf system default (/etc/dconf/db/local.d/00-gregos-ibus)
## preloading the xkb:us:intl keyboard engine, so us-intl composes without
## any first-run input-method action; users override it in ibus-setup.
##
## Flatpak apps do not inherit session environment. system_files carries
## /etc/flatpak/overrides/global (the system-wide override Flatpak merges for
## every installed app) so Flatpaks get the same IM environment without any
## user action. Setting these env vars only switches which input-context
## module the toolkits load. The module must be inside the app's sandbox and
## runtimes differ: the GNOME runtime ships it for GTK3 and GTK4, the
## freedesktop runtime only for GTK3. Apps whose runtime lacks it log a
## warning and fall back to their default input handling — the env override
## never breaks plain (Latin, dead-key) input. See the README for the
## per-app `GTK_IM_MODULE=simple` fallback.
##
## There is a third launch path that sees NONE of the above: systemd/D-Bus
## activation of desktop apps. When a .desktop file sets DBusActivatable=true
## (all of the GNOME apps Text Editor, Loupe, Showtime, Disk Utility,
## Seahorse, Nautilus itself, ...), launching it through
## org.freedesktop.Application — which is exactly what a file manager's
## "Open with..." context menu does — does not fork/exec the app as a child
## of the caller. The app is spawned as a --gapplication-service child of
## the systemd user manager, with the manager's environment instead of the
## caller's. That manager environment is imported from the login flow by
## niri-session (systemctl --user import-environment) BEFORE niri runs, so
## it never contains variables that only exist inside the niri session: apps
## spawned this way have no GTK_IM_MODULE, and since GTK 4.20 delegates
## dead-key composing to an input-method framework (the rationale at the top
## of this section), dead keys were dead precisely in those apps while
## working from each launcher-spawned app. system_files therefore carries
## /usr/lib/environment.d/10-gregos-ibus.conf, the same variables as a
## systemd environment.d drop-in: the user manager applies it at startup, so
## D-Bus-activated apps (and everything else started as a user unit) inherit
## the IM environment too. Session-spawned apps then see the variables twice
## with identical values, which is harmless, and a user's own
## ~/.config/environment.d keeps winning over /usr/lib settings.

### Install selected cross-desktop applications
##
## These applications are useful in the niri + Noctalia session without
## installing either full desktop environment. Install them after the desktop
## package cleanup above: its broad KDE prefix also matches kde-connect.
##
## Fedora's greetd PAM file contains optional gnome-keyring auth and session
## hooks; the leading '-' only silences errors if a module is missing.
## gnome-keyring-pam supplies the module that makes those hooks work.
## Fedora moved greetd's PAM file to /usr/lib/pam.d/greetd in Fedora 45
## (previously /etc/pam.d/greetd); /etc/pam.d still takes precedence when a
## copy exists there, so both layouts receive the same hooks.

dnf5 install -y \
    nautilus \
    gnome-keyring \
    gnome-keyring-pam \
    seahorse \
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
    ibus \
    ibus-gtk3 \
    ibus-gtk4 \
    ibus-anthy \
    ibus-hangul \
    ibus-libpinyin \
    ibus-chewing \
    ibus-m17n \
    ibus-typing-booster

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
## mariadb-server, so removing mariadb-server could pull mariadb back in).
## Removing the whole cluster (rather than one member) means no leftover member
## is left to pull its siblings back in.
##
## --- MariaDB server (~~132 MB) ---
## A full MariaDB SERVER on a desktop. Nothing Requires it: it is an orphan of
## the KDE PIM/akonadi stack that the desktop cleanup above strips. The generic
## client library (mariadb-connector-c[-config]) is kept - it is a normal shared
## library other code can link against.
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

DEBLOAT_APPS='makemkv stress-ng virtualbox-guest-additions'

# vim: drop the full editor, keep the bare `vi`. vim-minimal and vim-data are
# intentionally NOT listed (see the note above) - they provide /usr/bin/vi.
DEBLOAT_VIM='vim-enhanced vim-common vim-filesystem'

debloat_pkgs=""
for debloat_group in "${DEBLOAT_MARIADB}" "${DEBLOAT_APPS}" "${DEBLOAT_VIM}"; do
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

# The two removal passes above are the only ones that may touch credential
# storage; make sure neither of them dragged seahorse out with the GNOME apps
# (it is the only management UI for the keyring this image ships).
if ! rpm -q seahorse >/dev/null 2>&1; then
    echo "seahorse (the GNOME Keyring manager) was removed with the desktop packages" >&2
    exit 1
fi

### Verify the input-method stack survived every removal
##
## The ibus stack is installed in the transaction above, and the debloat right
## after it drops another batch of packages. dnf removal drags out dependents
## too, so one wrong entry in a removal list would silently take the input
## method with it and bring the dead-key bug straight back. Fail the build
## instead:
##
##   1. ibus and its toolkit input-context modules have to be installed -
##      without them GTK/Qt have nothing to compose with (the whole point of
##      the section above),
##   2. the XKB "keyboard" engine catalog has to be present (it is what
##      composes dead keys before any IME is configured),
##   3. the bare `vi` has to survive the vim debloat (vim-minimal + vim-data),
##   4. and fcitx5 has to actually be GONE - one input-method framework only,
##      so a future base image that re-grows an fcitx5 autostart cannot race
##      ibus.

for im_pkg in ibus ibus-gtk3 ibus-gtk4 ibus-anthy ibus-hangul ibus-libpinyin \
              ibus-chewing ibus-m17n ibus-typing-booster; do
    if ! rpm -q "${im_pkg}" >/dev/null 2>&1; then
        echo "input-method package '${im_pkg}' is missing after the removal steps" >&2
        exit 1
    fi
done

if [[ ! -e /usr/sbin/ibus-daemon ]]; then
    echo "ibus-daemon is missing (ibus incomplete)" >&2
    exit 1
fi

if [[ ! -e /usr/lib64/gtk-3.0/3.0.0/immodules/im-ibus.so ]] \
    || [[ ! -e /usr/lib64/gtk-4.0/4.0.0/immodules/libim-ibus.so ]] \
    || [[ ! -e /usr/lib64/qt6/plugins/platforminputcontexts/libibusplatforminputcontextplugin.so ]]; then
    echo "an ibus toolkit input-context module is missing (GTK3/GTK4/Qt6)" >&2
    exit 1
fi

# The XKB keyboard engines live in the ibus "simple" component catalog; our
# dconf default preloads xkb:us:intl:eng out of it, so the exact engine has to
# exist (see dotfiles for what is preloaded).
if ! grep -qw 'xkb:us:intl:eng' /usr/share/ibus/component/simple.xml 2>/dev/null; then
    echo "ibus keyboard engine catalog (simple.xml) is missing xkb:us:intl:eng" >&2
    exit 1
fi

if ! command -v vi >/dev/null 2>&1; then
    echo "the bare 'vi' editor is missing after the vim debloat" >&2
    exit 1
fi

for legacy_im_pkg in fcitx5 fcitx5-gtk fcitx5-qt fcitx5-configtool; do
    if rpm -q "${legacy_im_pkg}" >/dev/null 2>&1; then
        echo "legacy input-method package '${legacy_im_pkg}' is installed; gregOS standardises on ibus only" >&2
        exit 1
    fi
done

### Credential storage: GNOME Keyring unlock through the PAM flow
##
## Applications such as Zed store their tokens through the freedesktop Secret
## Service (libsecret). Two things have to hold for them to stay silent:
##
##   1. org.freedesktop.secrets must be owned by gnome-keyring, and
##   2. that daemon must be the one that received the login password - the one
##      pam_gnome_keyring started and unlocked during the greetd PAM session.
##
## Measured on a real gregOS install, (2) is what breaks, and it broke in two
## steps (gnome-keyring 50.x, Fedora 44 base):
##
##   a. pam's gnome-keyring-daemon is an unsupervised child of the PAM session
##      (exec'd as "gnome-keyring-daemon --daemonize", no --control-directory,
##      no systemd unit - the packaged unit is disabled). When it dies - and it
##      does - the login keyring's unlock state dies with it. Nothing restarts
##      it and nothing re-supplies the password.
##   b. The next client activates org.freedesktop.secrets, which starts a FRESH
##      daemon with no password (the D-Bus activation line is just
##      "gnome-keyring-daemon --start --components=secrets"). That daemon has
##      no way to know the login password, so the login keyring stays locked and
##      every app that needs a secret shows an unlock prompt - exactly the
##      "auth is not passed to the keyring" symptom.
##
## The image previously addressed this by enabling gnome-keyring's systemd
## user units (socket + service with --control-directory), hoping the user
## manager would bind the control socket and carry the unlock. That turned out
## to be unreliable: the user manager starts as part of the same PAM
## conversation as the login itself, so on a real greeter login it is usually
## not up yet when the PAM hook runs - the PAM module then forks its own
## daemon into a directory the socket unit later fails to bind (unit goes
## FAILED and drags the service down with its Requires=), and at other timings
## the socket-connected daemon never ends up owning the keyring. The result
## was the password prompt at every first login - the very symptom this was
## supposed to fix - now with more moving parts.
##
## The design this image ships instead is the packaged, upstream-blessed PAM
## flow, which the daemon's own source describes ("the strange world of PAM"):
##
##   - the auth hook (pam_gnome_keyring.so, no arguments) stashes the login
##     password in the PAM handle; the session hook (with auto_start) delivers
##     it: it connects to the daemon's control socket if one exists, otherwise
##     it forks `gnome-keyring-daemon --daemonize --login` (reads the password
##     from stdin, unlocks/creates the login keyring) and registers
##     GNOME_KEYRING_CONTROL in the PAM environment.
##   - the packaged systemd user units stay DISABLED. gnome-keyring 51.x
##     (Fedora 45) also carries the upstream fixes for the Secret Service
##     crash that had motivated the supervision in the first place, and a
##     supervised restart would never re-supply the login password anyway.
##   - the session keeps that PAM-started daemon: the first in-session client
##     asking for the Secret Service triggers the D-Bus activation file
##     (Exec=/usr/bin/gnome-keyring-daemon --start --foreground
##     --components=secrets), whose --start mode *discovers the running
##     daemon* through $GNOME_KEYRING_CONTROL / %t/keyring/control, forwards
##     the session environment (including the session bus address) to it, and
##     the daemon then claims org.freedesktop.secrets itself. Unlocked keyring
##     and its owner are the same process, no systemd involvement.
##   - keep gcr3's gcr-prompter available: the dialog shown when a prompt
##     really is needed. Fedora ships it as "gcr3" (gcr4 is a different
##     package and does not provide it).
##   - drop the KDE credential stack's leftovers so nothing can ever claim
##     org.freedesktop.secrets behind the keyring's back (the pattern cleanup
##     above removes them).
##
## The assertions below therefore verify the whole chain ships intact instead
## of wiring anything up: the runtime driver is exactly what upstream ships.

# The daemon, the PAM module, the prompter and the D-Bus activation files are
# one release; check all four so any packaging change fails the build here
# instead of surfacing as a locked keyring at login.
for keyring_pkg in gnome-keyring gnome-keyring-pam gcr3; do
    if ! rpm -q "${keyring_pkg}" >/dev/null 2>&1; then
        echo "keyring package '${keyring_pkg}' is missing" >&2
        exit 1
    fi
done

if [[ ! -x /usr/bin/gnome-keyring-daemon ]]; then
    echo "gnome-keyring-daemon binary is missing (gnome-keyring incomplete)" >&2
    exit 1
fi

if [[ ! -e /usr/lib64/security/pam_gnome_keyring.so ]]; then
    echo "pam_gnome_keyring.so is missing (gnome-keyring-pam incomplete)" >&2
    exit 1
fi

for keyring_file in \
    /usr/share/dbus-1/services/org.freedesktop.secrets.service \
    /usr/libexec/gcr-prompter \
    /usr/share/dbus-1/services/org.gnome.keyring.PrivatePrompter.service \
    /usr/share/dbus-1/services/org.gnome.keyring.SystemPrompter.service; do
    if [[ ! -e "${keyring_file}" ]]; then
        echo "keyring support file is missing: ${keyring_file}" >&2
        exit 1
    fi
done

# Fail the build if a future greetd package drops the existing PAM hooks;
# installing the module alone would then no longer unlock/start the keyring.
# Fedora 45 moved greetd's PAM file to /usr/lib/pam.d/greetd (F44 shipped it
# at /etc/pam.d/greetd); pam resolves /etc/pam.d first and falls back to the
# /usr/lib copy, so follow the same precedence and check whichever exists.
greetd_pam_file=/etc/pam.d/greetd
if [[ ! -e "/etc/pam.d/greetd" ]]; then
    greetd_pam_file=/usr/lib/pam.d/greetd
fi
if ! grep -Eq '^-?auth[[:space:]]+optional[[:space:]]+pam_gnome_keyring\.so([[:space:]]|$)' "${greetd_pam_file}" \
    || ! grep -Eq '^-?session[[:space:]]+optional[[:space:]]+pam_gnome_keyring\.so[[:space:]]+auto_start([[:space:]]|$)' "${greetd_pam_file}"; then
    echo "Fedora greetd PAM configuration (${greetd_pam_file}) is missing the GNOME Keyring hooks" >&2
    exit 1
fi

### Apply image-owned files after RPM transactions
##
## Package installs can create or replace files under /usr and /etc. Apply
## system_files afterwards so gregOS defaults and unit overrides win.

cp -avf "/ctx/system_files"/. /

# Rebuild the compiled dconf databases so the image-owned defaults are picked
# up without any user action. The important one is ibus's own system database
# (system-db:ibus, read through /etc/dconf/profile/ibus): the ibus defaults we
# ship in /etc/dconf/db/ibus.d/50-gregos-defaults end up compiled into
# /etc/dconf/db/ibus.
if ! command -v dconf >/dev/null 2>&1; then
    echo "dconf is not installed; cannot compile ibus's dconf defaults" >&2
    exit 1
fi
dconf update
if [[ ! -e /etc/dconf/db/ibus.d/50-gregos-defaults ]] || [[ ! -e /etc/dconf/db/ibus ]]; then
    echo "ibus dconf defaults are not in place after dconf update" >&2
    exit 1
fi

# The environment.d drop-in is the one channel that reaches systemd/D-Bus
# activated apps (see the "third launch path" paragraph in the input-method
# section above). It is applied from system_files with the copy above, so
# this is the first point where it can be verified at all. Fail the build if
# it is missing or incomplete: a future cleanup that removes the file
# silently re-opens the "dead keys broken in every DBusActivatable=true app
# opened from a file manager" bug, while the session looks fine. Check the
# file AND its three assignments, since churn inside the file is just as
# silent as the file itself going away.
if [[ ! -e /usr/lib/environment.d/10-gregos-ibus.conf ]]; then
    echo "ibus environment.d drop-in (system_files/usr/lib/environment.d/10-gregos-ibus.conf) is missing from the build root" >&2
    exit 1
fi

for im_env_assignment in GTK_IM_MODULE=ibus QT_IM_MODULE=ibus XMODIFIERS=@im=ibus; do
    if ! grep -qF "${im_env_assignment}" /usr/lib/environment.d/10-gregos-ibus.conf; then
        echo "'${im_env_assignment}' is missing from /usr/lib/environment.d/10-gregos-ibus.conf" >&2
        exit 1
    fi
done

### Verify the shipped kernel arguments (bootc kargs.d)
##
## system_files carries three drop-ins under /usr/lib/bootc/kargs.d/ that bootc
## applies when it creates or updates this image's deployment:
##
##   10-gregos-eac2.toml    EasyAntiCheat 2 for Linux baseline: kernel lockdown,
##                          kexec disabled and IOMMU enabled. These are also
##                          what EAC looks for, so a deployment without them
##                          cannot run EAC2 games.
##   20-gregos-zswap.toml   zswap tuning (see the zswap section above).
##   30-gregos-gaming.toml  x86 gaming tweaks (split_lock_detect, UMIP).
##
## bootc reads these files on every deployment path this image has (bootc
## install for disk/ISO images, bootc switch --mutate-in-place from the ISO
## kickstart, and bootc upgrade diffs them against the previous image while
## preserving machine-local kernel arguments). The `bootc container lint` step
## at the end of the Containerfile already fails the build on malformed TOML;
## what no step checks until now is that the files are still there and still
## carry the arguments they are supposed to. Fail the build so a future cleanup
## or rename cannot silently drop anti-cheat requirements or the zswap/gaming
## tweaks. Each match is made against the quoted array entry, so extra
## commentary in the files cannot gracefully satisfy a check.

for kargs_file in 10-gregos-eac2.toml 20-gregos-zswap.toml 30-gregos-gaming.toml; do
    if [[ ! -e "/usr/lib/bootc/kargs.d/${kargs_file}" ]]; then
        echo "bootc kargs.d drop-in '${kargs_file}' is missing" >&2
        exit 1
    fi
done

for eac2_karg in lockdown=integrity sysctl.kernel.kexec_load_disabled=1 \
                 intel_iommu=on amd_iommu=on; do
    if ! grep -qF "\"${eac2_karg}\"" /usr/lib/bootc/kargs.d/10-gregos-eac2.toml; then
        echo "EAC2 kernel argument '${eac2_karg}' is missing from /usr/lib/bootc/kargs.d/10-gregos-eac2.toml" >&2
        exit 1
    fi
done

for zswap_karg in zswap.enabled=1 zswap.shrinker_enabled=1 zswap.compressor=zstd \
                  zswap.max_pool_percent=25 zswap.zpool=zsmalloc; do
    if ! grep -qF "\"${zswap_karg}\"" /usr/lib/bootc/kargs.d/20-gregos-zswap.toml; then
        echo "zswap kernel argument '${zswap_karg}' is missing from /usr/lib/bootc/kargs.d/20-gregos-zswap.toml" >&2
        exit 1
    fi
done

# x86-specific parameters are skipped by the TOML itself on other architectures;
# the drop-in and its entries are still required to ship.
for gaming_karg in split_lock_detect=off clearcpuid=umip; do
    if ! grep -qF "\"${gaming_karg}\"" /usr/lib/bootc/kargs.d/30-gregos-gaming.toml; then
        echo "gaming kernel argument '${gaming_karg}' is missing from /usr/lib/bootc/kargs.d/30-gregos-gaming.toml" >&2
        exit 1
    fi
done

### GPU-variant configuration
##
## The image is built from one of three Bazzite bases, selected with the
## BASE_IMAGE build argument (wired through the Containerfile and Justfile,
## and set per-matrix-entry in build.yml):
##
##   ghcr.io/ublue-os/bazzite:stable            standard AMD/Intel image
##   ghcr.io/ublue-os/bazzite-nvidia:stable     proprietary NVIDIA driver
##   ghcr.io/ublue-os/bazzite-nvidia-open:stable open NVIDIA kernel modules
##
## gregOS-nova is built from the standard base too, so the matrix also passes
## IMAGE_VARIANT (standard, nvidia, nvidia-open or nova). Most of this script
## is identical for every variant; the differences are the shader-cache
## variable (Mesa vs the NVIDIA driver read different variables), the "limit
## free buffer pool" application profile for niri on the NVIDIA bases, and the
## open-stack validation plus GSP kernel argument on gregOS-nova. Detection of
## the NVIDIA bases stays by base-image name so each variant is reproducible
## and cannot be guessed wrong from the runtime package set.

# __GL_SHADER_DISK_CACHE_SIZE is documented in bytes, so 10 GB is spelled out
# exactly; the Mesa default below accepts the "10G" suffix shorthand.
shader_cache_line="DefaultEnvironment=MESA_SHADER_CACHE_MAX_SIZE=10G"
shader_cache_comment="# gregOS: cap Mesa's on-disk compiled-shader cache at ~10 GB"

# gregOS-nova is defined by the absence of the proprietary stack. Catching a
# wrong base here keeps a misconfigured matrix entry from publishing an image
# whose name promises an open stack it does not contain.
if [[ "${image_variant}" == "nova" && "${BASE_IMAGE:-}" == *nvidia* ]]; then
    echo "gregOS-nova must be built from the standard Bazzite base, not ${BASE_IMAGE}" >&2
    exit 1
fi

if [[ "${BASE_IMAGE:-}" == *nvidia* ]]; then
    echo "NVIDIA base image detected (${BASE_IMAGE}): applying NVIDIA configuration"

    shader_cache_line="DefaultEnvironment=__GL_SHADER_DISK_CACHE_SIZE=10737418240"
    shader_cache_comment="# gregOS: cap the NVIDIA driver's on-disk shader cache at ~10 GB"

    # NVIDIA's wayland fix for compositors: bound the free-buffer pool so
    # niri behaves with the driver's GL stack (upstream-recommended profile,
    # keyed on the compositor's process name). The directory is created by
    # the nvidia driver packages, but mkdir keeps this self-contained.
    mkdir -p /etc/nvidia/nvidia-application-profiles-rc.d
    cat > /etc/nvidia/nvidia-application-profiles-rc.d/50-limit-free-buffer-pool-in-wayland-compositors.json <<'EOF'
{
    "rules": [
        {
            "pattern": {
                "feature": "procname",
                "matches": "niri"
            },
            "profile": "Limit Free Buffer Pool On Wayland Compositors"
        }
    ],
    "profiles": [
        {
            "name": "Limit Free Buffer Pool On Wayland Compositors",
            "settings": [
                {
                    "key": "GLVidHeapReuseRatio",
                    "value": 0
                }
            ]
        }
    ]
}
EOF

    # Nix applications on non-NixOS resolve their GLX vendor through libglvnd.
    # The host driver bundles are bind-mounted at /run/opengl-driver and
    # /run/opengl-driver-32 by gregos-nix-graphics.service; tell the Nix
    # Xwayland path to use the NVIDIA vendor. Wayland EGL picks 10_nvidia.json
    # from those directories through the __EGL_VENDOR_LIBRARY_FILENAMES set by
    # the bundle build.
    if ! grep -q '^__GLX_VENDOR_LIBRARY_NAME=' /etc/environment 2>/dev/null; then
        printf '%s\n' '__GLX_VENDOR_LIBRARY_NAME=nvidia' >> /etc/environment
    fi
    cat > /usr/lib/environment.d/20-gregos-nix-nvidia.conf <<'EOF'
__GLX_VENDOR_LIBRARY_NAME=nvidia
EOF
fi

### Open-source NVIDIA stack (gregOS-nova)
##
## gregOS-nova is built from the same standard Bazzite base as gregOS and
## deliberately ships no NVIDIA proprietary driver or userspace library. The
## NVIDIA GPU stack is:
##
##   nouveau + GSP firmware   the open kernel driver for Turing (GTX 16xx /
##                            RTX 20xx) and newer. GSP is required for
##                            reclocking and for the interface NVK uses.
##   Mesa NVK                 the conformant open-source Vulkan 1.4 driver for
##                            NVIDIA GPUs.
##   Mesa Zink                OpenGL 4.6 layered over NVK. Mesa uses NVK+Zink
##                            by default for Turing and newer since 25.1.
##
## NOVA (nova-core + nova-drm), the upstream Rust driver intended to replace
## nouveau on GSP hardware, is not usable yet: nova-core is upstream, but
## nova-drm is still a work-in-progress skeleton (its Kconfig says it may not
## be functional) and Fedora's kernel does not build the modules. This variant
## therefore runs the open stack that works today - the same kernel and
## userspace interface NOVA is being built to serve. When nova-drm becomes
## functional and Fedora enables it, this variant picks it up through the
## kernel without a userspace change; the name records that target.
##
## Only Turing and newer have the GSP that both the current nouveau path and
## NOVA require. The build validates the whole open stack so a base-image
## change cannot silently leave the image without accelerated graphics.
if [[ "${image_variant}" == "nova" ]]; then
    echo "Open-source NVIDIA variant: validating nouveau + GSP + Mesa NVK"
    echo "NOVA itself is not usable yet; this image ships nouveau GSP + NVK, the stack nova-drm will replace"

    # GSP firmware is what brings up Turing+ GPUs under nouveau and what NOVA
    # will boot. Install it explicitly (the standard base already carries it)
    # so a slimmer future base cannot leave the GPU unaccelerated. The Mesa
    # packages are pinned for the same reason: NVK is the Vulkan driver and
    # nouveau_dri/zink_dri are the DRI drivers.
    dnf5 install -y nvidia-gpu-firmware mesa-vulkan-drivers mesa-dri-drivers

    for nova_package in nvidia-gpu-firmware mesa-vulkan-drivers mesa-dri-drivers; do
        if ! rpm -q "${nova_package}" >/dev/null 2>&1; then
            echo "required open NVIDIA package '${nova_package}' is missing after installation" >&2
            exit 1
        fi
    done

    # No proprietary NVIDIA package may be present. nvidia-gpu-firmware is a
    # firmware package, not a driver, and is required above.
    proprietary_nvidia="$(
        rpm -qa --qf '%{NAME}\n' \
            | grep -E '^(nvidia$|nvidia-|akmod-nvidia|kmod-nvidia|xorg-x11-drv-nvidia)' \
            | grep -v '^nvidia-gpu-firmware$' \
            | sort -u || true
    )"
    if [[ -n "${proprietary_nvidia}" ]]; then
        echo "gregOS-nova must not contain proprietary NVIDIA packages:" >&2
        printf '%s\n' "${proprietary_nvidia}" >&2
        exit 1
    fi

    # The userspace half of the open stack. nouveau_dri and zink_dri are
    # symlinks to Mesa's shared libdril_dri in current Fedora, so check that
    # the resolved target exists as well.
    for nova_file in \
        /usr/lib64/libvulkan_nouveau.so \
        /usr/share/vulkan/icd.d/nouveau_icd.x86_64.json \
        /usr/lib64/dri/nouveau_dri.so \
        /usr/lib64/dri/zink_dri.so; do
        if [[ ! -e "${nova_file}" ]]; then
            echo "open NVIDIA userspace file is missing: ${nova_file}" >&2
            exit 1
        fi
    done

    if ! compgen -G '/usr/lib/firmware/nvidia/*/gsp/gsp-*.bin*' >/dev/null; then
        echo "no GSP firmware found under /usr/lib/firmware/nvidia" >&2
        exit 1
    fi

    # Force the GSP path explicitly. Linux 6.18+ already defaults to GSP on
    # Turing/Ampere (and Ada+ already did), but GSP is the supported path for
    # NVK on Turing and newer and it is what nova-drm requires, so pin the
    # behavior instead of relying on a kernel default that may change. Pre-GSP
    # GPUs are outside this variant's supported range (Turing+), matching the
    # other open-NVIDIA images.
    install -d /usr/lib/bootc/kargs.d
    cat > /usr/lib/bootc/kargs.d/40-gregos-nova-gsp.toml <<'EOF'
# gregOS-nova: boot nouveau on GSP firmware. GSP is the supported path for
# NVK on Turing and newer, and it is what the future nova-drm driver uses.
kargs = [
  "nouveau.config=NvGspRm=1",
]
EOF

    if ! grep -qF '"nouveau.config=NvGspRm=1"' /usr/lib/bootc/kargs.d/40-gregos-nova-gsp.toml; then
        echo "the gregOS-nova GSP kernel argument is missing from its kargs.d drop-in" >&2
        exit 1
    fi

    # The proprietary variants set this to select the NVIDIA GLX vendor. If a
    # deployment rebased from one of them still has the line in /etc, remove it
    # so libglvnd keeps using Mesa on this image.
    sed -i '/^__GLX_VENDOR_LIBRARY_NAME=nvidia$/d' /etc/environment 2>/dev/null || true
    rm -f /usr/lib/environment.d/20-gregos-nix-nvidia.conf
fi

# Rewrite the shipped drop-in with the variant-correct variable. It is
# propagated through systemd's DefaultEnvironment, so every service inherits
# it - including greetd -> the Noctalia greeter -> the niri session -> every
# app launched inside it.
cat > /usr/lib/systemd/system.conf.d/99-gregos-shader-cache.conf <<EOF
${shader_cache_comment}
#
# Propagated through systemd's DefaultEnvironment, so every service inherits
# it - including greetd -> the Noctalia greeter -> the niri session -> every
# app launched inside it.
${shader_cache_line}
EOF


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

# Fail the build if the session resume wiring ever goes missing. The restore
# entry has to be the last spawn-at-startup of the shipped config, the
# session-actions file has to carry all three overrides (with their fallbacks,
# so the action still happens if the save fails), the compositor's own
# session-ending binds and the power button have to be wired, and logind has
# to stay out of the way: a dropped piece silently reverts that path to its
# plain behavior, and sessions then end without a niri-resume snapshot while
# the restore still runs at startup.
if ! grep -qF 'spawn-at-startup "niri-resume" "restore"' /etc/niri/config.kdl; then
    echo "niri-resume restore is missing from the shipped niri config" >&2
    exit 1
fi

if ! grep -qF 'spawn-at-startup "noctalia"' /etc/niri/config.kdl; then
    echo "noctalia is missing from the shipped niri config" >&2
    exit 1
fi

if [[ "$(grep -n 'spawn-at-startup "niri-resume" "restore"' /etc/niri/config.kdl | head -1 | cut -d: -f1)" \
      -le "$(grep -n 'spawn-at-startup "noctalia"' /etc/niri/config.kdl | head -1 | cut -d: -f1)" ]]; then
    echo "niri-resume restore must be spawned after noctalia in the shipped niri config" >&2
    exit 1
fi

# niri's hardcoded power key handling (suspend through a logind inhibitor)
# runs before configured binds, so without this flag the XF86PowerOff bind
# below would never fire and the power button would suspend instead.
if ! grep -qF 'disable-power-key-handling' /etc/niri/config.kdl; then
    echo "disable-power-key-handling is missing from the shipped niri config" >&2
    exit 1
fi

for session_bind in 'Mod+Shift+E { spawn-sh "niri-resume save-quit' \
                    'Ctrl+Alt+Delete { spawn-sh "niri-resume save-quit' \
                    'XF86PowerOff allow-when-locked=true { spawn-sh "niri-resume save-shutdown'; do
    if ! grep -qF "${session_bind}" /etc/niri/config.kdl; then
        echo "session-ending bind is missing from the shipped niri config: ${session_bind}" >&2
        exit 1
    fi
done

if [[ ! -e /etc/systemd/logind.conf.d/10-gregos-power-button.conf ]]; then
    echo "logind power button drop-in is missing from the build root" >&2
    exit 1
fi
if ! grep -qF 'HandlePowerKey=ignore' /etc/systemd/logind.conf.d/10-gregos-power-button.conf \
    || ! grep -qF 'HandlePowerKeyLongPress=poweroff' /etc/systemd/logind.conf.d/10-gregos-power-button.conf; then
    echo "logind power button drop-in does not ignore short presses / power off on long press" >&2
    exit 1
fi

for noctalia_actions_file in /usr/share/gregos/noctalia/15-gregos-session-actions.toml \
                             /etc/skel/.config/noctalia/15-gregos-session-actions.toml; do
    if [[ ! -e "${noctalia_actions_file}" ]]; then
        echo "Noctalia session actions file is missing: ${noctalia_actions_file}" >&2
        exit 1
    fi
    for session_command in 'niri-resume save-quit || niri msg action quit' \
                           'niri-resume save-reboot || systemctl reboot' \
                           'niri-resume save-shutdown || systemctl poweroff'; do
        if ! grep -qF "${session_command}" "${noctalia_actions_file}"; then
            echo "'${session_command}' is missing from ${noctalia_actions_file}" >&2
            exit 1
        fi
    done
done

### GnuPG: keep keyboxd disabled
##
## gpg 2.4.1+ writes an active "use-keyboxd" into ~/.gnupg/common.conf the first
## time it creates a home directory. Keys then live in keyboxd's own database,
## and distroboxes (which share $HOME with the host) could not verify signing
## keys with it. The shipped common.conf carries "#use-keyboxd" instead, so gpg
## keeps using the classic pubring.kbx.
##
## /etc/skel covers new accounts; gregos-gnupg-config-seed.service enforces the
## same setting in every existing home on each boot.

mkdir -p /usr/share/gregos/gnupg
cp -avf /ctx/dotfiles/gnupg/. /usr/share/gregos/gnupg/

install -d -m 0700 /etc/skel/.gnupg
install -m 0644 /ctx/dotfiles/gnupg/common.conf /etc/skel/.gnupg/common.conf

# Fail the build if the shipped default ever enables keyboxd again.
if grep -Eq '^[[:space:]]*use-keyboxd' /usr/share/gregos/gnupg/common.conf; then
    echo "gregOS must ship keyboxd disabled in common.conf" >&2
    exit 1
fi

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
systemctl enable gregos-gnupg-config-seed.service
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

### Nix
##
## Nix comes from Fedora's official packages (nix-core, nix-system,
## nix-filesystem, nix-libs, plus nix-daemon and nix-legacy). The binaries and
## the daemon live in /usr and are updated with the image; no Nix store paths
## are baked into the image at build time.
##
## The store itself still has to be writable and persistent, which the
## immutable deployment root cannot provide, so:
##
##   - nix.mount bind-mounts /var/home/nix over /nix;
##   - gregos-nix-store.service runs nix-store --init on that mount before the
##     daemon starts, creating /nix/store and /nix/var/nix on first boot;
##   - nix-daemon.service is enabled and creates its own socket (Fedora's
##     socket unit runs in a confined domain that cannot bind inside /nix).
##
## Users install and remove packages without root through `nix profile` or the
## shipped Home Manager launcher, which builds per-user profiles through the
## daemon.
##
## Graphics and compute are independent of Nix: the image build copies the
## host GPU driver stack into /usr/lib/gregos/nix-graphics (64-bit) and
## /usr/lib/gregos/nix-graphics-32 (32-bit), and
## gregos-nix-graphics.service bind-mounts them at /run/opengl-driver and
## /run/opengl-driver-32 on every boot. Nix apps therefore use the exact
## kernel-matched host drivers (Mesa, NVIDIA, CUDA, ROCm, Level Zero/OpenCL)
## without a per-app wrapper, in both architectures.
##
## Only the daemon, its persistent store and the host graphics/compute bundles
## are system-level. Users install everything else through flakes, nix profile
## or Home Manager, exactly as on any other Nix installation.
##
## The image owns the runtime wiring:
##   - gregos-nix-store.service (creates the store before the daemon starts)
##   - nix.mount / var-home-nix.service (persistent store at /var/home/nix)
##   - nix-daemon.service (enabled; creates the daemon socket itself)
##   - gregos-nix-graphics.service (bind-mounts both runtime trees at boot)
##   - /usr/bin/home-manager plus the default flake templates under
##     /usr/share/gregos/home-manager

# nix-core ships the CLI and nix.conf, nix-system the store layout and nixbld
# users, nix-legacy nix-store/nix-env. The nix metapackage pulls core+system.
# Fedora's Nix uses /usr/bin/busybox as the sandbox /bin/sh; without the
# busybox package every sandboxed build fails with
#   error: getting attributes of path "/usr/bin/busybox"
dnf5 install -y busybox nix nix-daemon nix-legacy

for nix_package in busybox nix nix-daemon nix-legacy nix-core nix-system nix-filesystem; do
    if ! rpm -q "${nix_package}" >/dev/null 2>&1; then
        echo "the ${nix_package} package is missing after installation" >&2
        exit 1
    fi
done

if [[ ! -x /usr/bin/busybox ]]; then
    echo "busybox is missing; Nix's sandbox shell is /usr/bin/busybox" >&2
    exit 1
fi

if ! nix --version | grep -q '^nix (Nix) '; then
    echo "the installed nix is not the official implementation" >&2
    nix --version >&2
    exit 1
fi

# Nixpkgs' packages and their bubblewrap wrappers expect the NixOS timezone
# path /etc/zoneinfo, not Fedora's /usr/share/zoneinfo. Wrapped packages bind
# /etc/zoneinfo into their sandbox, so without the NixOS-style link every
# bwrap-wrapped application fails at startup with:
#   bwrap: Can't find source path /etc/zoneinfo: No such file or directory
# The link itself is shipped in system_files (applied with the image files
# above); verify it here so a future cleanup cannot silently reintroduce the
# failure.
if [[ ! -d /usr/share/zoneinfo ]]; then
    echo "/usr/share/zoneinfo is missing; cannot provide the Nix /etc/zoneinfo path" >&2
    exit 1
fi
if [[ ! -L /etc/zoneinfo ]] || [[ "$(readlink /etc/zoneinfo)" != "/usr/share/zoneinfo" ]]; then
    echo "/etc/zoneinfo is not a symlink to /usr/share/zoneinfo (got: $(readlink /etc/zoneinfo 2>/dev/null || echo 'not a symlink'))" >&2
    exit 1
fi
if [[ ! -r /etc/zoneinfo/UTC ]]; then
    echo "/etc/zoneinfo does not resolve to a readable timezone database" >&2
    exit 1
fi

# gregOS settings live in /etc/nix/nix.custom.conf (shipped in system_files);
# the RPM-owned /etc/nix/nix.conf gets one include line so they survive package
# updates.
if ! grep -q '^include[[:space:]]\+nix\.custom\.conf$' /etc/nix/nix.conf; then
    printf '%s\n' 'include nix.custom.conf' >> /etc/nix/nix.conf
fi
if [[ ! -r /etc/nix/nix.custom.conf ]]; then
    echo "/etc/nix/nix.custom.conf is missing" >&2
    exit 1
fi

nix_config="$(HOME=/tmp nix config show 2>/dev/null)"
sandbox_paths="$(awk -F ' = ' '$1 == "sandbox-paths" { print $2 }' <<<"${nix_config}")"
if [[ "${sandbox_paths}" != */usr/bin/busybox* ]]; then
    echo "Nix's sandbox-paths (${sandbox_paths}) do not point at /usr/bin/busybox" >&2
    exit 1
fi

for nix_pattern in \
    '^experimental-features = .*flakes' \
    '^experimental-features = .*nix-command' \
    '^auto-optimise-store = true$' \
    '^substituters = .*https://nix-community\.cachix\.org' \
    '^trusted-public-keys = .*nix-community\.cachix\.org-1:' \
    '^trusted-users = root @wheel$' \
    '^ssl-cert-file = .*/etc/pki/ca-trust/extracted/pem/tls-ca-bundle\.pem$'; do
    if ! grep -Eq "${nix_pattern}" <<<"${nix_config}"; then
        echo "the effective Nix configuration does not match ${nix_pattern}" >&2
        exit 1
    fi
done

if [[ ! -r /etc/pki/ca-trust/extracted/pem/tls-ca-bundle.pem ]]; then
    echo "the Fedora CA bundle required by Nix is missing" >&2
    exit 1
fi

# /nix is the mount point for nix.mount. Anything written below it here would
# be hidden by the bind mount, so only the empty directory is part of the
# image; the store is initialised on the persistent backing directory at boot.
mkdir -p /nix
if [[ ! -d /nix ]]; then
    echo "/nix could not be created as the Nix mount point" >&2
    exit 1
fi

# nix-system ships sysusers.d/nix.conf and creates the build users when the
# package is installed. Verify them so the daemon's build-users-group resolves.
if ! getent group nixbld >/dev/null 2>&1; then
    echo "the nixbld group was not created by the nix-system package" >&2
    exit 1
fi
for nix_build_user in nixbld-1 nixbld-10; do
    if ! getent passwd "${nix_build_user}" >/dev/null 2>&1; then
        echo "the ${nix_build_user} build user was not created by the nix-system package" >&2
        exit 1
    fi
done

for nix_binary in /usr/bin/nix /usr/bin/nix-store /usr/bin/nix-daemon /usr/libexec/gregos/nix-store; do
    if [[ ! -x "${nix_binary}" ]]; then
        echo "required Nix binary is missing or not executable: ${nix_binary}" >&2
        exit 1
    fi
done
for nix_unit_file in \
    /usr/lib/systemd/system/nix-daemon.service \
    /usr/lib/systemd/system/nix-daemon.socket \
    /usr/lib/systemd/system/gregos-nix-store.service; do
    if [[ ! -r "${nix_unit_file}" ]]; then
        echo "required Nix unit file is missing: ${nix_unit_file}" >&2
        exit 1
    fi
done

# Home Manager launcher and the templates used by `home-manager switch`.
for home_manager_binary in /usr/bin/home-manager /usr/libexec/gregos/home-manager-setup; do
    if [[ ! -x "${home_manager_binary}" ]]; then
        echo "Home Manager helper is missing or not executable: ${home_manager_binary}" >&2
        exit 1
    fi
done
for home_manager_template in \
    /usr/share/gregos/home-manager/flake.nix \
    /usr/share/gregos/home-manager/home.nix \
    /usr/share/gregos/home-manager/ref; do
    if [[ ! -r "${home_manager_template}" ]]; then
        echo "Home Manager template is missing: ${home_manager_template}" >&2
        exit 1
    fi
done

# PAM sessions (including niri) get their environment from /etc/environment;
# systemd user services use environment.d. Both need the Fedora CA bundle
# because Fedora's Nix profile scripts look for /etc/pki/tls/certs/ca-bundle.crt,
# which this image does not ship. NIXPKGS_ALLOW_UNFREE makes the default
# unfree policy explicit for impure evaluation.
for nix_environment in \
    'NIX_SSL_CERT_FILE=/etc/pki/ca-trust/extracted/pem/tls-ca-bundle.pem' \
    'NIXPKGS_ALLOW_UNFREE=1'; do
    nix_environment_key="${nix_environment%%=*}"
    if ! grep -q "^${nix_environment_key}=" /etc/environment 2>/dev/null; then
        printf '%s\n' "${nix_environment}" >> /etc/environment
    fi
done

for nix_environment_file in /etc/environment /usr/lib/environment.d/10-gregos-nix.conf; do
    if ! grep -q '^NIXPKGS_ALLOW_UNFREE=1$' "${nix_environment_file}"; then
        echo "${nix_environment_file} does not allow unfree packages" >&2
        exit 1
    fi
done

## 32-bit userspace for the second driver bundle. Nix's FHS environment looks
## for /run/opengl-driver-32 on x86_64; without the i686 Mesa/NVIDIA libraries
## 32-bit Wine/Proton games only see the 64-bit ICDs.
if [[ "$(uname -m)" == "x86_64" ]]; then
    for mesa32_package in mesa-vulkan-drivers.i686 mesa-dri-drivers.i686; do
        if ! rpm -q "${mesa32_package}" >/dev/null 2>&1; then
            # NVIDIA supplies its own 32-bit Vulkan/GL stack; Mesa is only a
            # fallback there, so a missing Mesa i686 subpackage is not fatal.
            if [[ "${BASE_IMAGE:-}" == *nvidia* ]]; then
                dnf5 install -y "${mesa32_package}" || true
            else
                dnf5 install -y "${mesa32_package}"
            fi
        fi
    done
    if [[ "${BASE_IMAGE:-}" == *nvidia* ]] \
        && ! compgen -G '/usr/lib/libGLX_nvidia.so*' >/dev/null \
        && ! compgen -G '/usr/lib32/libGLX_nvidia.so*' >/dev/null \
        && ! compgen -G '/usr/lib/i386-linux-gnu/libGLX_nvidia.so*' >/dev/null; then
        dnf5 install -y xorg-x11-drv-nvidia-libs.i686
    fi
fi

# Build the host graphics/compute bundles. This is deliberately an image-build
# step, not a Nix build: it keeps the driver ABI matched to the running host
# kernel and rejects a host driver whose glibc requirement is newer than the
# image's own glibc. The bundles also carry the CUDA/ROCm/OpenCL/Level Zero
# user-space libraries.
/ctx/nix-host-graphics.sh

if [[ ! -s /usr/lib/gregos/nix-graphics/libs.list ]]; then
    echo "the host graphics bundle is empty (no /usr/lib/gregos/nix-graphics/libs.list)" >&2
    exit 1
fi

if [[ ! -x /usr/libexec/gregos/nix-graphics ]]; then
    echo "the host graphics service script is missing" >&2
    exit 1
fi

for graphics_file in \
    /usr/lib/environment.d/20-gregos-nix-graphics.conf \
    /etc/profile.d/20-gregos-nix-graphics.sh; do
    if [[ ! -r "${graphics_file}" ]]; then
        echo "host graphics environment file is missing: ${graphics_file}" >&2
        exit 1
    fi
done

if ! compgen -G "/usr/lib/gregos/nix-graphics/share/vulkan/icd.d/*.json" >/dev/null; then
    echo "the host graphics bundle contains no Vulkan ICD" >&2
    exit 1
fi

# 32-bit Nix applications (Wine/Proton, 32-bit launchers) need the second
# bundle. On x86_64 it must exist and carry at least one Vulkan ICD; on other
# architectures the orchestrator skips it.
if [[ "$(uname -m)" == "x86_64" ]]; then
    if [[ ! -s /usr/lib/gregos/nix-graphics-32/libs.list ]]; then
        echo "the 32-bit host graphics bundle is empty (no /usr/lib/gregos/nix-graphics-32/libs.list)" >&2
        exit 1
    fi
    if ! compgen -G "/usr/lib/gregos/nix-graphics-32/share/vulkan/icd.d/*.json" >/dev/null; then
        echo "the 32-bit host graphics bundle contains no Vulkan ICD" >&2
        exit 1
    fi
    if ! grep -q '/run/opengl-driver-32/lib' /usr/lib/environment.d/20-gregos-nix-graphics.conf; then
        echo "the host graphics environment does not expose /run/opengl-driver-32" >&2
        exit 1
    fi
    if ! grep -q '/run/opengl-driver-32/share/vulkan/icd.d/' \
        /usr/lib/environment.d/20-gregos-nix-graphics.conf; then
        echo "the host graphics environment has no 32-bit Vulkan ICDs" >&2
        exit 1
    fi
fi

# A CUDA-capable base must actually contribute the driver API, otherwise the
# host bundle was built from a Mesa-only stack.
if [[ "${BASE_IMAGE:-}" == *nvidia* ]] \
    && ! grep -qx 'lib/libcuda.so.1' /usr/lib/gregos/nix-graphics/libs.list; then
    echo "NVIDIA base image detected but the host graphics bundle has no libcuda.so.1" >&2
    exit 1
fi

# The NVIDIA variants must also provide the 32-bit userspace, otherwise 32-bit
# Wine/Proton games fall back to llvmpipe or fail to create a Vulkan instance.
if [[ "${BASE_IMAGE:-}" == *nvidia* ]]; then
    if ! grep -q '^lib/libGLX_nvidia\.so' /usr/lib/gregos/nix-graphics-32/libs.list; then
        echo "NVIDIA base image detected but the 32-bit host graphics bundle has no libGLX_nvidia" >&2
        exit 1
    fi
    if ! compgen -G "/usr/lib/gregos/nix-graphics-32/share/vulkan/icd.d/nvidia_icd*.json" >/dev/null; then
        echo "NVIDIA base image detected but the 32-bit bundle has no NVIDIA Vulkan ICD" >&2
        exit 1
    fi
fi

# gregOS-nova has no proprietary NVIDIA userspace, so its Nix bundle must not
# contain any either: Mesa NVK and the DRI drivers are the entire graphics
# stack. Verifying the bundle here is what makes "Nix apps are accelerated"
# true for the open variant instead of an assumption.
if [[ "${image_variant}" == "nova" ]]; then
    for nova_nix_lib in lib/libvulkan_nouveau.so lib/dri/nouveau_dri.so lib/dri/zink_dri.so; do
        if ! grep -qx "${nova_nix_lib}" /usr/lib/gregos/nix-graphics/libs.list; then
            echo "the host graphics bundle is missing ${nova_nix_lib} for gregOS-nova" >&2
            exit 1
        fi
    done

    if grep -q '^lib/libnvidia-' /usr/lib/gregos/nix-graphics/libs.list; then
        echo "the host graphics bundle contains proprietary NVIDIA libraries on gregOS-nova" >&2
        exit 1
    fi

    if [[ "$(uname -m)" == "x86_64" ]]; then
        for nova_nix_lib in lib/libvulkan_nouveau.so lib/dri/nouveau_dri.so lib/dri/zink_dri.so; do
            if ! grep -qx "${nova_nix_lib}" /usr/lib/gregos/nix-graphics-32/libs.list; then
                echo "the 32-bit host graphics bundle is missing ${nova_nix_lib} for gregOS-nova" >&2
                exit 1
            fi
        done
        if grep -q '^lib/libnvidia-' /usr/lib/gregos/nix-graphics-32/libs.list; then
            echo "the 32-bit host graphics bundle contains proprietary NVIDIA libraries on gregOS-nova" >&2
            exit 1
        fi
        if ! grep -q '/run/opengl-driver-32/lib/libvulkan_nouveau.so' \
            /usr/lib/gregos/nix-graphics-32/share/vulkan/icd.d/nouveau_icd.i686.json; then
            echo "the 32-bit host graphics bundle does not point the nouveau Vulkan ICD at NVK" >&2
            exit 1
        fi
    fi

    if ! grep -q '/run/opengl-driver/lib/libvulkan_nouveau.so' \
        /usr/lib/gregos/nix-graphics/share/vulkan/icd.d/nouveau_icd.x86_64.json; then
        echo "the host graphics bundle does not point the nouveau Vulkan ICD at NVK" >&2
        exit 1
    fi

    if grep -q '^__GLX_VENDOR_LIBRARY_NAME=' /etc/environment 2>/dev/null; then
        echo "__GLX_VENDOR_LIBRARY_NAME must not be set on gregOS-nova (it selects the proprietary GLX vendor)" >&2
        exit 1
    fi
fi

# Enable the runtime units. nix.mount pulls in var-home-nix.service through
# its [Install] RequiredBy=. The daemon service is enabled directly rather
# than nix-daemon.socket: systemd creates socket files in the init_t domain,
# which SELinux does not allow inside the persistent store, while the daemon
# service runs unconfined and creates its own socket after
# gregos-nix-store.service has initialised the store.
nix_units=(
    nix.mount
    gregos-nix-store.service
    gregos-nix-graphics.service
    nix-daemon.service
)
for unit in "${nix_units[@]}"; do
    systemctl enable "${unit}"
done
for unit in "${nix_units[@]}"; do
    if ! systemctl is-enabled "${unit}" >/dev/null 2>&1; then
        echo "systemd unit '${unit}' is not enabled after enablement" >&2
        exit 1
    fi
done

# nix-daemon.socket would try to bind the same path from init_t and fail; the
# service owns the socket on this image. Mask the unit so an enable symlink
# left over from an earlier image cannot bring it back.
systemctl mask nix-daemon.socket
if [[ "$(systemctl is-enabled nix-daemon.socket 2>/dev/null || true)" != "masked" ]]; then
    echo "nix-daemon.socket must be masked; nix-daemon.service creates the socket" >&2
    exit 1
fi

nix --version

# The package transactions after the gaming cleanup (snapd, Nix, 32-bit
# drivers) must not pull a launcher back in through dependencies or weak
# dependencies. The cleanup's own checks ran before those transactions.
for game_pkg in heroic lutris steam; do
    if rpm -q "${game_pkg}" >/dev/null 2>&1; then
        echo "game launcher package '${game_pkg}' was installed at the end of the build" >&2
        exit 1
    fi
done
