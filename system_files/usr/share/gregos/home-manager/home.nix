{ config, pkgs, ... }:

{
  home.username = "@USER@";
  home.homeDirectory = "@HOME@";
  home.stateVersion = "26.11";

  # Integration with a non-NixOS Linux distribution: XDG data directories,
  # NIX_PATH and the user profile wiring.
  targets.genericLinux = {
    enable = true;

    # gregOS already links the host GPU stack at /run/opengl-driver and exports
    # the loader variables system-wide. Do not let Home Manager build and
    # install a second, Nix-owned driver set: that would require `sudo` and
    # would replace the kernel-matched host drivers again on the next boot.
    gpu.enable = false;
  };

  # Keep the host driver tree on the search path for programs started from a
  # Home Manager session, matching the image-wide environment.
  home.sessionVariables = {
    LD_LIBRARY_PATH = "/run/opengl-driver/lib";
    LIBGL_DRIVERS_PATH = "/run/opengl-driver/lib/dri";
    LIBVA_DRIVERS_PATH = "/run/opengl-driver/lib/dri";
  };

  # Home Manager manages its own generations once the first one is active.
  programs.home-manager.enable = true;

  # Declare user packages here, then run `home-manager switch`.
  # Removing a line and switching again removes the package.
  home.packages = [
    # pkgs.hello
  ];
}
