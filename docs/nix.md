# Portal with Nix

[Documentation index](README.md) · [Install Portal](install.md)

Portal's flake builds the whole package, its Lisp, native module and app host,
from pinned inputs, so Emacs never builds or downloads anything. Nix fetches
each dependency and checks it by hash:

- Portal's pinned Bun, from the URL and digest in `tools/bun.manifest`.
- The app host's packages, from `host/bun.lock`, without its development tools.
- The Swift packages that `native/Package.resolved` pins, libghostty-spm and
  DisplayLink, and the GhosttyKit binary libghostty-spm names, by its own
  checksum. SwiftPM builds them as local packages and downloads nothing.

Apple's Swift and Clang still come from Xcode, as for any Portal build, so the
build needs Xcode with Swift 6.2 or newer, chosen with `xcode-select`, and runs
outside Nix's sandbox. On macOS Nix's sandbox is off by default; if yours is
on, allow such builds in `nix.conf`:

```
sandbox = relaxed
```

The package is for macOS only, and its module is built against the Emacs it
is for: Emacs 31.1 or newer, built for macOS's graphical interface.

## Emacs with Portal

The overlay adds `portal` to every Emacs package set, built for that set's
Emacs. With home-manager:

```nix
{
  inputs.portal.url = "github:xiaoxinghu/portal";
  inputs.portal.inputs.nixpkgs.follows = "nixpkgs";

  # In your home-manager configuration:
  nixpkgs.overlays = [ inputs.portal.overlays.default ];
  programs.emacs = {
    enable = true;
    package = pkgs.emacs;
    extraPackages = epkgs: [ epkgs.portal ];
  };
}
```

Or with any Emacs: `((pkgs.emacsPackagesFor pkgs.emacs).withPackages (epkgs:
[ epkgs.portal ]))`. Emacs activates Portal like any installed package, so
your configuration only needs:

```elisp
(use-package portal :ensure nil)
```

`packages.<system>.default` is Portal for nixpkgs' default `emacs`, as an
installed package in `share/emacs/site-lisp/elpa/portal-VERSION`, with its
build in `build/` beside the Lisp.

## Upgrades

Portal's build is in the Nix store, so `M-x portal-build` does not apply.
Without the native sources beside the Lisp, Portal accepts only a build of the
same Portal version, which the package always is. Restart Emacs after an
upgrade that rebuilt the module, as after any rebuild.

## Changing the pins

`nix/package.nix` reads Bun's version and digest from `tools/bun.manifest` and
the Swift packages' revisions from `native/Package.resolved`, so those files
stay the only place to change them. Their content hashes live in
`nix/package.nix`:

- After changing a Swift pin, update its `hash`, and for a new GhosttyKit
  binary, `ghosttyKitURL` and `ghosttyKitChecksum`, which libghostty-spm's
  `Package.swift` names.
- After changing `host/bun.lock`, update `hostModules`' `outputHash`.

Build once with the old hash: Nix stops and reports the hash it got, which
replaces it.

## Developing with Nix

`nix develop` gives CMake, Ninja and Portal's pinned Bun, and leaves Xcode's
Swift in charge, for the commands in [Contributing](../CONTRIBUTING.md).
