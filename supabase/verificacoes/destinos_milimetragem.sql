-- Somente leitura. Não cadastra participantes, não instala nem libera escritas.
select current_database() as banco,version() as versao;
select assinatura,to_regprocedure(assinatura) as encontrada from (values
 ('public.frota_gestao_salvar_cadastro(uuid,text,uuid,jsonb)'),
 ('public.frota_gestao_listar_cadastros()'),
 ('public.frota_gestao_validar_simplificado(jsonb,uuid,bigint)'),
 ('public.frota_gestao_validar_edicao_simplificada(jsonb,uuid,bigint)'),
 ('public.frota_gestao_validar_destinos_coletivos(jsonb)'),
 ('public.frota_gestao_validar_destino_nominal(jsonb,jsonb)'),
 ('public.frota_gestao_validar_classificacao_tipo(jsonb)')
) r(assinatura);
select c.relname,c.reloptions,c.relacl,c.relrowsecurity,a.attname,format_type(a.atttypid,a.atttypmod) as tipo
from pg_class c join pg_namespace n on n.oid=c.relnamespace
left join pg_attribute a on a.attrelid=c.oid and a.attname='milimetragem' and not a.attisdropped
where n.nspname='public' and c.relname in ('frota_gestao_veiculos','frota_gestao_cadastros');
select conname,convalidated,pg_get_constraintdef(oid) as definicao from pg_constraint
where conrelid=to_regclass('public.frota_gestao_cadastros') and conname='frota_gestao_cadastros_tipo_check';
select p.oid::regprocedure as assinatura,p.prosecdef,p.provolatile,p.proconfig,
 md5(replace(p.prosrc,chr(13),'')) as hash_corpo,
 has_function_privilege('anon',p.oid,'EXECUTE') as anon_executa,
 has_function_privilege('authenticated',p.oid,'EXECUTE') as autenticado_executa
from pg_proc p join pg_namespace n on n.oid=p.pronamespace
where n.nspname='public' and p.proname in ('frota_gestao_salvar_cadastro','frota_gestao_listar_cadastros','frota_gestao_validar_destinos_coletivos','frota_gestao_validar_destino_nominal','frota_gestao_validar_classificacao_tipo','frota_gestao_validar_simplificado','frota_gestao_validar_edicao_simplificada');
