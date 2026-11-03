-- Origem: SQL 90 do módulo Gestão da Frota (extraído do laboratório, sem alterações de lógica).
-- PREPARADO, NÃO EXECUTADO. Instalação manual após 89; ver BANCO-CICLO-01.md.
-- (begin/commit removidos: o Supabase CLI já executa cada migration em uma transação)
do $$ begin
  if to_regprocedure('public.frota_gestao_preparacao_estoque()') is null then raise exception 'Confira 84 a 89 completos antes de instalar 90.';end if;
  if exists(select 1 from public.frota_gestao_hbf h join public.frota_gestao_nf_versoes v on v.id=h.versao_id
    where h.estado='emitido' and exists(select 1 from public.frota_gestao_nf_versoes nv where nv.nota_id=v.nota_id and nv.numero_versao>v.numero_versao)) then
    raise exception 'Há HBF emitido de versão fiscal já substituída. Concilie o histórico antes da instalação, sem apagar emissões.';
  end if;
end $$;

-- Uma linha por fato financeiro, inclusive compensações, sem multiplicação pelos rateios.
create or replace view public.frota_gestao_custos_detalhados with(security_invoker=true) as
select c.id,c.origem,c.valor,c.executado_em,c.criado_em,c.custo_estornado_id,
  raiz.origem natureza_custo,c.veiculo_id,v.placa,c.unidade_custo_id,u.nome unidade,
  o.id os_id,o.numero::text numero_os,oi.id os_item_id,oi.tipo_manutencao,oi.descricao componente,
  n.id nota_id,n.numero numero_nf,n.serie,n.fornecedor_id,f.razao_social fornecedor,
  nv.id versao_id,nv.numero_versao,nv.finalizada_em,nv.emissao,
  case when raiz.origem='servico' then vf.categoria_id else cl.categoria_id end categoria_id,
  case when raiz.origem='servico' then vf.centro_custo else cl.centro_custo end centro_custo,
  case when raiz.origem='servico' then vf.conta_id else cl.conta_id end conta_id,
  cat.nome categoria,cc.nome centro_nome,ct.nome conta,ct.codigo conta_codigo,
  a.id aplicacao_id,l.id lote_id,c.estorno_id
from public.frota_gestao_custos c
join public.frota_gestao_custos raiz on raiz.id=coalesce(c.custo_estornado_id,c.id)
join public.veiculos v on v.id=c.veiculo_id join public.operacoes u on u.id=c.unidade_custo_id
left join public.frota_gestao_vinculos vf on vf.id=raiz.vinculo_id
left join public.frota_gestao_aplicacoes a on a.id=raiz.aplicacao_id
left join public.frota_gestao_lotes l on l.id=a.lote_id
join public.frota_gestao_nf_itens ni on ni.id=coalesce(vf.nf_item_id,l.nf_item_id)
join public.frota_gestao_nf_versoes nv on nv.id=ni.versao_id
join public.frota_gestao_notas n on n.id=nv.nota_id
join public.frota_gestao_fornecedores f on f.fornecedor_id=n.fornecedor_id
join public.frota_gestao_os_itens oi on oi.id=coalesce(vf.os_item_id,a.os_item_id)
join public.frota_gestao_os o on o.id=oi.os_id
left join lateral (
  select case when count(distinct coalesce(x.categoria_id::text,'#'))=1 then max(x.categoria_id::text)::uuid end categoria_id,
    case when count(distinct coalesce(x.conta_id::text,'#'))=1 then max(x.conta_id::text)::uuid end conta_id,
    case when count(distinct coalesce(x.centro_custo,'#'))=1 then max(x.centro_custo) end centro_custo
  from public.frota_gestao_vinculos x where x.nf_item_id=ni.id and
    (x.os_item_id=oi.id or (x.os_item_id is null and not exists(select 1 from public.frota_gestao_vinculos ex where ex.nf_item_id=ni.id and ex.os_item_id=oi.id)))
) cl on raiz.origem='peca_aplicada'
left join public.frota_gestao_categorias cat on cat.id=case when raiz.origem='servico' then vf.categoria_id else cl.categoria_id end
left join public.frota_gestao_contas ct on ct.id=case when raiz.origem='servico' then vf.conta_id else cl.conta_id end
left join public.frota_centros_custo cc on cc.codigo=case when raiz.origem='servico' then vf.centro_custo else cl.centro_custo end;
revoke all on public.frota_gestao_custos_detalhados from public,anon,authenticated;

