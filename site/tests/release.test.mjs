import assert from 'node:assert/strict';
import { selectRelease } from '../src/scripts/release.mjs';

const asset = name => ({ name, browser_download_url: 'https://github.com/WeOpen/WeGit/releases/download/v1.0.0/' + name });
const archive = 'WeGit-1.0.0-macos-arm64-adhoc.zip';
const release = { tag_name:'v1.0.0', draft:false, prerelease:false, assets:[asset(archive),asset(archive + '.sha256'),asset('manifest.json')] };
assert.equal(selectRelease([]), null);
assert.equal(selectRelease([{...release,draft:true}]), null);
assert.equal(selectRelease([release]).download, asset(archive).browser_download_url);
assert.equal(selectRelease([{...release,assets:[asset(archive)]}]).download, null);
assert.equal(selectRelease([{...release,assets:release.assets.map(item=>({...item,browser_download_url:item.browser_download_url.replace('github.com','example.invalid')}))}]).download, null);
assert.equal(selectRelease([{...release,assets:release.assets.map(item=>({...item,browser_download_url:item.browser_download_url.replace('v1.0.0/','v0.9.0/')}))}]).download, null);
assert.equal(selectRelease([{...release,assets:release.assets.map(item=>({...item,browser_download_url:asset('other.zip').browser_download_url}))}]).download, null);
assert.equal(selectRelease([{...release,tag_name:'v1.1.0-beta.1',prerelease:true},release]).tag,'v1.0.0');
assert.equal(selectRelease([{...release,tag_name:'v1.1.0-beta.1',prerelease:true}]).prerelease,true);
assert.equal(selectRelease([{...release,tag_name:'unreviewed build'}]),null);
assert.throws(()=>selectRelease({}), /Invalid release/);
console.log('Website release behavior: 11 cases passed.');
