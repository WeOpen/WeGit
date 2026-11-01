const fs=require('node:fs'),path=require('node:path');
const sharp=require(process.argv[2]||'sharp');
const root=path.resolve(__dirname,'..');
const scratch=path.resolve(root,'../../.build/brand-r4-tools');fs.mkdirSync(scratch,{recursive:true});
function cleanComponents(mask,w,h,minArea,onlyLargest=false){
 const seen=new Uint8Array(w*h),q=new Int32Array(w*h),parts=[];
 for(let i=0;i<w*h;i++){if(!mask[i]||seen[i])continue;let a=0,z=0;q[z++]=i;seen[i]=1;while(a<z){let k=q[a++],x=k%w,y=(k/w)|0;let next=[];if(x>0)next.push(k-1);if(x<w-1)next.push(k+1);if(y>0)next.push(k-w);if(y<h-1)next.push(k+w);for(const j of next)if(mask[j]&&!seen[j]){seen[j]=1;q[z++]=j;}}
 if(z>=minArea)parts.push(q.slice(0,z));}
 parts.sort((a,b)=>b.length-a.length);let result=new Uint8Array(w*h);for(const p of onlyLargest?parts.slice(0,1):parts)for(const i of p)result[i]=255;return result;
}
(async()=>{
 const input=path.join(root,'r3/generated/logo-horizontal.png');
 const jobs=[
 {name:'git',crop:{left:110,top:95,width:566,height:566},kind:'white',largest:true,min:1000},
 {name:'seal',crop:{left:492,top:494,width:120,height:120},kind:'white',min:80},
 {name:'wordmark',crop:{left:700,top:240,width:1040,height:300},kind:'black',min:250},
 {name:'plate',crop:{left:110,top:95,width:566,height:566},kind:'alpha',largest:true,min:1000}];
 for(const j of jobs){let {data,info}=await sharp(input).extract(j.crop).ensureAlpha().raw().toBuffer({resolveWithObject:true});let mask=new Uint8Array(info.width*info.height);
 for(let i=0;i<mask.length;i++){let r=data[i*4],g=data[i*4+1],b=data[i*4+2],a=data[i*4+3];mask[i]=(j.kind==='white'?a>190&&r>215&&g>215&&b>215:j.kind==='black'?a>120&&r<90&&g<90&&b<90:a>180)?255:0;}
 mask=cleanComponents(mask,info.width,info.height,j.min,j.largest);
 await sharp(Buffer.from(mask),{raw:{width:info.width,height:info.height,channels:1}}).png().toFile(path.join(scratch,j.name+'-mask.png'));
 console.log(j.name,j.crop);
 }
 fs.writeFileSync(path.join(__dirname,'master-regions.json'),JSON.stringify({input:'r3/generated/logo-horizontal.png',regions:jobs},null,2)+'\n');
})();