create or replace function public.frota_gestao_ratear_item(p_item uuid,p_total numeric)
returns table(vinculo_id uuid,valor numeric) language sql stable security definer set search_path=pg_catalog,public as $$
  with pesos as (select id,quantidade,sum(quantidade) over() soma from public.frota_gestao_vinculos where nf_item_id=p_item),
  parcelas as (select id,floor(round(p_total*100)*quantidade/soma) base,
    round(p_total*100)*quantidade/soma-floor(round(p_total*100)*quantidade/soma) resto from pesos),
  ordem as (select *,row_number() over(order by resto desc,id) pos,round(p_total*100)-sum(base) over() faltam from parcelas)
  select id,round((base+case when pos<=faltam then 1 else 0 end)/100,2) from ordem
$$;
revoke all on function public.frota_gestao_ratear_item(uuid,numeric) from public,anon,authenticated;

create or replace function public.frota_gestao_filtrar_custos(p_filtros jsonb)
returns setof public.frota_gestao_custos_detalhados language sql stable security definer set search_path=pg_catalog,public as $$
  select c.* from public.frota_gestao_custos_detalhados c
  where c.executado_em between (p_filtros->>'inicio')::date and (p_filtros->>'fim')::date
    and (coalesce(p_filtros->>'unidade_id','')='' or c.unidade_custo_id::text=p_filtros->>'unidade_id')
    and (coalesce(p_filtros->>'veiculo_id','')='' or c.veiculo_id::text=p_filtros->>'veiculo_id')
    and (coalesce(p_filtros->>'fornecedor_id','')='' or c.fornecedor_id::text=p_filtros->>'fornecedor_id')
    and (coalesce(p_filtros->>'manutencao','')='' or c.tipo_manutencao=p_filtros->>'manutencao')
    and (coalesce(p_filtros->>'categoria_id','')='' or coalesce(c.categoria_id::text,'sem_classificacao')=p_filtros->>'categoria_id')
$$;
revoke all on function public.frota_gestao_filtrar_custos(jsonb) from public,anon,authenticated;

create or replace function public.frota_gestao_validar_filtros(p_filtros jsonb)
returns void language plpgsql immutable set search_path=pg_catalog,public as $$
begin
  if jsonb_typeof(p_filtros) is distinct from 'object' or octet_length(p_filtros::text)>4096
    or coalesce(p_filtros->>'inicio','') !~ '^[0-9]{4}-[0-9]{2}-[0-9]{2}$' or coalesce(p_filtros->>'fim','') !~ '^[0-9]{4}-[0-9]{2}-[0-9]{2}$'
    or (p_filtros->>'fim')::date<(p_filtros->>'inicio')::date then raise exception 'Confira o período dos filtros.';end if;
end $$;
revoke all on function public.frota_gestao_validar_filtros(jsonb) from public,anon,authenticated;

