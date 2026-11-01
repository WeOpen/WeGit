// ICO container with the already exported PNG payloads; no image resampling.
const fs=require('node:fs'),path=require('node:path');const r=path.resolve(__dirname,'../github');
const sizes=[16,32,48,64],payloads=sizes.map(n=>fs.readFileSync(path.join(r,`favicon-${n}.png`)));
const header=Buffer.alloc(6+16*sizes.length);header.writeUInt16LE(1,2);header.writeUInt16LE(sizes.length,4);let offset=header.length;
sizes.forEach((n,i)=>{const p=6+16*i;header[p]=n;header[p+1]=n;header.writeUInt16LE(1,p+4);header.writeUInt16LE(32,p+6);header.writeUInt32LE(payloads[i].length,p+8);header.writeUInt32LE(offset,p+12);offset+=payloads[i].length;});
fs.writeFileSync(path.join(r,'favicon.ico'),Buffer.concat([header,...payloads]));
fs.writeFileSync(path.join(r,'site.webmanifest'),JSON.stringify({name:'WeGit',short_name:'WeGit',icons:[{src:'favicon-192.png',sizes:'192x192',type:'image/png'},{src:'favicon-512.png',sizes:'512x512',type:'image/png'}],theme_color:'#B3322D',background_color:'#F7F3ED',display:'standalone'},null,2)+'\n');
