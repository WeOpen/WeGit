#!/bin/bash
set -euo pipefail
project_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$project_root"
case "${1:-}" in ''|--compile-only) ;; *) echo "Usage: scripts/verify-gpg-compatibility.sh [--compile-only]" >&2; exit 2 ;; esac
mkdir -p .build
check_run="$(mktemp -d "$project_root/.build/gpg-compatibility-XXXXXX")"
swift build --product WeGitAskPass
sdk_path="$(xcrun --sdk macosx --show-sdk-path)"
library_path="$(swift build --show-bin-path)"
xcrun swiftc -parse-as-library -sdk "$sdk_path" -target arm64-apple-macosx27.0 \
  -I "$library_path" "$library_path/WeGitCore.o" scripts/GPGCompatibilityChecks.swift \
  -o "$check_run/checks"
ditto "$library_path/WeGit_WeGitCore.bundle" "$check_run/WeGit_WeGitCore.bundle"
if [[ "${1:-}" == --compile-only ]]; then
  echo "GPG compatibility checker compiled; no signing check executed."
  exit 0
fi
report_directory="$project_root/.build/ci/gpg-compatibility"
mkdir -p "$report_directory"
brew_executable="$(command -v brew)"
brew_git="$("$brew_executable" --prefix git)/bin/git"
gpg_prefix="$("$brew_executable" --prefix gnupg)"
apple_git="$(xcrun --find git)"
for executable in "$brew_git" "$gpg_prefix/bin/gpg" "$gpg_prefix/bin/gpgconf"; do
  if [[ ! -x "$executable" ]]; then
    echo "Required installed Homebrew Git/GnuPG binary is unavailable; no fallback or installation was attempted." >&2
    exit 78
  fi
done
"$brew_executable" list --versions git gnupg > "$report_directory/homebrew-versions.txt"
python3 - "$report_directory/source.json" <<'PY'
from pathlib import Path
import hashlib, json, subprocess, sys
source = sorted(path for path in Path('WeGitCore').rglob('*') if path.is_file() and not path.is_symlink())
digest = hashlib.sha256()
for path in source:
    digest.update(path.as_posix().encode() + b'\0' + hashlib.sha256(path.read_bytes()).digest())
report = {
    'commit': subprocess.check_output(['git', 'rev-parse', 'HEAD'], text=True).strip(),
    'workspaceDirty': bool(subprocess.check_output(['git', 'status', '--porcelain'], text=True)),
    'coreSourceSHA256': digest.hexdigest(), 'coreInputCount': len(source),
    'coreDigestMethod': 'SHA256 of sorted relative path, NUL and file SHA256 bytes',
    'checksSHA256': hashlib.sha256(Path('scripts/GPGCompatibilityChecks.swift').read_bytes()).hexdigest(),
    'fixture': 'Private mkdtemp directory, global Git file and GNUPGHOME; no original HOME changes',
    'scope': 'Noninteractive unprotected ephemeral OpenPGP signing only',
    'releaseReady': False,
}
Path(sys.argv[1]).write_text(json.dumps(report, indent=2) + '\n')
PY
validation_failed=0
if ! "$check_run/checks" "$apple_git" "$gpg_prefix/bin/gpg" "$gpg_prefix/bin/gpgconf" "$report_directory/apple.json" apple; then validation_failed=1; fi
if ! "$check_run/checks" "$brew_git" "$gpg_prefix/bin/gpg" "$gpg_prefix/bin/gpgconf" "$report_directory/homebrew.json" homebrew; then validation_failed=1; fi
echo "Reports: $report_directory"
exit "$validation_failed"
