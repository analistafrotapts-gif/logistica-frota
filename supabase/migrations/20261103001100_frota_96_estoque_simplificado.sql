-- Origem: SQL 96 do módulo Gestão da Frota (extraído do laboratório, sem alterações de lógica).
-- MANUAL, após 95 revisado e seus predecessores. Não libera escritas.
-- Não converte saldos/custos do contrato anterior nem do Gestran.
-- (begin/commit removidos: o Supabase CLI já executa cada migration em uma transação)
create table if not exists public.frota_gestao_lancamento_aplicacoes (
 id uuid primary key default gen_random_uuid(), chave uuid not null unique,
 lote_id uuid not null references public.frota_gestao_lancamento_lotes(id),
 veiculo_id uuid not null references public.veiculos(id), placa text not null,
 centro_custo text not null check(centro_custo in ('501','301','201','101','401')),
 quantidade numeric(20,6) not null check(quantidade>0 and quantidade<1e14),
 valor numeric(18,2) not null check(valor>=0 and valor<1e16), dados jsonb not null,
 criado_por uuid not null references public.perfis(id), criado_em timestamptz not null default clock_timestamp()
);
-- Sem preencher retroativamente: aplicações anteriores conservam sua evidência fiscal.
alter table public.frota_gestao_lancamento_aplicacoes add column if not exists manutencao text check(manutencao in ('preventiva','corretiva'));
create index if not exists frota_gestao_lancamento_aplicacoes_lote on public.frota_gestao_lancamento_aplicacoes(lote_id);
alter table public.frota_gestao_lancamento_aplicacoes enable row level security;
revoke all on public.frota_gestao_lancamento_aplicacoes from public,anon,authenticated;
grant select on public.frota_gestao_lancamento_aplicacoes to authenticated;
drop policy if exists leitura_ativa on public.frota_gestao_lancamento_aplicacoes;
create policy leitura_ativa on public.frota_gestao_lancamento_aplicacoes for select to authenticated using(public.frota_gestao_usuario_ativo());
drop trigger if exists registrar_auditoria on public.frota_gestao_lancamento_aplicacoes;
create trigger registrar_auditoria after insert on public.frota_gestao_lancamento_aplicacoes for each row execute function public.frota_gestao_auditar();
drop trigger if exists preservar_original on public.frota_gestao_lancamento_aplicacoes;
create trigger preservar_original before update or delete on public.frota_gestao_lancamento_aplicacoes for each row execute function public.frota_gestao_snapshot_simplificado();

create or replace function public.frota_gestao_aplicar_simplificado(p_chave uuid,p_dados jsonb,p_confirmado boolean)
returns jsonb language plpgsql security definer set search_path=pg_catalog,public as $$
declare lote public.frota_gestao_lancamento_lotes; anterior public.frota_gestao_lancamento_aplicacoes;
 aplicado numeric; custo numeric; qtd numeric; valor_aplicar numeric; veiculo uuid; placa_atual text;
begin
 perform public.frota_gestao_exigir_escrita(false);
 if not public.frota_gestao_usuario_ativo() then raise exception using errcode='42501',message='Conta ativa necessária.';end if;
 if p_chave is null or p_confirmado is distinct from true then raise exception 'Confirme a aplicação.';end if;
 if p_dados is null or jsonb_typeof(p_dados)<>'object' or octet_length(p_dados::text)>2048 then raise exception 'Dados de aplicação inválidos.';end if;
 perform pg_advisory_xact_lock(hashtextextended('frota-aplicar:'||p_chave::text,0));
 select * into anterior from public.frota_gestao_lancamento_aplicacoes where chave=p_chave;
 if found then
  if anterior.dados is distinct from p_dados then raise exception 'Solicitação já confirmada com outros dados.';end if;
  return to_jsonb(anterior)||jsonb_build_object('quantidade',anterior.quantidade::text,'valor',anterior.valor::text);
 end if;
 if coalesce(p_dados->>'quantidade','')!~'^[0-9]{1,14}(\.[0-9]{1,6})?$' or coalesce(p_dados->>'centro_custo','') not in ('501','301','201','101','401') then raise exception 'Confira quantidade e centro de custo.';end if;
 if coalesce(p_dados->>'manutencao','') not in ('preventiva','corretiva') then raise exception 'Selecione Preventivo ou Corretivo para esta aplicação.';end if;
 qtd:=(p_dados->>'quantidade')::numeric;
 select * into lote from public.frota_gestao_lancamento_lotes where id=(p_dados->>'lote_id')::uuid for update;
 if not found then raise exception 'Entrada de estoque não encontrada.';end if;
 select id,placa into veiculo,placa_atual from public.veiculos where id=(p_dados->>'veiculo_id')::uuid;
 if veiculo is null then raise exception 'Selecione uma placa cadastrada.';end if;
 select coalesce(sum(quantidade),0),coalesce(sum(valor),0) into aplicado,custo from public.frota_gestao_lancamento_aplicacoes where lote_id=lote.id;
 if qtd<=0 or qtd>lote.quantidade-aplicado then raise exception 'Quantidade maior que o saldo disponível ou inválida. Atualize o estoque.';end if;
 -- Custo acumulado arredondado evita perder/somar centavos em aplicações parciais.
 valor_aplicar:=round(lote.valor*(aplicado+qtd)/lote.quantidade,2)-custo;
 insert into public.frota_gestao_lancamento_aplicacoes(chave,lote_id,veiculo_id,placa,centro_custo,quantidade,valor,dados,criado_por,manutencao)
 values(p_chave,lote.id,veiculo,placa_atual,p_dados->>'centro_custo',qtd,valor_aplicar,p_dados,auth.uid(),p_dados->>'manutencao') returning * into anterior;
 return to_jsonb(anterior)||jsonb_build_object('quantidade',anterior.quantidade::text,'valor',anterior.valor::text);
