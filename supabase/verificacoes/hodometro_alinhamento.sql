-- SOMENTE LEITURA. Não instala, não ativa e não consulta NFs/perfis.
select assinatura,to_regprocedure(assinatura) encontrada from (values
 ('public.frota_gestao_salvar_elegibilidade_alinhamento(uuid,uuid,boolean)'),
 ('public.frota_gestao_validar_hodometro_alinhamento(jsonb)'),
 ('public.frota_gestao_salvar_alinhamento(uuid,text,jsonb,text,boolean)')) x(assinatura);
select p.oid::regprocedure assinatura,p.prosecdef,p.proconfig,
 has_function_privilege('anon',p.oid,'EXECUTE') anon_executa,
 has_function_privilege('authenticated',p.oid,'EXECUTE') autenticado_executa,
 md5(replace(p.prosrc,chr(13),'')) hash_corpo,
 position('validar_hodometro_alinhamento' in p.prosrc)>0 valida_hodometro_nf,
 position('hodometro_obrigatorio' in p.prosrc)>0 informa_capacidade
from pg_proc p join pg_namespace n on n.oid=p.pronamespace where n.nspname='public'
and p.proname in ('frota_gestao_validar_hodometro_alinhamento','frota_gestao_validar_simplificado',
 'frota_gestao_validar_edicao_simplificada','frota_gestao_salvar_alinhamento','frota_gestao_alinhamentos');
select c.relname,c.reloptions from pg_class c join pg_namespace n on n.oid=c.relnamespace
where n.nspname='public' and c.relname='frota_gestao_pneus_fontes';
