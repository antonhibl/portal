# SPDX-License-Identifier: GPL-3.0-or-later
# Portal as an Emacs package for Nix: its Lisp, native module and app host,
# built from pinned inputs.  Nix fetches every dependency, each checked by
# hash: Bun, from tools/bun.manifest; the app host's packages; and the Swift
# packages that native/Package.resolved pins, with GhosttyKit's binary.
# SwiftPM then builds them as local packages and downloads nothing.  Apple's
# Swift and Clang come from the host's Xcode, as for any Portal build, so the
# build runs outside Nix's sandbox.  See docs/nix.md.
{
  lib,
  stdenvNoCC,
  fetchurl,
  fetchFromGitHub,
  unzip,
  cmake,
  ninja,
  emacs,
  src,
}:
let
  lines = file: lib.splitString "\n" (builtins.readFile (src + file));
  field = prefix: file: lib.removePrefix prefix (lib.findFirst (lib.hasPrefix prefix) "" (lines file));

  version = field ";; Version: " "/portal.el";

  # Portal's pinned Bun, as resolve-bun.sh would download it.
  bunVersion = field "version " "/tools/bun.manifest";
  bunPlatform = if stdenvNoCC.hostPlatform.isAarch64 then "darwin-aarch64" else "darwin-x64";
  bunEntry = lib.splitString " " (field "${bunPlatform} " "/tools/bun.manifest");
  bun = stdenvNoCC.mkDerivation {
    pname = "portal-bun";
    version = bunVersion;
    src = fetchurl {
      url = builtins.elemAt bunEntry 0;
      sha256 = builtins.elemAt bunEntry 1;
    };
    nativeBuildInputs = [ unzip ];
    sourceRoot = "bun-${bunPlatform}";
    installPhase = "install -Dm755 bun $out/bin/bun";
    # Bun's binary is signed: leave it as released.
    dontFixup = true;
  };

  # The app host's packages, without its development tools.  Both macOS
  # architectures get the same tree, so one hash covers them.
  hostModules = stdenvNoCC.mkDerivation {
    pname = "portal-host-modules";
    inherit version;
    src = src + "/host";
    nativeBuildInputs = [ bun ];
    dontConfigure = true;
    buildPhase = ''
      runHook preBuild
      export HOME=$TMPDIR
      bun install --production --frozen-lockfile --no-progress --os=darwin --cpu=arm64
      runHook postBuild
    '';
    installPhase = "cp -R node_modules $out";
    dontFixup = true;
    outputHashMode = "recursive";
    outputHashAlgo = "sha256";
    outputHash = "sha256-T5f9ri6O2LRKC6znq1P5cZB26+JJ2JHJKLRyQ+Cq73Y=";
  };

  # The Swift packages native/Package.resolved pins.  A pin changes with its
  # hash here; GhosttyKit's binary is the one libghostty-spm names, with its
  # checksum.
  pins = (builtins.fromJSON (builtins.readFile (src + "/native/Package.resolved"))).pins;
  revision = identity: (lib.findFirst (pin: pin.identity == identity) null pins).state.revision;
  libghostty = fetchFromGitHub {
    owner = "Lakr233";
    repo = "libghostty-spm";
    rev = revision "libghostty-spm";
    hash = "sha256-lgaLYeFYRJEvRxvcgYlby8H6WJHLTbTJhRuCmlePL4s=";
  };
  displayLink = fetchFromGitHub {
    owner = "Lakr233";
    repo = "DisplayLink";
    rev = revision "displaylink";
    hash = "sha256-f5MtJ0ytM+VBOglGq1W1M9s+uQsnDZIZJu9vKqrqLKk=";
  };
  ghosttyKitURL = "https://github.com/Lakr233/libghostty-spm/releases/download/upstream.0538f7535be0-2/GhosttyKit.xcframework.zip";
  ghosttyKitChecksum = "bb882b33bb859eb0741d32fc8e428f4b4a650da8a756c8da2b0287aa8c260cea";
  ghosttyKit = fetchurl {
    url = ghosttyKitURL;
    sha256 = ghosttyKitChecksum;
  };
