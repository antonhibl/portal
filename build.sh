#!/bin/sh
# SPDX-License-Identifier: GPL-3.0-or-later
set -eu
cd "$(dirname "$0")"

EMACS=${EMACS:-emacs}
# App-bundle installations keep include/ beside etc/. Other installations can
# provide EMACS_INCLUDE, e.g. EMACS_INCLUDE=/opt/homebrew/include ./build.sh.
EMACS_INCLUDE=${EMACS_INCLUDE:-$("$EMACS" --batch -Q --eval \
  '(princ (expand-file-name "../include" data-directory))')}
if [ ! -f "$EMACS_INCLUDE/emacs-module.h" ]; then
    echo "Set EMACS_INCLUDE to the directory containing emacs-module.h." >&2
    exit 1
fi

mkdir -p build
xcrun clang -Wall -Wextra -Werror -fPIC -I "$EMACS_INCLUDE" \
    -c native/bootstrap.c -o build/bootstrap.o
xcrun swiftc -swift-version 6 -warnings-as-errors -emit-library -module-name Anymacs \
    -import-objc-header "$EMACS_INCLUDE/emacs-module.h" \
    native/Module.swift native/NativeView.swift build/bootstrap.o -framework AppKit \
    -o build/.anymacs.dylib
# Replace atomically so rebuilding cannot overwrite a library mapped by Emacs.
mv -f build/.anymacs.dylib build/anymacs.dylib
echo "Built build/anymacs.dylib"
