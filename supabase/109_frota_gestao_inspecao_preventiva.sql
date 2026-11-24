-- MANUAL: após 108 e todos os predecessores. Não executar automaticamente.
-- Inspeção Preventiva: lista inicial somente para placas já cadastradas na unidade correta.
-- Não altera linhas legadas, lançamentos, custos ou marcações explícitas do cadastro.
begin;
set local lock_timeout='5s';
set local statement_timeout='60s';
do $instalar$ declare fonte text;antes text;depois text;begin
 if to_regprocedure('public.frota_gestao_validar_hodometro_alinhamento(jsonb)') is null then raise exception 'Instale e verifique SQL 108 antes de 109.';end if;
 -- Acrescenta uma coluna preservando a definição vigente e o filtro de exclusões do SQL 105.
 if not exists(select 1 from pg_attribute where attrelid='public.frota_gestao_veiculos'::regclass and attname='inspecao_preventiva' and not attisdropped) then
  fonte:=rtrim(pg_get_viewdef('public.frota_gestao_veiculos'::regclass,true),E';\n ');
  execute 'create or replace view public.frota_gestao_veiculos with (security_barrier=true) as select base.*,
   coalesce((select c.dados->>''inspecao_preventiva'' from public.frota_gestao_cadastros c where c.id=base.id and c.tipo=''veiculos''),
    (exists(select 1 from public.operacoes o where o.id=base.operacao_id and o.ativa and (
     (lower(o.nome) ~ ''^patos($|[^a-z])'' and base.placa=any(array[''OFE2918'',''RLR8D79'',''RLR8F59'',''RLR8F99'',''RLU6A66'',''RLU6A86'',''RLU6A96'',''RLU6B06'',''RLX6B97'',''RLX7E88'',''SKZ7H28'',''SLB3G16'',''SLB3J86'',''TOT4F19'',''TOT4F49'',''TOT4F59'',''TOU7F79''])) or
     (lower(o.nome) ~ ''^sum[eé]($|[^a-z])'' and base.placa=any(array[''RLS8A29'',''SKZ7H38'',''SKZ8I17'',''SKZ8I57'']))
    )))::text)=''true'' inspecao_preventiva from ('||fonte||') base';
 end if;
 fonte:=replace(pg_get_functiondef('public.frota_gestao_salvar_cadastro(uuid,text,uuid,jsonb)'::regprocedure),chr(13),'');
 if position('inspecao-preventiva-01' in fonte)=0 then
  antes:=$a$p_dados:=jsonb_build_object('placa',chave_cadastro,$a$;
  depois:=$b$-- inspecao-preventiva-01: preservar marcação explícita; falso não volta à lista inicial.
  if p_dados ? 'inspecao_preventiva' and (p_dados->>'inspecao_preventiva' is null or p_dados->>'inspecao_preventiva' not in ('true','false')) then raise exception 'Confira a participacao na Inspecao Preventiva.';end if;
  p_dados:=p_dados||jsonb_build_object('inspecao_preventiva',coalesce(p_dados->>'inspecao_preventiva',(select dados->>'inspecao_preventiva' from public.frota_gestao_cadastros where id=p_id),(select inspecao_preventiva::text from public.frota_gestao_veiculos where id=p_id),(exists(select 1 from public.operacoes o where o.id=(p_dados->>'unidade_id')::uuid and o.ativa and (
     (lower(o.nome) ~ '^patos($|[^a-z])' and chave_cadastro=any(array['OFE2918','RLR8D79','RLR8F59','RLR8F99','RLU6A66','RLU6A86','RLU6A96','RLU6B06','RLX6B97','RLX7E88','SKZ7H28','SLB3G16','SLB3J86','TOT4F19','TOT4F49','TOT4F59','TOU7F79'])) or
     (lower(o.nome) ~ '^sum[eé]($|[^a-z])' and chave_cadastro=any(array['RLS8A29','SKZ7H38','SKZ8I17','SKZ8I57']))
    )))::text,'false'));
  p_dados:=jsonb_build_object('inspecao_preventiva',p_dados->>'inspecao_preventiva','placa',chave_cadastro,$b$;
  if position(antes in fonte)=0 then raise exception 'Normalizacao do cadastro divergente.';end if;
  fonte:=replace(fonte,antes,depois);
  -- Reservar o destino operacional; um cadastro nominal não pode assumir este nome.
  fonte:=replace(fonte,'''placa'',''estoque'',''milimetragem''','''placa'',''estoque'',''milimetragem'',''inspeção preventiva'',''inspecao preventiva''');
  execute fonte;
 end if;
 fonte:=pg_get_functiondef('public.frota_gestao_listar_cadastros()'::regprocedure);
 if position('''inspecao_preventiva''' in fonte)=0 then
  antes:='''contrato'',''cadastros-01''';
  if position(antes in fonte)=0 then raise exception 'Contrato de cadastros divergente.';end if;
  execute replace(fonte,antes,antes||',''inspecao_preventiva'',true');
 end if;
end $instalar$;
create or replace function public.frota_gestao_validar_destinos_coletivos(p_dados jsonb)
returns void language plpgsql stable security definer set search_path=pg_catalog,public as $$
declare item jsonb;cfg jsonb;grupo text;participantes jsonb;cad jsonb;v jsonb;r jsonb;l jsonb;n integer;i integer;q numeric;total numeric;
begin
 if not public.frota_gestao_usuario_ativo() then raise exception using errcode='42501',message='Conta ativa necessaria.';end if;
 for item in select * from jsonb_array_elements(p_dados#>'{nota,itens}') loop
  cfg:=p_dados#>array['finalizacao','itens',item->>'numero'];grupo:=nullif(cfg->>'destino_grupo','');
  if grupo is null then
   if exists(select 1 from jsonb_array_elements(p_dados#>'{nota,dados_fiscais,conferencia_hbf,linhas}') x where x->>'destino_id'='inspecao_preventiva' and split_part(x->>'id',':',1)=item->>'numero') then raise exception 'Inspecao sem grupo de rateio.';end if;
   continue;
  end if;
  if grupo='inspecao_preventiva' and not exists(select 1 from public.operacoes where id=(cfg->>'destino_unidade')::uuid and ativa and lower(nome) ~ '^(patos|sum[eé])($|[^a-z])') then raise exception 'Selecione Patos ou Sume para a Inspecao Preventiva.';end if;
  if grupo not in ('milimetragem','inspecao_preventiva') then
   select dados into cad from public.frota_gestao_cadastros where id=grupo::uuid and tipo='destinos';
   if not found then raise exception 'Destino nao cadastrado. Volte a alocacao.';end if;
  end if;
  select coalesce(jsonb_agg(to_jsonb(x) order by x.placa collate "C",x.id),'[]') into participantes from public.frota_gestao_veiculos x
   where case when grupo='milimetragem' then x.milimetragem when grupo='inspecao_preventiva' then x.inspecao_preventiva and x.operacao_id=(cfg->>'destino_unidade')::uuid else (cad->>'veiculos')::jsonb ? x.id::text end;
  n:=jsonb_array_length(participantes);
  if n not between 1 and 100 or jsonb_array_length(cfg->'rateios') is distinct from n then raise exception 'Veiculos elegiveis alterados ou ausentes. Atualize o grupo na alocacao.';end if;
  q:=public.frota_gestao_decimal_nf(item->>'quantidade',6)*1000000;
  total:=(public.frota_gestao_decimal_nf(item->>'bruto',2)-public.frota_gestao_decimal_nf(item->>'desconto',2)+public.frota_gestao_decimal_nf(item->>'acrescimo',2))*100;
  if q<n then raise exception 'Quantidade fiscal insuficiente para o grupo.';end if;
  for i in 0..n-1 loop
   v:=participantes->i;r:=cfg->'rateios'->i;
   select value into l from jsonb_array_elements(p_dados#>'{nota,dados_fiscais,conferencia_hbf,linhas}') where value->>'id'=(item->>'numero')||':'||i;
   if grupo='inspecao_preventiva' and (r->>'unidade_id' is distinct from v->>'operacao_id' or l->>'destino_id' is distinct from grupo or l->>'destino_nome' is distinct from 'Inspeção Preventiva') then raise exception 'Unidade ou destino da Inspecao Preventiva divergente.';end if;
   if r->>'destino' is distinct from 'veiculo' or r->>'veiculo_id' is distinct from v->>'id' or r->>'placa' is distinct from v->>'placa' or l->>'veiculo' is distinct from v->>'placa' then raise exception 'Placas do rateio coletivo divergentes. Recalcule a alocacao.';end if;
   if public.frota_gestao_decimal_nf(r->>'quantidade',6)*1000000<>floor(q/n)+(case when i<mod(q,n) then 1 else 0 end)
    or public.frota_gestao_decimal_nf(r->>'valor',2)*100<>floor(total/n)+(case when i<mod(total,n) then 1 else 0 end) then raise exception 'Rateio coletivo deve ser igualitario e conciliado em centavos.';end if;
  end loop;
 end loop;
end $$;
revoke all on function public.frota_gestao_validar_destinos_coletivos(jsonb) from public,anon,authenticated;
-- A conferência simplificada deve reconhecer a nova origem como custo por veículo/OS.
do $$ declare assinatura text;fonte text;begin
 foreach assinatura in array array['public.frota_gestao_validar_simplificado(jsonb,uuid,bigint)','public.frota_gestao_validar_edicao_simplificada(jsonb,uuid,bigint)'] loop
  fonte:=pg_get_functiondef(to_regprocedure(assinatura));
  if position('''inspecao_preventiva''' in fonte)=0 then
   if position('''veiculo'',''milimetragem''' in fonte)=0 then raise exception 'Validador 103 divergente: %',assinatura;end if;
   execute replace(fonte,'''veiculo'',''milimetragem''','''veiculo'',''milimetragem'',''inspecao_preventiva''');
  end if;
 end loop;
end $$;
revoke all on function public.frota_gestao_validar_simplificado(jsonb,uuid,bigint),public.frota_gestao_validar_edicao_simplificada(jsonb,uuid,bigint) from public,anon,authenticated;
notify pgrst,'reload schema';
commit;
