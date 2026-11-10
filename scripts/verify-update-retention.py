#!/usr/bin/env python3
"""Run private non-XCTest update retention controls using the actual Core APIs."""
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
        value = subprocess.run(command, cwd=ROOT, stdout=stream, stderr=subprocess.STDOUT)
    if value.returncode:
        raise RuntimeError(f'Command failed ({value.returncode}); retained log: {log}')

def main():
    directory = Path(tempfile.mkdtemp(prefix='update-retention-', dir=ROOT / '.build'))
    names = ['Package.swift', 'scripts/ProductionUpdateChecks.swift', 'scripts/UpdateRetentionChecks.swift', 'scripts/verify-update-retention.py']
    names += [str(p.relative_to(ROOT)) for base in ['WeGitCore', 'WeGitAskPass'] for p in (ROOT/base).rglob('*') if p.is_file()]
    before = {name: digest(ROOT/name) for name in sorted(names)}
    (directory/'inputs-before.json').write_text(json.dumps(before, indent=2)+'\n')
    fixture = (ROOT/'scripts/ProductionUpdateChecks.swift').read_text()
    marker = 'private final class Fixture {'
    if fixture.count(marker) != 1: raise RuntimeError('Shared private fixture source changed')
    source = directory/'ActualRetentionControls.swift'
    source.write_text((ROOT/'scripts/UpdateRetentionChecks.swift').read_text()+'\n'+fixture[fixture.index(marker):])
    run(['swift','build','--product','WeGitAskPass','-Xswiftc','-enable-testing'],directory/'core-build.log')
    library = Path(subprocess.check_output(['swift','build','--show-bin-path'],cwd=ROOT,text=True).strip())
    run(['xcrun','swiftc','-parse-as-library','-swift-version','6','-enable-testing','-I',str(library),'-I',str(library/'Modules'),str(library/'WeGitCore.o'),str(source),'-o',str(directory/'checks')],directory/'compile.log')
    shutil.copytree(library/'WeGit_WeGitCore.bundle',directory/'WeGit_WeGitCore.bundle')
    run([str(directory/'checks'),str(directory/'result.json')],directory/'run.log')
    if {name:digest(ROOT/name) for name in before} != before: raise RuntimeError('Inputs changed during retention controls')
    result=json.loads((directory/'result.json').read_text())
    if result['total'] != len(set(result['passed'])) or result['failed'] != 0 or result['total'] != 28:
        raise RuntimeError('Incomplete retention controls')
    (directory/'inputs.json').write_text(json.dumps(dict(sourceFiles=before,total=result['total'],failed=0,
        coreObjectSHA256=digest(library/'WeGitCore.o'),controlBinarySHA256=digest(directory/'checks'),resultSHA256=digest(directory/'result.json'),
        xctestExecuted=False,actualProductionInstall=False),indent=2)+'\n')
    print(f'{result["total"]} private update retention controls passed; {directory}')

if __name__=='__main__': main()
