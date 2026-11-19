// Importa o backup do aplicativo atual (texto da página "Backup") para a SUA conta no Supabase.
// Uso: SUPABASE_URL=... SUPABASE_ANON_KEY=... APM_EMAIL=... APM_PASSWORD=... node scripts/import-backup.mjs backup.json
// Roda como o próprio usuário (RLS aplicada). Idempotente: pode repetir sem duplicar.
import {createClient} from '@supabase/supabase-js';import fs from 'fs';
const {SUPABASE_URL,SUPABASE_ANON_KEY,APM_EMAIL,APM_PASSWORD}=process.env,file=process.argv[2];
if(!SUPABASE_URL||!SUPABASE_ANON_KEY||!APM_EMAIL||!APM_PASSWORD||!file){console.error('Faltam variáveis de ambiente ou o arquivo do backup.');process.exit(1)}
const backup=JSON.parse(fs.readFileSync(file,'utf8'));
if(!Array.isArray(backup.sales)){console.error('Arquivo não parece um backup do aplicativo (faltam as vendas).');process.exit(1)}
const sb=createClient(SUPABASE_URL,SUPABASE_ANON_KEY);
const {error:e1}=await sb.auth.signInWithPassword({email:APM_EMAIL,password:APM_PASSWORD});
if(e1){console.error('Login falhou:',e1.message);process.exit(1)}
const {data,error}=await sb.rpc('import_backup',{p:backup});
if(error){console.error('Importação falhou:',error.message);process.exit(1)}
console.log('Origem:',backup.sales.length,'vendas no arquivo.');console.log('Resultado no banco:',data);
if(data.orders<backup.sales.length)console.warn('ATENÇÃO: há menos pedidos no banco do que no arquivo. Confira duplicados ou dados inválidos.');
if(data.orders_without_product>0)console.warn(`Aviso: ${data.orders_without_product} pedido(s) sem produto vinculado (normal para vendas antigas sem produto no catálogo).`);
