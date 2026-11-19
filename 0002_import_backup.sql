-- Importa o texto da página "Backup" do aplicativo atual para a conta autenticada.
-- Idempotente: pedidos, produtos, compras etc. já existentes são ignorados (nada é sobrescrito).
create function public.import_backup(p jsonb) returns jsonb language plpgsql as $$
declare res jsonb;
begin
  if auth.uid() is null then raise exception 'usuário não autenticado'; end if;
  if p is null or jsonb_typeof(p->'sales') is distinct from 'array' then raise exception 'backup inválido: faltam as vendas'; end if;
  perform set_config('apm.importing', 'on', true);

  insert into public.suppliers(name)
    select distinct trim(x->>'name') from jsonb_array_elements(coalesce(p->'sups','[]')) x where trim(coalesce(x->>'name','')) <> '' on conflict do nothing;

  insert into public.products(legacy_id,name,sku,asin,category,supplier_id,buy_cost,freight,price,min_stock,avg_cost,archived)
    select x->>'id', x->>'name', coalesce(x->>'sku',''), coalesce(x->>'asin',''), coalesce(x->>'cat',''),
      (select s.id from public.suppliers s where s.user_id = auth.uid() and s.name = x->>'sup'),
      coalesce((x->>'buy')::numeric,0), coalesce((x->>'freight')::numeric,0), coalesce((x->>'price')::numeric,0),
      coalesce((x->>'min')::numeric,0)::int, coalesce((x->>'avg')::numeric,0), coalesce((x->>'archived')::boolean,false)
    from jsonb_array_elements(coalesce(p->'prods','[]')) x on conflict do nothing;

  insert into public.orders(amazon_order_id,order_date,product_id,product_name,sku,fulfillment,qty,unit_price,discount,unit_cost,purchase_freight,
      commission_pct,commission_fixed,logistics_fee,seller_shipping,tax_pct,packaging,ads,other_costs,source,moves_stock)
    select x->>'order', (x->>'date')::date,
      (select pr.id from public.products pr where pr.user_id = auth.uid() and pr.legacy_id = x->>'pid' and (x->>'pid') <> ''),
      coalesce(x->>'product',''), coalesce(x->>'sku',''), coalesce(x->>'mode','FBM'), (x->>'qty')::int, (x->>'price')::numeric,
      coalesce((x->>'disc')::numeric,0), coalesce((x->>'cost')::numeric,0), coalesce((x->>'pfreight')::numeric,0),
      coalesce((x->>'cp')::numeric,0), coalesce((x->>'cf')::numeric,0), coalesce((x->>'fee')::numeric,0), coalesce((x->>'ship')::numeric,0),
      coalesce((x->>'tp')::numeric,0), coalesce((x->>'pack')::numeric,0), coalesce((x->>'ads')::numeric,0), coalesce((x->>'other')::numeric,0),
      case when x->>'src' = 'CSV' then 'CSV' else 'MANUAL' end, false
    from jsonb_array_elements(p->'sales') x on conflict do nothing;

  insert into public.purchases(legacy_id,purchase_date,supplier_id,invoice_no,pay_method,pay_status,due_date,freight,tax,other,discount,alloc_criterion,notes)
    select x->>'id', (x->>'date')::date, (select s.id from public.suppliers s where s.user_id = auth.uid() and s.name = x->>'sup'),
      coalesce(x->>'nf',''), coalesce(x->>'fp','Pix'), coalesce(x->>'pay','A pagar'), nullif(x->>'due','')::date,
      coalesce((x->>'freight')::numeric,0), coalesce((x->>'tax')::numeric,0), coalesce((x->>'other')::numeric,0), coalesce((x->>'disc')::numeric,0),
      coalesce(x->>'crit','val'), coalesce(x->>'obs','')
    from jsonb_array_elements(coalesce(p->'purch','[]')) x on conflict do nothing;

  insert into public.purchase_items(purchase_id,position,product_id,qty,unit_cost)
    select pu.id, (i.ord - 1)::int, pr.id, (i.v->>'qty')::int, (i.v->>'cost')::numeric
    from jsonb_array_elements(coalesce(p->'purch','[]')) x
      cross join lateral jsonb_array_elements(x->'items') with ordinality as i(v, ord)
      join public.purchases pu on pu.user_id = auth.uid() and pu.legacy_id = x->>'id'
      join public.products pr on pr.user_id = auth.uid() and pr.legacy_id = i.v->>'pid'
    on conflict do nothing;

  update public.purchases pu set status = m.st, received_at = m.r
    from (select x->>'id' as lid, x->>'status' as st, nullif(x->>'recAt','')::date as r from jsonb_array_elements(coalesce(p->'purch','[]')) x) m
    where pu.user_id = auth.uid() and pu.legacy_id = m.lid and m.st in ('Recebida','Cancelada') and pu.status = 'Pedido';

  insert into public.inventory_movements(product_id,type,qty,unit_cost,move_date,order_ref,purchase_id,note)
    select pr.id, x->>'type', (x->>'qty')::int, nullif(x->>'cost','')::numeric, coalesce((x->>'date')::date, current_date), nullif(x->>'order',''),
      (select pu.id from public.purchases pu where pu.user_id = auth.uid() and pu.legacy_id = x->>'ref'), coalesce(x->>'note','')
    from jsonb_array_elements(coalesce(p->'mov','[]')) x
      join public.products pr on pr.user_id = auth.uid() and pr.legacy_id = x->>'pid'
    order by (x->>'type' = 'RET') on conflict do nothing;

  insert into public.order_returns(order_id,return_date,reason,refund,fees_back,fees_unrecovered,extra_cost,condition,resell)
    select o.id, nullif(x->>'date','')::date, coalesce(x->>'motivo',''), coalesce((x->>'refund')::numeric,0), coalesce((x->>'feesBack')::numeric,0),
      coalesce((x->>'unrec')::numeric,0), coalesce((x->>'extra')::numeric,0), coalesce(x->>'cond','Revendável'), coalesce((x->>'resell')::boolean,false)
    from jsonb_array_elements(coalesce(p->'returns','[]')) x
      join public.orders o on o.user_id = auth.uid() and lower(regexp_replace(o.amazon_order_id,'\s+','','g')) = lower(regexp_replace(x->>'order','\s+','','g'))
    on conflict do nothing;

  insert into public.payouts(order_id,status,due_date,paid_date,received,reference,reconciled)
    select o.id, coalesce(v->>'status','Pendente'), nullif(v->>'due','')::date, nullif(v->>'paid','')::date,
      coalesce(nullif(v->>'got','')::numeric,0), coalesce(v->>'ref',''), coalesce((v->>'rec')::boolean,false)
    from jsonb_each(coalesce(p->'payouts','{}')) e(k, v)
      join public.orders o on o.user_id = auth.uid() and lower(regexp_replace(o.amazon_order_id,'\s+','','g')) = lower(regexp_replace(e.k,'\s+','','g'))
    on conflict do nothing;

  insert into public.expenses(legacy_id,expense_date,category,description,amount)
    select x->>'id', (x->>'date')::date, x->>'cat', x->>'desc', (x->>'amount')::numeric from jsonb_array_elements(coalesce(p->'exp','[]')) x on conflict do nothing;

  insert into public.settings(data) values (jsonb_build_object('cfg', coalesce(p->'cfg','{}'::jsonb), 'cash', coalesce(p->'cash','0'::jsonb))) on conflict do nothing;

  perform set_config('apm.importing', 'off', true);
  select jsonb_build_object(
    'orders', (select count(*) from public.orders where user_id = auth.uid()),
    'orders_without_product', (select count(*) from public.orders where user_id = auth.uid() and product_id is null),
    'products', (select count(*) from public.products where user_id = auth.uid()),
    'purchases', (select count(*) from public.purchases where user_id = auth.uid()),
    'movements', (select count(*) from public.inventory_movements where user_id = auth.uid()),
    'returns', (select count(*) from public.order_returns where user_id = auth.uid()),
    'payouts', (select count(*) from public.payouts where user_id = auth.uid()),
    'expenses', (select count(*) from public.expenses where user_id = auth.uid()),
    'source_sales', jsonb_array_length(p->'sales')) into res;
  return res;
end $$;