create or replace function public.frota_gestao_painel(p_filtros jsonb,p_pagina integer)
returns jsonb language plpgsql stable security definer set search_path=pg_catalog,public as $$
declare resultado jsonb;
begin
  if not public.frota_gestao_usuario_ativo() then raise exception using errcode='42501',message='Conta inativa ou não autenticada.';end if;
  perform public.frota_gestao_validar_filtros(p_filtros);
  if p_pagina is null or p_pagina<0 then raise exception 'Página inválida.';end if;
  with custos as materialized(select * from public.frota_gestao_filtrar_custos(p_filtros)),
  vigentes as materialized(select distinct on(nota_id) * from public.frota_gestao_nf_versoes order by nota_id,numero_versao desc),
  fiscais as materialized(
    select v.*,i.natureza,n.nota_id,n.emissao,n.finalizada_em,nt.fornecedor_id,f.razao_social fornecedor
    from public.frota_gestao_vinculos v join public.frota_gestao_nf_itens i on i.id=v.nf_item_id
    join vigentes n on n.id=i.versao_id and n.estado='finalizada'
    join public.frota_gestao_notas nt on nt.id=n.nota_id join public.frota_gestao_fornecedores f on f.fornecedor_id=nt.fornecedor_id
    left join public.frota_gestao_os_itens oi on oi.id=v.os_item_id
    where (coalesce(p_filtros->>'veiculo_id','')='' or v.veiculo_id::text=p_filtros->>'veiculo_id')
      and (coalesce(p_filtros->>'fornecedor_id','')='' or nt.fornecedor_id::text=p_filtros->>'fornecedor_id')
      and (coalesce(p_filtros->>'manutencao','')='' or oi.tipo_manutencao=p_filtros->>'manutencao')
      and (coalesce(p_filtros->>'categoria_id','')='' or coalesce(v.categoria_id::text,'sem_classificacao')=p_filtros->>'categoria_id')
  ), fiscais_periodo as materialized(select * from fiscais where emissao between (p_filtros->>'inicio')::date and (p_filtros->>'fim')::date
    and (coalesce(p_filtros->>'unidade_id','')='' or unidade_custo_id::text=p_filtros->>'unidade_id')),
  saldos as materialized(
    select m.lote_id,m.local_id,sum(case when m.tipo in ('entrada_nf','transferencia_entrada','ajuste_entrada','retorno_fisico') then m.valor else -m.valor end) valor
    from public.frota_gestao_movimentos m join public.frota_gestao_locais l on l.id=m.local_id
    where (m.criado_em at time zone 'America/Sao_Paulo')::date<=(p_filtros->>'fim')::date
      and (coalesce(p_filtros->>'unidade_id','')='' or l.operacao_id::text=p_filtros->>'unidade_id') group by m.lote_id,m.local_id
  ), estoque as (
    select r.valor from saldos s join public.frota_gestao_lotes l on l.id=s.lote_id
    cross join lateral public.frota_gestao_ratear_item(l.nf_item_id,s.valor) r
    join public.frota_gestao_vinculos f on f.id=r.vinculo_id join public.frota_gestao_nf_itens ni on ni.id=f.nf_item_id
    join public.frota_gestao_nf_versoes nv on nv.id=ni.versao_id join public.frota_gestao_notas nt on nt.id=nv.nota_id
    left join public.frota_gestao_os_itens oi on oi.id=f.os_item_id
    where (coalesce(p_filtros->>'veiculo_id','')='' or f.veiculo_id::text=p_filtros->>'veiculo_id')
      and (coalesce(p_filtros->>'fornecedor_id','')='' or nt.fornecedor_id::text=p_filtros->>'fornecedor_id')
      and (coalesce(p_filtros->>'manutencao','')='' or oi.tipo_manutencao=p_filtros->>'manutencao')
      and (coalesce(p_filtros->>'categoria_id','')='' or coalesce(f.categoria_id::text,'sem_classificacao')=p_filtros->>'categoria_id')
  ), itens_os as materialized(
    select i.*,o.estado,o.id ordem_id from public.frota_gestao_os_itens i join public.frota_gestao_os o on o.id=i.os_id
    where (o.criado_em at time zone 'America/Sao_Paulo')::date between (p_filtros->>'inicio')::date and (p_filtros->>'fim')::date
      and (coalesce(p_filtros->>'unidade_id','')='' or o.operacao_id::text=p_filtros->>'unidade_id')
      and (coalesce(p_filtros->>'veiculo_id','')='' or o.veiculo_id::text=p_filtros->>'veiculo_id')
      and (coalesce(p_filtros->>'manutencao','')='' or i.tipo_manutencao=p_filtros->>'manutencao')
      and ((coalesce(p_filtros->>'fornecedor_id','')='' and coalesce(p_filtros->>'categoria_id','')='')
        or exists(select 1 from fiscais f where f.os_item_id=i.id))
  ), pendencias as (
    select i.*,greatest(i.quantidade_prevista-coalesce((select sum(v.quantidade*ni.fator_conversao) from public.frota_gestao_vinculos v
      join public.frota_gestao_nf_itens ni on ni.id=v.nf_item_id join vigentes nv on nv.id=ni.versao_id and nv.estado='finalizada'
      where v.os_item_id=i.id),0),0) pendente from itens_os i where i.estado<>'cancelada'
  ), detalhe as (select to_jsonb(c)||jsonb_build_object('valor',c.valor::text) dados from custos c order by c.executado_em desc,c.id limit 25 offset p_pagina::bigint*25)
  select jsonb_build_object('contrato','05','indicadores',jsonb_build_object(
    'efetivo',coalesce((select sum(valor) from custos),0)::text,
    'servicos',coalesce((select sum(valor) from custos where natureza_custo='servico'),0)::text,
    'aplicadas',coalesce((select sum(valor) from custos where natureza_custo='peca_aplicada'),0)::text,
    'aquisicoes',coalesce((select sum(valor_documentado) from fiscais_periodo where natureza='peca'),0)::text,
    'estoque',coalesce((select sum(valor) from estoque),0)::text,
    'notas',(select count(distinct nota_id) from fiscais_periodo),
    'abertas',(select count(distinct ordem_id) from itens_os where estado in ('aberta','em_execucao')),
    'concluidas',(select count(distinct ordem_id) from itens_os where estado='encerrada'),
    'previsto_pendente',coalesce((select sum(round(valor_previsto*pendente/quantidade_prevista,2)) from pendencias where previsao_informada),0)::text,
    'previsoes_nao_informadas',(select count(*) from pendencias where not previsao_informada and pendente>0),
    'estornos_quantidade',(select count(*) from custos where origem='estorno'),
    'estornos_valor',coalesce((select -sum(valor) from custos where origem='estorno'),0)::text,
    'sem_classificacao',(select count(*) from custos where categoria_id is null)),
    'mensal',coalesce((select jsonb_agg(to_jsonb(x) order by x.nome) from(select to_char(executado_em,'YYYY-MM') nome,sum(valor)::text valor from custos group by 1)x),'[]'),
    'veiculos',coalesce((select jsonb_agg(to_jsonb(x) order by x.ordem desc,x.nome) from(select placa nome,sum(valor)::text valor,sum(valor) ordem from custos group by placa order by sum(valor) desc,placa limit 10)x),'[]'),
    'fornecedores',coalesce((select jsonb_agg(to_jsonb(x) order by x.ordem desc,x.nome) from(select fornecedor nome,sum(valor_documentado)::text valor,sum(valor_documentado) ordem from fiscais_periodo group by fornecedor_id,fornecedor order by sum(valor_documentado) desc,fornecedor limit 10)x),'[]'),
    'categorias',coalesce((select jsonb_agg(to_jsonb(x) order by x.nome) from(select coalesce(categoria,'Sem classificação') nome,sum(valor)::text valor from custos group by categoria_id,categoria)x),'[]'),
    'manutencoes',coalesce((select jsonb_agg(to_jsonb(x) order by x.nome) from(select tipo_manutencao nome,sum(valor)::text valor,count(distinct os_item_id) quantidade from custos group by tipo_manutencao)x),'[]'),
    'unidades',coalesce((select jsonb_agg(to_jsonb(x) order by x.nome) from(select unidade nome,sum(valor)::text valor from custos group by unidade_custo_id,unidade)x),'[]'),
    'naturezas',coalesce((select jsonb_agg(to_jsonb(x) order by x.nome) from(select natureza_custo nome,sum(valor)::text valor from custos group by natureza_custo)x),'[]'),
    'total',(select count(*) from custos),'linhas',coalesce((select jsonb_agg(dados) from detalhe),'[]')) into resultado;
  return resultado;
