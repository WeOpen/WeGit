#!/bin/bash
set -euo pipefail
# Keep a writable private global config: checkout's post-job safe.directory
# cleanup also writes global configuration, so /dev/null is not a valid target.
isolated_config="$(mktemp "${RUNNER_TEMP:?}/wegit-git-XXXXXX")"
chmod 600 "$isolated_config"
printf 'GIT_CONFIG_GLOBAL=%s\nGIT_CONFIG_SYSTEM=/dev/null\n' "$isolated_config" >> "${GITHUB_ENV:?}"
