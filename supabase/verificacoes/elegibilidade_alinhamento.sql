-- SOMENTE LEITURA. Não instala nem ativa recurso; não consulta registros fiscais.
select assinatura,to_regprocedure(assinatura) encontrada from (values
 ('public.frota_gestao_alinhamentos()'),
 ('public.frota_gestao_salvar_elegibilidade_alinhamento(uuid,uuid,boolean)')) x(assinatura);
select c.relname,c.relrowsecurity,a.attname,format_type(a.atttypid,a.atttypmod) tipo,a.attidentity
from pg_class c join pg_namespace n on n.oid=c.relnamespace
join pg_attribute a on a.attrelid=c.oid and a.attnum>0 and not a.attisdropped
where n.nspname='public' and c.relname='frota_gestao_pneus_elegibilidade' order by a.attnum;
select tablename,policyname,roles,cmd,qual,with_check from pg_policies
where schemaname='public' and tablename='frota_gestao_pneus_elegibilidade';
select c.relname,r.rolname,has_table_privilege(r.oid,c.oid,'SELECT') le,
has_table_privilege(r.oid,c.oid,'INSERT,UPDATE,DELETE,TRUNCATE') alguma_escrita_direta
from pg_class c join pg_namespace n on n.oid=c.relnamespace cross join pg_roles r
where n.nspname='public' and c.relname='frota_gestao_pneus_elegibilidade' and r.rolname in ('anon','authenticated');
select p.oid::regprocedure assinatura,p.prosecdef,p.proconfig,r.rolname,has_function_privilege(r.oid,p.oid,'EXECUTE') executa,
md5(replace(p.prosrc,chr(13),'')) hash_corpo
from pg_proc p join pg_namespace n on n.oid=p.pronamespace cross join pg_roles r
where n.nspname='public' and p.proname in ('frota_gestao_salvar_elegibilidade_alinhamento','frota_gestao_alinhamentos')
and r.rolname in ('anon','authenticated');
