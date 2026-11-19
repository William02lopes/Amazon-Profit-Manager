-- Amazon Profit Manager — esquema PostgreSQL (Supabase) v1
-- Regras: dinheiro em numeric (nunca float); isolamento por usuário via RLS e chaves compostas;
-- livro de estoque somente de acréscimo; compras recebidas imutáveis; auditoria automática.

create table public.suppliers (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null default auth.uid() references auth.users(id) on delete cascade,
  name text not null check (length(trim(name)) > 0),
  created_at timestamptz not null default now(),
  unique (user_id, id), unique (user_id, name)
);

create table public.products (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null default auth.uid() references auth.users(id) on delete cascade,
  legacy_id text,
  name text not null check (length(trim(name)) > 0),
  sku text not null default '', asin text not null default '', category text not null default '',
  supplier_id uuid,
  buy_cost numeric(14,4) not null default 0 check (buy_cost >= 0),
  freight numeric(14,4) not null default 0 check (freight >= 0),
  price numeric(14,2) not null default 0 check (price >= 0),
  min_stock integer not null default 0 check (min_stock >= 0),
  avg_cost numeric(14,4) not null default 0 check (avg_cost >= 0),   -- custo médio ponderado
  archived boolean not null default false,
  created_at timestamptz not null default now(),
  unique (user_id, id),
  foreign key (user_id, supplier_id) references public.suppliers (user_id, id) on delete restrict
);
create unique index products_sku_uq on public.products (user_id, lower(sku)) where sku <> '';
create unique index products_asin_uq on public.products (user_id, lower(asin)) where asin <> '';
create unique index products_legacy_uq on public.products (user_id, legacy_id) where legacy_id is not null;

create table public.purchases (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null default auth.uid() references auth.users(id) on delete cascade,
  legacy_id text,
  purchase_date date not null,
  supplier_id uuid,
  invoice_no text not null default '',
  pay_method text not null default 'Pix' check (pay_method in ('Pix','Boleto','Cartão','Transferência','Dinheiro')),
  pay_status text not null default 'A pagar' check (pay_status in ('A pagar','Pago')),
  due_date date,
  freight numeric(14,2) not null default 0 check (freight >= 0),
  tax numeric(14,2) not null default 0 check (tax >= 0),            -- impostos não recuperáveis
  other numeric(14,2) not null default 0 check (other >= 0),
  discount numeric(14,2) not null default 0 check (discount >= 0),
  alloc_criterion text not null default 'val' check (alloc_criterion in ('val','qty')),
  status text not null default 'Pedido' check (status in ('Pedido','Recebida','Cancelada')),
  received_at date,
  notes text not null default '',
  created_at timestamptz not null default now(),
  unique (user_id, id),
  foreign key (user_id, supplier_id) references public.suppliers (user_id, id) on delete restrict
);
create unique index purchases_nf_uq on public.purchases (user_id, coalesce(supplier_id::text,''), invoice_no)
  where invoice_no <> '' and status <> 'Cancelada';
create unique index purchases_legacy_uq on public.purchases (user_id, legacy_id) where legacy_id is not null;

create table public.purchase_items (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null default auth.uid() references auth.users(id) on delete cascade,
  purchase_id uuid not null,
  position integer not null default 0,
  product_id uuid not null,
  qty integer not null check (qty >= 1),
  unit_cost numeric(14,4) not null check (unit_cost > 0),
  unique (purchase_id, product_id),
  foreign key (user_id, purchase_id) references public.purchases (user_id, id) on delete restrict,
  foreign key (user_id, product_id) references public.products (user_id, id) on delete restrict
);

create table public.orders (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null default auth.uid() references auth.users(id) on delete cascade,
  amazon_order_id text not null check (length(trim(amazon_order_id)) > 0),
  order_date date not null,
  product_id uuid,
  product_name text not null default '', sku text not null default '',
  fulfillment text not null default 'FBM' check (fulfillment in ('FBA','FBM','DBA')),
  qty integer not null check (qty >= 1),
  unit_price numeric(14,2) not null check (unit_price > 0),
  discount numeric(14,2) not null default 0 check (discount >= 0),
  unit_cost numeric(14,4) not null default 0 check (unit_cost >= 0),         -- custo congelado na venda
  purchase_freight numeric(14,4) not null default 0 check (purchase_freight >= 0),
  commission_pct numeric(7,4) not null default 0 check (commission_pct between 0 and 100),
  commission_fixed numeric(14,4) not null default 0 check (commission_fixed >= 0),
  logistics_fee numeric(14,4) not null default 0 check (logistics_fee >= 0),
  seller_shipping numeric(14,4) not null default 0 check (seller_shipping >= 0),
  tax_pct numeric(7,4) not null default 0 check (tax_pct between 0 and 100),
  packaging numeric(14,4) not null default 0 check (packaging >= 0),
  ads numeric(14,2) not null default 0 check (ads >= 0),
  other_costs numeric(14,2) not null default 0 check (other_costs >= 0),
  source text not null default 'MANUAL' check (source in ('MANUAL','CSV','SPAPI')),
  moves_stock boolean not null default true,
  created_at timestamptz not null default now(),
  unique (user_id, id),
  foreign key (user_id, product_id) references public.products (user_id, id) on delete restrict
);
create unique index orders_amazon_uq on public.orders (user_id, lower(regexp_replace(amazon_order_id, '\s+', '', 'g')));

