const fs=require('node:fs'),path=require('node:path'),crypto=require('node:crypto');
const sharp=require(process.argv[2]||'sharp'),root=path.resolve(__dirname,'..'),checks=[];
const ok=(name,pass)=>{checks.push({name,passed:!!pass});if(!pass)throw Error(name)};
const files=dir=>fs.readdirSync(dir,{withFileTypes:true}).flatMap(e=>e.isDirectory()?files(path.join(dir,e.name)):[path.join(dir,e.name)]);
(async()=>{
 const master={};for(const [part,name] of [['git-branch','git'],['seal-ku','seal'],['wordmark','wordmark']])master[part]=JSON.parse(fs.readFileSync(path.join(__dirname,name+'-contours.json'))).d;
 for(const folder of ['source','logo','github','macos'])for(const p of files(path.join(root,folder))){
  if(!p.endsWith('.svg')||p.includes('/fonts/')||p.includes('/references/'))continue;
  const xml=fs.readFileSync(p,'utf8'),label=path.relative(root,p);ok(label+' no font dependency',!/<text\b/.test(xml));
  for(const [part,d] of Object.entries(master))for(const tag of xml.matchAll(/<path\b[^>]+>/g))if(tag[0].includes(`data-brand-part="${part}"`))ok(label+' shared '+part,tag[0].includes(`d="${d}"`));
 }
 for(const name of ['git-symbol','seal-ku','wordmark'])ok(name+' editable vector',!/<image\b/.test(fs.readFileSync(path.join(__dirname,name+'.svg'),'utf8')));
 for(const j of JSON.parse(fs.readFileSync(path.join(__dirname,'export-jobs.json')))){
  const m=await sharp(path.join(root,j.png)).metadata();ok(j.png+' dimensions',m.width===j.width&&m.height===j.height);
  if(j.png.startsWith('logo/')||j.png.startsWith('macos/templates/'))ok(j.png+' transparent margin',m.hasAlpha&&(await sharp(path.join(root,j.png)).stats()).channels[3].min===0);
 }
 ok('Two hollow endpoints',JSON.parse(fs.readFileSync(path.join(root,'docs/geometry.json'))).gitHoleCount===2);
 ok('Verified small seal unchanged',crypto.createHash('sha256').update(fs.readFileSync(path.join(__dirname,'seal-contours.json'))).digest('hex')==='630e58e56e6835c59f03e252318f9b1ffb3a94f4b758598a0a1983b80ef76bf4');
 const mean=(await sharp(path.join(__dirname,'materials/ink-red.jpg')).stats()).channels.map(c=>c.mean);
 ok('Cinnabar pigment centered on #B3322D',mean.every((v,i)=>Math.abs(v-[179,50,45][i])<2));
 for(const a of ['Default','Dark']){
  const render=await sharp(path.join(root,`macos/composer-${a}.png`)).ensureAlpha().raw().toBuffer({resolveWithObject:true});
  for(const layer of ['branch','seal']){
   const mask=await sharp(path.join(root,`macos/WeGit.icon/Assets/${layer}.svg`)).ensureAlpha().raw().toBuffer();let n=0,correct=0;
   for(let i=0;i<mask.length;i+=4)if(mask[i+3]>250){n++;const rgb=[...render.data.subarray(i,i+3)];if(a==='Default'?Math.min(...rgb)>210:Math.max(...rgb)<90)correct++;}
   ok(`Composer ${a} ${layer} ${a==='Dark'?'black':'white'}`,n>200&&correct/n>.96);
  }
 }
 for(const suffix of ['','-dark','-monochrome']){
  const p=path.join(root,`macos/app-icon${suffix}-2048.png`),m=await sharp(p).metadata();ok('HD Icon '+suffix,m.width===2048&&m.height===2048);
  const {data,info}=await sharp(p).ensureAlpha().raw().toBuffer({resolveWithObject:true});let edge=0;for(let x=0;x<info.width;x++)edge+=data[x*4+3]+data[((info.height-1)*info.width+x)*4+3];for(let y=0;y<info.height;y++)edge+=data[(y*info.width)*4+3]+data[(y*info.width+info.width-1)*4+3];ok('Uncut outer margin '+suffix,edge===0);
 }
 for(const name of ['wegit-logo-horizontal','wegit-logo-horizontal-dark'])for(const width of [480,960]){
  const p=path.join(root,`logo/${name}-${width}.webp`),m=await sharp(p).metadata();ok(path.basename(p),m.width===width&&m.height===width/3&&m.hasAlpha&&fs.statSync(p).size<=100*1024);
 }
 const report={version:'R5',status:'passed',checks:checks.length,inkMeanRGB:mean,scope:'Independent full imagegen masters; common geometry; HD transparent complete exports; actual Icon Composer Default/Dark renders. Native app inspection is recorded separately.',results:checks};
 fs.writeFileSync(path.join(root,'validation.json'),JSON.stringify(report,null,2)+'\n');console.log(JSON.stringify({checks:checks.length,inkMeanRGB:mean}));
})().catch(e=>{console.error(e);process.exit(1)});
