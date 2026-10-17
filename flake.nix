# SPDX-License-Identifier: GPL-3.0-or-later
{
  description = "Portal: native web views and Ghostty terminals inside macOS Emacs";

  inputs.nixpkgs.url = "github:NixOS/nixpkgs/nixpkgs-unstable";

  outputs =
    { self, nixpkgs }:
    let
      systems = [
        "aarch64-darwin"
        "x86_64-darwin"
      ];
      each = f: nixpkgs.lib.genAttrs systems (system: f nixpkgs.legacyPackages.${system});
      # Portal for EMACS, an Emacs 31.1 or newer built for macOS's graphical
      # interface: its module is built against that Emacs's header.
      portalFor = pkgs: emacs: pkgs.callPackage ./nix/package.nix { inherit emacs; src = self; };
    in
    {
      packages = each (pkgs: rec {
        portal = portalFor pkgs pkgs.emacs;
        default = portal;
      });

      # Adds `portal' to every Emacs package set, built for that set's Emacs:
      # (emacsPackagesFor emacs).withPackages (epkgs: [ epkgs.portal ]).
      overlays.default = final: prev: {
        emacsPackagesFor =
          emacs:
          (prev.emacsPackagesFor emacs).overrideScope (
            _: _: { portal = portalFor final emacs; }
          );
      };

      # The tools CONTRIBUTING.md's build needs, besides Xcode's Swift.
      devShells = each (pkgs: {
        default = pkgs.mkShellNoCC {
          packages = [
            pkgs.cmake
            pkgs.ninja
            (portalFor pkgs pkgs.emacs).passthru.bun
          ];
          shellHook = ''
            unset DEVELOPER_DIR SDKROOT
            export PATH="$PATH:/usr/bin"
          '';
        };
      });
    };
}
