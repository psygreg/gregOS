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
    xdg-desktop-portal-gtk

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

desktop_pkgs="$(rpm -qa --qf '%{NAME}\n' | grep -E "${REMOVE_PATTERNS}" | sort -u || true)"
if [[ -n "${desktop_pkgs}" ]]; then
    echo "Removing desktop environment packages:"
    printf '%s\n' "${desktop_pkgs}"
    printf '%s\n' "${desktop_pkgs}" | xargs -r dnf5 -y remove
fi

# Bazaar's curated-flatpak configuration is baked into the base image (not
# owned by any RPM); remove it along with the app.
rm -rfv /usr/share/ublue-os/bazaar

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
    showtime \
    kde-connect \
    wlsunset \
    cava

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
