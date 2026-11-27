{ config, lib, pkgs, ... }:

let
  # `nix.gc` only forwards flags to `nix-collect-garbage`, and its age-based
  # deletion has no lower bound: a profile left untouched for two weeks would
  # be reduced to its current generation and lose every rollback. This helper
  # applies the same two-week rule but never drops below three generations,
  # then collects the store paths that are no longer referenced.
  nixGc = pkgs.writeShellApplication {
    name = "gregos-nix-gc";
    runtimeInputs = with pkgs; [
      coreutils
      gawk
      nix
    ];
    text = ''
      keep=3
      max_age_days=14
      profiles_dir="''${XDG_STATE_HOME:-''${HOME}/.local/state}/nix/profiles"

      [[ -d "$profiles_dir" ]] || exit 0

      cutoff="$(date -d "$max_age_days days ago" '+%Y-%m-%d %H:%M:%S')"

      for profile in "$profiles_dir"/*; do
          # Profiles are symlinks such as home-manager -> home-manager-4-link;
          # generation links point into the store and are skipped here.
          [[ -L "$profile" ]] || continue
          name="$(basename "$profile")"
          target="$(basename "$(readlink "$profile")")"
          [[ "$target" == "$name"-*-link ]] || continue

          # Delete generations older than the cutoff, except the newest `keep`
          # and the current one. nix-env refuses to delete the current
          # generation, and a rollback may have left it older than newer
          # generations.
          mapfile -t expired < <(
              nix-env --profile "$profile" --list-generations |
                  awk -v cutoff="$cutoff" -v keep="$keep" '
                      {
                          number[NR] = $1
                          current[NR] = ($0 ~ /\(current\)/)
                          old[NR] = ($2 " " $3 < cutoff)
                      }
                      END {
                          first = NR - keep + 1
                          if (first < 1) first = 1
                          for (i = first; i <= NR; i++) keep_number[number[i]] = 1
                          for (i = 1; i <= NR; i++)
                              if (old[i] && !current[i] && !keep_number[number[i]])
                                  print number[i]
                      }
                  '
          )

          if (( ''${#expired[@]} > 0 )); then
              nix-env --profile "$profile" --delete-generations "''${expired[@]}"
          fi
      done

      nix-collect-garbage
    '';
  };
in
{
  home.username = "@USER@";
  home.homeDirectory = "@HOME@";
  home.stateVersion = "26.11";

  # Integration with a non-NixOS Linux distribution: XDG data directories,
  # NIX_PATH and the user profile wiring.
  targets.genericLinux = {
    enable = true;

    # gregOS already bind-mounts the host GPU stack at /run/opengl-driver and
    # exports the loader variables system-wide. Do not let Home Manager build and
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

  # Reclaim space once a week. `nix.gc` is not used because its only knob is
  # the `nix-collect-garbage` command line, which cannot keep a minimum number
  # of generations. The store itself is already hard-link optimised by the
  # daemon (auto-optimise-store); nixGc removes the profile entries that keep
  # old package sets alive and then collects the unreferenced store paths.
  systemd.user.services.gregos-nix-gc = {
    Unit.Description = "gregOS Nix garbage collector";
    Service = {
      Type = "oneshot";
      ExecStart = lib.getExe nixGc;
    };
  };

  systemd.user.timers.gregos-nix-gc = {
    Unit.Description = "Weekly gregOS Nix garbage collection";
    Timer = {
      OnCalendar = "weekly";
      Persistent = true;
      Unit = "gregos-nix-gc.service";
    };
    Install.WantedBy = [ "timers.target" ];
  };

  # Declare user packages here, then run `home-manager switch`.
  # Removing a line and switching again removes the package. The flake sets
  # up nixpkgs for this machine's architecture and allows unfree packages by
  # default, so entries like pkgs.vscode or pkgs.steam work here.
  home.packages = [
    # pkgs.hello
  ];
}