create table public.order_returns (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null default auth.uid() references auth.users(id) on delete cascade,
  order_id uuid not null,
  return_date date, reason text not null default '',
  refund numeric(14,2) not null default 0 check (refund >= 0),
  fees_back numeric(14,2) not null default 0 check (fees_back >= 0),
  fees_unrecovered numeric(14,2) not null default 0 check (fees_unrecovered >= 0),
  extra_cost numeric(14,2) not null default 0 check (extra_cost >= 0),
  condition text not null default 'Revendável' check (condition in ('Revendável','Danificado','Em análise')),
  resell boolean not null default false,
  created_at timestamptz not null default now(),
  unique (order_id),
  foreign key (user_id, order_id) references public.orders (user_id, id) on delete cascade
);

create table public.payouts (
  order_id uuid primary key,
  user_id uuid not null default auth.uid() references auth.users(id) on delete cascade,
  status text not null default 'Pendente' check (status in ('Pendente','Previsto','Parcialmente recebido','Recebido','Em análise')),
  due_date date, paid_date date,
  received numeric(14,2) not null default 0 check (received >= 0),
  reference text not null default '',
  reconciled boolean not null default false,
  foreign key (user_id, order_id) references public.orders (user_id, id) on delete cascade
);

create table public.inventory_movements (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null default auth.uid() references auth.users(id) on delete cascade,
  product_id uuid not null,
  type text not null check (type in ('IN','OUT','ADJ','RET')),
  qty integer not null check (qty <> 0),
  unit_cost numeric(14,4),
  move_date date not null default current_date,
  order_ref text, purchase_id uuid, note text not null default '',
  created_at timestamptz not null default now(),
  foreign key (user_id, product_id) references public.products (user_id, id) on delete restrict,
  foreign key (user_id, purchase_id) references public.purchases (user_id, id) on delete restrict
);
create unique index movements_order_once on public.inventory_movements (user_id, product_id, order_ref, type) where order_ref is not null;

create table public.expenses (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null default auth.uid() references auth.users(id) on delete cascade,
  legacy_id text,
  expense_date date not null,
  category text not null, description text not null,
  amount numeric(14,2) not null check (amount > 0),
  created_at timestamptz not null default now()
);
create unique index expenses_dup_uq on public.expenses (user_id, expense_date, category, lower(description), amount);

create table public.settings (user_id uuid primary key default auth.uid() references auth.users(id) on delete cascade, data jsonb not null default '{}');

create table public.audit_log (
  id bigint generated always as identity primary key,
  user_id uuid not null, entity text not null, entity_id text, action text not null,
  detail jsonb, at timestamptz not null default now()
);
create index audit_log_user_at on public.audit_log (user_id, at desc);

-- ===== Auditoria automática (imutável para o usuário) =====
create function public.audit_row() returns trigger language plpgsql security definer set search_path = public as $$
declare r jsonb; u uuid;
begin
  if tg_op = 'DELETE' then r := to_jsonb(old); else r := to_jsonb(new); end if;
  u := (r->>'user_id')::uuid;
  insert into public.audit_log(user_id, entity, entity_id, action, detail)
  values (u, tg_table_name, coalesce(r->>'id', r->>'order_id'), tg_op,
    case when tg_op = 'UPDATE' then jsonb_build_object('old', to_jsonb(old), 'new', to_jsonb(new)) else r end);
  return null;
end $$;
do $$ declare t text; begin
  foreach t in array array['suppliers','products','purchases','purchase_items','orders','order_returns','payouts','inventory_movements','expenses'] loop
    execute format('create trigger audit_%1$s after insert or update or delete on public.%1$s for each row execute function public.audit_row()', t);
  end loop; end $$;

