# SPDX-License-Identifier: GPL-3.0-or-later
cmake_minimum_required(VERSION 3.29)

# Portal's C Emacs bindings, tested against a fake backend. This needs only a
# C compiler and Emacs: no Swift, Apple frameworks, Bun or Ghostty. The
# top-level project includes it, and it can be configured alone to run just
# these tests. SwiftPM compiles the same sources into the production module.
project(portal-core LANGUAGES C)
set(portal_root "${CMAKE_CURRENT_SOURCE_DIR}/../..")

if(DEFINED ENV{EMACS} AND NOT DEFINED EMACS)
    set(EMACS "$ENV{EMACS}" CACHE FILEPATH "Emacs executable")
endif()
find_program(EMACS NAMES emacs REQUIRED)
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

include(CTest)
if(BUILD_TESTING)
    # The real bindings with test/portal-fake-backend.c in place of native/Backend.swift.
    add_library(portal-test-module MODULE emacs.c "${portal_root}/test/portal-fake-backend.c")
    target_include_directories(portal-test-module PRIVATE include "${EMACS_INCLUDE}")
    target_compile_options(portal-test-module PRIVATE -Wall -Wextra -Werror)
    set_target_properties(portal-test-module PROPERTIES
        C_STANDARD 11 C_STANDARD_REQUIRED ON C_EXTENSIONS OFF PREFIX "")
    add_test(NAME module
        COMMAND "${CMAKE_COMMAND}" -E env "PORTAL_TEST_MODULE=$<TARGET_FILE:portal-test-module>"
            "${EMACS}" --batch -Q --module-assertions
            -l "${portal_root}/test/portal-module-tests.el"
            -f ert-run-tests-batch-and-exit)
    set_tests_properties(module PROPERTIES TIMEOUT 30)
endif()
