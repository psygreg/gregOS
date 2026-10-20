#!/bin/bash

set -ouex pipefail

# Copy the contents of system_files/ of the git repo to /
cp -avf "/ctx/system_files"/. /

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
    xdg-desktop-portal-gtk

### Install noctalia-greeter and nwg-look from the Terra repository
##
## Neither is in Fedora's own repos yet. Bazzite already carries
## terra-release with the Terra repos disabled, so enable them just for this
## transaction (--enable-repo does not change the repo files on disk) and
## leave everything as shipped afterwards.

dnf5 install -y --enable-repo=terra --enable-repo=terra-extras noctalia-greeter nwg-look

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

### Remove KDE Plasma and GNOME desktops and their tied applications
##
## The base image is Bazzite (Kinoite-based) and ships KDE Plasma. niri +
## Noctalia replaces it as the only desktop. Everything not tied to the
## desktop environments is kept: Steam, gamescope, drivers, ujust, Bazzite
## Portal, Waydroid, Cockpit, the audio stack, and so on. Bazaar is removed
## too: software and system management is centered on LinuxToys instead.
## Packages that depend on the removed ones are dropped automatically as
## well (krunner-bazaar is caught by the krunner pattern below).

REMOVE_PATTERNS='^(bazaar|plasma-|kwin|kde|kf5-|kf6-|kio|kded|kinit|konsole|dolphin|kate|kwrite|ark|gwenview|okular|spectacle|kcalc|kfind|kdialog|kmenuedit|kinfocenter|ksystemlog|ksystemstats|kcharselect|kcolorchooser|skanpage|svgpart|kamera|print-manager|drkonqi|milou|kactivity|kwayland|kpipewire|kdecoration|breeze|oxygen|sddm|polkit-kde|xdg-desktop-portal-kde|layer-shell-qt|qqc2|libplasma|libkworkspace|libkdcraw|libkexiv2|libksane|kimageformat|khelpcenter|kfilemetadata|baloo|ksshaskpass|kwallet|krunner|kscreen|khotkeys|kuserfeedback|gnome-shell|gnome-session|gnome-settings-daemon|gnome-control-center|gnome-tour|gnome-initial-setup|gnome-software|gnome-classic-session|gnome-text-editor|gnome-calculator|gnome-font-viewer|gnome-logs|gnome-weather|gnome-maps|gnome-characters|gnome-clocks|gnome-contacts|gnome-connections|gnome-photos|gnome-screenshot|gnome-system-monitor)'

desktop_pkgs="$(rpm -qa --qf '%{NAME}\n' | grep -E "${REMOVE_PATTERNS}" | sort -u || true)"
if [[ -n "${desktop_pkgs}" ]]; then
    echo "Removing desktop environment packages:"
    printf '%s\n' "${desktop_pkgs}"
    printf '%s\n' "${desktop_pkgs}" | xargs -r dnf5 -y remove
fi

# Bazaar's curated-flatpak configuration is baked into the base image (not
# owned by any RPM); remove it along with the app.
rm -rfv /usr/share/ublue-os/bazaar

### Deploy the shipped niri + Noctalia configuration
##
##  - /usr/share/gregos/ is the canonical copy inside the image
##  - /etc/skel/.config/ seeds new user accounts
##  - gregos-niri-config-seed.service copies the same files into existing
##    user homes on first boot, so rebasing to this image just works without
##    manual steps. The seeder only ever adds missing files.

mkdir -p /usr/share/gregos/niri /usr/share/gregos/noctalia
cp -avf /ctx/dotfiles/niri/. /usr/share/gregos/niri/
cp -avf /ctx/dotfiles/noctalia/. /usr/share/gregos/noctalia/

mkdir -p /etc/skel/.config/niri /etc/skel/.config/noctalia
cp -avf /ctx/dotfiles/niri/. /etc/skel/.config/niri/
cp -avf /ctx/dotfiles/noctalia/. /etc/skel/.config/noctalia/

### Login manager: greetd + Noctalia Greeter
##
## Replaces KDE's login manager (plasma-login-manager / SDDM). The greeter
## runs as the "greeter" system account (provided by greetd and added to the
## video/input groups by the shipped sysusers.d rule) and offers the niri
## session.

cat > /etc/greetd/config.toml <<'EOF'
# Managed by gregOS - greetd running the Noctalia greeter
[terminal]
vt = 1

[default_session]
command = "/usr/bin/noctalia-greeter-session"
user = "greeter"
EOF

systemctl disable sddm.service 2>/dev/null || true
systemctl disable plasma-login-manager.service 2>/dev/null || true
systemctl disable gdm.service 2>/dev/null || true
systemctl enable greetd.service
ln -sfn /usr/lib/systemd/system/greetd.service /etc/systemd/system/display-manager.service

systemctl enable gregos-niri-config-seed.service

#### Example for enabling a System Unit File

systemctl enable podman.socket
