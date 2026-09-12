import { build } from 'esbuild';
import { mkdir, readFile, writeFile, copyFile } from 'node:fs/promises';
const root = new URL('../../../Sources/Threading/Resources/RemoteClient/', import.meta.url);
const output = new URL('../.wrangler/invitation-assets/', import.meta.url);
await mkdir(output, {recursive:true});
for (const name of ['app.js','app.css','xterm.js','xterm.css']) await copyFile(new URL(name,root),new URL(name,output));
const html = (await readFile(new URL('index.html',root),'utf8'))
  .replaceAll('href="/', 'href="/join/assets/')
  .replace('src="/xterm.js"','src="/join/assets/xterm.js"')
  .replace('<script src="/app.js"></script>','<script type="module" src="/join/assets/boot.js"></script>');
await writeFile(new URL('index.html',output),html);
await build({entryPoints:[new URL('../web/boot.mjs',import.meta.url).pathname],
  outfile:new URL('boot.js',output).pathname,bundle:true,format:'esm',platform:'browser',target:'es2022',minify:false});
console.log('Built public client from the shipping RemoteClient assets.');
