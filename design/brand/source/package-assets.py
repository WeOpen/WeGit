#!/usr/bin/env python3
"""Package current R5 deliverables and necessary inputs, excluding historical R2."""
from pathlib import Path
import hashlib,json,zipfile
r=Path(__file__).resolve().parents[1]
files=[]
for name in ['BRAND.md','README.md','preview.png','validation.json']:
 files.append(r/name)
for folder in ['logo','macos','github']:
 files.extend(p for p in (r/folder).rglob('*') if p.is_file())
# Current source tools, vectors and frozen material layers; unused R2 font files are not dependencies.
files.extend(p for p in (r/'source').glob('*') if p.is_file())
files.extend(p for p in (r/'source/materials').rglob('*') if p.is_file())
files.extend(p for p in (r/'r5/generated').rglob('*') if p.is_file())
files.append(r/'source/reference/r5-direction.png')
files.append(r/'r5/provenance.json')
files.append(r/'source/fonts/ChongXi-LICENSE.md')
files.extend(p for p in (r/'docs').glob('*') if p.is_file() and p.name!='seal-ku-proof.svg')
files=sorted(set(files))
# Asset catalog includes current production assets, without historical inputs or documentation.
asset_folders=('logo','macos','github')
assets=[]
for p in files:
 rel=str(p.relative_to(r))
 if rel.split('/')[0] in asset_folders:
  assets.append({'file':rel,'bytes':p.stat().st_size,'sha256':hashlib.sha256(p.read_bytes()).hexdigest()})
index=r/'ASSETS.json';index.write_text(json.dumps({'version':'R5','assets':len(assets),'entries':assets},ensure_ascii=False,indent=2)+'\n');files.append(index)
files=sorted(set(files));manifest=r/'manifest.sha256'
manifest.write_text(''.join(hashlib.sha256(p.read_bytes()).hexdigest()+'  '+str(p.relative_to(r))+'\n' for p in files))
files.append(manifest)
out=r.parent/'WeGit-brand-r5.zip'
with zipfile.ZipFile(out,'w',zipfile.ZIP_DEFLATED) as z:
 for p in files:z.write(p,Path('WeGit-brand-r5')/p.relative_to(r))
with zipfile.ZipFile(out) as z:
 assert z.testzip() is None
 assert not any('/revisions/' in n for n in z.namelist())
Path(str(out)+'.sha256').write_text(hashlib.sha256(out.read_bytes()).hexdigest()+'  '+out.name+'\n')
print(json.dumps({'currentAssetFiles':len(assets),'bundleEntries':len(files),'bundleBytes':out.stat().st_size,'zipIntegrity':'passed'},ensure_ascii=False))
