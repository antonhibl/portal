# SPDX-License-Identifier: GPL-3.0-or-later
cmake_minimum_required(VERSION 3.29)

# CMake orchestrates the native Swift package, Bun host and integration tests.
project(portal LANGUAGES NONE)

if(NOT APPLE)
    message(FATAL_ERROR "Portal requires macOS with AppKit and WebKit")
endif()

find_program(BUN NAMES bun HINTS "$ENV{HOME}/.bun/bin" REQUIRED)
execute_process(COMMAND "${BUN}" -e
    "if (typeof Bun.markdown?.html !== 'function') process.exit(1)"
    RESULT_VARIABLE bun_markdown_status)
if(NOT bun_markdown_status EQUAL 0)
    message(FATAL_ERROR "Bun must support Bun.markdown.html (tested with Bun 1.3.14)")
endif()
# The executable includes Bun and all UI assets; Bun is only a build dependency.
# Publish atomically so a running host can survive a rebuild.
add_custom_command(
    OUTPUT "${CMAKE_BINARY_DIR}/portal-host"
    COMMAND "${BUN}" build "${CMAKE_SOURCE_DIR}/host/server.ts"
        --compile --minify --sourcemap
        --no-compile-autoload-dotenv --no-compile-autoload-bunfig
        --outfile "${CMAKE_BINARY_DIR}/.portal-host"
    COMMAND "${CMAKE_COMMAND}" -E rename
        "${CMAKE_BINARY_DIR}/.portal-host" "${CMAKE_BINARY_DIR}/portal-host"
    DEPENDS host/server.ts host/hello.html host/markdown.ts host/markdown.css
        host/package.json host/tsconfig.json "${BUN}"
    WORKING_DIRECTORY "${CMAKE_SOURCE_DIR}"
    COMMENT "Compiling the standalone Bun UI host"
    VERBATIM)
add_custom_target(portal-ui-host ALL DEPENDS "${CMAKE_BINARY_DIR}/portal-host")

if(DEFINED ENV{EMACS} AND NOT DEFINED EMACS)
    set(EMACS "$ENV{EMACS}" CACHE FILEPATH "Emacs executable")
endif()
find_program(EMACS NAMES emacs REQUIRED)
include(CTest)
if(BUILD_TESTING)
    add_test(NAME ui-host
        COMMAND "${CMAKE_COMMAND}" -E env
            "PORTAL_TEST_HOST=${CMAKE_BINARY_DIR}/portal-host"
            "${EMACS}" --batch -Q -L "${CMAKE_SOURCE_DIR}"
            -l "${CMAKE_SOURCE_DIR}/test/portal-server-tests.el"
            -f ert-run-tests-batch-and-exit)
    set_tests_properties(ui-host PROPERTIES TIMEOUT 30)
    add_test(NAME quick-terminal
        COMMAND "${EMACS}" --batch -Q -L "${CMAKE_SOURCE_DIR}"
            -l "${CMAKE_SOURCE_DIR}/test/portal-terminal-quick-tests.el"
            -f ert-run-tests-batch-and-exit)
    set_tests_properties(quick-terminal PROPERTIES TIMEOUT 30)
    add_test(NAME terminal-bindings
        COMMAND "${EMACS}" --batch -Q -L "${CMAKE_SOURCE_DIR}"
            -l "${CMAKE_SOURCE_DIR}/test/portal-terminal-bindings-tests.el"
            -f ert-run-tests-batch-and-exit)
    set_tests_properties(terminal-bindings PROPERTIES TIMEOUT 30)
endif()
set(EMACS_INCLUDE "$ENV{EMACS_INCLUDE}" CACHE PATH "Directory containing emacs-module.h")
if(NOT EMACS_INCLUDE)
    execute_process(COMMAND "${EMACS}" --batch -Q --eval
        "(princ (expand-file-name \"../include\" data-directory))"
        OUTPUT_VARIABLE emacs_include OUTPUT_STRIP_TRAILING_WHITESPACE
        COMMAND_ERROR_IS_FATAL ANY)
    unset(EMACS_INCLUDE CACHE)
    find_path(EMACS_INCLUDE emacs-module.h HINTS "${emacs_include}")
endif()
if(NOT EXISTS "${EMACS_INCLUDE}/emacs-module.h")
    message(FATAL_ERROR "Set -DEMACS_INCLUDE=/path/to/include containing emacs-module.h")
endif()

# SwiftPM builds the one native module, including its small C entry point.
# Keep the bundle intact: Ghostty locates terminfo and shell integration here.
file(WRITE "${CMAKE_BINARY_DIR}/emacs-include.txt" "${EMACS_INCLUDE}\n")
set(native_package "${CMAKE_SOURCE_DIR}/native")
set(native_scratch "${CMAKE_BINARY_DIR}/swift")
set(native_bundle "${CMAKE_BINARY_DIR}/portal.bundle/Contents")
execute_process(
    COMMAND "${CMAKE_COMMAND}" -E env "EMACS_INCLUDE=${EMACS_INCLUDE}"
        xcrun swift build --package-path "${native_package}"
        --scratch-path "${native_scratch}" -c release --show-bin-path
    OUTPUT_VARIABLE native_bin OUTPUT_STRIP_TRAILING_WHITESPACE
    COMMAND_ERROR_IS_FATAL ANY)
add_custom_target(portal ALL
    COMMAND "${CMAKE_COMMAND}" -E env "EMACS_INCLUDE=${EMACS_INCLUDE}"
        xcrun swift build --package-path "${native_package}"
        --scratch-path "${native_scratch}" -c release --product portal
        --force-resolved-versions
    COMMAND "${CMAKE_COMMAND}" -E make_directory "${native_bundle}/MacOS" "${native_bundle}/Resources"
    COMMAND "${CMAKE_COMMAND}" -E copy "${native_package}/Info.plist" "${native_bundle}/Info.plist"
    COMMAND "${CMAKE_COMMAND}" -E copy_directory
        "${native_bin}/GhosttyKit_GhosttyTerminal.bundle"
        "${native_bundle}/Resources/GhosttyKit_GhosttyTerminal.bundle"
    # Publish atomically: never overwrite a library already mapped by Emacs.
    COMMAND "${CMAKE_COMMAND}" -E copy
        "${native_bin}/libportal.dylib" "${native_bundle}/MacOS/.portal.dylib"
    COMMAND "${CMAKE_COMMAND}" -E rename
        "${native_bundle}/MacOS/.portal.dylib" "${native_bundle}/MacOS/portal.dylib"
    BYPRODUCTS "${native_bundle}/MacOS/portal.dylib"
    COMMENT "Building the Portal native module"
    VERBATIM)
