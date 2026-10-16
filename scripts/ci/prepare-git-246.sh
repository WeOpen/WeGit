#!/bin/bash
set -euo pipefail
project_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
# Annotated v2.46.0 tag resolves to this exact upstream commit.
mkdir -p "$project_root/.build"
git_commit=39bf06adf96da25b87c9aa7d35a32ef3683eb4a4
build_root="$(mktemp -d "$project_root/.build/git-246-XXXXXX")"
install_root="$build_root/install"
env GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_SYSTEM=/dev/null git init -q "$build_root/source"
env GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_SYSTEM=/dev/null git -C "$build_root/source" \
  -c http.lowSpeedLimit=1024 -c http.lowSpeedTime=60 \
  fetch --quiet --depth 1 https://github.com/git/git.git refs/tags/v2.46.0:refs/tags/v2.46.0
test "$(git -C "$build_root/source" rev-parse v2.46.0^{commit})" = "$git_commit"
git -C "$build_root/source" checkout --quiet --detach "$git_commit"
test "$(git -C "$build_root/source" rev-parse HEAD)" = "$git_commit"
make -C "$build_root/source" -j2 prefix="$install_root" NO_GETTEXT=YesPlease NO_TCLTK=YesPlease all install
"$install_root/bin/git" --version | grep -Fx 'git version 2.46.0'
if [[ -n "${GITHUB_ENV:-}" ]]; then
  echo "WEGIT_TEST_GIT_246=$install_root/bin/git" >> "$GITHUB_ENV"
fi
printf '%s\n' "$install_root/bin/git" > "$project_root/.build/git-246-path"