end $$;
revoke all on function public.frota_gestao_painel(jsonb,integer) from public,anon;
grant execute on function public.frota_gestao_painel(jsonb,integer) to authenticated;

create or replace function public.frota_gestao_opcoes_gerenciais()
returns jsonb language plpgsql stable security definer set search_path=pg_catalog,public as $$
begin
  if not public.frota_gestao_usuario_ativo() then raise exception using errcode='42501',message='Conta inativa ou não autenticada.';end if;
  return jsonb_build_object('unidades',coalesce((select jsonb_agg(jsonb_build_object('id',id,'nome',nome) order by nome) from public.operacoes),'[]'),
    'veiculos',coalesce((select jsonb_agg(jsonb_build_object('id',id,'nome',placa) order by placa,id) from public.veiculos),'[]'),
    'fornecedores',coalesce((select jsonb_agg(jsonb_build_object('id',fornecedor_id,'nome',razao_social) order by razao_social) from public.frota_gestao_fornecedores),'[]'),
    'categorias',coalesce((select jsonb_agg(jsonb_build_object('id',id,'nome',nome) order by nome) from public.frota_gestao_categorias),'[]'));
end $$;
revoke all on function public.frota_gestao_opcoes_gerenciais() from public,anon;
grant execute on function public.frota_gestao_opcoes_gerenciais() to authenticated;

