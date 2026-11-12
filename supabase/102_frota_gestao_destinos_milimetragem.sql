-- MANUAL: após 99 revisado, 100 e 101. Preparação local; não libera escritas.
-- Não remarca veículos existentes nem converte histórico em custos novos.
begin;
set local lock_timeout='5s';
set local statement_timeout='60s';
do $$ begin
 if to_regclass('public.frota_gestao_exclusoes_simplificadas') is null then raise exception 'Instale 99, 100 e 101 antes de 102.';end if;
 if position('''obz''' in pg_get_functiondef('public.frota_gestao_validar_simplificado(jsonb,uuid,bigint)'::regprocedure))=0 then raise exception 'SQL 101 ausente.';end if;
end $$;
alter table public.frota_gestao_cadastros drop constraint frota_gestao_cadastros_tipo_check;
alter table public.frota_gestao_cadastros add constraint frota_gestao_cadastros_tipo_check check(tipo in ('veiculos','fornecedores','contas','classificacoes','destinos'));
create or replace view public.frota_gestao_veiculos with (security_barrier=true) as
 select v.id,coalesce(c.dados->>'placa',v.placa) placa,
 coalesce((c.dados->>'unidade_id')::uuid,v.operacao_id) operacao_id,
 coalesce(c.dados->>'centro_custo',to_jsonb(v)->>'centro_custo') centro_custo,
 coalesce(c.dados->>'milimetragem','false')='true' and coalesce(c.dados->>'centro_custo',to_jsonb(v)->>'centro_custo') in ('101','201','301') milimetragem
 from public.veiculos v left join public.frota_gestao_cadastros c on c.id=v.id and c.tipo='veiculos'
 where public.frota_gestao_usuario_ativo();

do $instalar$ declare fonte text;antes text;depois text;begin
 fonte:=replace(pg_get_functiondef('public.frota_gestao_salvar_cadastro(uuid,text,uuid,jsonb)'::regprocedure),chr(13),'');
 if position('''destinos''' in fonte)=0 then
  if position('(''veiculos'',''fornecedores'',''contas'',''classificacoes'')' in fonte)=0 then raise exception 'Cadastro 98 divergente.';end if;
  fonte:=replace(fonte,'(''veiculos'',''fornecedores'',''contas'',''classificacoes'')','(''veiculos'',''fornecedores'',''contas'',''classificacoes'',''destinos'')');
  antes:=$a$p_dados:=jsonb_build_object('placa',chave_cadastro,'centro_custo',p_dados->>'centro_custo','unidade_id',p_dados->>'unidade_id');$a$;
  depois:=$b$if coalesce(p_dados->>'milimetragem','false') not in ('true','false') then raise exception 'Confira a marcacao de milimetragem.';end if;
  if p_dados->>'milimetragem'='true' and p_dados->>'centro_custo' not in ('101','201','301') then raise exception 'Milimetragem: selecione Entrega, Puxada ou Armazem.';end if;
  p_dados:=jsonb_build_object('placa',chave_cadastro,'centro_custo',p_dados->>'centro_custo','unidade_id',p_dados->>'unidade_id','milimetragem',coalesce(p_dados->>'milimetragem',(select dados->>'milimetragem' from public.frota_gestao_cadastros where id=p_id),'false'));$b$;
  if position(antes in fonte)=0 then raise exception 'Normalizacao de veiculo 98 divergente.';end if;fonte:=replace(fonte,antes,depois);
  antes:=$a$ else
  chave_cadastro:=lower(btrim(p_dados->>'nome'));$a$;
  depois:=$b$ elsif p_tipo='destinos' then
  chave_cadastro:=lower(btrim(p_dados->>'nome'));
  if coalesce(chave_cadastro,'')='' or length(chave_cadastro)>80 or chave_cadastro in ('placa','estoque','milimetragem') then raise exception 'Informe outro nome para o destino (ate 80 caracteres).';end if;
  if jsonb_typeof(coalesce(p_dados->>'veiculos','[]')::jsonb)<>'array' then raise exception 'Selecione os veiculos do destino.';end if;
  if jsonb_array_length(coalesce(p_dados->>'veiculos','[]')::jsonb) not between 1 and 100 then raise exception 'Selecione de 1 a 100 veiculos.';end if;
  if exists(select 1 from jsonb_array_elements_text((p_dados->>'veiculos')::jsonb) x where x !~ '^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$') then raise exception 'Veiculo invalido.';end if;
  if (select count(distinct x) from jsonb_array_elements_text((p_dados->>'veiculos')::jsonb) x)<>jsonb_array_length((p_dados->>'veiculos')::jsonb) then raise exception 'Veiculo repetido no destino.';end if;
  if exists(select 1 from jsonb_array_elements_text((p_dados->>'veiculos')::jsonb) x where not exists(select 1 from public.frota_gestao_veiculos v where v.id=x::uuid and v.centro_custo in ('101','201','301','401','501'))) then raise exception 'Confira os veiculos e centros de custo do destino.';end if;
  p_dados:=jsonb_build_object('nome',btrim(p_dados->>'nome'),'veiculos',(p_dados->>'veiculos')::jsonb::text);
 else
  chave_cadastro:=lower(btrim(p_dados->>'nome'));$b$;
  if position(antes in fonte)=0 then raise exception 'Classificacao 98 divergente.';end if;fonte:=replace(fonte,antes,depois);
  execute fonte;
 end if;
