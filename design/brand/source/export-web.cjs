// Size-limited web derivatives; source vectors remain untouched.
const fs=require('node:fs'),path=require('node:path');const sharp=require(process.argv[2]||'sharp');const r=path.resolve(__dirname,'..');
(async()=>{for(const name of ['wegit-logo-horizontal','wegit-logo-horizontal-dark'])for(const width of [480,960]){const file=`logo/${name}-${width}.webp`;await sharp(path.join(r,'logo',name+'.png')).resize(width).webp({quality:92,alphaQuality:100,effort:6}).toFile(path.join(r,file));}console.log('WebP headers exported at 480/960 px.');})();