alter table public.frota_gestao_hbf add column if not exists substituido_por_versao_id uuid references public.frota_gestao_nf_versoes(id);
alter table public.frota_gestao_hbf add column if not exists hash_emissao text;
create index if not exists frota_gestao_hbf_versao on public.frota_gestao_hbf(versao_id,criado_em,id);

create or replace function public.frota_gestao_proteger_hbf()
returns trigger language plpgsql set search_path=pg_catalog,public as $$
begin
  if tg_op='DELETE' then raise exception 'Histórico HBF não pode ser excluído.';end if;
  if new.id<>old.id or new.versao_id<>old.versao_id or new.versao_modelo<>old.versao_modelo or new.dados is distinct from old.dados
    or new.criado_por<>old.criado_por or new.criado_em<>old.criado_em or new.hash_emissao is distinct from old.hash_emissao
    or (old.estado='invalidado' and new.estado<>'invalidado') or (old.encaminhamento='encaminhado' and
      (new.encaminhamento<>old.encaminhamento or new.encaminhado_em is distinct from old.encaminhado_em or new.encaminhado_por is distinct from old.encaminhado_por)) then
    raise exception 'Snapshot HBF e encaminhamento confirmado são imutáveis.';
  end if;
  return new;
end $$;
revoke all on function public.frota_gestao_proteger_hbf() from public,anon,authenticated;
drop trigger if exists proteger_hbf on public.frota_gestao_hbf;
create trigger proteger_hbf before update or delete on public.frota_gestao_hbf for each row execute function public.frota_gestao_proteger_hbf();

create or replace function public.frota_gestao_substituir_hbf()
returns trigger language plpgsql security definer set search_path=pg_catalog,public as $$
begin
  update public.frota_gestao_hbf h set estado='invalidado',substituido_por_versao_id=new.id
    where h.versao_id in (select id from public.frota_gestao_nf_versoes where nota_id=new.nota_id and numero_versao<new.numero_versao)
      and h.estado='emitido';
  return null;
end $$;
revoke all on function public.frota_gestao_substituir_hbf() from public,anon,authenticated;
drop trigger if exists substituir_hbf on public.frota_gestao_nf_versoes;
create trigger substituir_hbf after insert on public.frota_gestao_nf_versoes for each row execute function public.frota_gestao_substituir_hbf();

create or replace function public.frota_gestao_emitir_hbf(p_versao uuid,p_chave uuid,p_confirmado boolean)
returns jsonb language plpgsql security definer set search_path=pg_catalog,public as $$
declare versao public.frota_gestao_nf_versoes;nota public.frota_gestao_notas;anterior public.frota_gestao_hbf;
  linhas jsonb;dados jsonb;assinatura text;autor text;momento timestamptz:=clock_timestamp();total_linhas numeric;
