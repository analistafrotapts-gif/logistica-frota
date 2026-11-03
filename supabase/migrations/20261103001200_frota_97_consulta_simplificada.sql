-- Origem: SQL 97 do módulo Gestão da Frota (extraído do laboratório, sem alterações de lógica).
-- SOMENTE instalação manual futura, após 95 e 96 revisados e seus predecessores.
-- Acrescenta consulta; não altera dados, tabelas, ACL legada nem libera escritas.
-- (begin/commit removidos: o Supabase CLI já executa cada migration em uma transação)
create or replace function public.frota_gestao_dashboard_simplificado()
returns jsonb language plpgsql stable security definer set search_path=pg_catalog,public as $$
declare custos jsonb; compras jsonb; estoque jsonb;
begin
 if not public.frota_gestao_usuario_ativo() then raise exception using errcode='42501',message='Conta ativa necessária.';end if;
 select coalesce(jsonb_agg(to_jsonb(x) order by x.reconhecido_em desc,x.id),'[]') into custos from (
  select (c->>'origem')||':'||(c->>'lancamento_id')||':'||(c->>'referencia') id,
   c->>'origem' origem,n.id lancamento_id,n.numero,n.serie,n.fornecedor,c->>'referencia' referencia,
   (c->>'veiculo_id')::uuid veiculo_id,c->>'placa' placa,c->>'centro_custo' centro_custo,
   c->>'valor' valor,c->>'quantidade' quantidade,c->>'conta' conta,c->>'classificacao' classificacao,
   c->>'manutencao' manutencao,(c->>'reconhecido_em')::timestamptz reconhecido_em,
   n.unidade_fiscal_id,o.nome unidade_fiscal,h.linha->>'unidade' unidade,h.linha->>'pecas_servicos' descricao,
   h.linha->>'conta_codigo' conta_codigo,os.numero::text numero_os
  from jsonb_array_elements(public.frota_gestao_custos_simplificados()) c
  join public.frota_gestao_lancamentos n on n.id=(c->>'lancamento_id')::uuid
  join public.operacoes o on o.id=n.unidade_fiscal_id
  left join public.frota_gestao_lancamento_aplicacoes a on a.id=case when c->>'origem'='aplicacao' then (c->>'referencia')::uuid end
  left join public.frota_gestao_lancamento_lotes l on l.id=a.lote_id
  left join lateral (select linha from jsonb_array_elements(n.hbf->'linhas') linha where linha->>'id'=coalesce(l.parcela_id,c->>'referencia')) h on true
  left join public.frota_gestao_lancamento_os os on os.lancamento_id=n.id and os.veiculo_id=(c->>'veiculo_id')::uuid
 ) x;
 select coalesce(jsonb_agg(to_jsonb(x) order by x.reconhecido_em desc,x.id),'[]') into compras from (
  select n.id::text||':'||(h->>'id') id,n.id lancamento_id,n.numero,n.fornecedor,n.finalizada_em reconhecido_em,
   n.unidade_fiscal_id,o.nome unidade_fiscal,h->>'veiculo_id' veiculo_id,h->>'veiculo' placa,
   substring(h->>'centro_custo' from '[0-9]{3}$') centro_custo,h->>'quantidade' quantidade,h->>'unidade' unidade,
   h->>'valor_total' valor,h->>'classificacao' classificacao,h->>'conta_codigo' conta_codigo,h->>'conta' conta,
   h->>'manutencao' manutencao,h->>'pecas_servicos' descricao
  from public.frota_gestao_lancamentos n join public.operacoes o on o.id=n.unidade_fiscal_id
  cross join lateral jsonb_array_elements(n.hbf->'linhas') h
 ) x;
 estoque:=public.frota_gestao_estoque_simplificado();
 return jsonb_build_object('contrato','dashboard-simplificado-01','custos',custos,'compras',compras,
  'estoque',estoque->'lotes','consultado_em',statement_timestamp());
end $$;
revoke all on function public.frota_gestao_dashboard_simplificado() from public,anon;
grant execute on function public.frota_gestao_dashboard_simplificado() to authenticated;
notify pgrst,'reload schema';
