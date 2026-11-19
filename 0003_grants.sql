-- Permissões explícitas: funciona com "Automatically expose new tables" ligado OU desligado.
-- Só usuários logados (authenticated) acessam; anon (sem login) não acessa nada. A segurança por linha continua no RLS.
grant usage on schema public to authenticated;
grant select, insert, update, delete on all tables in schema public to authenticated;
grant usage, select on all sequences in schema public to authenticated;
grant execute on function public.receive_purchase(uuid), public.import_backup(jsonb) to authenticated;
revoke all on all tables in schema public from anon;
revoke execute on function public.receive_purchase(uuid), public.import_backup(jsonb) from anon, public;