begin
  perform public.frota_gestao_exigir_escrita(false);
  if not public.frota_gestao_usuario_ativo() then raise exception using errcode='42501',message='Conta inativa ou não autenticada.';end if;
  if p_chave is null or p_confirmado is distinct from true then raise exception 'Confirme explicitamente a emissão do HBF.';end if;
  perform pg_advisory_xact_lock(hashtextextended('hbf-emissao:'||p_chave::text,0));
  assinatura:=encode(sha256(convert_to('hbf-01:'||p_versao::text,'UTF8')),'hex');
  select * into anterior from public.frota_gestao_hbf where id=p_chave;
  if found then
    if anterior.hash_emissao is distinct from assinatura then raise exception 'Chave de emissão reutilizada com outra versão.';end if;
    return to_jsonb(anterior);
  end if;
  select * into versao from public.frota_gestao_nf_versoes where id=p_versao;
  if not found then raise exception 'Versão fiscal não encontrada.';end if;
  -- A correção futura precisa usar o mesmo row lock da identidade fiscal.
  select * into nota from public.frota_gestao_notas where id=versao.nota_id for update;
  if versao.estado<>'finalizada' or exists(select 1 from public.frota_gestao_nf_versoes where nota_id=nota.id and numero_versao>versao.numero_versao) then raise exception 'Emita somente para a versão finalizada vigente da NF.';end if;
  if not exists(select 1 from public.frota_gestao_nf_itens where versao_id=p_versao) or exists(
    select 1 from public.frota_gestao_nf_itens i where i.versao_id=p_versao and
      (i.quantidade_compra<>(select coalesce(sum(quantidade),0) from public.frota_gestao_vinculos where nf_item_id=i.id)
       or i.liquido<>(select coalesce(sum(valor_documentado),0) from public.frota_gestao_vinculos where nf_item_id=i.id)))
    or versao.total<>(select coalesce(sum(liquido),0) from public.frota_gestao_nf_itens where versao_id=p_versao) then raise exception 'NF, itens e rateios não conciliam. HBF não emitido.';end if;
  if exists(select 1 from public.frota_gestao_vinculos v join public.frota_gestao_nf_itens i on i.id=v.nf_item_id
    left join public.frota_gestao_categorias c on c.id=v.categoria_id where i.versao_id=p_versao and
      (v.centro_custo is null or v.conta_id is null or c.coluna_hbf is null)) then raise exception 'Complete centro de custo, conta e coluna HBF das categorias de todos os rateios.';end if;
  select jsonb_agg(jsonb_build_object('vinculo_id',v.id,'item',i.numero_item,'veiculo',coalesce(ve.placa,case when v.classificacao->>'destino'='estoque' then 'Estoque' else 'Apropriação pendente' end),
    'numero_os',coalesce(o.numero::text,'—'),'numero_nf',nota.numero,'centro_custo',v.centro_custo||' · '||cc.nome,'conta',ct.codigo||' · '||ct.nome,
    'pecas_servicos',i.descricao_conferida,'quantidade',v.quantidade::text,'unidade',i.unidade_compra,'unidade_custo',u.nome,
    'servicos',case when c.coluna_hbf='servicos' then (v.valor_documentado+d.valor)::text else '0.00' end,
    'pecas',case when c.coluna_hbf='pecas' then (v.valor_documentado+d.valor)::text else '0.00' end,
    'lavagem',case when c.coluna_hbf='lavagem' then (v.valor_documentado+d.valor)::text else '0.00' end,
    'pneus',case when c.coluna_hbf='pneus' then (v.valor_documentado+d.valor)::text else '0.00' end,
    'oleo_lubrificante',case when c.coluna_hbf='oleo_lubrificante' then (v.valor_documentado+d.valor)::text else '0.00' end,
    'desconto',d.valor::text,'valor_total',v.valor_documentado::text,'acrescimo_item',i.acrescimo::text) order by i.numero_item,v.id),sum(v.valor_documentado)
    into linhas,total_linhas
  from public.frota_gestao_nf_itens i join public.frota_gestao_vinculos v on v.nf_item_id=i.id
  join lateral public.frota_gestao_ratear_item(i.id,i.desconto) d on d.vinculo_id=v.id
  left join public.veiculos ve on ve.id=v.veiculo_id left join public.frota_gestao_os o on o.id=v.os_id
  join public.frota_centros_custo cc on cc.codigo=v.centro_custo join public.frota_gestao_contas ct on ct.id=v.conta_id
  join public.frota_gestao_categorias c on c.id=v.categoria_id join public.operacoes u on u.id=v.unidade_custo_id where i.versao_id=p_versao;
  if total_linhas is distinct from versao.total then raise exception 'Linhas HBF não conciliam com a nota.';end if;
  select nome into autor from public.perfis where id=auth.uid();
  dados:=jsonb_build_object('contrato','05','modelo','hbf-01','preliminar',false,'emissao_id',p_chave,'versao_id',p_versao,
    'numero_versao',versao.numero_versao,'nota_id',nota.id,'numero_nf',nota.numero,'serie',nota.serie,'chave_acesso',nota.chave_acesso,
    'fornecedor',(select razao_social from public.frota_gestao_fornecedores where fornecedor_id=nota.fornecedor_id),
    'documento_fornecedor',(select documento from public.frota_gestao_fornecedores where fornecedor_id=nota.fornecedor_id),
    'unidade_fiscal',(select nome from public.operacoes where id=nota.unidade_fiscal_id),'emissao_nf',versao.emissao,'finalizada_em',versao.finalizada_em,
    'autor',autor,'autor_id',auth.uid(),'gerado_em',momento,'total',versao.total::text,'linhas',linhas,
    'desconto',(select sum(desconto)::text from public.frota_gestao_nf_itens where versao_id=p_versao),
    'acrescimo',(select sum(acrescimo)::text from public.frota_gestao_nf_itens where versao_id=p_versao),
    'referencias',coalesce((select jsonb_agg(jsonb_build_object('descricao',descricao,'url',url) order by criado_em,id) from public.frota_gestao_referencias where versao_id=p_versao),'[]'),
    'dados_fiscais',versao.dados_fiscais);
  insert into public.frota_gestao_hbf(id,versao_id,versao_modelo,dados,hash_emissao,criado_em) values(p_chave,p_versao,'hbf-01',dados,assinatura,momento) returning * into anterior;
  return to_jsonb(anterior);
