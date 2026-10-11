# SPDX-License-Identifier: GPL-3.0-or-later
# Sourced by graphical test scripts after they set root, before they use their
# arguments. When this clone sets `git config portal.testVm <ssh-alias>`, the
# script reruns itself in that VM through test/vm.sh, so its windows stay off
# this desktop. Every worktree shares the setting. The VM's copy has no Git
# metadata, so there the script runs on the guest's desktop.
if [ -e "$root/.git" ]; then
    portal_test_vm=$(git -C "$root" config --get portal.testVm || :)
    if [ -n "$portal_test_vm" ]; then
        PORTAL_TEST_VM=$portal_test_vm exec bash "$root/test/vm.sh" \
            sh "test/${0##*/}" "$@"
    fi
fi
