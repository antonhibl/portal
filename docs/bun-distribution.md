# Bun build and distribution options

Recorded: 2026-09-17. Status: decision deferred.

## Current behaviour

`./build.sh` uses CMake to build the native Emacs module and compile the
TypeScript server into `build/portal-host`. CMake currently requires `bun` on
`PATH` and invokes it by name.

Bun is a **build dependency**, but users running the compiled host do not need
to install it. The host executable contains the Bun runtime, server code, and
Hello World page assets. See [Bun's standalone executable documentation](https://bun.com/docs/bundler/executables).

Source builds also require graphical macOS Emacs and its module header, Apple's
Swift/Clang toolchain, CMake, and Ninja. Removing the Bun installation step does
not remove these native build requirements.

## Options

| Approach | User experience | Tradeoffs |
| --- | --- | --- |
| Keep the current build requirement | Install Bun, then run `./build.sh`. | Simplest build setup, but requires users building from source to manage Bun. |
| Automatically download Bun during the build | Run `./build.sh`; CMake obtains its own Bun compiler. | No manual Bun installation; first build needs a download or a supplied local executable. |
| Distribute a prebuilt host | Install a release containing the matching `portal-host`, or have the build download it. | No Bun compiler needed on the user's machine; we maintain release artifacts for each supported architecture. |

### Automatically download Bun

Proposed implementation:

- Pin a Bun version and archive checksum for each supported Mac architecture.
- Download and extract it into a private build directory such as `build/tools/`.
- Verify the archive checksum before extraction and execution.
- Invoke the downloaded executable directly, without modifying `PATH`, shell
  configuration, or a global Bun installation.
- Cache it for subsequent builds and fall back to `bun` on `PATH` for
  development and offline builds.

Bun provides direct executable downloads for macOS Apple Silicon and Intel.
See the [installation documentation](https://bun.com/docs/installation).
CMake provides [download, hash verification, and archive extraction](https://cmake.org/cmake/help/latest/command/file.html).

This keeps the single-command source build. Bun remains a build dependency,
but the project manages it. A clean offline build would need a supplied Bun
executable or a previously populated cache.

### Distribute a prebuilt host

Proposed implementation:

- Build and test `portal-host` in CI for macOS Apple Silicon and Intel.
- Publish versioned artifacts with checksums, paired with the matching Lisp
  package and control protocol.
- Include the host in release packages, or download the matching artifact
  during installation/build.
- Make CMake's Bun requirement conditional so using a prebuilt host skips
  server compilation. Retain source compilation for development.

Bun supports compiling executables for both Mac architectures; each artifact
should still be tested on its target. Shipping just the prebuilt host leaves
the native Emacs module to be built locally. Distributing that module as well
would need a separate compatibility and release plan.

## Size measurements

Measured locally on Apple Silicon with Bun 1.3.14. These are uncompressed file
sizes, not download sizes or runtime memory usage.

| Artifact | Bytes | MB (decimal) | MiB |
| --- | ---: | ---: | ---: |
| Bun executable | 63,096,576 | 63.1 | 60.2 |
| Compiled Hello World host, including Bun | 63,446,114 | 63.4 | 60.5 |

Almost all the host's size comes from the runtime. A distributed compiled host
already includes Bun, so it needs no separate Bun executable. A local source
build using the automatic-download option would retain both the cached compiler
and the compiled host. Sizes will vary with Bun versions and target architecture.

## Recommendation to revisit

Automatically download a pinned Bun for source builds, then add prebuilt host
artifacts when establishing releases. These options can coexist: contributors
build from source while release users receive the compiled host.

This is a proposal, not an accepted decision. Neither automatic download nor
prebuilt artifact distribution is implemented; the current build still requires
an installed Bun executable.
