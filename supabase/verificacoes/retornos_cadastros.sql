-- SOMENTE LEITURA. Não instala nem ativa recursos. Não imprime dados de usuários/NFs.
select assinatura,to_regprocedure(assinatura) encontrada from (values
 ('public.frota_gestao_validar_classificacao_tipo(jsonb)'),
 ('public.frota_gestao_historico_estoque()'),
 ('public.frota_gestao_retornar_estoque(uuid,uuid,text,boolean)'),
 ('public.frota_gestao_excluir_cadastro(uuid,text,uuid,text,boolean)')) x(assinatura);
select nome,to_regclass('public.'||nome) encontrada from (values
 ('frota_gestao_retornos_estoque'),('frota_gestao_cadastros_excluidos'),
 ('frota_gestao_aplicacoes_efetivas'),('frota_gestao_cadastros_ativos')) x(nome);
select tablename,policyname,roles,cmd,qual,with_check from pg_catalog.pg_policies
where schemaname='public' and tablename in ('frota_gestao_retornos_estoque','frota_gestao_cadastros_excluidos');
select c.relname,c.relrowsecurity,r.rolname,
 has_table_privilege(r.oid,c.oid,'SELECT') leitura,
 has_table_privilege(r.oid,c.oid,'INSERT,UPDATE,DELETE,TRUNCATE') alguma_escrita_direta
from pg_catalog.pg_class c join pg_catalog.pg_namespace n on n.oid=c.relnamespace
cross join pg_catalog.pg_roles r where n.nspname='public'
and c.relname in ('frota_gestao_retornos_estoque','frota_gestao_cadastros_excluidos')
and r.rolname in ('anon','authenticated');
select p.oid::regprocedure assinatura,p.prosecdef,p.proconfig,r.rolname,
 has_function_privilege(r.oid,p.oid,'EXECUTE') executa
from pg_catalog.pg_proc p join pg_catalog.pg_namespace n on n.oid=p.pronamespace
cross join pg_catalog.pg_roles r where n.nspname='public'
and p.proname in ('frota_gestao_historico_estoque','frota_gestao_retornar_estoque','frota_gestao_excluir_cadastro')
and r.rolname in ('anon','authenticated');
