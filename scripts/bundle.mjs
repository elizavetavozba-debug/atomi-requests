import {readFile,mkdir,writeFile} from 'node:fs/promises';
const core=await readFile(new URL('../supabase/functions/_shared/core.js',import.meta.url),'utf8');
const root=new URL('../.local/dashboard/',import.meta.url);await mkdir(root,{recursive:true});
for(const name of ['create-application','telegram-hook','setup-telegram'])await writeFile(new URL(`${name}.ts`,root),`${core}\nDeno.serve(createHandler('${name}', { env: Deno.env.toObject() }));\n`);
console.log('Три самостоятельные функции подготовлены в .local/dashboard.');
