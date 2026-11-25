# shellcheck shell=sh
# Put Determinate Nix on the PATH of every login shell.
#
# The system profile (Nix itself plus the preinstalled fh CLI) lives in
# /nix/var/nix/profiles/default. The profile script shipped inside the Nix
# store adds both that profile and the user's own profile, sets NIX_PROFILES,
# NIX_SSL_CERT_FILE and XDG_DATA_DIRS, and is the upstream-supported way to
# wire Nix into a shell.
#
# GUI applications do not source this file; they find nix/fh through the
# /usr/local/bin symlinks created by gregos-nix-seed.service, and user-installed
# applications through their absolute /nix/store paths in .desktop files.
#
# Set the CA bundle before sourcing nix-daemon.sh: that script only fills
# NIX_SSL_CERT_FILE when it is unset, and its Fedora candidate path
# (/etc/pki/tls/certs/ca-bundle.crt) does not exist on this image.
NIX_SSL_CERT_FILE=/etc/pki/ca-trust/extracted/pem/tls-ca-bundle.pem
export NIX_SSL_CERT_FILE

if [ -r /nix/var/nix/profiles/default/etc/profile.d/nix-daemon.sh ]; then
    # shellcheck disable=SC1091
    . /nix/var/nix/profiles/default/etc/profile.d/nix-daemon.sh
fi
