# Graphics driver environment for Nix applications running on gregOS.
#
# Nixpkgs builds its libglvnd and Vulkan loader to look for drivers in
# /run/opengl-driver (the NixOS convention). On a non-NixOS system that
# directory does not exist, so Nix-built graphical programs fall back to
# software rendering unless a compatible driver set is placed there.
#
# This expression builds that driver set from the *same* pinned nixpkgs as the
# rest of the Nix stack, which keeps the Mesa/Vulkan ABI consistent with what
# Nix applications expect. The image build links the resulting store path at
# /run/opengl-driver on boot (see usr/libexec/gregos/nix-graphics).
#
# The NVIDIA variants substitute the exact proprietary userspace driver
# version used by the host base image (detected by build_files/nix-seed.sh and
# passed through GREGOS_NVIDIA_VERSION/GREGOS_NVIDIA_HASH). The host provides
# the matching kernel modules; this expression only supplies the userspace
# libs and the EGL/Vulkan vendor metadata.
let
  # Pinned nixpkgs revision for the driver set. This is the source of truth:
  # build_files/nix-seed.sh reads this value for the seed version stamp, so an
  # image rebuild reproduces the same drivers unless this line is changed.
  nixpkgsRev = "2786a2a72088ecf32aea5b3ec52099e6a7cff78f";

  nixpkgs = builtins.fetchGit {
    url = "https://github.com/NixOS/nixpkgs";
    rev = nixpkgsRev;
  };

  pkgs = import nixpkgs {
    system = "x86_64-linux";
    config = {
      allowUnfree = true;
      nvidia.acceptLicense = true;
    };
  };

  nvidiaVersion = builtins.getEnv "GREGOS_NVIDIA_VERSION";
  nvidiaHash = builtins.getEnv "GREGOS_NVIDIA_HASH";
  withNvidia = nvidiaVersion != "" && nvidiaHash != "";

  nvidiaLibs =
    pkgs.linuxPackages.nvidiaPackages.mkDriver {
      version = nvidiaVersion;
      sha256_64bit = nvidiaHash;
      # The build is x86_64-only; this value is unused but mkDriver requires
      # the attribute to exist.
      sha256_aarch64 = nvidiaHash;
      useSettings = false;
      usePersistenced = false;
    };

  nvidia = nvidiaLibs.override {
    libsOnly = true;
  };

  # EGL external platform implementations used by the NVIDIA driver on
  # Wayland (egl-wayland/egl-wayland2) and for GBM/X11 interop.
  nvidiaEglPlatforms = pkgs.symlinkJoin {
    name = "nvidia-egl-external-platforms";
    paths = [
      pkgs.egl-wayland
      pkgs.egl-gbm
      pkgs.egl-wayland2
      pkgs.egl-x11
    ];
  };

  mesaDrivers = [
    pkgs.mesa
    pkgs.libvdpau-va-gl
    pkgs.intel-media-driver
  ];

  graphics = pkgs.buildEnv {
    name = "gregos-nix-graphics";
    paths =
      mesaDrivers
      ++ pkgs.lib.optionals withNvidia [
        nvidia.out
        nvidiaEglPlatforms
      ];
  };
in
{
  inherit graphics;
}
