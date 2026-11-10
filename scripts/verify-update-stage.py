#!/usr/bin/env python3
"""Compile the actual transient stage helper and exercise private SQLite captures."""
import hashlib
import json
from pathlib import Path
import shutil
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parents[1]


def digest(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def run(command, log):
    with log.open('w') as stream:
        result = subprocess.run(command, cwd=ROOT, stdout=stream, stderr=subprocess.STDOUT)
    if result.returncode:
        raise RuntimeError(f'Command failed ({result.returncode}); retained log: {log}')


def main():
    folder = Path(tempfile.mkdtemp(prefix='update-stage-', dir=ROOT / '.build'))
    names = ['Package.swift', 'WeGit/App/UpdateApplicationBridge.swift',
             'scripts/UpdateStageChecks.swift', 'scripts/verify-update-stage.py']
    names += [str(path.relative_to(ROOT)) for base in ['WeGitCore', 'WeGitAskPass']
              for path in (ROOT / base).rglob('*') if path.is_file()]
    before = {name: digest(ROOT / name) for name in sorted(names)}
    (folder / 'inputs-before.json').write_text(json.dumps(before, indent=2) + '\n')
    original = (ROOT / 'WeGit/App/UpdateApplicationBridge.swift').read_text()
    marker = '/// A fresh transient directory is removed only after its complete byte map is sealed.'
    if original.count(marker) != 1:
        raise RuntimeError('Actual transient stage source boundary changed')
    # Preserve the complete private implementation byte-for-byte; the harness is
    # appended in the same file solely to access private types without changing API.
    source = folder / 'ActualUpdateStageControl.swift'
    source.write_text('import AppKit\nimport CryptoKit\nimport Darwin\nimport Foundation\nimport WeGitCore\n\n'
                      + original[original.index(marker):] + '\n'
                      + (ROOT / 'scripts/UpdateStageChecks.swift').read_text())
    scratch = ROOT / '.build'
    run(['swift', 'build', '--scratch-path', str(scratch), '-c', 'debug', '--product', 'WeGitAskPass'],
        folder / 'core-build.log')
    library = Path(subprocess.check_output(['swift', 'build', '--scratch-path', str(scratch), '-c', 'debug',
                                          '--show-bin-path'], cwd=ROOT, text=True).strip())
    run(['xcrun', 'swiftc', '-parse-as-library', '-swift-version', '6', '-I', str(library),
         '-I', str(library / 'Modules'), str(library / 'WeGitCore.o'), str(source),
         '-o', str(folder / 'checks')], folder / 'compile.log')
    shutil.copytree(library / 'WeGit_WeGitCore.bundle', folder / 'WeGit_WeGitCore.bundle')
    run([str(folder / 'checks'), str(folder / 'result.json')], folder / 'run.log')
    if {name: digest(ROOT / name) for name in before} != before:
        raise RuntimeError('Inputs changed during update-stage controls')
    report = json.loads((folder / 'result.json').read_text())
    if report.get('total') != 15 or report.get('failed') != 0 or len(set(report.get('passed', []))) != 15:
        raise RuntimeError('Expected 15 distinct actual update-stage controls')
    receipt = dict(sourceFiles=before, total=15, failed=0, xctestExecuted=False, actualProductionInstall=False,
                   extractedSourceSHA256=digest(source), coreObjectSHA256=digest(library / 'WeGitCore.o'),
                   controlBinarySHA256=digest(folder / 'checks'), resultSHA256=digest(folder / 'result.json'))
    (folder / 'inputs.json').write_text(json.dumps(receipt, indent=2) + '\n')
    print(f'15/15 private update-stage controls passed; {folder}')


if __name__ == '__main__':
    main()
