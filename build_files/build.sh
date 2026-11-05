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

### Built-in: latencydevil launcher wrapper on PATH
##
## gregOS ships the latencydevil launcher wrapper
## (https://github.com/psygreg/latencydevil) as an image built-in, next to
## helpers like the niri display-setup script. It takes a launch command,
## injects GPU-aware low-latency environment variables in front of it, then
## execs the command - so games launch as "latencydevil -- %command%" in Steam
## launch options, or "latencydevil -- <command>" in a terminal (Flatpaks
## included). That wrapper usage is by name, which is why - unlike the display
## helper, spawned by niri through its full path - the binary is installed on
## the system PATH as an image-owned file in /usr/bin.
##
## NOT /usr/local/bin, even though that is upstream's own suggested install
## location: in this base image /usr/local is a symlink to ../var/usrlocal,
## and /var content is not carried from the image onto deployed hosts (the
## same problem as /opt, documented in the Containerfile) - a binary placed
## there during the build would be gone again after the first deployment.
## /usr/bin is the usual system path: it ships with the image on every PATH,
## and on deployed systems it is immutable, so removals and replacements of
## latencydevil happen through image updates like every other built-in.
##
## There is no package to install: the GitHub release ships a single
## self-contained binary named "latencydevil". Download it from the latest
## release the same way LinuxToys and Heroic above are fetched: resolve the
## current asset through the GitHub API. The GITHUB_TOKEN build secret (wired
## up in build.yml and the Justfile) authenticates the request in CI to avoid
## unauthenticated API rate limits; local builds fall back to anonymous
## access. Daily image builds therefore automatically pick up every new
## latencydevil release.

latencydevil_url="$(/ctx/ghcurl https://api.github.com/repos/psygreg/latencydevil/releases/latest \
    | jq -r '.assets[] | select(.name == "latencydevil") | .browser_download_url')"
echo "Fetching latencydevil: ${latencydevil_url}"
/ctx/ghcurl "${latencydevil_url}" -o /tmp/latencydevil
install -m 0755 /tmp/latencydevil /usr/bin/latencydevil
rm -f /tmp/latencydevil

# Fail the build if the binary did not land on PATH as an executable - nothing
# else ships it, and Steam launch options resolve "latencydevil" through PATH
# only.
if [[ ! -x /usr/bin/latencydevil ]]; then
    echo "latencydevil is missing from /usr/bin after installation" >&2
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
## Everything else in this script is identical for all three; only the
## shader-cache drop-in differs (Mesa vs the NVIDIA driver read different
## variables), and only the NVIDIA images need the "limit free buffer pool"
## application profile for niri. Detection is by base-image name so each
## variant stays reproducible and cannot be guessed wrong from the runtime
## package set.

# __GL_SHADER_DISK_CACHE_SIZE is documented in bytes, so 10 GB is spelled out
# exactly; the Mesa default below accepts the "10G" suffix shorthand.
shader_cache_line="DefaultEnvironment=MESA_SHADER_CACHE_MAX_SIZE=10G"
shader_cache_comment="# gregOS: cap Mesa's on-disk compiled-shader cache at ~10 GB"

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