end $$;
revoke all on function public.frota_gestao_emitir_hbf(uuid,uuid,boolean) from public,anon;
grant execute on function public.frota_gestao_emitir_hbf(uuid,uuid,boolean) to authenticated;

create or replace function public.frota_gestao_consultar_hbf(p_id uuid)
returns jsonb language plpgsql stable security definer set search_path=pg_catalog,public as $$
begin
  if not public.frota_gestao_usuario_ativo() then raise exception using errcode='42501',message='Conta inativa ou não autenticada.';end if;
  return (select to_jsonb(h) from public.frota_gestao_hbf h where id=p_id);
end $$;
revoke all on function public.frota_gestao_consultar_hbf(uuid) from public,anon;
grant execute on function public.frota_gestao_consultar_hbf(uuid) to authenticated;

create or replace function public.frota_gestao_encaminhar_hbf(p_id uuid,p_confirmado boolean)
returns jsonb language plpgsql security definer set search_path=pg_catalog,public as $$
declare emissao public.frota_gestao_hbf;
begin
  perform public.frota_gestao_exigir_escrita(false);
  if not public.frota_gestao_usuario_ativo() then raise exception using errcode='42501',message='Conta inativa ou não autenticada.';end if;
  if p_confirmado is distinct from true then raise exception 'Confirme o encaminhamento realizado ao financeiro.';end if;
  select * into emissao from public.frota_gestao_hbf where id=p_id;
  if not found then raise exception 'HBF não encontrado.';end if;
  perform 1 from public.frota_gestao_notas where id=(select nota_id from public.frota_gestao_nf_versoes where id=emissao.versao_id) for update;
  select * into emissao from public.frota_gestao_hbf where id=p_id for update;
  if emissao.estado<>'emitido' then raise exception 'HBF substituído ou invalidado não pode ser encaminhado.';end if;
  if emissao.encaminhamento='nao_informado' then
    update public.frota_gestao_hbf set encaminhamento='encaminhado',encaminhado_por=auth.uid(),encaminhado_em=clock_timestamp() where id=p_id returning * into emissao;
  end if;
  return to_jsonb(emissao);
