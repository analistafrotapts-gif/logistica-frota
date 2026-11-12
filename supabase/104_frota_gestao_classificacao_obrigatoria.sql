-- MANUAL: após 103 e seus predecessores. Não reclassifica registros anteriores.
begin;
set local lock_timeout='5s';
set local statement_timeout='60s';
do $$ begin
 if to_regprocedure('public.frota_gestao_validar_destino_nominal(jsonb,jsonb)') is null then raise exception 'Instale e verifique SQL 103 antes de 104.';end if;
end $$;
create or replace function public.frota_gestao_validar_classificacao_tipo(p_dados jsonb)
returns void language plpgsql stable security definer set search_path=pg_catalog,public as $$
declare item jsonb;cfg jsonb;rateio jsonb;
begin
 if not public.frota_gestao_usuario_ativo() then raise exception using errcode='42501',message='Conta ativa necessaria.';end if;
 for item in select * from jsonb_array_elements(p_dados#>'{nota,itens}') loop
  cfg:=p_dados#>array['finalizacao','itens',item->>'numero'];
  if coalesce(cfg->>'manutencao','') not in ('preventiva','corretiva','obz') then
   raise exception 'Item %: selecione Corretivo, Preventivo ou Contas de OBZ.',item->>'numero';
  end if;
  if jsonb_typeof(cfg->'rateios') is distinct from 'array' or jsonb_array_length(cfg->'rateios')=0 then raise exception 'Item %: confira os destinos da alocacao.',item->>'numero';end if;
  for rateio in select * from jsonb_array_elements(cfg->'rateios') loop
   if regexp_replace(coalesce(rateio->>'classificacao',''),'[[:space:]]','','g')='' or length(rateio->>'classificacao')>80 then
    raise exception 'Item %: selecione uma classificacao em cada destino.',item->>'numero';
   end if;
  end loop;
 end loop;
end $$;
revoke all on function public.frota_gestao_validar_classificacao_tipo(jsonb) from public,anon,authenticated;
do $$ declare assinatura text;fonte text;begin
 foreach assinatura in array array['public.frota_gestao_validar_simplificado(jsonb,uuid,bigint)','public.frota_gestao_validar_edicao_simplificada(jsonb,uuid,bigint)'] loop
  fonte:=pg_get_functiondef(to_regprocedure(assinatura));
  if position('perform public.frota_gestao_validar_classificacao_tipo(p_dados)' in fonte)=0 then
   if position('d:=p_dados;n:=' in fonte)=0 then raise exception 'Validador 103 divergente: %',assinatura;end if;
   fonte:=replace(fonte,'d:=p_dados;n:=','perform public.frota_gestao_validar_classificacao_tipo(p_dados); d:=p_dados;n:=');execute fonte;
  end if;
 end loop;
end $$;
revoke all on function public.frota_gestao_validar_simplificado(jsonb,uuid,bigint),public.frota_gestao_validar_edicao_simplificada(jsonb,uuid,bigint) from public,anon,authenticated;
notify pgrst,'reload schema';
commit;
