-- PREPARAÇÃO LOCAL: após 107. Leituras antigas desconhecidas não são preenchidas nem alteradas.
begin;
set local lock_timeout='5s';
set local statement_timeout='60s';
do $$ begin
 if to_regprocedure('public.frota_gestao_salvar_elegibilidade_alinhamento(uuid,uuid,boolean)') is null then raise exception 'Instale e verifique SQL107 antes de 108.';end if;
end $$;
create or replace function public.frota_gestao_validar_hodometro_alinhamento(p_dados jsonb)
returns void language plpgsql stable security definer set search_path=pg_catalog,public as $$
declare item jsonb;cfg jsonb;parcela jsonb;leitura text;
begin
 if not public.frota_gestao_usuario_ativo() then raise exception using errcode='42501',message='Conta ativa necessária.';end if;
 if p_dados#>'{finalizacao,hodometros}' is not null and jsonb_typeof(p_dados#>'{finalizacao,hodometros}')<>'object' then raise exception 'Confira as leituras de hodômetro por veículo.';end if;
 for item in select * from jsonb_array_elements(p_dados#>'{nota,itens}') loop
  cfg:=p_dados#>array['finalizacao','itens',item->>'numero'];
  for parcela in select * from jsonb_array_elements(cfg->'rateios') loop
   if translate(lower(coalesce(parcela->>'classificacao','')),'áàãâéêíóôõúüç','aaaaeeiooouuc') ~ '(^|[^a-z])(alinhamento|balanceamento)([^a-z]|$)' then
    if parcela->>'destino' is distinct from 'veiculo' or coalesce(parcela->>'veiculo_id','')='' then raise exception 'Item %: selecione uma placa para registrar o hodômetro de alinhamento e balanceamento.',item->>'numero';end if;
    leitura:=p_dados#>>array['finalizacao','hodometros',parcela->>'veiculo_id'];
    if coalesce(leitura,'') !~ '^[0-9]{1,12}$' then raise exception 'Item %: informe o hodômetro de %, em quilômetros inteiros, sem valores negativos.',item->>'numero',parcela->>'placa';end if;
   end if;
  end loop;
 end loop;
end $$;
revoke all on function public.frota_gestao_validar_hodometro_alinhamento(jsonb) from public,anon,authenticated;

do $$ declare assinatura text;fonte text;antes text;begin
 foreach assinatura in array array['public.frota_gestao_validar_simplificado(jsonb,uuid,bigint)','public.frota_gestao_validar_edicao_simplificada(jsonb,uuid,bigint)'] loop
  fonte:=pg_get_functiondef(to_regprocedure(assinatura));
  if position('perform public.frota_gestao_validar_hodometro_alinhamento(p_dados)' in fonte)=0 then
   antes:='perform public.frota_gestao_validar_classificacao_tipo(p_dados);';
   if position(antes in fonte)=0 then raise exception 'Validação104/107 divergente: %',assinatura;end if;
   fonte:=replace(fonte,antes,antes||' perform public.frota_gestao_validar_hodometro_alinhamento(p_dados);');execute fonte;
  end if;
 end loop;
 fonte:=pg_get_functiondef('public.frota_gestao_salvar_alinhamento(uuid,text,jsonb,text,boolean)'::regprocedure);
 if position('hodometro' in fonte)=0 then
  antes:=$a$if vid is null then raise exception 'Selecione um veículo cadastrado.';end if;$a$;
  if position(antes in fonte)=0 or position('dados:=jsonb_build_object(''veiculo_id'',vid' in fonte)=0 then raise exception 'Salvamento106 divergente.';end if;
  fonte:=replace(fonte,antes,antes||$a$ if coalesce(p_dados->>'hodometro','') !~ '^[0-9]{1,12}$' then raise exception 'Informe o hodômetro em quilômetros inteiros, sem valores negativos.';end if;$a$);
  fonte:=replace(fonte,'dados:=jsonb_build_object(''veiculo_id'',vid','dados:=jsonb_build_object(''hodometro'',(p_dados->>''hodometro'')::bigint::text,''veiculo_id'',vid');execute fonte;
 end if;
 fonte:=pg_get_functiondef('public.frota_gestao_alinhamentos()'::regprocedure);
 if position('hodometro_obrigatorio' in fonte)=0 then
  if position('elegibilidade_editavel' in fonte)=0 or position('''contrato'',''alinhamentos-01''' in fonte)=0 then raise exception 'Consulta107 divergente.';end if;
  fonte:=replace(fonte,'''contrato'',''alinhamentos-01''','''contrato'',''alinhamentos-01'',''hodometro_obrigatorio'',true');execute fonte;
 end if;
end $$;

create or replace view public.frota_gestao_pneus_fontes with (security_barrier=true,security_invoker=true) as
select 'nf:'||n.id::text||':'||n.versao_id::text||':'||(l->>'veiculo_id')||':'||substring(l->>'centro_custo' from '[0-9]{3}$') fonte,n.id nota_id,n.versao_id,
 n.momento criado_em,p.nome autor,
 jsonb_build_object('veiculo_id',l->>'veiculo_id','placa',l->>'veiculo',
 'centro_custo',substring(l->>'centro_custo' from '[0-9]{3}$'),
 'data',substring(n.hbf->>'emissao_nf',1,10),'numero_nf',n.hbf->>'numero_nf',
 'hodometro',n.dados#>>array['finalizacao','hodometros',l->>'veiculo_id'],
 'fornecedor',n.hbf->>'fornecedor','valor',sum((l->>'valor_total')::numeric)::text,'observacao',string_agg(l->>'pecas_servicos','; ' order by l->>'id')) dados,
 exists(select 1 from public.frota_gestao_lancamentos_vigentes v where v.id=n.id and v.versao_id=n.versao_id) vigente,
 case when exists(select 1 from public.frota_gestao_exclusoes_simplificadas x where x.nota_id=n.id) then 'NF excluída'
 when not exists(select 1 from public.frota_gestao_lancamentos_vigentes v where v.id=n.id and v.versao_id=n.versao_id) then 'NF substituída' else 'NF vigente' end situacao
from (
 select id,versao_id,hbf,dados,finalizada_em momento,criado_por from public.frota_gestao_lancamentos
 union all select nota_id,id,hbf,dados,criado_em,criado_por from public.frota_gestao_edicoes_simplificadas
) n cross join lateral jsonb_array_elements(n.hbf->'linhas') l join public.perfis p on p.id=n.criado_por
where public.frota_gestao_usuario_ativo()
 and coalesce(l->>'veiculo_id','') ~ '^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$'
 and translate(lower(coalesce(l->>'classificacao','')),'áàãâéêíóôõúüç','aaaaeeiooouuc') ~ '(^|[^a-z])(alinhamento|balanceamento)([^a-z]|$)'
group by n.id,n.versao_id,n.momento,n.hbf,p.nome,l->>'veiculo_id',l->>'veiculo',substring(l->>'centro_custo' from '[0-9]{3}$'),n.dados#>>array['finalizacao','hodometros',l->>'veiculo_id'];
revoke all on public.frota_gestao_pneus_fontes from public,anon;
grant select on public.frota_gestao_pneus_fontes to authenticated;
notify pgrst,'reload schema';
commit;