in
stdenvNoCC.mkDerivation {
  pname = "emacs-portal";
  inherit version src;

  nativeBuildInputs = [
    bun
    cmake
    emacs
    ninja
    unzip
  ];

  # Xcode's Swift and Clang build the native module.
  __noChroot = true;
  dontUseCmakeConfigure = true;
  dontUseNinjaBuild = true;
  dontUseNinjaInstall = true;

  postPatch = ''
    # SwiftPM builds the pinned packages from here, as local packages.
    swift=$PWD/nix-swift
    mkdir -p $swift
    cp -R ${libghostty} $swift/libghostty-spm
    cp -R ${displayLink} $swift/DisplayLink
    chmod -R u+w $swift
    unzip -q ${ghosttyKit} -d $swift/libghostty-spm
    substituteInPlace $swift/libghostty-spm/Package.swift \
      --replace-fail '.package(url: "https://github.com/Lakr233/DisplayLink.git", from: "3.0.1")' \
                     '.package(path: "../DisplayLink")' \
      --replace-fail 'url: "${ghosttyKitURL}",' 'path: "GhosttyKit.xcframework"' \
      --replace-fail 'checksum: "${ghosttyKitChecksum}"' ""
    substituteInPlace native/Package.swift \
      --replace-fail '.package(url: "https://github.com/Lakr233/libghostty-spm.git", exact: "2.2.2026100303")' \
                     ".package(path: \"$swift/libghostty-spm\")"
    # SwiftPM rewrites Package.resolved for local packages; the license
    # notices read the pins, and the packages' texts, from here instead.
    cp native/Package.resolved $swift/Package.resolved
    substituteInPlace licenses/notices.ts \
      --replace-fail 'join(root, "native", "Package.resolved")' "\"$swift/Package.resolved\"" \
      --replace-fail 'join(build, "swift", "checkouts", text.slice(6))' "join(\"$swift\", text.slice(6))"
    substituteInPlace CMakeLists.txt \
      --replace-fail ' --force-resolved-versions' "" \
      --replace-fail '--frozen-lockfile' '--frozen-lockfile --production'
    cp -R ${hostModules} host/node_modules
    chmod -R u+w host/node_modules
  '';

  buildPhase = ''
    runHook preBuild
    export HOME=$TMPDIR
    # Apple's toolchain, from Xcode, rather than what Nix's environment names.
    unset DEVELOPER_DIR SDKROOT CC CXX LD NIX_CFLAGS_COMPILE NIX_LDFLAGS MACOSX_DEPLOYMENT_TARGET
    export PATH="$PATH:/usr/bin:/bin:/usr/sbin:/sbin"
    if ! /usr/bin/xcrun --find swift >/dev/null 2>&1; then
      echo "Portal's native module needs Xcode's Swift 6.2 or newer (xcode-select)" >&2
      exit 1
    fi
    cmake --preset dev -DBUILD_TESTING=OFF -DBUN=${bun}/bin/bun \
      -DEMACS=${emacs}/bin/emacs -DEMACS_INCLUDE=${emacs}/include
    cmake --build --preset dev
    runHook postBuild
  '';

  installPhase = ''
    runHook preInstall
    # An installed package, as package.el lays one out, with the build that
    # portal-build.el finds beside its Lisp.
    package=$out/share/emacs/site-lisp/elpa/portal-${version}
    mkdir -p $package/build
    cp portal*.el LICENSE $package/
    cp -R build/portal.bundle build/portal-host build/licenses build/portal-build.eld $package/build/
    (cd $package &&
      emacs --batch -Q -L . -f batch-byte-compile portal*.el &&
      emacs --batch -Q --eval '(loaddefs-generate "." "portal-autoloads.el")')
    cat > $package/portal-pkg.el <<EOF
    (define-package "portal" "${version}" "Native web views and terminals for macOS"
      '((emacs "31.1")) :url "https://github.com/xiaoxinghu/portal")
    EOF
    runHook postInstall
  '';

  # The module and the app host are signed binaries: leave them as built.
  dontFixup = true;

  passthru = {
    inherit bun hostModules;
  };

  meta = {
    description = "Native web views and Ghostty terminals inside macOS Emacs";
    homepage = "https://github.com/xiaoxinghu/portal";
    license = lib.licenses.gpl3Plus;
    platforms = lib.platforms.darwin;
  };
}
