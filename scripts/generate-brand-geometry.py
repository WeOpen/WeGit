#!/usr/bin/env python3
"""Export the frozen R5 vector contours to the immutable native path cache."""
from pathlib import Path
import json,re
root=Path(__file__).resolve().parents[1]
source=root/'design/brand/source'
def contours(name):
 d=json.loads((source/f'{name}-contours.json').read_text())['d']
 if re.search(r'[^MLZ0-9.\-\s]',d):raise ValueError('Re-export unsupported curve commands before native integration')
 result=[]
 for piece in d.split('M')[1:]:
  values=re.findall(r'-?\d+(?:\.\d+)?',piece)
  assert len(values)%2==0
  result.append('        "'+';'.join(','.join(values[i:i+2]) for i in range(0,len(values),2))+'"')
 return ',\n'.join(result)
text=(source/'BrandGeometry.swift.template').read_text().replace('{{GIT}}',contours('git')).replace('{{SEAL}}',contours('seal'))
target=root/'WeGit/DesignSystem/BrandGeometry.swift'
if not target.exists() or target.read_text()!=text:target.write_text(text)
print('Native branch and seal share the frozen R5 contours.')
