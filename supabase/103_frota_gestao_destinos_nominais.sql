-- MANUAL: após 102 e seus predecessores. Destinos por nome, sem placa/OS/estoque.
-- Não altera lançamentos anteriores nem libera a ativação do módulo.
begin;
set local lock_timeout='5s';
set local statement_timeout='60s';
do $$ declare fonte text;inicio integer;fim integer;novo text;begin
 if to_regprocedure('public.frota_gestao_validar_destinos_coletivos(jsonb)') is null then raise exception 'Instale e verifique SQL 102 antes de 103.';end if;
 fonte:=replace(pg_get_functiondef('public.frota_gestao_salvar_cadastro(uuid,text,uuid,jsonb)'::regprocedure),chr(13),'');
 if position('destino-nominal-01' in fonte)=0 then
  inicio:=position(' elsif p_tipo=''destinos'' then' in fonte);
  fim:=position(E'\n else\n  chave_cadastro:=lower' in substring(fonte from inicio));
  if inicio=0 or fim=0 then raise exception 'Cadastro 102 divergente.';end if;
  novo:=$n$ elsif p_tipo='destinos' then
  -- destino-nominal-01: a regra de custo pertence ao destino, não a um grupo de placas.
  chave_cadastro:=lower(btrim(p_dados->>'nome'));
  if coalesce(chave_cadastro,'')='' or length(chave_cadastro)>80 or chave_cadastro in ('placa','estoque','milimetragem') then raise exception 'Informe outro nome para o destino (ate 80 caracteres).';end if;
  p_dados:=jsonb_build_object('nome',btrim(p_dados->>'nome'));
$n$;
  fonte:=substring(fonte from 1 for inicio-1)||novo||substring(fonte from inicio+fim-1);execute fonte;
 end if;
 fonte:=pg_get_functiondef('public.frota_gestao_listar_cadastros()'::regprocedure);
 if position('''destinos_nominais''' in fonte)=0 then
  if position('''destinos_coletivos'', true' in fonte)>0 then fonte:=replace(fonte,'''destinos_coletivos'', true','''destinos_coletivos'', true, ''destinos_nominais'', true');
  elsif position('''destinos_coletivos'',true' in fonte)>0 then fonte:=replace(fonte,'''destinos_coletivos'',true','''destinos_coletivos'',true,''destinos_nominais'',true');
  else raise exception 'Consulta 102 divergente.';end if;execute fonte;
 end if;
end $$;

create or replace function public.frota_gestao_validar_destino_nominal(p jsonb,l jsonb)
returns void language plpgsql stable security definer set search_path=pg_catalog,public as $$
declare nome text;
begin
 if not public.frota_gestao_usuario_ativo() then raise exception using errcode='42501',message='Conta ativa necessaria.';end if;
 select dados->>'nome' into nome from public.frota_gestao_cadastros where id=(p->>'destino_id')::uuid and tipo='destinos';
 if nome is null or p->>'destino_nome' is distinct from nome or l->>'veiculo' is distinct from nome or l->>'destino_id' is distinct from p->>'destino_id' then raise exception 'Confira o destino cadastrado na alocacao.';end if;
 if coalesce(p->>'veiculo_id','')<>'' or coalesce(p->>'placa','')<>'' or coalesce(p->>'os_item_id','')<>'' then raise exception 'Destino nominal nao pode vincular placa ou OS.';end if;
 if coalesce(l->>'centro_custo','') not in ('Administrativo 501','Armazém 301','Entrega 201','Puxada 101','Vendas 401') then raise exception 'Selecione a Unidade de Negocio do destino.';end if;
end $$;
revoke all on function public.frota_gestao_validar_destino_nominal(jsonb,jsonb) from public,anon,authenticated;

do $$ declare assinatura text;fonte text;antes text;depois text;begin
 foreach assinatura in array array['public.frota_gestao_validar_simplificado(jsonb,uuid,bigint)','public.frota_gestao_validar_edicao_simplificada(jsonb,uuid,bigint)'] loop
  fonte:=replace(pg_get_functiondef(to_regprocedure(assinatura)),chr(13),'');
  if position('public.frota_gestao_validar_destino_nominal(p,l)' in fonte)=0 then
   antes:=$a$if placa<>'Estoque' then$a$;
   depois:=$b$if p->>'destino'='cadastro' then perform public.frota_gestao_validar_destino_nominal(p,l);
   elsif placa<>'Estoque' then$b$;
   if position(antes in fonte)=0 then raise exception 'Validacao fiscal divergente.';end if;fonte:=replace(fonte,antes,depois);
   fonte:=replace(fonte,'where x->>''veiculo''<>''Estoque''','where x->>''veiculo''<>''Estoque'' and coalesce(x->>''destino_id'',''veiculo'') in (''veiculo'',''milimetragem'')');execute fonte;
  end if;
 end loop;
 foreach assinatura in array array['public.frota_gestao_finalizar_simplificado(uuid,bigint,uuid,boolean)','public.frota_gestao_confirmar_edicao_simplificada(uuid,uuid,uuid,jsonb,text,boolean)'] loop
  fonte:=pg_get_functiondef(to_regprocedure(assinatura));
  if position('elsif l->>''veiculo''<>''Estoque''' in fonte)=0 then
   antes:=$a$if l->>'veiculo'<>'Estoque' then$a$;
   depois:=$b$if p->>'destino'='cadastro' then
   l:=l||jsonb_build_object('veiculo_id',null,'numero_os','—');
  elsif l->>'veiculo'<>'Estoque' then$b$;
   if position(antes in fonte)=0 then raise exception 'Finalizacao simplificada divergente.';end if;fonte:=replace(fonte,antes,depois);execute fonte;
  end if;
 end loop;
 fonte:=pg_get_functiondef('public.frota_gestao_dashboard_simplificado()'::regprocedure);
 if position('destino_nome' in fonte)=0 then
  antes:=$a$h.linha->>'conta_codigo' conta_codigo,os.numero::text numero_os$a$;
  depois:=$b$h.linha->>'conta_codigo' conta_codigo,os.numero::text numero_os,
   coalesce(h.linha->>'destino_id',case when c->>'origem'='aplicacao' then 'estoque' else 'veiculo' end) destino_id,
   coalesce(h.linha->>'destino_nome',case when c->>'origem'='aplicacao' then 'Estoque' else 'Placa' end) destino_nome$b$;
  if position(antes in fonte)=0 then raise exception 'Dashboard 97/99 divergente.';end if;fonte:=replace(fonte,antes,depois);
  antes:=$a$h->>'manutencao' manutencao,h->>'pecas_servicos' descricao$a$;
  depois:=$b$h->>'manutencao' manutencao,h->>'pecas_servicos' descricao,
   coalesce(h->>'destino_id',case when h->>'veiculo'='Estoque' then 'estoque' else 'veiculo' end) destino_id,
   coalesce(h->>'destino_nome',case when h->>'veiculo'='Estoque' then 'Estoque' else 'Placa' end) destino_nome$b$;
  if position(antes in fonte)=0 then raise exception 'Compras do Dashboard divergentes.';end if;fonte:=replace(fonte,antes,depois);execute fonte;
 end if;
end $$;
revoke all on function public.frota_gestao_validar_simplificado(jsonb,uuid,bigint),public.frota_gestao_validar_edicao_simplificada(jsonb,uuid,bigint) from public,anon,authenticated;
notify pgrst,'reload schema';
commit;
