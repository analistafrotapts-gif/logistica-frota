-- MANUAL após 104 e todos os predecessores. Não libera escritas, não remove registros legados.
begin;
set local lock_timeout='5s';
set local statement_timeout='60s';
do $$ begin
 if to_regprocedure('public.frota_gestao_validar_classificacao_tipo(jsonb)') is null then raise exception 'Instale e verifique SQL 104 antes de 105.';end if;
end $$;
create table if not exists public.frota_gestao_retornos_estoque (
 id uuid primary key default gen_random_uuid(),chave uuid not null unique,
 aplicacao_id uuid not null unique references public.frota_gestao_lancamento_aplicacoes(id),
 motivo text not null check(length(btrim(motivo)) between 5 and 1000),
 criado_por uuid not null references public.perfis(id),criado_em timestamptz not null default clock_timestamp()
);
create table if not exists public.frota_gestao_cadastros_excluidos (
 id uuid primary key default gen_random_uuid(),chave uuid not null unique,
 tipo text not null check(tipo in ('veiculos','fornecedores','contas','classificacoes','destinos')),
 cadastro_id uuid not null,motivo text not null check(length(btrim(motivo)) between 5 and 1000),
 criado_por uuid not null references public.perfis(id),criado_em timestamptz not null default clock_timestamp(),unique(tipo,cadastro_id)
);
do $$ declare t text;begin
 foreach t in array array['frota_gestao_retornos_estoque','frota_gestao_cadastros_excluidos'] loop
  execute format('alter table public.%I enable row level security',t);
  execute format('revoke all on public.%I from public,anon,authenticated',t);
  execute format('grant select on public.%I to authenticated',t);
  execute format('drop policy if exists leitura_ativa on public.%I',t);
  execute format('create policy leitura_ativa on public.%I for select to authenticated using(public.frota_gestao_usuario_ativo())',t);
  execute format('drop trigger if exists preservar_original on public.%I',t);
  execute format('create trigger preservar_original before update or delete on public.%I for each row execute function public.frota_gestao_snapshot_simplificado()',t);
  execute format('drop trigger if exists registrar_auditoria on public.%I',t);
  execute format('create trigger registrar_auditoria after insert on public.%I for each row execute function public.frota_gestao_auditar()',t);
 end loop;
end $$;
create or replace view public.frota_gestao_aplicacoes_efetivas with (security_barrier=true,security_invoker=true) as
 select a.* from public.frota_gestao_lancamento_aplicacoes a
 where not exists(select 1 from public.frota_gestao_retornos_estoque r where r.aplicacao_id=a.id);
revoke all on public.frota_gestao_aplicacoes_efetivas from public,anon,authenticated;
grant select on public.frota_gestao_aplicacoes_efetivas to authenticated;

create or replace function public.frota_gestao_retornar_estoque(p_chave uuid,p_aplicacao uuid,p_motivo text,p_confirmado boolean)
returns jsonb language plpgsql security definer set search_path=pg_catalog,public as $$
declare a public.frota_gestao_lancamento_aplicacoes;r public.frota_gestao_retornos_estoque;l public.frota_gestao_lancamento_lotes;
begin
 perform public.frota_gestao_exigir_escrita(false);
 if not public.frota_gestao_usuario_ativo() then raise exception using errcode='42501',message='Conta ativa necessária.';end if;
 if p_chave is null or p_aplicacao is null or p_confirmado is distinct from true or p_motivo is null or length(btrim(p_motivo)) not between 5 and 1000 then raise exception 'Confirme a aplicação e informe o motivo do retorno (5 a 1000 caracteres).';end if;
 perform pg_advisory_xact_lock(hashtextextended('frota-retorno:'||p_chave::text,0));
 select * into r from public.frota_gestao_retornos_estoque where chave=p_chave;
 if found then
  if r.aplicacao_id<>p_aplicacao or r.motivo<>btrim(p_motivo) then raise exception 'Chave já confirmada com outros dados.';end if;
  return to_jsonb(r);
 end if;
 select * into a from public.frota_gestao_lancamento_aplicacoes where id=p_aplicacao;
 if not found then raise exception 'Aplicação não encontrada.';end if;
 select * into l from public.frota_gestao_lancamento_lotes where id=a.lote_id;
 -- Mesma ordem das operações de aplicação/edição/exclusão: NF, lote, aplicação.
 perform 1 from public.frota_gestao_lancamentos where id=l.lancamento_id for update;
 perform 1 from public.frota_gestao_lancamento_lotes where id=l.id for update;
 perform 1 from public.frota_gestao_lancamento_aplicacoes where id=a.id for update;
 if not exists(select 1 from public.frota_gestao_lotes_vigentes where id=l.id) then raise exception 'NF excluída ou entrada de versão anterior. O retorno não pode reativar esse estoque.';end if;
 if exists(select 1 from public.frota_gestao_retornos_estoque where aplicacao_id=a.id) then raise exception 'Esta aplicação já retornou ao estoque. Atualize o histórico.';end if;
 insert into public.frota_gestao_retornos_estoque(chave,aplicacao_id,motivo,criado_por) values(p_chave,a.id,btrim(p_motivo),auth.uid()) returning * into r;
 return to_jsonb(r);
