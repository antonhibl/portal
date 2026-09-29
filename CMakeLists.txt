# SPDX-License-Identifier: GPL-3.0-or-later
cmake_minimum_required(VERSION 3.29)

# CMake orchestrates the native module, Bun host and integration tests.
project(portal LANGUAGES NONE)

if(NOT APPLE)
    message(FATAL_ERROR "Portal requires macOS with AppKit and WebKit")
endif()

include(CTest)
# The C Emacs bindings and their fake-backend tests. This locates Emacs and
# emacs-module.h for the rest of the build.
add_subdirectory(native/Core)

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
    COMMAND "${BUN}" install --cwd "${CMAKE_SOURCE_DIR}/host" --frozen-lockfile
    COMMAND "${BUN}" run "${CMAKE_SOURCE_DIR}/host/build-editor.ts"
    COMMAND "${BUN}" build "${CMAKE_SOURCE_DIR}/host/server.ts"
        --compile --minify --sourcemap
        --no-compile-autoload-dotenv --no-compile-autoload-bunfig
        --outfile "${CMAKE_BINARY_DIR}/.portal-host"
    COMMAND "${CMAKE_COMMAND}" -E rename
        "${CMAKE_BINARY_DIR}/.portal-host" "${CMAKE_BINARY_DIR}/portal-host"
    DEPENDS host/actions.ts host/server.ts host/hello.html host/markdown.ts host/markdown.css
        host/tasks.ts host/tasks-client.ts host/tasks.css
        host/package.json host/bun.lock host/tsconfig.json host/build-editor.ts
        host/editor-bootstrap.ts host/excalidraw.tsx host/excalidraw.html host/excalidraw.css "${BUN}"
    WORKING_DIRECTORY "${CMAKE_SOURCE_DIR}"
    COMMENT "Compiling the standalone Bun UI host"
    VERBATIM)
add_custom_target(portal-ui-host ALL DEPENDS "${CMAKE_BINARY_DIR}/portal-host")

if(BUILD_TESTING)
    add_test(NAME host-actions COMMAND "${BUN}" test "${CMAKE_SOURCE_DIR}/host/actions.test.ts")
    add_test(NAME host-tasks COMMAND "${BUN}" test "${CMAKE_SOURCE_DIR}/host/tasks.test.ts")
    add_test(NAME actions
        COMMAND "${CMAKE_COMMAND}" -E env
            "PORTAL_TEST_HOST=${CMAKE_BINARY_DIR}/portal-host"
            "${EMACS}" --batch -Q -L "${CMAKE_SOURCE_DIR}" -L "${CMAKE_SOURCE_DIR}/test"
            -l "${CMAKE_SOURCE_DIR}/test/portal-actions-tests.el"
            -f ert-run-tests-batch-and-exit)
    set_tests_properties(actions PROPERTIES TIMEOUT 30)
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
    add_test(NAME terminal-metadata
        COMMAND "${EMACS}" --batch -Q -L "${CMAKE_SOURCE_DIR}"
            -l "${CMAKE_SOURCE_DIR}/test/portal-terminal-metadata-tests.el"
            -f ert-run-tests-batch-and-exit)
    set_tests_properties(terminal-metadata PROPERTIES TIMEOUT 30)
    add_test(NAME view
        COMMAND "${EMACS}" --batch -Q -L "${CMAKE_SOURCE_DIR}"
            -l "${CMAKE_SOURCE_DIR}/test/portal-view-tests.el"
            -f ert-run-tests-batch-and-exit)
    set_tests_properties(view PROPERTIES TIMEOUT 30)
    add_test(NAME web
        COMMAND "${CMAKE_COMMAND}" -E env
            "PORTAL_TEST_HOST=${CMAKE_BINARY_DIR}/portal-host"
            "${EMACS}" --batch -Q -L "${CMAKE_SOURCE_DIR}"
            -l "${CMAKE_SOURCE_DIR}/test/portal-web-tests.el"
            -f ert-run-tests-batch-and-exit)
    set_tests_properties(web PROPERTIES TIMEOUT 30)
    add_test(NAME tasks
        COMMAND "${CMAKE_COMMAND}" -E env
            "PORTAL_TEST_HOST=${CMAKE_BINARY_DIR}/portal-host"
            "${EMACS}" --batch -Q -L "${CMAKE_SOURCE_DIR}"
            -l "${CMAKE_SOURCE_DIR}/test/portal-tasks-tests.el"
            -f ert-run-tests-batch-and-exit)
    set_tests_properties(tasks PROPERTIES TIMEOUT 30)
    add_test(NAME toolbar
        COMMAND "${EMACS}" --batch -Q -L "${CMAKE_SOURCE_DIR}"
            -l "${CMAKE_SOURCE_DIR}/test/portal-toolbar-tests.el"
            -f ert-run-tests-batch-and-exit)
    set_tests_properties(toolbar PROPERTIES TIMEOUT 30)
    add_test(NAME input
        COMMAND "${EMACS}" --batch -Q -L "${CMAKE_SOURCE_DIR}"
            -l "${CMAKE_SOURCE_DIR}/test/portal-input-tests.el"
            -f ert-run-tests-batch-and-exit)
    set_tests_properties(input PROPERTIES TIMEOUT 30)
    add_test(NAME terminal-bindings
        COMMAND "${EMACS}" --batch -Q -L "${CMAKE_SOURCE_DIR}"
            -l "${CMAKE_SOURCE_DIR}/test/portal-terminal-bindings-tests.el"
            -f ert-run-tests-batch-and-exit)
    set_tests_properties(terminal-bindings PROPERTIES TIMEOUT 30)
    add_test(NAME excalidraw
        COMMAND "${EMACS}" --batch -Q -L "${CMAKE_SOURCE_DIR}"
            -l "${CMAKE_SOURCE_DIR}/test/portal-excalidraw-tests.el"
            -f ert-run-tests-batch-and-exit)
    set_tests_properties(excalidraw PROPERTIES TIMEOUT 30)
endif()
# SwiftPM builds the one native module: the C bindings and the Swift backend.
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
