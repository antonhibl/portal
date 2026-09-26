// swift-tools-version: 6.0
// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import PackageDescription

// CMake writes the discovered header path for both builds and SourceKit-LSP.
let configuration = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
    .appendingPathComponent("../build/emacs-include.txt")
guard let emacsInclude = ProcessInfo.processInfo.environment["EMACS_INCLUDE"]
    ?? (try? String(contentsOf: configuration, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines)) else {
    fatalError("Run cmake --preset dev or build.sh to locate emacs-module.h")
}

let package = Package(
    name: "Portal",
    platforms: [.macOS(.v13)],
    products: [.library(name: "portal", type: .dynamic, targets: ["Portal"])],
    dependencies: [
        .package(url: "https://github.com/Lakr233/libghostty-spm.git", exact: "1.6.20260909")
    ],
    targets: [
        // The C ABI entry point and header import; all Swift features share one target.
        .target(name: "CEmacs", path: "Emacs",
                cSettings: [.unsafeFlags(["-I", emacsInclude, "-Wall", "-Wextra", "-Werror"])]),
        .target(name: "Portal", dependencies: [
            "CEmacs", .product(name: "GhosttyTerminal", package: "libghostty-spm"),
            .product(name: "GhosttyTheme", package: "libghostty-spm")
        ], path: ".", exclude: ["Emacs", "Info.plist"],
           sources: ["Module.swift", "NativeHost.swift", "NativeEventChannel.swift", "NativeInput.swift",
                     "Views.swift", "WebView.swift", "WebEditor.swift", "Terminal.swift", "Toolbar.swift",
                     "WebToolbar.swift"],
           swiftSettings: [.unsafeFlags(["-warnings-as-errors", "-Xcc", "-I" + emacsInclude])])
    ]
)
