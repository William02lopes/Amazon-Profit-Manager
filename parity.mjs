// Paridade: o cálculo do aplicativo atual (JS) x o banco (SQL numeric) com dados aleatórios, e importação do backup.
import {JSDOM} from 'jsdom';import fs from 'fs';import path from 'path';import {fileURLToPath} from 'url';
import {setup,as} from './run-tests.mjs';
const dir=path.dirname(fileURLToPath(import.meta.url));
let pass=0,fail=0;const ok=(n,c)=>{c?pass++:fail++;console.log((c?'PASS ':'FAIL ')+n)};
const html=fs.readFileSync(path.join(dir,'../../app/amazon-profit-manager.html'),'utf8');
const w=new JSDOM(html,{runScripts:'dangerously',url:'https://example.com/'}).window;
let seed=12345;const rnd=()=>{seed|=0;seed=seed+0x6D2B79F5|0;let t=Math.imul(seed^seed>>>15,1|seed);t=t+Math.imul(t^t>>>7,61|t)^t;return((t^t>>>14)>>>0)/4294967296};
const R=(a,b,d=2)=>+(a+rnd()*(b-a)).toFixed(d),I=(a,b)=>Math.floor(a+rnd()*(b-a+1));
const S=w.S;S.sales=[];S.returns=[];S.payouts={};S.exp=[];S.sups=[{name:'F1'},{name:'F2'}];S.mov=[];S.purch=[];
S.prods=Array.from({length:12},(_,i)=>({id:'p'+i,name:'Prod '+i,sku:'SKU'+i,asin:'',cat:'c',sup:'F1',buy:R(1,50),freight:R(0,3),price:R(10,90),min:2,avg:0,archived:false}));
for(let i=0;i<300;i++){const price=R(0.5,500),qty=I(1,9),gross=price*qty;
 S.sales.push({mode:['FBA','FBM','DBA'][I(0,2)],price,qty,cost:R(0,300),pfreight:R(0,5),cp:R(0,30,1),cf:rnd()<.3?R(0,3):0,fee:R(0,20),ship:R(0,10),pack:R(0,5),tp:R(0,15,1),ads:R(0,20),other:R(0,20),disc:rnd()<.3?R(0,gross*.5):0,order:'O-'+i,date:'2026-10-'+String(I(1,28)).padStart(2,'0'),product:'x',sku:'—',pid:''});
 if(rnd()<.2)S.returns.push({order:'O-'+i,date:'2026-10-20',motivo:'',refund:R(0,gross*.9),feesBack:R(0,10),unrec:R(0,5),extra:R(0,8),cond:'Revendável',resell:rnd()<.5})}
for(let i=0;i<40;i++){const n=I(1,4),ids=[...Array(12).keys()].sort(()=>rnd()-.5).slice(0,n),items=ids.map(k=>({pid:'p'+k,qty:I(1,30),cost:R(0.5,80)}));
 S.purch.push({id:'c'+i,date:'2026-10-02',sup:'F1',nf:'NF'+i,fp:'Pix',pay:'A pagar',due:'',freight:R(0,40),tax:R(0,10),other:R(0,10),disc:R(0,5),crit:rnd()<.5?'val':'qty',obs:'',items,status:'Pedido'})}
const appProfit={};S.sales.forEach(s=>appProfit[s.order]=w.calcS(s).profit);
const appUnit={};S.purch.forEach(c=>{const a=w.alloc(c);c.items.forEach((it,k)=>appUnit[c.id+'|'+it.pid]=a[k].unit);appUnit['T'+c.id]=w.pTotal(c)});
const backup=JSON.parse(w.bkData());
const db=await setup(),A='11111111-1111-1111-1111-111111111111';await as(db,A);
const res=(await db.query(`select import_backup($1::jsonb) r`,[JSON.stringify(backup)])).rows[0].r;
ok('importação: 300 vendas, 12 produtos, 40 compras',res.orders===300&&res.products===12&&res.purchases===40);
ok('importação: devoluções importadas',res.returns===S.returns.length);
const res2=(await db.query(`select import_backup($1::jsonb) r`,[JSON.stringify(backup)])).rows[0].r;
ok('importar de novo não duplica (idempotente)',res2.orders===300&&res2.purchases===40&&res2.returns===S.returns.length);
const rows=(await db.query(`select amazon_order_id o, profit::float p from order_results`)).rows;
let exact=0,within=0,max=0;rows.forEach(r=>{const d=Math.abs(r.p-appProfit[r.o]);if(d<1e-9)exact++;if(d<=0.0101)within++;max=Math.max(max,d)});
console.log(`   lucro por pedido: ${exact}/300 idênticos ao centavo, ${within}/300 dentro de 1 centavo, maior diferença ${max.toFixed(4)}`);
ok('lucro SQL x app: todos dentro de 1 centavo',rows.length===300&&within===300);
ok('lucro SQL x app: ≥ 98% idênticos',exact>=294);
let un=0,tot=0;for(const c of S.purch){const id=(await db.query(`select id from purchases where legacy_id=$1`,[c.id])).rows[0].id;await db.query(`select receive_purchase($1)`,[id])}
const mv=(await db.query(`select p.legacy_id pid, pu.legacy_id cid, m.unit_cost::float u from inventory_movements m join products p on p.id=m.product_id join purchases pu on pu.id=m.purchase_id where m.type='IN'`)).rows;
mv.forEach(m=>{tot++;if(Math.abs(m.u-appUnit[m.cid+'|'+m.pid])<1e-9)un++});
ok('custo real unitário (rateio) idêntico ao app em '+tot+' itens',tot>0&&un===tot);
const ts=(await db.query(`select pu.legacy_id cid, round(sum(m.qty*m.unit_cost),2)::float s from inventory_movements m join purchases pu on pu.id=m.purchase_id group by 1`)).rows;
ok('soma dos custos reais ≈ total de cada compra (±0,05 por arredondamento unitário)',ts.every(t=>Math.abs(t.s-appUnit['T'+t.cid])<=0.05));
ok('estoque da conta A tem saldos positivos após recebimentos',(await db.query(`select count(*)::int c from product_stock where qty>0`)).rows[0].c===12);
console.log(`\n${pass} aprovados, ${fail} falharam`);process.exit(fail?1:0)
