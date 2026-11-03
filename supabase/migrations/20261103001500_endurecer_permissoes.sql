-- Rede de segurança: nenhuma tabela do schema public aceita escrita direta
-- pela API (anon/authenticated). Toda gravação passa pelas funções
-- frota_gestao_* (security definer), que aplicam as regras fiscais e de estoque.
do $$
declare tabela record;
begin
  for tabela in select c.relname from pg_class c join pg_namespace n on n.oid = c.relnamespace
      where n.nspname = 'public' and c.relkind in ('r', 'v', 'm', 'p') loop
    execute format('revoke insert, update, delete, truncate, references, trigger on public.%I from public, anon, authenticated', tabela.relname);
    execute format('revoke all on public.%I from anon', tabela.relname);
  end loop;
end $$;

do $$
declare sequencia record;
begin
  for sequencia in select c.relname from pg_class c join pg_namespace n on n.oid = c.relnamespace
      where n.nspname = 'public' and c.relkind = 'S' loop
    execute format('revoke all on sequence public.%I from public, anon, authenticated', sequencia.relname);
  end loop;
end $$;

notify pgrst, 'reload schema';
