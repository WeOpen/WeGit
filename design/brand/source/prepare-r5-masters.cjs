// Derive editable geometry from the full independent imagegen master, never a reference-board crop.
// The original complete raster remains intact in r5/generated/.
const fs=require('node:fs'),path=require('node:path');
const sharp=require(process.argv[2]||'sharp');
const root=path.resolve(__dirname,'..'),scratch=path.resolve(root,'../../.build/brand-r5-tools');
fs.mkdirSync(scratch,{recursive:true});
function components(mask,w,h,min,largest=false){
 const seen=new Uint8Array(w*h),q=new Int32Array(w*h),parts=[];
 for(let i=0;i<w*h;i++){if(!mask[i]||seen[i])continue;let a=0,z=0;q[z++]=i;seen[i]=1;while(a<z){const k=q[a++],x=k%w,y=(k/w)|0;
 for(const j of [x>0?k-1:-1,x<w-1?k+1:-1,y>0?k-w:-1,y<h-1?k+w:-1])if(j>=0&&mask[j]&&!seen[j]){seen[j]=1;q[z++]=j;}}
 if(z>=min)parts.push(q.slice(0,z));}
 parts.sort((a,b)=>b.length-a.length);const out=Buffer.alloc(w*h);for(const p of largest?parts.slice(0,1):parts)for(const i of p)out[i]=255;return out;
}
(async()=>{
 const input=path.join(root,'r5/generated/logo-horizontal.png');
 const original=await sharp(input).ensureAlpha().raw().toBuffer({resolveWithObject:true});
 function bounds(predicate){let x0=original.info.width,y0=original.info.height,x1=0,y1=0;for(let y=0;y<original.info.height;y++)for(let x=0;x<original.info.width;x++){const i=(y*original.info.width+x)*4;if(predicate(...original.data.subarray(i,i+4),x,y)){x0=Math.min(x0,x);y0=Math.min(y0,y);x1=Math.max(x1,x);y1=Math.max(y1,y);}}return {left:x0,top:y0,width:x1-x0+1,height:y1-y0+1};}
 const plateBounds=bounds((r,g,b,a,x)=>a>200&&r>100&&r>g*1.6&&r>b*1.6&&x<original.info.width*.4);
 const wordBounds=bounds((r,g,b,a,x)=>a>180&&Math.max(r,g,b)<80&&x>plateBounds.left+plateBounds.width);
 const jobs=[
 {name:'plate',region:plateBounds,kind:'alpha',largest:true,min:1500,w:566,h:566},
 {name:'git',region:plateBounds,kind:'white',largest:true,min:1500,w:566,h:566},
 {name:'wordmark',region:wordBounds,kind:'black',min:500,w:1040,h:300}];
 console.log({plateBounds,wordBounds});
 for(const j of jobs){const {data,info}=await sharp(input).extract(j.region).ensureAlpha().raw().toBuffer({resolveWithObject:true});const mask=Buffer.alloc(info.width*info.height);
 for(let i=0;i<mask.length;i++){const [r,g,b,a]=data.subarray(i*4,i*4+4);mask[i]=(j.kind==='white'?a>180&&r>210&&g>210&&b>210:j.kind==='black'?a>100&&Math.max(r,g,b)<90:a>180)?255:0;}
 const clean=components(mask,info.width,info.height,j.min,j.largest);
 await sharp(clean,{raw:{width:info.width,height:info.height,channels:1}}).resize(j.w,j.h,{fit:'fill',kernel:'lanczos3'}).threshold(128).png().toFile(path.join(scratch,j.name+'-mask.png'));
 }
 fs.writeFileSync(path.join(__dirname,'r5-master-regions.json'),JSON.stringify({input:'r5/generated/logo-horizontal.png',regions:jobs,seal:'Existing verified seal-contours.json is preserved byte for byte'},null,2)+'\n');
})();
