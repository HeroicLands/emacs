#!/bin/sh
# SPDX-License-Identifier: GPL-3.0-or-later
set -eu
root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
work=$(mktemp -d "${TMPDIR:-/tmp}/emacs hooks.XXXXXX")
trap 'rm -rf "$work"' 0
export GIT_CONFIG_NOSYSTEM=1 GIT_CONFIG_GLOBAL=/dev/null
unset GIT_CONFIG_COUNT GIT_DIR GIT_WORK_TREE GIT_INDEX_FILE GIT_COMMON_DIR
fail() { printf '%s\n' "$*" >&2; exit 1; }
pass() { "$@" >"$work/output" 2>&1 || { cat "$work/output" >&2; fail "Expected success: $*"; }; }
refuse() {
    expected=$1
    shift
    if "$@" >"$work/output" 2>&1; then fail "Expected refusal: $*"; fi
    grep -F "$expected" "$work/output" >/dev/null || {
        cat "$work/output" >&2
        fail "Missing hook diagnostic: $expected"
    }
}
identity() {
    git -C "$1" config user.name 'Hook Test'
    git -C "$1" config user.email 'hook@example.com'
    git -C "$1" config commit.gpgsign false
}
# Snapshot the setup inputs so this also tests uncommitted changes.
seed="$work/source"
git init -q -b main "$seed"
identity "$seed"
cp "$root/Makefile" "$seed/Makefile"
cp -R "$root/.githooks" "$seed/.githooks"
git -C "$seed" add -- Makefile .githooks
git -C "$seed" -c core.hooksPath=/dev/null commit -qm 'Hook installation fixture'

clone="$work/fresh clone"
git clone -q "$seed" "$clone"
identity "$clone"
pass make -C "$clone" hooks
[ "$(git -C "$clone" config --local core.hooksPath)" = .githooks ] || fail 'Hooks were not configured locally'
refuse "protected branch 'main'" git -C "$clone" commit --allow-empty -m 'Protected commit'
git -C "$clone" switch -q -c feature
pass git -C "$clone" commit --allow-empty -m 'Ordinary developer prose'
refuse 'Co-Authored-By trailer naming an assistant' git -C "$clone" commit --allow-empty -m 'Co-Authored-By: Contributor <codex@openai.com>'

# Start with another fresh clone so setup is performed from the worktree.
parent="$work/worktree clone"
linked="$work/linked worktree"
git clone -q "$seed" "$parent"
identity "$parent"
git -C "$parent" worktree add -q -b linked "$linked"
pass make -C "$linked" hooks
[ "$(git -C "$parent" config --local core.hooksPath)" = .githooks ] || fail 'Worktree setup did not configure the clone'
refuse "protected branch 'main'" git -C "$parent" commit --allow-empty -m 'Protected parent commit'
pass git -C "$linked" commit --allow-empty -m 'Ordinary linked-worktree prose'
refuse 'Co-Authored-By trailer naming an assistant' git -C "$linked" commit --allow-empty -m 'Co-Authored-By: Contributor <codex@openai.com>'
printf '%s\n' 'Hook setup passes in fresh clones and a linked worktree.'
