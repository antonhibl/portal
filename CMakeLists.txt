# SPDX-License-Identifier: GPL-3.0-or-later
cmake_minimum_required(VERSION 3.29)

# CMake orchestrates the native module, Bun host and integration tests.
project(portal LANGUAGES C)

if(NOT APPLE)
    message(FATAL_ERROR "Portal requires macOS with AppKit and WebKit")
endif()

include(CTest)
# The C Emacs bindings and their fake-backend tests. This locates Emacs and
# emacs-module.h for the rest of the build.
add_subdirectory(native/Core)

# Record Bun's absolute path so the Bun validated here is the one the build and
# tests run. Search again if the recorded executable was removed or moved.
if(DEFINED CACHE{BUN} AND NOT EXISTS "${BUN}")
    message(STATUS "Recorded Bun ${BUN} no longer exists; searching PATH again")
    unset(BUN CACHE)
endif()
find_program(BUN NAMES bun REQUIRED)
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
    # Runs docs/launcher.md's examples; launcher.el is not needed.
    add_test(NAME launcher
        COMMAND "${EMACS}" --batch -Q -L "${CMAKE_SOURCE_DIR}" -L "${CMAKE_SOURCE_DIR}/test"
            -l "${CMAKE_SOURCE_DIR}/test/portal-launcher-tests.el"
            -f ert-run-tests-batch-and-exit)
    set_tests_properties(launcher PROPERTIES TIMEOUT 30)
    # The Lisp module on the real C core, with the fake backend's hot keys.
    add_test(NAME global-shortcut
        COMMAND "${CMAKE_COMMAND}" -E env "PORTAL_TEST_MODULE=$<TARGET_FILE:portal-test-module>"
            "${EMACS}" --batch -Q --module-assertions -L "${CMAKE_SOURCE_DIR}"
            -l "${CMAKE_SOURCE_DIR}/test/portal-global-shortcut-tests.el"
            -f ert-run-tests-batch-and-exit)
    set_tests_properties(global-shortcut PROPERTIES TIMEOUT 30)
    # Exercise the documented absolute-path entry point in a fresh Emacs.
    # Do not add the package directory with -L: Portal must load its own siblings.
    add_test(NAME startup
        COMMAND "${EMACS}" --batch -Q
            -l "${CMAKE_SOURCE_DIR}/test/portal-startup-tests.el"
            -f ert-run-tests-batch-and-exit)
    set_tests_properties(startup PROPERTIES TIMEOUT 30)
    add_executable(portal-process-tests test/portal-process-tests.c)
    target_include_directories(portal-process-tests PRIVATE native/Core/include)
    target_compile_options(portal-process-tests PRIVATE -Wall -Wextra -Werror)
    add_test(NAME processes COMMAND portal-process-tests)
    set_tests_properties(processes PROPERTIES TIMEOUT 30)
    add_test(NAME pi-extension COMMAND "${BUN}" test "${CMAKE_SOURCE_DIR}/test/portal-pi.test.ts")
    set_tests_properties(pi-extension PROPERTIES TIMEOUT 30)
    add_test(NAME vm-runner COMMAND "${BUN}" test "${CMAKE_SOURCE_DIR}/test/vm.test.ts")
    set_tests_properties(vm-runner PROPERTIES TIMEOUT 30)
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
    add_test(NAME terminal-choose
        COMMAND "${EMACS}" --batch -Q -L "${CMAKE_SOURCE_DIR}"
            -l "${CMAKE_SOURCE_DIR}/test/portal-terminal-choose-tests.el"
            -f ert-run-tests-batch-and-exit)
    set_tests_properties(terminal-choose PROPERTIES TIMEOUT 30)
    add_test(NAME agents
        COMMAND "${EMACS}" --batch -Q -L "${CMAKE_SOURCE_DIR}"
            -l "${CMAKE_SOURCE_DIR}/test/portal-agents-tests.el"
            -f ert-run-tests-batch-and-exit)
    set_tests_properties(agents PROPERTIES TIMEOUT 30)
    add_test(NAME agent-discovery
        COMMAND "${CMAKE_COMMAND}" -E env
            "PORTAL_TEST_PROCESS_SNAPSHOT=$<TARGET_FILE:portal-process-tests>"
            "${EMACS}" --batch -Q -L "${CMAKE_SOURCE_DIR}"
            -l "${CMAKE_SOURCE_DIR}/test/portal-agent-discovery-tests.el"
            -f ert-run-tests-batch-and-exit)
    set_tests_properties(agent-discovery PROPERTIES TIMEOUT 30)
    # The optional Consult and Embark adapters, the task view, agent dashboard
    # under Evil and the launcher's graphical completion fixtures use the GNU
    # and NonGNU ELPA releases the user guides name, downloaded once and checked
    # by hash.
    set(elpa_packages
        "elpa.gnu.org/packages/consult-3.10=68aa5daeb701958482dccab3b23a454ff9a9be6b2f4c41fbcc7a353ecfeab096"
        "elpa.gnu.org/packages/embark-1.2=65e4553e709a9619016a635c435f648add310c75601b3b0818ca71c5b46678ea"
        "elpa.gnu.org/packages/vertico-2.15=5c3492edb1e0020da711d9a4213a3878e90e7af8e2e6375757901f4b399872ff"
        "elpa.gnu.org/packages/orderless-1.8=9b4b1253bab2e1d984ad0a31028716d0eff2cd358144bb9caced3b15088e69aa"
        "elpa.gnu.org/packages/marginalia-2.13=e1b228d1d4aa4648982aa79ebb9a2e1d2824b7cd40e01d39ed541f1b7663edba"
        "elpa.gnu.org/packages/dash-2.20.0=28f84b0905f84520163f5dd2087e47cac042bd27b7ec34eeb293f1ada7d36cb2"
        "elpa.nongnu.org/nongnu/evil-1.15.0=1840cc67172a0d7cfbc58dc25eca95dff1375e6a06ddf7bc0ce9034c5ba32f32"
        "elpa.nongnu.org/nongnu/goto-chg-1.7.5=5e6dbb79355e0db5e3b5e5b8643da0738a7b69b9c0b787982b06edc0369abbc8")
    set(elpa_load_path "")
    foreach(entry IN LISTS elpa_packages)
        string(REPLACE "=" ";" entry "${entry}")
        list(GET entry 0 path)
        list(GET entry 1 hash)
        get_filename_component(package "${path}" NAME)
        set(directory "${CMAKE_BINARY_DIR}/elpa/${package}")
        if(NOT EXISTS "${directory}")
            file(DOWNLOAD "https://${path}.tar"
                "${CMAKE_BINARY_DIR}/elpa/${package}.tar" EXPECTED_HASH SHA256=${hash})
            file(ARCHIVE_EXTRACT INPUT "${CMAKE_BINARY_DIR}/elpa/${package}.tar"
                DESTINATION "${CMAKE_BINARY_DIR}/elpa")
            file(REMOVE "${CMAKE_BINARY_DIR}/elpa/${package}.tar")
        endif()
        list(APPEND elpa_load_path -L "${directory}")
    endforeach()
    # The task view is tested with org-ql 0.8.10 and the other libraries it
    # loads that Emacs lacks, and with evil-collection, from their release
    # tags: MELPA Stable keeps only each package's latest release.  Dash and
    # Evil come from GNU and NonGNU ELPA above.
    set(github_packages
        "alphapapa/org-ql=v0.8.10=1a0b416f47bcfb1f45345f62ad5fa89f15c7758941adeb0076db76217078607d"
        "alphapapa/org-super-agenda=v1.3=0ef83a5c42188d571ff977edd54415f09bc833e048b087f1781d492d05a853f7"
        "alphapapa/ts.el=0.3=c79efa802fde5c84fecca01f7b80fbb54b29b792067b5f1a1e517181f2176cc6"
        "emacsorphanage/ov=1.0.6=f2a8bb7bd5077542fa31de38323a9cc31142df0c7864a0f43196cde2722fe336"
        "magnars/s.el=1.13.1=807b9a29f26b5b3ded8e9bba979201b6714cb275286306c32fb72b8098073999"
        "Wilfred/ht.el=2.3=1a85a4659f603f7e2199f82198e7be2f78c32a195cbdd8402435c22f3b233a4b"
        "emacs-evil/evil-collection=3.0.3=d2fddb2689bded204f4ad1b24a06e3c41af12cbb59c1f8b6a2fee1d8ad68d333")
    foreach(entry IN LISTS github_packages)
        string(REPLACE "=" ";" entry "${entry}")
        list(GET entry 0 repository)
        list(GET entry 1 tag)
        list(GET entry 2 hash)
        # GitHub names the folder after the repository and the tag, without a v.
        get_filename_component(name "${repository}" NAME)
        string(REGEX REPLACE "^v" "" version "${tag}")
        set(directory "${CMAKE_BINARY_DIR}/elpa/${name}-${version}")
        if(NOT EXISTS "${directory}")
            file(DOWNLOAD "https://codeload.github.com/${repository}/tar.gz/refs/tags/${tag}"
                "${directory}.tar.gz" EXPECTED_HASH SHA256=${hash})
            file(ARCHIVE_EXTRACT INPUT "${directory}.tar.gz" DESTINATION "${CMAKE_BINARY_DIR}/elpa")
            file(REMOVE "${directory}.tar.gz")
        endif()
        list(APPEND elpa_load_path -L "${directory}")
    endforeach()
    add_test(NAME agents-evil
        COMMAND "${EMACS}" --batch -Q -L "${CMAKE_SOURCE_DIR}" ${elpa_load_path}
            -l "${CMAKE_SOURCE_DIR}/test/portal-agents-evil-tests.el"
            --eval "(ert-run-tests-batch-and-exit 'portal-agents-visit-works-with-evil-collection)")
    set_tests_properties(agents-evil PROPERTIES TIMEOUT 30)
    add_test(NAME tasks-view
        COMMAND "${EMACS}" --batch -Q -L "${CMAKE_SOURCE_DIR}" ${elpa_load_path}
            -l "${CMAKE_SOURCE_DIR}/test/portal-tasks-view-tests.el"
            -f ert-run-tests-batch-and-exit)
    set_tests_properties(tasks-view PROPERTIES TIMEOUT 30)
    foreach(adapter consult embark)
        add_test(NAME terminal-${adapter}
            COMMAND "${EMACS}" --batch -Q -L "${CMAKE_SOURCE_DIR}" ${elpa_load_path}
                -l "${CMAKE_SOURCE_DIR}/test/portal-terminal-${adapter}-tests.el"
                -f ert-run-tests-batch-and-exit)
        set_tests_properties(terminal-${adapter} PROPERTIES TIMEOUT 30)
    endforeach()
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
