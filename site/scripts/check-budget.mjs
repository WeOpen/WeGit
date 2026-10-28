import { readFileSync, readdirSync } from 'node:fs'
import { join } from 'node:path'
import { gzipSync } from 'node:zlib'
function files(folder) { return readdirSync(folder, { withFileTypes: true }).flatMap(entry => entry.isDirectory() ? files(join(folder, entry.name)) : [join(folder, entry.name)]) }
const client = files('dist/client'), server = files('dist/server').filter(path => path.endsWith('.js'))
const bytes = path => readFileSync(path)
const result = {
  publicBytes: client.reduce((sum, path) => sum + bytes(path).length, 0),
  cssBytes: client.filter(path => path.endsWith('.css')).reduce((sum, path) => sum + bytes(path).length, 0),
  clientScriptGzipBytes: client.filter(path => path.endsWith('.js')).reduce((sum, path) => sum + gzipSync(bytes(path)).length, 0),
  workerGzipBytes: server.reduce((sum, path) => sum + gzipSync(bytes(path)).length, 0),
}
console.log(JSON.stringify(result))
for (const [key, limit] of Object.entries({ publicBytes: 3_000_000, cssBytes: 65_536, clientScriptGzipBytes: 153_600, workerGzipBytes: 524_288 })) {
  if (result[key] > limit) throw new Error(key + ' exceeded project budget: ' + result[key] + ' > ' + limit)
}
