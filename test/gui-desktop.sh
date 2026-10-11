# SPDX-License-Identifier: GPL-3.0-or-later
# Sourced by graphical test scripts after they set root, before they use their
# arguments. When PORTAL_TEST_VM or this clone's `git config portal.testVm`
# names a VM, the script reruns itself there through test/vm.sh, which picks
# the alias, so its windows stay off this desktop. Every worktree shares the
# setting. The VM's copy has no Git metadata, so there the script runs on the
# guest's desktop.
if [ -e "$root/.git" ] && { [ -n "${PORTAL_TEST_VM:-}" ] ||
    [ -n "$(git -C "$root" config --get portal.testVm || :)" ]; }; then
    exec bash "$root/test/vm.sh" sh "test/${0##*/}" "$@"
fi