end $$;
revoke all on function public.frota_gestao_aplicar_simplificado(uuid,jsonb,boolean) from public,anon;
grant execute on function public.frota_gestao_aplicar_simplificado(uuid,jsonb,boolean) to authenticated;

create or replace function public.frota_gestao_estoque_simplificado()
returns jsonb language plpgsql stable security definer set search_path=pg_catalog,public as $$
declare lotes jsonb; aplicacoes jsonb; veiculos jsonb;
begin
 if not public.frota_gestao_usuario_ativo() then raise exception using errcode='42501',message='Conta ativa necessária.';end if;
 select coalesce(jsonb_agg(to_jsonb(x) order by x.criado_em desc,x.id),'[]') into lotes from (
  select l.id,l.lancamento_id,n.numero,n.serie,n.fornecedor,l.descricao,l.unidade,l.criado_em,o.nome unidade_fiscal,
   l.quantidade::text quantidade,l.valor::text valor,(l.quantidade-coalesce(a.quantidade,0))::text saldo,
   (l.valor-coalesce(a.valor,0))::text valor_saldo,coalesce(a.quantidade,0)::text quantidade_aplicada,
   coalesce(a.valor,0)::text valor_aplicado,coalesce(h.linha->>'conta','—') conta,coalesce(h.linha->>'conta_codigo','') conta_codigo,coalesce(h.linha->>'manutencao','') manutencao,coalesce(h.linha->>'classificacao','') classificacao
  from public.frota_gestao_lancamento_lotes l join public.frota_gestao_lancamentos n on n.id=l.lancamento_id
  join public.operacoes o on o.id=l.unidade_fiscal_id
  left join lateral (select sum(quantidade) quantidade,sum(valor) valor from public.frota_gestao_lancamento_aplicacoes where lote_id=l.id) a on true
  left join lateral (select linha from jsonb_array_elements(n.hbf->'linhas') linha where linha->>'id'=l.parcela_id) h on true
 ) x;
 select coalesce(jsonb_agg(to_jsonb(x) order by x.criado_em desc,x.id),'[]') into aplicacoes from (
  select a.id,a.chave,a.lote_id,a.veiculo_id,a.placa,a.centro_custo,a.quantidade::text quantidade,a.valor::text valor,a.criado_em,p.nome autor,a.manutencao
  from public.frota_gestao_lancamento_aplicacoes a join public.perfis p on p.id=a.criado_por
 ) x;
 select coalesce(jsonb_agg(jsonb_build_object('id',v.id,'placa',v.placa,'centro_custo',to_jsonb(v)->>'centro_custo') order by v.placa),'[]') into veiculos from public.veiculos v;
 return jsonb_build_object('contrato','estoque-simplificado-01','manutencao_editavel',true,'lotes',lotes,'aplicacoes',aplicacoes,'veiculos',veiculos);
end $$;
revoke all on function public.frota_gestao_estoque_simplificado() from public,anon;
grant execute on function public.frota_gestao_estoque_simplificado() to authenticated;

-- Fonte para o próximo Dashboard: nunca inclui valor ainda parado em estoque.
create or replace function public.frota_gestao_custos_simplificados()
returns jsonb language plpgsql stable security definer set search_path=pg_catalog,public as $$
begin
 if not public.frota_gestao_usuario_ativo() then raise exception using errcode='42501',message='Conta ativa necessária.';end if;
 return coalesce((select jsonb_agg(to_jsonb(x)) from (
  select 'direto' origem,n.id lancamento_id,l->>'id' referencia,(l->>'veiculo_id')::uuid veiculo_id,l->>'veiculo' placa,
   substring(l->>'centro_custo' from '[0-9]{3}$') centro_custo,l->>'valor_total' valor,l->>'quantidade' quantidade,l->>'conta' conta,l->>'manutencao' manutencao,n.finalizada_em reconhecido_em,coalesce(l->>'classificacao','') classificacao
  from public.frota_gestao_lancamentos n cross join lateral jsonb_array_elements(n.hbf->'linhas') l where l->>'veiculo'<>'Estoque'
  union all
  select 'aplicacao',l.lancamento_id,a.id::text,a.veiculo_id,a.placa,a.centro_custo,a.valor::text,a.quantidade::text,h.linha->>'conta',coalesce(a.manutencao,h.linha->>'manutencao'),a.criado_em,coalesce(h.linha->>'classificacao','')
  from public.frota_gestao_lancamento_aplicacoes a join public.frota_gestao_lancamento_lotes l on l.id=a.lote_id
  join public.frota_gestao_lancamentos n on n.id=l.lancamento_id
  left join lateral (select linha from jsonb_array_elements(n.hbf->'linhas') linha where linha->>'id'=l.parcela_id) h on true
 ) x),'[]');
end $$;
revoke all on function public.frota_gestao_custos_simplificados() from public,anon;
grant execute on function public.frota_gestao_custos_simplificados() to authenticated;
notify pgrst,'reload schema';