-- ===== Proteções =====
create function public.purchases_guard() returns trigger language plpgsql as $$
begin
  if tg_op = 'DELETE' then raise exception 'compras não são excluídas: use o cancelamento (status Cancelada)'; end if;
  if old.status = 'Cancelada' then raise exception 'compra cancelada não pode ser alterada'; end if;
  if old.status = 'Recebida' and (new.status <> 'Recebida' or new.purchase_date <> old.purchase_date or new.freight <> old.freight
     or new.tax <> old.tax or new.other <> old.other or new.discount <> old.discount or new.alloc_criterion <> old.alloc_criterion) then
    raise exception 'compra recebida: só dados de cabeçalho (fornecedor, NF, pagamento, vencimento, observação) podem mudar';
  end if;
  if old.status = 'Recebida' and new.status = 'Recebida' and new.received_at is distinct from old.received_at then raise exception 'data de recebimento é imutável'; end if;
  if old.status = 'Pedido' and new.status = 'Cancelada' and exists (select 1 from public.inventory_movements m where m.purchase_id = old.id) then
    raise exception 'compra com movimentação de estoque não pode ser cancelada'; end if;
  return new;
end $$;
create trigger purchases_guard before update or delete on public.purchases for each row execute function public.purchases_guard();

create function public.items_guard() returns trigger language plpgsql as $$
declare st text; pid uuid := coalesce(new.purchase_id, old.purchase_id);
begin
  select status into st from public.purchases where id = pid;
  if st is distinct from 'Pedido' and current_setting('apm.importing', true) is distinct from 'on' then
    raise exception 'itens só podem ser alterados em compras pendentes (status: %)', coalesce(st, 'inexistente'); end if;
  return coalesce(new, old);
end $$;
create trigger items_guard before insert or update or delete on public.purchase_items for each row execute function public.items_guard();

create function public.movements_guard() returns trigger language plpgsql as $$
begin
  if tg_op in ('UPDATE','DELETE') then
    if current_setting('apm.mov_edit', true) is distinct from 'on' then raise exception 'movimentações de estoque são um livro somente de acréscimo'; end if;
    return coalesce(new, old);
  end if;
  if new.type = 'RET' and current_setting('apm.importing', true) is distinct from 'on' and not exists
     (select 1 from public.inventory_movements m where m.user_id = new.user_id and m.product_id = new.product_id and m.order_ref = new.order_ref and m.type = 'OUT') then
    raise exception 'devolução só retorna ao estoque se a venda baixou o estoque'; end if;
  return new;
end $$;
create trigger movements_guard before insert or update or delete on public.inventory_movements for each row execute function public.movements_guard();

create function public.orders_after_insert() returns trigger language plpgsql as $$
begin
  if new.product_id is not null and new.moves_stock and current_setting('apm.importing', true) is distinct from 'on' then
    insert into public.inventory_movements(product_id, type, qty, move_date, order_ref, note)
    values (new.product_id, 'OUT', -new.qty, new.order_date, new.amazon_order_id, 'Venda');
  end if; return new;
end $$;
create trigger orders_after_insert after insert on public.orders for each row execute function public.orders_after_insert();

create function public.orders_after_update() returns trigger language plpgsql as $$
begin
  if new.qty <> old.qty then
    perform set_config('apm.mov_edit', 'on', true);
    update public.inventory_movements set qty = case when type = 'OUT' then -new.qty else new.qty end
      where user_id = new.user_id and order_ref = new.amazon_order_id and type in ('OUT','RET');
    perform set_config('apm.mov_edit', 'off', true);
  end if; return new;
end $$;
create trigger orders_after_update after update on public.orders for each row execute function public.orders_after_update();

create function public.orders_before_delete() returns trigger language plpgsql as $$
begin
  perform set_config('apm.mov_edit', 'on', true);
  delete from public.inventory_movements where user_id = old.user_id and order_ref = old.amazon_order_id and type in ('OUT','RET');
  perform set_config('apm.mov_edit', 'off', true);
  return old;
end $$;
create trigger orders_before_delete before delete on public.orders for each row execute function public.orders_before_delete();

create function public.returns_after() returns trigger language plpgsql as $$
declare o public.orders%rowtype;
begin
  if tg_op = 'DELETE' then
    select * into o from public.orders where id = old.order_id;
    if found then
      perform set_config('apm.mov_edit', 'on', true);
      delete from public.inventory_movements where user_id = old.user_id and order_ref = o.amazon_order_id and type = 'RET';
      perform set_config('apm.mov_edit', 'off', true);
    end if;
    return old;
  end if;
  if new.resell and current_setting('apm.importing', true) is distinct from 'on' then
    select * into o from public.orders where id = new.order_id;
    if o.product_id is not null and exists (select 1 from public.inventory_movements m where m.user_id = o.user_id and m.order_ref = o.amazon_order_id and m.type = 'OUT') then
      insert into public.inventory_movements(product_id, type, qty, move_date, order_ref, note)
      values (o.product_id, 'RET', o.qty, coalesce(new.return_date, current_date), o.amazon_order_id, 'Devolução revendável');
    end if;
  end if; return new;
end $$;
create trigger returns_after after insert or delete on public.order_returns for each row execute function public.returns_after();

