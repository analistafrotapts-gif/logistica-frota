-- SOMENTE LEITURA. Não instala nem ativa o módulo de pneus. Não consulta registros fiscais.
select assinatura,to_regprocedure(assinatura) encontrada from (values
 ('public.frota_gestao_retornar_estoque(uuid,uuid,text,boolean)'),
 ('public.frota_gestao_alinhamentos()'),
 ('public.frota_gestao_salvar_alinhamento(uuid,text,jsonb,text,boolean)')) x(assinatura);
select n.nspname,c.relname,c.relkind,c.relrowsecurity,c.reloptions from pg_class c
join pg_namespace n on n.oid=c.relnamespace where n.nspname='public'
and c.relname in ('frota_gestao_pneus_alinhamentos','frota_gestao_pneus_fontes');
select tablename,policyname,roles,cmd,qual,with_check from pg_policies
where schemaname='public' and tablename='frota_gestao_pneus_alinhamentos';
select c.relname,r.rolname,has_table_privilege(r.oid,c.oid,'SELECT') le,
has_table_privilege(r.oid,c.oid,'INSERT,UPDATE,DELETE,TRUNCATE') alguma_escrita_direta
from pg_class c join pg_namespace n on n.oid=c.relnamespace cross join pg_roles r
where n.nspname='public' and c.relname='frota_gestao_pneus_alinhamentos' and r.rolname in ('anon','authenticated');
select p.oid::regprocedure assinatura,p.prosecdef,p.proconfig,r.rolname,
has_function_privilege(r.oid,p.oid,'EXECUTE') executa,md5(replace(p.prosrc,chr(13),'')) hash_corpo
from pg_proc p join pg_namespace n on n.oid=p.pronamespace cross join pg_roles r
where n.nspname='public' and p.proname in ('frota_gestao_alinhamentos','frota_gestao_salvar_alinhamento')
and r.rolname in ('anon','authenticated');