end $$;
revoke all on function public.frota_gestao_encaminhar_hbf(uuid,boolean) from public,anon;
grant execute on function public.frota_gestao_encaminhar_hbf(uuid,boolean) to authenticated;

create or replace function public.frota_gestao_central_hbf(p_busca text,p_pagina integer)
returns jsonb language plpgsql stable security definer set search_path=pg_catalog,public as $$
declare resultado jsonb;
begin
  if not public.frota_gestao_usuario_ativo() then raise exception using errcode='42501',message='Conta inativa ou não autenticada.';end if;
  if p_pagina is null or p_pagina<0 or length(coalesce(p_busca,''))>100 then raise exception 'Busca inválida.';end if;
  with notas as materialized(select n.*,v.id versao_id,v.numero_versao,v.estado,f.razao_social fornecedor from public.frota_gestao_notas n
    join lateral(select * from public.frota_gestao_nf_versoes where nota_id=n.id order by numero_versao desc limit 1)v on true
    join public.frota_gestao_fornecedores f on f.fornecedor_id=n.fornecedor_id
    where n.numero ilike '%'||coalesce(p_busca,'')||'%' or f.razao_social ilike '%'||coalesce(p_busca,'')||'%'),
  pagina as(select to_jsonb(n)||jsonb_build_object('emissoes',coalesce((select jsonb_agg(to_jsonb(h)-'dados' order by h.criado_em desc,h.id) from public.frota_gestao_hbf h
    join public.frota_gestao_nf_versoes v on v.id=h.versao_id where v.nota_id=n.id),'[]')) dados from notas n order by criado_em desc,id limit 25 offset p_pagina::bigint*25)
  select jsonb_build_object('total',(select count(*) from notas),'linhas',coalesce((select jsonb_agg(dados) from pagina),'[]')) into resultado;
  return resultado;
end $$;
revoke all on function public.frota_gestao_central_hbf(text,integer) from public,anon;
grant execute on function public.frota_gestao_central_hbf(text,integer) to authenticated;

create or replace function public.frota_gestao_preparacao_gerencial()
returns jsonb language plpgsql stable security definer set search_path=pg_catalog,public as $$
begin
  if not public.frota_gestao_usuario_ativo() then raise exception using errcode='42501',message='Conta inativa ou não autenticada.';end if;
  perform substituido_por_versao_id,hash_emissao from public.frota_gestao_hbf where false;
  return jsonb_build_object('contrato','05','disponivel',has_function_privilege('authenticated','public.frota_gestao_painel(jsonb,integer)','EXECUTE')
    and has_function_privilege('authenticated','public.frota_gestao_emitir_hbf(uuid,uuid,boolean)','EXECUTE')
    and has_function_privilege('authenticated','public.frota_gestao_consultar_hbf(uuid)','EXECUTE')
    and has_function_privilege('authenticated','public.frota_gestao_encaminhar_hbf(uuid,boolean)','EXECUTE')
    and has_function_privilege('authenticated','public.frota_gestao_central_hbf(text,integer)','EXECUTE')
    and has_function_privilege('authenticated','public.frota_gestao_opcoes_gerenciais()','EXECUTE'));
end $$;
revoke all on function public.frota_gestao_preparacao_gerencial() from public,anon;
grant execute on function public.frota_gestao_preparacao_gerencial() to authenticated;