-- ===== Recebimento de compra (atômico): rateio em centavos + custo médio ponderado =====
-- Rateio: proporcional ao valor (val) ou quantidade (qty); a diferença de arredondamento vai para o último item.
create function public.receive_purchase(p_id uuid) returns void language plpgsql as $$
declare c public.purchases%rowtype; n int; sb numeric; extra bigint; acc bigint := 0; k int := 0; r record; sh bigint; tot bigint; unit numeric(14,4); on_hand bigint;
begin
  select * into c from public.purchases where id = p_id for update;
  if not found then raise exception 'compra não encontrada'; end if;
  if c.status <> 'Pedido' then raise exception 'compra não está pendente de recebimento (%)', c.status; end if;
  select count(*), sum(case when c.alloc_criterion = 'qty' then qty else qty * unit_cost end) into n, sb from public.purchase_items where purchase_id = p_id;
  if n = 0 then raise exception 'compra sem itens'; end if;
  extra := round((c.freight + c.tax + c.other - c.discount) * 100)::bigint;
  for r in select * from public.purchase_items where purchase_id = p_id order by position, id loop
    k := k + 1;
    if k = n then sh := extra - acc;
    else sh := floor(extra * (case when c.alloc_criterion = 'qty' then r.qty else r.qty * r.unit_cost end) / nullif(sb, 0) + 0.5)::bigint; end if;
    acc := acc + sh;
    tot := round(r.qty * r.unit_cost * 100)::bigint + sh;
    if tot <= 0 then raise exception 'custo total do item deve ser positivo'; end if;
    unit := round(tot / 100.0 / r.qty, 4);
    select coalesce(sum(qty), 0) into on_hand from public.inventory_movements where product_id = r.product_id;
    update public.products set avg_cost = round(case when on_hand > 0 then (on_hand * avg_cost + r.qty * unit) / (on_hand + r.qty) else unit end, 4) where id = r.product_id;
    insert into public.inventory_movements(product_id, type, qty, unit_cost, move_date, purchase_id, note)
      values (r.product_id, 'IN', r.qty, unit, current_date, p_id, 'Compra NF ' || coalesce(nullif(c.invoice_no, ''), 's/n'));
  end loop;
  update public.purchases set status = 'Recebida', received_at = current_date where id = p_id;
end $$;

-- ===== Visões =====
create view public.product_stock with (security_invoker = true) as
  select p.id as product_id, p.user_id, p.name, p.sku, p.min_stock, p.avg_cost,
         coalesce(sum(m.qty), 0)::int as qty, round(greatest(coalesce(sum(m.qty), 0), 0) * p.avg_cost, 2) as value_at_cost
  from public.products p left join public.inventory_movements m on m.product_id = p.id group by p.id;

create view public.order_results with (security_invoker = true) as
  with b as (select o.*, o.unit_price * o.qty - o.discount as net, (o.unit_cost + o.purchase_freight) * o.qty as acq_raw from public.orders o),
  c as (select b.*, b.commission_pct / 100 * b.net + b.commission_fixed * b.qty as comm_raw, (b.logistics_fee + b.seller_shipping) * b.qty as logi_raw,
               b.tax_pct / 100 * b.net as tax_raw, b.packaging * b.qty + b.ads + b.other_costs as oth_raw from b)
  select c.id, c.user_id, c.amazon_order_id, c.order_date, c.product_id, c.qty,
    round(c.net, 2) - coalesce(r.refund, 0) as net_revenue,
    round(c.acq_raw, 2) as cogs, round(c.comm_raw, 2) as commission, round(c.logi_raw, 2) as logistics,
    round(c.tax_raw, 2) as tax, round(c.oth_raw, 2) as other_costs_total, coalesce(r.refund, 0) as refund,
    round(round(c.net - (c.acq_raw + c.comm_raw + c.logi_raw + c.tax_raw + c.oth_raw), 2)
      - coalesce(r.refund, 0) + coalesce(r.fees_back, 0) - coalesce(r.extra_cost, 0)
      + case when coalesce(r.resell, false) then round(c.acq_raw, 2) else 0 end, 2) as profit
  from c left join public.order_returns r on r.order_id = c.id;

-- ===== Segurança por linha (RLS): cada conta só vê e altera os próprios dados =====
do $$ declare t text; begin
  foreach t in array array['suppliers','products','purchases','purchase_items','orders','order_returns','payouts','inventory_movements','expenses','settings'] loop
    execute format('alter table public.%I enable row level security', t);
    execute format('create policy own_rows on public.%I for all to authenticated using (user_id = auth.uid()) with check (user_id = auth.uid())', t);
  end loop;
end $$;
alter table public.audit_log enable row level security;
create policy audit_read_own on public.audit_log for select to authenticated using (user_id = auth.uid());
