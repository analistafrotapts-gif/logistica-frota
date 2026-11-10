-- Exclusivamente leitura de metadados. Não instala nem ativa funcionalidades.
select current_database() as banco,current_user as papel,version() as versao;
select assinatura,to_regprocedure(assinatura) as encontrada from (values
 ('public.frota_gestao_validar_simplificado(jsonb,uuid,bigint)'),
 ('public.frota_gestao_aplicar_simplificado(uuid,jsonb,boolean)'),
 ('public.frota_gestao_listar_cadastros()'),
 ('public.frota_gestao_carregar_edicao_simplificada(uuid)'),
 ('public.frota_gestao_confirmar_edicao_simplificada(uuid,uuid,uuid,jsonb,text,boolean)'),
 ('public.frota_gestao_apagar_simplificado(uuid,uuid,uuid,text,boolean)')
) r(assinatura);
select c.relname,c.relrowsecurity,k.conname,k.contype,pg_get_constraintdef(k.oid) as definicao
from pg_class c join pg_namespace n on n.oid=c.relnamespace
left join pg_constraint k on k.conrelid=c.oid
where n.nspname='public' and c.relname in ('frota_gestao_lancamentos','frota_gestao_edicoes_simplificadas','frota_gestao_exclusoes_simplificadas')
order by c.relname,k.conname;
select c.relname,t.tgname,t.tgenabled,pg_get_triggerdef(t.oid) as definicao
from pg_trigger t join pg_class c on c.oid=t.tgrelid join pg_namespace n on n.oid=c.relnamespace
where n.nspname='public' and c.relname='frota_gestao_lancamentos' and not t.tgisinternal;
select tablename,policyname,roles,cmd,qual,with_check from pg_policies
where schemaname='public' and tablename in ('frota_gestao_edicoes_simplificadas','frota_gestao_exclusoes_simplificadas');
select p.oid::regprocedure::text as assinatura,p.prosecdef,p.proconfig,
 md5(replace(p.prosrc,chr(13),'')) as hash_corpo,
 has_function_privilege('anon',p.oid,'EXECUTE') as anon_executa,
 has_function_privilege('authenticated',p.oid,'EXECUTE') as autenticado_executa
from pg_proc p join pg_namespace n on n.oid=p.pronamespace
where n.nspname='public' and p.proname in ('frota_gestao_validar_simplificado','frota_gestao_validar_edicao_simplificada','frota_gestao_identidade_simplificada','frota_gestao_carregar_edicao_simplificada','frota_gestao_confirmar_edicao_simplificada','frota_gestao_apagar_simplificado','frota_gestao_recibo_exclusao_simplificada')
order by assinatura;