end $$;
revoke all on function public.frota_gestao_retornar_estoque(uuid,uuid,text,boolean) from public,anon;
grant execute on function public.frota_gestao_retornar_estoque(uuid,uuid,text,boolean) to authenticated;

create or replace function public.frota_gestao_historico_estoque()
returns jsonb language plpgsql stable security definer set search_path=pg_catalog,public as $$
begin
 if not public.frota_gestao_usuario_ativo() then raise exception using errcode='42501',message='Conta ativa necessária.';end if;
 return jsonb_build_object('contrato','historico-estoque-01','eventos',coalesce((select jsonb_agg(to_jsonb(e) order by e.data desc,e.id) from (
  select l.id::text id,'entrada'::text tipo,l.id lote_id,null::uuid aplicacao_id,coalesce(ed.hbf->>'numero_nf',n.numero) numero,l.descricao,l.unidade,l.quantidade::text quantidade,l.valor::text valor,
   'Estoque'::text placa,''::text centro_custo,l.criado_em data,p.nome autor,''::text motivo,
   case when v.id is null then 'NF excluída ou versão substituída' else 'Entrada registrada' end situacao,false retornavel
  from public.frota_gestao_lancamento_lotes l join public.frota_gestao_lancamentos n on n.id=l.lancamento_id
  left join public.frota_gestao_edicoes_simplificadas ed on ed.nota_id=n.id and ed.id::text=split_part(l.parcela_id,':',1)
  join public.perfis p on p.id=l.criado_por left join public.frota_gestao_lotes_vigentes v on v.id=l.id
  union all
  select a.id::text,'aplicacao',l.id,a.id,coalesce(ed.hbf->>'numero_nf',n.numero),l.descricao,l.unidade,a.quantidade::text,a.valor::text,a.placa,a.centro_custo,a.criado_em,p.nome,'',
   case when v.id is null then 'NF excluída ou versão substituída' when r.id is not null then 'Retornada ao estoque' else 'Aplicação ativa' end,v.id is not null and r.id is null
  from public.frota_gestao_lancamento_aplicacoes a join public.frota_gestao_lancamento_lotes l on l.id=a.lote_id
  join public.frota_gestao_lancamentos n on n.id=l.lancamento_id join public.perfis p on p.id=a.criado_por
  left join public.frota_gestao_edicoes_simplificadas ed on ed.nota_id=n.id and ed.id::text=split_part(l.parcela_id,':',1)
  left join public.frota_gestao_retornos_estoque r on r.aplicacao_id=a.id left join public.frota_gestao_lotes_vigentes v on v.id=l.id
  union all
  select r.id::text,'retorno',l.id,a.id,coalesce(ed.hbf->>'numero_nf',n.numero),l.descricao,l.unidade,a.quantidade::text,a.valor::text,a.placa,a.centro_custo,r.criado_em,p.nome,r.motivo,'Retorno confirmado',false
  from public.frota_gestao_retornos_estoque r join public.frota_gestao_lancamento_aplicacoes a on a.id=r.aplicacao_id
  join public.frota_gestao_lancamento_lotes l on l.id=a.lote_id join public.frota_gestao_lancamentos n on n.id=l.lancamento_id join public.perfis p on p.id=r.criado_por
  left join public.frota_gestao_edicoes_simplificadas ed on ed.nota_id=n.id and ed.id::text=split_part(l.parcela_id,':',1)
 ) e),'[]'));
