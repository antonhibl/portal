# SPDX-License-Identifier: GPL-3.0-or-later
cmake_minimum_required(VERSION 3.29)

# SourceKit-LSP needs the compiler inside the toolchain, not /usr/bin/swiftc.
if(NOT DEFINED CMAKE_Swift_COMPILER)
    execute_process(COMMAND xcrun --find swiftc
        OUTPUT_VARIABLE CMAKE_Swift_COMPILER OUTPUT_STRIP_TRAILING_WHITESPACE
        COMMAND_ERROR_IS_FATAL ANY)
endif()
project(anymacs LANGUAGES C Swift)
set(CMAKE_EXPORT_COMPILE_COMMANDS ON)
# Both clangd and SourceKit-LSP discover the database at the source root.
file(CREATE_LINK "${CMAKE_BINARY_DIR}/compile_commands.json"
    "${CMAKE_SOURCE_DIR}/compile_commands.json" SYMBOLIC)

if(NOT APPLE)
    message(FATAL_ERROR "Anymacs requires macOS with AppKit and WebKit")
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
    OUTPUT "${CMAKE_BINARY_DIR}/anymacs-host"
    COMMAND "${BUN}" build "${CMAKE_SOURCE_DIR}/host/server.ts"
        --compile --minify --sourcemap
        --no-compile-autoload-dotenv --no-compile-autoload-bunfig
        --outfile "${CMAKE_BINARY_DIR}/.anymacs-host"
    COMMAND "${CMAKE_COMMAND}" -E rename
        "${CMAKE_BINARY_DIR}/.anymacs-host" "${CMAKE_BINARY_DIR}/anymacs-host"
    DEPENDS host/server.ts host/hello.html host/markdown.ts host/markdown.css
        host/package.json host/tsconfig.json "${BUN}"
    WORKING_DIRECTORY "${CMAKE_SOURCE_DIR}"
    COMMENT "Compiling the standalone Bun UI host"
    VERBATIM)
add_custom_target(anymacs-ui-host ALL DEPENDS "${CMAKE_BINARY_DIR}/anymacs-host")

if(DEFINED ENV{EMACS} AND NOT DEFINED EMACS)
    set(EMACS "$ENV{EMACS}" CACHE FILEPATH "Emacs executable")
endif()
find_program(EMACS NAMES emacs REQUIRED)
include(CTest)
if(BUILD_TESTING)
    add_test(NAME ui-host
        COMMAND "${CMAKE_COMMAND}" -E env
            "ANYMACS_TEST_HOST=${CMAKE_BINARY_DIR}/anymacs-host"
            "${EMACS}" --batch -Q -L "${CMAKE_SOURCE_DIR}"
            -l "${CMAKE_SOURCE_DIR}/test/anymacs-server-tests.el"
            -f ert-run-tests-batch-and-exit)
    set_tests_properties(ui-host PROPERTIES TIMEOUT 30)
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

add_library(anymacs MODULE native/bootstrap.c native/Module.swift native/NativeView.swift)
set_target_properties(anymacs PROPERTIES
    PREFIX "" SUFFIX ".dylib"
    LIBRARY_OUTPUT_DIRECTORY "${CMAKE_BINARY_DIR}/native"
    Swift_MODULE_NAME Anymacs
    Swift_LANGUAGE_VERSION 6)
target_include_directories(anymacs PRIVATE "${EMACS_INCLUDE}")
file(MAKE_DIRECTORY "${CMAKE_BINARY_DIR}/pch")
target_compile_options(anymacs PRIVATE
    "$<$<COMPILE_LANGUAGE:C>:-Wall;-Wextra;-Werror>"
    "$<$<COMPILE_LANGUAGE:Swift>:-warnings-as-errors;-import-objc-header;${EMACS_INCLUDE}/emacs-module.h;-pch-output-dir;${CMAKE_BINARY_DIR}/pch>")
find_library(APPKIT_FRAMEWORK AppKit REQUIRED)
find_library(WEBKIT_FRAMEWORK WebKit REQUIRED)
target_link_libraries(anymacs PRIVATE "${APPKIT_FRAMEWORK}" "${WEBKIT_FRAMEWORK}")

# Publish a copy atomically; never relink a library already mapped by Emacs.
add_custom_command(TARGET anymacs POST_BUILD
    COMMAND "${CMAKE_COMMAND}" -E copy "$<TARGET_FILE:anymacs>" "${CMAKE_BINARY_DIR}/.anymacs.dylib"
    COMMAND "${CMAKE_COMMAND}" -E rename "${CMAKE_BINARY_DIR}/.anymacs.dylib" "${CMAKE_BINARY_DIR}/anymacs.dylib"
    BYPRODUCTS "${CMAKE_BINARY_DIR}/anymacs.dylib"
    VERBATIM)
