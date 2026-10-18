from pathlib import Path
import json,re,collections,math,sys
from PIL import Image
p=Path(sys.argv[1]);a=json.loads((p/'manifest.json').read_text())[0]['attachments'];byname={x['exportedFileName']:x for x in a};issues=json.loads((p/'issues-summary.json').read_text())
def lum(c):
 a=[x/255 for x in c];a=[x/12.92 if x<=0.04045 else ((x+0.055)/1.055)**2.4 for x in a];return sum(x*y for x,y in zip(a,[.2126,.7152,.0722]))
def ratio(a,b):
 x,y=sorted([lum(a),lum(b)]);return (y+.05)/(x+.05)
rows=[]
for i,x in enumerate(issues,1):
 if x['kind']!='contrast':continue
 t=byname[x['evidence']]['timestamp'];candidates=[z for z in a if z['suggestedHumanReadableName'].startswith('Element Screenshot') and abs(z['timestamp']-t)<.02];assert len(candidates)==1,(i,candidates)
 z=candidates[0];im=Image.open(p/z['exportedFileName']).convert('RGB');c=collections.Counter(im.getdata());bg=c.most_common(1)[0][0];fg,count=max(((rgb,n) for rgb,n in c.items() if n>=3),key=lambda q:ratio(q[0],bg));r=ratio(fg,bg);rows.append(dict(index=i,theme=x['theme'],text=x['summary'],bounds=x['attributes'],crop=z['exportedFileName'],size=im.size,background=bg,highestContrastRepeatedPixel=fg,highestContrastPixelCount=count,highestRepeatedPixelContrast=round(r,3)));print(i,x['theme'],x['summary'],bg,fg,count,round(r,3))
(p/'contrast-observations.json').write_text(json.dumps(rows,ensure_ascii=False,indent=2)+'\n')