end $$;
revoke all on function public.frota_gestao_historico_estoque() from public,anon;
grant execute on function public.frota_gestao_historico_estoque() to authenticated;

create or replace function public.frota_gestao_excluir_cadastro(p_chave uuid,p_tipo text,p_id uuid,p_motivo text,p_confirmado boolean)
returns jsonb language plpgsql security definer set search_path=pg_catalog,public as $$
declare r public.frota_gestao_cadastros_excluidos;
begin
 perform public.frota_gestao_exigir_escrita(false);
 if not public.frota_gestao_usuario_ativo() then raise exception using errcode='42501',message='Conta ativa necessária.';end if;
 if p_chave is null or p_id is null or p_tipo is null or p_tipo not in ('veiculos','fornecedores','contas','classificacoes','destinos') or p_confirmado is distinct from true or p_motivo is null or length(btrim(p_motivo)) not between 5 and 1000 then raise exception 'Confirme o cadastro e informe o motivo da exclusão.';end if;
 perform pg_advisory_xact_lock(hashtextextended('frota-excluir-cadastro-op:'||p_chave::text,0));
 select * into r from public.frota_gestao_cadastros_excluidos where chave=p_chave;
 if found then
  if r.tipo<>p_tipo or r.cadastro_id<>p_id or r.motivo<>btrim(p_motivo) then raise exception 'Chave já confirmada com outros dados.';end if;
  return to_jsonb(r);
 end if;
 perform pg_advisory_xact_lock(hashtextextended('frota-cadastro-id:'||p_id::text,0));
 perform 1 from public.frota_gestao_cadastros where id=p_id for update;
 if not exists(select 1 from public.frota_gestao_cadastros where id=p_id and tipo=p_tipo)
  and not(p_tipo='veiculos' and exists(select 1 from public.veiculos where id=p_id))
  and not(p_tipo='fornecedores' and exists(select 1 from public.frota_gestao_fornecedores where fornecedor_id=p_id)) then raise exception 'Cadastro não encontrado.';end if;
 if exists(select 1 from public.frota_gestao_cadastros_excluidos where tipo=p_tipo and cadastro_id=p_id) then raise exception 'Cadastro já excluído. Atualize a listagem.';end if;
 insert into public.frota_gestao_cadastros_excluidos(chave,tipo,cadastro_id,motivo,criado_por) values(p_chave,p_tipo,p_id,btrim(p_motivo),auth.uid()) returning * into r;
 return to_jsonb(r);
end $$;
revoke all on function public.frota_gestao_excluir_cadastro(uuid,text,uuid,text,boolean) from public,anon;
grant execute on function public.frota_gestao_excluir_cadastro(uuid,text,uuid,text,boolean) to authenticated;

create or replace view public.frota_gestao_cadastros_ativos with (security_barrier=true,security_invoker=true) as
 select c.* from public.frota_gestao_cadastros c where not exists(
  select 1 from public.frota_gestao_cadastros_excluidos x where x.tipo=c.tipo and x.cadastro_id=c.id);
revoke all on public.frota_gestao_cadastros_ativos from public,anon,authenticated;
grant select on public.frota_gestao_cadastros_ativos to authenticated;