end $instalar$;
do $$ declare fonte text;begin
 fonte:=pg_get_functiondef('public.frota_gestao_listar_cadastros()'::regprocedure);
 if position('''destinos_coletivos''' in fonte)=0 then
  if position('''contrato'',''cadastros-01''' in fonte)=0 then raise exception 'Consulta de cadastros divergente.';end if;
  fonte:=replace(fonte,'''contrato'',''cadastros-01''','''contrato'',''cadastros-01'',''destinos_coletivos'',true');execute fonte;
 end if;
end $$;

create or replace function public.frota_gestao_validar_destinos_coletivos(p_dados jsonb)
returns void language plpgsql stable security definer set search_path=pg_catalog,public as $$
declare item jsonb;cfg jsonb;grupo text;participantes jsonb;cad jsonb;v jsonb;r jsonb;l jsonb;n integer;i integer;q numeric;total numeric;
begin
 if not public.frota_gestao_usuario_ativo() then raise exception using errcode='42501',message='Conta ativa necessaria.';end if;
 for item in select * from jsonb_array_elements(p_dados#>'{nota,itens}') loop
  cfg:=p_dados#>array['finalizacao','itens',item->>'numero'];grupo:=nullif(cfg->>'destino_grupo','');
  if grupo is null then continue;end if;
  if grupo<>'milimetragem' then
   select dados into cad from public.frota_gestao_cadastros where id=grupo::uuid and tipo='destinos';
   if not found then raise exception 'Destino nao cadastrado. Volte a alocacao.';end if;
  end if;
  select coalesce(jsonb_agg(to_jsonb(x) order by x.placa collate "C",x.id),'[]') into participantes from public.frota_gestao_veiculos x
   where case when grupo='milimetragem' then x.milimetragem else (cad->>'veiculos')::jsonb ? x.id::text end;
  n:=jsonb_array_length(participantes);
  if n not between 1 and 100 or jsonb_array_length(cfg->'rateios') is distinct from n then raise exception 'Veiculos elegiveis alterados ou ausentes. Atualize o grupo na alocacao.';end if;
  q:=public.frota_gestao_decimal_nf(item->>'quantidade',6)*1000000;
  total:=(public.frota_gestao_decimal_nf(item->>'bruto',2)-public.frota_gestao_decimal_nf(item->>'desconto',2)+public.frota_gestao_decimal_nf(item->>'acrescimo',2))*100;
  if q<n then raise exception 'Quantidade fiscal insuficiente para o grupo.';end if;
  for i in 0..n-1 loop
   v:=participantes->i;r:=cfg->'rateios'->i;
   select value into l from jsonb_array_elements(p_dados#>'{nota,dados_fiscais,conferencia_hbf,linhas}') where value->>'id'=(item->>'numero')||':'||i;
   if r->>'destino' is distinct from 'veiculo' or r->>'veiculo_id' is distinct from v->>'id' or r->>'placa' is distinct from v->>'placa' or l->>'veiculo' is distinct from v->>'placa' then raise exception 'Placas do rateio coletivo divergentes. Recalcule a alocacao.';end if;
   if public.frota_gestao_decimal_nf(r->>'quantidade',6)*1000000<>floor(q/n)+(case when i<mod(q,n) then 1 else 0 end)
    or public.frota_gestao_decimal_nf(r->>'valor',2)*100<>floor(total/n)+(case when i<mod(total,n) then 1 else 0 end) then raise exception 'Rateio coletivo deve ser igualitario e conciliado em centavos.';end if;
  end loop;
 end loop;
end $$;
revoke all on function public.frota_gestao_validar_destinos_coletivos(jsonb) from public,anon,authenticated;
do $$ declare assinatura text;fonte text;begin
 foreach assinatura in array array['public.frota_gestao_validar_simplificado(jsonb,uuid,bigint)','public.frota_gestao_validar_edicao_simplificada(jsonb,uuid,bigint)'] loop
  fonte:=replace(pg_get_functiondef(to_regprocedure(assinatura)),chr(13),'');
  if position('perform public.frota_gestao_validar_destinos_coletivos(p_dados)' in fonte)=0 then
   if position('d:=p_dados;n:=' in fonte)=0 then raise exception 'Validador divergente: %',assinatura;end if;
   fonte:=replace(fonte,'d:=p_dados;n:=','perform public.frota_gestao_validar_destinos_coletivos(p_dados); d:=p_dados;n:=');execute fonte;
  end if;
 end loop;
end $$;
revoke all on function public.frota_gestao_validar_simplificado(jsonb,uuid,bigint),public.frota_gestao_validar_edicao_simplificada(jsonb,uuid,bigint) from public,anon,authenticated;
notify pgrst,'reload schema';
commit;
