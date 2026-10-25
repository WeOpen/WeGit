// R5: shared two-node imagegen-derived vectors, exact brand pigment and shallow native tile.
// Dependency: sharp (pass its module path as argv[2] if not installed locally).
const fs=require('node:fs'),path=require('node:path'),crypto=require('node:crypto');
const sharp=require(process.argv[2]||'sharp');
const root=path.resolve(__dirname,'..');const jobs=[];
const read=name=>JSON.parse(fs.readFileSync(path.join(__dirname,name+'-contours.json')));
const G=read('git'),S=read('seal'),W=read('wordmark'),P=read('plate');
const vector=(part,d)=>`<path data-brand-part="${part}" fill="currentColor" fill-rule="evenodd" d="${d}"/>`;
const git=vector('git-branch',G.d),seal=vector('seal-ku',S.d),word=vector('wordmark',W.d);
const svg=(w,h,body,label='WeGit',view=`0 0 ${w} ${h}`)=>`<svg xmlns="http://www.w3.org/2000/svg" width="${w}" height="${h}" viewBox="${view}" role="img" aria-label="${label}"><title>${label}</title>${body}</svg>\n`;
const write=(name,w,h,body,png=true,view)=>{const dest=path.join(root,name+'.svg');fs.mkdirSync(path.dirname(dest),{recursive:true});fs.writeFileSync(dest,svg(w,h,body,'WeGit',view));if(png)jobs.push({svg:name+'.svg',png:name+'.png',width:w,height:h});};
(async()=>{
 // Preserve the full newly generated material, calibrating its pigment around exact #B3322D.
 const material=await sharp(path.join(root,'r5/generated/ink-red.png')).removeAlpha().raw().toBuffer({resolveWithObject:true});
 const rgb=Buffer.alloc(material.info.width*material.info.height*3);let mean=0;
 for(let i=0;i<rgb.length;i+=3)mean+=.2126*material.data[i]+.7152*material.data[i+1]+.0722*material.data[i+2];
 mean/=rgb.length/3;
 for(let i=0;i<rgb.length;i+=3){const lum=.2126*material.data[i]+.7152*material.data[i+1]+.0722*material.data[i+2];const scale=1+Math.max(-.14,Math.min(.14,(lum-mean)/255*.65));for(let c=0;c<3;c++)rgb[i+c]=Math.round([179,50,45][c]*scale);}
 const ink=await sharp(rgb,{raw:{width:material.info.width,height:material.info.height,channels:3}}).jpeg({quality:96,chromaSubsampling:'4:4:4'}).toBuffer();
 fs.writeFileSync(path.join(__dirname,'materials/ink-red.jpg'),ink);
 const image='data:image/jpeg;base64,'+ink.toString('base64');
 // Standard macOS artwork occupies 824 of a 1024 canvas (same as Finder/Terminal).
 // The base is native editable geometry, with only a two-pixel lip and close shadow.
 const tile='M322 100H702C850 100 924 174 924 322V702C924 850 850 924 702 924H322C174 924 100 850 100 702V322C100 174 174 100 322 100Z';
 const base=dark=>`<defs><linearGradient id="tile" x2=".1" y2="1"><stop stop-color="${dark?'#1F1F1F':'#FFFDFA'}"/><stop offset=".7" stop-color="${dark?'#1F1F1F':'#F7F3ED'}"/><stop offset="1" stop-color="${dark?'#1F1F1F':'#EFE8DD'}"/></linearGradient><filter id="tile-shadow" x="-.1" y="-.1" width="1.2" height="1.2"><feDropShadow dx="0" dy="3" stdDeviation="3" flood-color="#1F1F1F" flood-opacity=".12"/></filter></defs><path d="${tile}" transform="translate(0 2)" fill="${dark?'#141414':'#D4C8B9'}"/><path d="${tile}" fill="url(#tile)" filter="url(#tile-shadow)"/><path d="${tile}" fill="none" stroke="${dark?'#FFFFFF':'#FFFFFF'}" stroke-opacity="${dark?'.08':'.75'}" stroke-width="1.2"/>`;
 const plate=(mono=false)=>`<defs><clipPath id="plate-clip"><path d="${P.d}"/></clipPath>${mono?'<filter id="mono-ink"><feColorMatrix type="saturate" values="0"/><feComponentTransfer><feFuncR type="linear" slope=".28" intercept=".04"/><feFuncG type="linear" slope=".28" intercept=".04"/><feFuncB type="linear" slope=".28" intercept=".04"/></feComponentTransfer></filter>':''}</defs><g data-brand-part="ink-plate" clip-path="url(#plate-clip)"><image href="${image}" width="566" height="566" preserveAspectRatio="xMidYMid slice" ${mono?'filter="url(#mono-ink)"':''}/></g>`;
 const symbol=(mono=false,withSeal=true,dark=false)=>plate(mono)+`<g color="${dark?'#1F1F1F':'#FFFFFF'}">${git}</g>${withSeal?`<g transform="translate(382 420)" color="${dark?'#1F1F1F':'#FFFFFF'}">${seal}</g>`:''}`;
 const horizontal=(dark=false,mono=false)=>`<g transform="translate(40 40) scale(${320/566})">${symbol(mono)}</g><g transform="translate(400 100) scale(.6)" color="${dark?'#F7F3ED':'#1F1F1F'}">${word}</g><g transform="translate(1060 185) scale(.72)" color="${mono?(dark?'#F7F3ED':'#1F1F1F'):'#B3322D'}">${seal}</g>`;
 write('source/git-symbol',566,566,git,false);
 write('source/seal-ku',120,120,seal,false);
 write('source/wordmark',1040,300,word,false);
 write('source/icon-master-flat',566,566,`<path d="${P.d}" fill="#B3322D"/><g color="#FFFFFF">${git}<g transform="translate(382 420)">${seal}</g></g>`,false);
 write('source/icon-master',566,566,symbol(),false);
 write('source/ink-plate',566,566,plate(),false);
 write('logo/wegit-logo-horizontal',1200,400,horizontal());
 write('logo/wegit-logo-horizontal-dark',1200,400,horizontal(true));
 write('logo/wegit-logo-horizontal-monochrome',1200,400,horizontal(false,true));
 write('logo/wegit-symbol',1024,1024,`<g transform="scale(${1024/566})">${symbol()}</g>`);
 write('logo/wegit-symbol-monochrome',1024,1024,`<g transform="scale(${1024/566})">${symbol(true)}</g>`);
 write('logo/wegit-wordmark',1040,300,`<g color="#1F1F1F">${word}</g>`);
 write('logo/wegit-wordmark-dark',1040,300,`<g color="#F7F3ED">${word}</g>`);
 write('logo/seal-ku-red',600,600,`<g transform="scale(5)" color="#B3322D">${seal}</g>`);
 write('logo/seal-ku-black',600,600,`<g transform="scale(5)" color="#1F1F1F">${seal}</g>`);
 write('logo/seal-ku-white',600,600,`<g transform="scale(5)" color="#FFFFFF">${seal}</g>`);
 // One shared foreground on a shallow tile, with the complete 1024 canvas preserved.
 const icon=(dark=false,mono=false)=>base(dark)+`<g transform="translate(203 203) scale(${618/566})">${symbol(mono,true,dark)}</g>`;
 for(const [suffix,dark,mono] of [['',false,false],['-dark',true,false],['-monochrome',false,true]]){
  write('macos/app-icon'+suffix+'-1024',1024,1024,icon(dark,mono));
  jobs.push({svg:'macos/app-icon'+suffix+'-1024.svg',png:'macos/app-icon'+suffix+'-2048.png',width:2048,height:2048});
  for(const size of [16,32,64,128,256,512])jobs.push({svg:'macos/app-icon'+suffix+'-1024.svg',png:`macos/sizes/app-icon${suffix}-${size}.png`,width:size,height:size});
 }
 for(const name of ['toolbar-git','menu-bar-git']){
  write('macos/'+name,24,24,`<g color="#000000">${git}</g>`,false,'-12 -12 590 590');
  for(const size of [16,18,20,24,32,36,40,48,64])jobs.push({svg:'macos/'+name+'.svg',png:`macos/templates/${name}-${size}.png`,width:size,height:size});
 }
 write('github/avatar',1024,1024,`<rect width="1024" height="1024" fill="#F7F3ED"/><g transform="translate(128 128) scale(${768/566})">${symbol()}</g>`);
 for(const [name,w,h,dark] of [['banner',1600,480,false],['banner-dark',1600,480,true],['social-preview',1280,640,false],['social-preview-dark',1280,640,true]]){
  const scale=Math.min((w-100)/1200,(h-60)/400);
  write('github/'+name,w,h,`<rect width="${w}" height="${h}" fill="${dark?'#1F1F1F':'#F7F3ED'}"/><g transform="translate(${(w-1200*scale)/2} ${(h-400*scale)/2}) scale(${scale})">${horizontal(dark)}</g>`);
 }
 write('github/favicon',566,566,`<path d="${P.d}" fill="#B3322D"/><g color="#FFFFFF">${git}</g>`,false);
 for(const size of [16,32,48,64,180,192,512])jobs.push({svg:'github/favicon.svg',png:`github/favicon-${size}.png`,width:size,height:size});
 write('macos/composer-plate',1024,1024,`<g transform="translate(128 128) scale(${768/566})">${plate()}</g>`);
 // The system owns the outer material, mask and lighting in modern Composer.
 const assets=path.join(root,'macos/WeGit.icon/Assets');fs.mkdirSync(assets,{recursive:true});
 fs.writeFileSync(path.join(assets,'branch.svg'),svg(1024,1024,`<g transform="translate(128 128) scale(${768/566})" color="#FFFFFF">${git}</g>`));
 fs.writeFileSync(path.join(assets,'seal.svg'),svg(1024,1024,`<g transform="translate(128 128) scale(${768/566})"><g transform="translate(382 420)" color="#FFFFFF">${seal}</g></g>`));
 const solid=hex=>'srgb:'+hex.match(/../g).map(x=>(parseInt(x,16)/255).toFixed(5)).join(',')+',1';
 fs.writeFileSync(path.join(root,'macos/WeGit.icon/icon.json'),JSON.stringify({'fill-specializations':[{'value':{'solid':solid('F7F3ED')}},{'appearance':'dark','value':{'solid':solid('1F1F1F')}}],groups:[{name:'R5 shared two-node identity',layers:[{name:'Verified Ku small seal','image-name':'seal.svg',glass:false,'fill-specializations':[{value:{solid:solid('FFFFFF')}},{appearance:'dark',value:{solid:solid('1F1F1F')}}]},{name:'Two Git nodes','image-name':'branch.svg',glass:false,'fill-specializations':[{value:{solid:solid('FFFFFF')}},{appearance:'dark',value:{solid:solid('1F1F1F')}}]},{name:'Cinnabar ink','image-name':'plate.png',glass:false}],shadow:{kind:'neutral',opacity:.03},translucency:{enabled:false,value:0}}],'supported-platforms':{squares:['macOS']}},null,2)+'\n');
 for(const suffix of ['','-dark','-monochrome'])for(const width of [2400,4800])jobs.push({svg:'logo/wegit-logo-horizontal'+suffix+'.svg',png:'logo/wegit-logo-horizontal'+suffix+'-'+width+'.png',width,height:width/3});

 for(const j of jobs){const out=path.join(root,j.png);fs.mkdirSync(path.dirname(out),{recursive:true});await sharp(path.join(root,j.svg),{density:144}).resize(j.width,j.height).toColourspace('srgb').png().toFile(out);}
 fs.copyFileSync(path.join(root,'macos/composer-plate.png'),path.join(assets,'plate.png'));
 fs.writeFileSync(path.join(__dirname,'export-jobs.json'),JSON.stringify(jobs,null,2)+'\n');
 const sourceImage=fs.readFileSync(path.join(root,'r5/generated/logo-horizontal.png'));
 fs.writeFileSync(path.join(root,'docs/geometry.json'),JSON.stringify({version:'R5',reference:'r5/generated/logo-horizontal.png',referenceSha256:crypto.createHash('sha256').update(sourceImage).digest('hex'),symbolViewBox:[0,0,566,566],sealViewBox:[0,0,120,120],sealPlacement:[382,420],wordmarkViewBox:[0,0,1040,300],gitContourCount:G.contourCount,gitHoleCount:G.contourCount-1,traceMethod:'Apple Vision contours from full independent R5 imagegen master; verified Ku path preserved',materialLayer:'r5/generated/ink-red.png, pigment calibrated to #B3322D',sourceType:'Editable vector outlines + separately generated raster material; no reference-board image crop'},null,2)+'\n');
 console.log(`R5 generated ${jobs.length} PNG exports, shared SVG masters and editable Composer project.`);
})();