-- Leituras efetivas; os eventos físicos permanecem disponíveis na consulta histórica.
do $$ declare assinatura text;fonte text;antes text;begin
 foreach assinatura in array array['frota_gestao_validar_simplificado(jsonb,uuid,bigint)','frota_gestao_validar_edicao_simplificada(jsonb,uuid,bigint)','frota_gestao_validar_destino_nominal(jsonb,jsonb)','frota_gestao_validar_destinos_coletivos(jsonb)'] loop
  fonte:=pg_get_functiondef(('public.'||assinatura)::regprocedure);
  fonte:=regexp_replace(fonte,'public[.]frota_gestao_cadastros\M','public.frota_gestao_cadastros_ativos','g');execute fonte;
 end loop;
 foreach assinatura in array array['frota_gestao_estoque_simplificado()','frota_gestao_custos_simplificados()'] loop
  fonte:=pg_get_functiondef(('public.'||assinatura)::regprocedure);
  if position('public.frota_gestao_aplicacoes_efetivas' in fonte)=0 then
   if position('public.frota_gestao_lancamento_aplicacoes' in fonte)=0 then raise exception 'Predecessor divergente: %',assinatura;end if;
   fonte:=replace(fonte,'public.frota_gestao_lancamento_aplicacoes','public.frota_gestao_aplicacoes_efetivas');execute fonte;
  end if;
 end loop;
 fonte:=pg_get_functiondef('public.frota_gestao_aplicar_simplificado(uuid,jsonb,boolean)'::regprocedure);
 if position('from public.frota_gestao_aplicacoes_efetivas where lote_id=lote.id' in fonte)=0 then
  antes:='from public.frota_gestao_lancamento_aplicacoes where lote_id=lote.id';
  if position(antes in fonte)=0 or position('round(lote.valor*(aplicado+qtd)/lote.quantidade,2)-custo' in fonte)=0 then raise exception 'Aplicação 96/99 divergente.';end if;
  fonte:=replace(fonte,antes,'from public.frota_gestao_aplicacoes_efetivas where lote_id=lote.id');
  fonte:=replace(fonte,'round(lote.valor*(aplicado+qtd)/lote.quantidade,2)-custo',
   'case when qtd=lote.quantidade-aplicado then lote.valor-custo else round((lote.valor-custo)*qtd/(lote.quantidade-aplicado),2) end');execute fonte;
 end if;
 fonte:=regexp_replace(pg_get_viewdef('public.frota_gestao_veiculos'::regclass,true),';[[:space:]]*$','');
 if position('frota_gestao_cadastros_excluidos' in fonte)=0 then
  execute 'create or replace view public.frota_gestao_veiculos with (security_barrier=true) as select v.* from ('||fonte||') v where not exists(select 1 from public.frota_gestao_cadastros_excluidos x where x.tipo=''veiculos'' and x.cadastro_id=v.id)';
 end if;
 fonte:=pg_get_functiondef('public.frota_gestao_listar_cadastros()'::regprocedure);
 if position('''exclusao_disponivel''' in fonte)=0 then
  fonte:=replace(fonte,'''contrato'',''cadastros-01''','''contrato'',''cadastros-01'',''exclusao_disponivel'',true');
  antes:=')c),''[]'')';
  if position(antes in fonte)=0 then raise exception 'Listagem de cadastros 103 divergente.';end if;
  fonte:=replace(fonte,antes,')c where not exists(select 1 from public.frota_gestao_cadastros_excluidos x where x.tipo=c.tipo and x.cadastro_id=c.id)),''[]'')');execute fonte;
 end if;
 -- Evita editar/recriar silenciosamente um registro excluído. O histórico conserva a chave.
 fonte:=pg_get_functiondef('public.frota_gestao_salvar_cadastro(uuid,text,uuid,jsonb)'::regprocedure);
 if position('frota-cadastro-id:' in fonte)=0 then
  antes:=' if p_tipo=''veiculos'' then';
  if position(antes in fonte)=0 then raise exception 'Cadastro 103 divergente.';end if;
  fonte:=replace(fonte,antes,' if p_id is not null then perform pg_advisory_xact_lock(hashtextextended(''frota-cadastro-id:''||p_id::text,0)); if exists(select 1 from public.frota_gestao_cadastros_excluidos where tipo=p_tipo and cadastro_id=p_id) then raise exception ''Cadastro excluído; não pode ser editado.'';end if;end if;'||antes);execute fonte;
 end if;
end $$;
notify pgrst,'reload schema';
commit;
