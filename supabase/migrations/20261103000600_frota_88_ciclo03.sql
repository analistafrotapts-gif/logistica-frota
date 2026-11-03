-- Origem: SQL 88 do módulo Gestão da Frota (extraído do laboratório, sem alterações de lógica).
-- CICLO 03. Execução MANUAL somente após 84 -> 85 -> 86 -> 87 conferidos.
-- Não instala jobs, não escreve em Gestran/cadastros antigos e não finaliza dados na instalação.
-- (begin/commit removidos: o Supabase CLI já executa cada migration em uma transação)
alter table public.frota_gestao_os add column if not exists periodo_inicio date;
alter table public.frota_gestao_os add column if not exists periodo_fim date;
alter table public.frota_gestao_os add column if not exists hash_abertura text;
alter table public.frota_gestao_os_itens add column if not exists previsao_informada boolean not null default true;
alter table public.frota_gestao_operacoes add column if not exists rascunho_id uuid references public.frota_gestao_rascunhos(id);
create unique index if not exists frota_gestao_finalizacao_rascunho_unica on public.frota_gestao_operacoes(rascunho_id) where tipo='finalizar_nf';
do $$ begin
  if not exists(select 1 from pg_constraint where conrelid='public.frota_gestao_os'::regclass and conname='frota_gestao_os_periodo') then
    alter table public.frota_gestao_os add constraint frota_gestao_os_periodo
      check((periodo_inicio is null and periodo_fim is null) or (periodo_inicio is not null and periodo_fim is not null and periodo_fim>=periodo_inicio));
  end if;
end $$;
-- Impede duplicar a mesma identificação por caminho com chave e por caminho manual.
create unique index if not exists frota_gestao_identificacao_unica on public.frota_gestao_notas
  (fornecedor_id,ltrim(btrim(numero),'0'),ltrim(btrim(serie),'0'));
create unique index if not exists frota_gestao_rateio_unico on public.frota_gestao_vinculos
  (nf_item_id,(classificacao->>'rateio_indice')) where classificacao ? 'rateio_indice';

create or replace function public.frota_gestao_decimal_nf(p_valor text,p_casas integer)
returns numeric language plpgsql immutable set search_path=pg_catalog,public as $$
begin
  if p_valor is null or p_valor !~ ('^[0-9]{1,12}(\.[0-9]{1,'||p_casas||'})?$') then raise exception 'Quantidade ou valor fiscal inválido: use ponto e a precisão permitida.'; end if;
  return p_valor::numeric;
end $$;
revoke all on function public.frota_gestao_decimal_nf(text,integer) from public,anon,authenticated;

create or replace function public.frota_gestao_candidatas_nf(p_veiculo uuid,p_contexto jsonb,p_catalogo uuid,p_manutencao text)
returns jsonb language plpgsql stable security definer set search_path=pg_catalog,public as $$
begin
  return coalesce((select jsonb_agg(jsonb_build_object('item_id',c.id,'os_id',c.os_id,'numero',c.numero::text,'estado',c.estado,'pendente',c.pendente::text) order by c.numero,c.id)
    from (select i.id,i.os_id,o.numero,o.estado,i.quantidade_prevista-coalesce((select sum(v.quantidade*n.fator_conversao)
      from public.frota_gestao_vinculos v join public.frota_gestao_nf_itens n on n.id=v.nf_item_id
      join public.frota_gestao_nf_versoes f on f.id=n.versao_id where v.os_item_id=i.id and f.estado='finalizada'),0) as pendente
      from public.frota_gestao_os_itens i join public.frota_gestao_os o on o.id=i.os_id
      join public.operacoes op on op.id=o.operacao_id and op.ativa
      where o.veiculo_id=p_veiculo and o.estado in ('aberta','em_execucao','encerrada')
        and btrim(o.contexto_id)=btrim(p_contexto->>'contexto') and o.medidor=p_contexto->>'medidor' and o.periodo_inicio<=(p_contexto->>'fim')::date and o.periodo_fim>=(p_contexto->>'inicio')::date
        and i.catalogo_id=p_catalogo and i.tipo_manutencao=p_manutencao) c where c.pendente>0),'[]'::jsonb);
end $$;
revoke all on function public.frota_gestao_candidatas_nf(uuid,jsonb,uuid,text) from public,anon,authenticated;

create or replace function public.frota_gestao_conferir_nf(p_id uuid,p_revisao bigint)
returns jsonb language plpgsql security definer set search_path=pg_catalog,public as $$
declare r public.frota_gestao_rascunhos; d jsonb; plano jsonb; linha jsonb; cfg jsonb; parcela jsonb; contexto jsonb;
  fornecedor public.frota_gestao_fornecedores; catalogo public.frota_gestao_catalogo; veiculo public.veiculos;
  q numeric; fator numeric; bruto numeric; desconto numeric; acrescimo numeric; liquido numeric; preco numeric;
  soma numeric:=0; soma_q numeric; soma_v numeric; qp numeric; vp numeric; candidatas jsonb; escolhida jsonb;
  pendencias jsonb:='[]'; linhas jsonb:='[]'; rateios jsonb; indice integer; identidade text; numero_fiscal text; serie_fiscal text; chave text; emissao date;
begin
  if not public.frota_gestao_usuario_ativo() then raise exception using errcode='42501',message='Conta inativa ou não autenticada.'; end if;
  select * into r from public.frota_gestao_rascunhos where id=p_id;
  if not found or r.finalizado_em is not null or r.atualizado_em<clock_timestamp()-interval '7 days' then raise exception 'Rascunho ausente, expirado ou finalizado.'; end if;
  if p_revisao is null or r.revisao<>p_revisao then raise exception 'O rascunho mudou. Recarregue antes de conferir/finalizar.'; end if;
  d:=r.dados;plano:=d->'finalizacao';
  if d->>'formato'<>'1' or jsonb_typeof(plano) is distinct from 'object' or jsonb_typeof(d#>'{nota,itens}') is distinct from 'array'
    or jsonb_array_length(d#>'{nota,itens}') not between 1 and 1000 then raise exception 'Complete os dados e as destinações da conferência.'; end if;
  numero_fiscal:=btrim(d#>>'{nota,numero}');serie_fiscal:=btrim(d#>>'{nota,serie}');chave:=nullif(btrim(d#>>'{nota,chave}'),'');
  if numero_fiscal is null or numero_fiscal !~ '^[0-9]{1,12}$' or serie_fiscal is null or serie_fiscal !~ '^[0-9]{1,3}$' or (chave is not null and chave !~ '^[0-9]{44}$') then raise exception 'Confira número, série e chave fiscal.'; end if;
  if numero_fiscal::numeric=0 then raise exception 'Número fiscal deve ser positivo.';end if;
  if plano->>'emissao' is null or plano->>'emissao' !~ '^[0-9]{4}-[0-9]{2}-[0-9]{2}$' then raise exception 'Confirme a data de emissão.'; end if;
  emissao:=(plano->>'emissao')::date;
  if substring(d#>>'{nota,emissao}',1,10) is distinct from plano->>'emissao' then raise exception 'A data confirmada diverge do cabeçalho da nota.'; end if;
  select * into fornecedor from public.frota_gestao_fornecedores where fornecedor_id=(plano->>'fornecedor_id')::uuid;
  if not found or coalesce(d#>>'{nota,documento_fornecedor}','') !~ '^[0-9 ./-]+$' or fornecedor.documento is distinct from regexp_replace(d#>>'{nota,documento_fornecedor}','[^0-9]','','g') then raise exception 'Selecione um fornecedor cadastrado com CPF/CNPJ correspondente à nota.'; end if;
  if not exists(select 1 from public.operacoes where id=(d->>'unidadeFiscal')::uuid and ativa) then raise exception 'Selecione uma unidade fiscal ativa.'; end if;
  identidade:=coalesce(chave,fornecedor.documento||':'||ltrim(serie_fiscal,'0')||':'||ltrim(numero_fiscal,'0'));
  if exists(select 1 from public.frota_gestao_notas n where n.identidade_fiscal=identidade or n.chave_acesso=chave
    or (n.fornecedor_id=fornecedor.fornecedor_id and ltrim(btrim(n.numero),'0')=ltrim(numero_fiscal,'0') and ltrim(btrim(n.serie),'0')=ltrim(serie_fiscal,'0'))) then raise exception 'Nota fiscal já lançada. Não finalize uma duplicidade.'; end if;
  if nullif(d->>'referencia','') is not null and ((d->>'referencia') !~ '^https://[^[:space:]@]+$' or (d->>'referencia') ~* '(token|signature|expires|x-amz|x-goog|sig)=') then raise exception 'Use referência HTTPS permanente, sem credenciais ou assinatura temporária.'; end if;
  if exists(select 1 from jsonb_array_elements(d#>'{nota,itens}') i group by i->>'numero' having count(*)>1) then raise exception 'Linhas fiscais repetidas.'; end if;
  if (select count(*) from jsonb_object_keys(plano->'itens'))<>jsonb_array_length(d#>'{nota,itens}') then raise exception 'Classifique todas as linhas fiscais, sem itens adicionais.'; end if;
  for linha in select * from jsonb_array_elements(d#>'{nota,itens}') loop
    if coalesce(linha->>'numero','') !~ '^[1-9][0-9]{0,5}$' or nullif(btrim(linha->>'descricao'),'') is null then raise exception 'Item sem número/descrição.'; end if;
    cfg:=plano->'itens'->(linha->>'numero');
    select * into catalogo from public.frota_gestao_catalogo where id=(cfg->>'catalogo_id')::uuid and ativo;
    if not found then raise exception 'Selecione catálogo ativo para o item %.',linha->>'numero'; end if;
    if cfg->>'manutencao' is null or cfg->>'manutencao' not in ('preventiva','corretiva') then raise exception 'Confira o tipo de manutenção do item.'; end if;
    q:=public.frota_gestao_decimal_nf(linha->>'quantidade',6);fator:=public.frota_gestao_decimal_nf(cfg->>'fator',8);
    preco:=public.frota_gestao_decimal_nf(linha->>'unitario',10);bruto:=public.frota_gestao_decimal_nf(linha->>'bruto',2);
    desconto:=public.frota_gestao_decimal_nf(linha->>'desconto',2);acrescimo:=public.frota_gestao_decimal_nf(linha->>'acrescimo',2);liquido:=bruto-desconto+acrescimo;
    if q<=0 or fator<=0 or liquido<0 or nullif(btrim(linha->>'unidade'),'') is null or round(q*preco,2)<>bruto or trunc(q*fator,6)<>q*fator then raise exception 'Quantidade, unidade, fator, bruto ou líquido inconsistentes no item %.',linha->>'numero'; end if;
    if catalogo.natureza='servico' and (fator<>1 or upper(btrim(linha->>'unidade'))<>upper(catalogo.unidade_padrao)) then raise exception 'Serviços exigem unidade do catálogo e fator 1.'; end if;
    if catalogo.natureza='peca' and not exists(select 1 from public.frota_gestao_locais l join public.operacoes o on o.id=l.operacao_id where l.id=(cfg->>'local_id')::uuid and o.ativa) then raise exception 'Informe local físico ativo para a entrada integral da peça.'; end if;
    if jsonb_typeof(cfg->'rateios') is distinct from 'array' or jsonb_array_length(cfg->'rateios') not between 1 and 100 then raise exception 'Informe de 1 a 100 destinos para cada linha.'; end if;
    soma_q:=0;soma_v:=0;rateios:='[]';indice:=0;
    for parcela in select * from jsonb_array_elements(cfg->'rateios') loop
      qp:=public.frota_gestao_decimal_nf(parcela->>'quantidade',6);vp:=public.frota_gestao_decimal_nf(parcela->>'valor',2);
      if qp<=0 or trunc(qp*fator,6)<>qp*fator then raise exception 'Quantidade inválida no rateio.'; end if;
      soma_q:=soma_q+qp;soma_v:=soma_v+vp;candidatas:='[]';escolhida:=null;
      if not exists(select 1 from public.operacoes where id=(parcela->>'unidade_id')::uuid and ativa)
        or not exists(select 1 from public.frota_centros_custo where codigo=parcela->>'centro_custo')
        or not exists(select 1 from public.frota_gestao_contas where id=(parcela->>'conta_id')::uuid and ativa)
        or not exists(select 1 from public.frota_gestao_categorias where id=(parcela->>'categoria_id')::uuid and ativa) then raise exception 'Confira unidade de custo, centro, conta e categoria do rateio.'; end if;
      if parcela->>'destino'='veiculo' then
        select * into veiculo from public.veiculos where id=(parcela->>'veiculo_id')::uuid;
        if not found or regexp_replace(upper(veiculo.placa),'[^A-Z0-9]','','g') is distinct from regexp_replace(upper(parcela->>'placa'),'[^A-Z0-9]','','g') then raise exception 'Confira a placa e o cadastro do veículo.'; end if;
        contexto:=plano->'veiculos'->veiculo.id::text;
        if nullif(btrim(contexto->>'contexto'),'') is null or length(contexto->>'contexto')>200 or contexto->>'medidor' not in ('km','horimetro') or contexto->>'medidor' is null
          or coalesce(contexto->>'inicio','') !~ '^[0-9]{4}-[0-9]{2}-[0-9]{2}$' or coalesce(contexto->>'fim','') !~ '^[0-9]{4}-[0-9]{2}-[0-9]{2}$' or (contexto->>'fim')::date<(contexto->>'inicio')::date then raise exception 'Confira contexto, período e medidor do veículo.'; end if;
        if catalogo.natureza='servico' and ((parcela->>'executado_em') is null or parcela->>'executado_em'='' or (parcela->>'executado_em')::date not between (contexto->>'inicio')::date and (contexto->>'fim')::date or (parcela->>'executado_em')::date>current_date) then raise exception 'Informe a data real de execução dentro do período conferido.'; end if;
        candidatas:=public.frota_gestao_candidatas_nf(veiculo.id,contexto,catalogo.id,cfg->>'manutencao');
        if nullif(parcela->>'os_item_id','') is null and jsonb_array_length(candidatas)=0 and not exists(select 1 from public.operacoes where id=veiculo.operacao_id and ativa) then raise exception 'Nova OS exige unidade operacional atual e ativa no cadastro do veículo.';end if;
        if nullif(parcela->>'os_item_id','') is not null then
          select c into escolhida from jsonb_array_elements(candidatas) c where c->>'item_id'=parcela->>'os_item_id';
          if escolhida is null or (escolhida->>'pendente')::numeric<qp*fator then pendencias:=pendencias||jsonb_build_array('Item '||(linha->>'numero')||': OS incompatível ou faturamento pendente insuficiente.');
          elsif catalogo.natureza='servico' and not exists(select 1 from public.frota_gestao_os where id=(escolhida->>'os_id')::uuid and (parcela->>'executado_em')::date between periodo_inicio and periodo_fim) then pendencias:=pendencias||jsonb_build_array('Data do serviço fora do período da OS selecionada.');end if;
        elsif jsonb_array_length(candidatas)>0 then pendencias:=pendencias||jsonb_build_array('Item '||(linha->>'numero')||': confira as OS existentes antes de criar outra; divida faturamentos parciais se necessário.');end if;
        if nullif(parcela->>'os_item_id','') is null and exists(select 1 from public.frota_gestao_os o join public.frota_gestao_os_itens oi on oi.os_id=o.id
          where o.veiculo_id=veiculo.id and o.estado in ('aberta','em_execucao','encerrada') and oi.catalogo_id=catalogo.id
            and (nullif(btrim(o.contexto_id),'') is null or o.periodo_inicio is null or o.periodo_fim is null or (btrim(o.contexto_id)=btrim(contexto->>'contexto') and o.medidor<>contexto->>'medidor'))
            and oi.quantidade_prevista>coalesce((select sum(v.quantidade*ni.fator_conversao) from public.frota_gestao_vinculos v join public.frota_gestao_nf_itens ni on ni.id=v.nf_item_id
              join public.frota_gestao_nf_versoes nv on nv.id=ni.versao_id where v.os_item_id=oi.id and nv.estado='finalizada'),0)) then
          pendencias:=pendencias||jsonb_build_array('Existem OS com pendência e contexto/período ou medidor não verificável. Regularize a conferência antes de propor outra OS.');end if;
      elsif (catalogo.natureza='peca' and parcela->>'destino'='estoque') or (catalogo.natureza='servico' and parcela->>'destino'='pendente') then
        if nullif(parcela->>'veiculo_id','') is not null or nullif(parcela->>'placa','') is not null or nullif(parcela->>'os_item_id','') is not null then raise exception 'Destino sem veículo não pode identificar OS ou placa.'; end if;
      else raise exception 'Destino incompatível com peça/serviço.'; end if;
      rateios:=rateios||jsonb_build_array(jsonb_build_object('indice',indice,'destino',parcela->>'destino','veiculo',coalesce(parcela->>'placa',''),'valor',vp::text,
        'quantidade',qp::text,'centro_custo',parcela->>'centro_custo','conta',(select nome from public.frota_gestao_contas where id=(parcela->>'conta_id')::uuid),
        'categoria',(select nome from public.frota_gestao_categorias where id=(parcela->>'categoria_id')::uuid),'unidade_custo',(select nome from public.operacoes where id=(parcela->>'unidade_id')::uuid),'executado_em',coalesce(parcela->>'executado_em',''),
        'os_item_id',coalesce(parcela->>'os_item_id',''),'acao',case when parcela->>'destino'<>'veiculo' then 'sem_os' when nullif(parcela->>'os_item_id','') is null then 'criar' else 'vincular' end,'candidatas',candidatas));indice:=indice+1;
    end loop;
    if soma_q<>q or soma_v<>liquido then raise exception 'Rateio do item % não concilia quantidade e centavos do líquido.',linha->>'numero';end if;
    soma:=soma+liquido;linhas:=linhas||jsonb_build_array(jsonb_build_object('numero',linha->>'numero','natureza',catalogo.natureza,'liquido',liquido::text,'rateios',rateios));
  end loop;
  if soma<>public.frota_gestao_decimal_nf(d#>>'{nota,total}',2) then raise exception 'Itens, descontos e acréscimos não conciliam com o total da nota. Distribua os ajustes gerais explicitamente.';end if;
  return jsonb_build_object('contrato','03','rascunho_id',r.id,'revisao',r.revisao::text,'total',soma::text,'fornecedor',fornecedor.razao_social,'linhas',linhas,'pendencias',pendencias);
end $$;
revoke all on function public.frota_gestao_conferir_nf(uuid,bigint) from public,anon;
grant execute on function public.frota_gestao_conferir_nf(uuid,bigint) to authenticated;

create or replace function public.frota_gestao_finalizar_nf(p_id uuid,p_revisao bigint,p_chave uuid,p_confirmado boolean)
returns jsonb language plpgsql security definer set search_path=pg_catalog,public as $$
declare r public.frota_gestao_rascunhos; operacao public.frota_gestao_operacoes; resumo jsonb; plano jsonb; linha jsonb; cfg jsonb; parcela jsonb; contexto jsonb; candidato jsonb;
  assinatura text; nota uuid:=gen_random_uuid();versao uuid:=gen_random_uuid();item_id uuid;lote_id uuid;vinculo uuid;os_id uuid;os_item uuid;
  criadas jsonb:='{}';itens_criados jsonb:='{}';ordens jsonb:='[]';resultado_final jsonb;identidade text;veiculo uuid;unidade_os uuid;catalogo public.frota_gestao_catalogo;
  numero_os bigint;qp numeric;vp numeric;liquido numeric;q numeric;fator numeric;indice integer;chave_item text; finalizada timestamptz;originais jsonb;descricao_origem text;
begin
  perform public.frota_gestao_exigir_escrita(false);
  if not public.frota_gestao_usuario_ativo() then raise exception using errcode='42501',message='Conta inativa ou não autenticada.';end if;
  if p_id is null or p_revisao is null or p_chave is null or p_confirmado is distinct from true then raise exception 'A confirmação explícita e a chave da solicitação são obrigatórias.';end if;
  assinatura:=encode(sha256(convert_to(jsonb_build_object('contrato','03','rascunho',p_id,'revisao',p_revisao)::text,'UTF8')),'hex');
  perform pg_advisory_xact_lock(hashtextextended('nf-operacao:'||p_chave::text,0));
  select * into operacao from public.frota_gestao_operacoes where id=p_chave;
  if found then
    if operacao.tipo<>'finalizar_nf' or operacao.hash_entrada<>assinatura then raise exception 'Chave idempotente reutilizada com conteúdo diferente.';end if;
    return operacao.resultado;
  end if;
  if not (public.frota_gestao_preparacao_rascunhos()->>'expiracao_agendada')::boolean then raise exception 'Banco/agendamento de rascunhos não preparado.';end if;
  r:=public.frota_gestao_travar_rascunho(p_id,p_revisao);
  if r.atualizado_em<clock_timestamp()-interval '7 days' or r.dados->'conferido' is distinct from 'true'::jsonb then raise exception 'Rascunho expirado ou conferência não confirmada.';end if;
  plano:=r.dados->'finalizacao';
  perform 1 from public.frota_gestao_fornecedores f where f.fornecedor_id=(plano->>'fornecedor_id')::uuid for share;
  perform 1 from public.frota_gestao_catalogo c where c.id in(select (i.value->>'catalogo_id')::uuid from jsonb_each(plano->'itens') i) order by c.id for share;
  -- Ordem única para todas as NFs dos mesmos veículos; outras transações futuras devem seguir este protocolo.
  for veiculo in select distinct (p->>'veiculo_id')::uuid from jsonb_each(plano->'itens') i
    cross join lateral jsonb_array_elements(i.value->'rateios') p where p->>'destino'='veiculo' order by 1 loop
    perform pg_advisory_xact_lock(hashtextextended('nf-veiculo:'||veiculo::text,0));
    perform 1 from public.veiculos v where v.id=veiculo for share;
    perform 1 from public.frota_gestao_os where veiculo_id=veiculo order by id for update;
    perform 1 from public.frota_gestao_os_itens i where i.os_id in(select o.id from public.frota_gestao_os o where o.veiculo_id=veiculo) order by i.id for update;
  end loop;
  resumo:=public.frota_gestao_conferir_nf(p_id,p_revisao);
  if jsonb_array_length(resumo->'pendencias')>0 then raise exception '%',resumo->'pendencias';end if;
  identidade:=coalesce(nullif(btrim(r.dados#>>'{nota,chave}'),''),(select documento from public.frota_gestao_fornecedores where fornecedor_id=(plano->>'fornecedor_id')::uuid)||':'||ltrim(btrim(r.dados#>>'{nota,serie}'),'0')||':'||ltrim(btrim(r.dados#>>'{nota,numero}'),'0'));
  insert into public.frota_gestao_notas(id,identidade_fiscal,fornecedor_id,numero,serie,chave_acesso,unidade_fiscal_id)
    values(nota,identidade,(plano->>'fornecedor_id')::uuid,btrim(r.dados#>>'{nota,numero}'),btrim(r.dados#>>'{nota,serie}'),nullif(btrim(r.dados#>>'{nota,chave}'),''),(r.dados->>'unidadeFiscal')::uuid);
  insert into public.frota_gestao_nf_versoes(id,nota_id,rascunho_id,numero_versao,estado,emissao,total,dados_fiscais,motivo)
    values(versao,nota,p_id,1,'finalizada',(plano->>'emissao')::date,(resumo->>'total')::numeric,r.dados,'Lançamento inicial conferido');
  insert into public.frota_gestao_operacoes(id,tipo,hash_entrada,resultado,rascunho_id) values(p_chave,'finalizar_nf',assinatura,'{}',p_id);
  for linha in select * from jsonb_array_elements(r.dados#>'{nota,itens}') loop
    cfg:=plano->'itens'->(linha->>'numero');select * into catalogo from public.frota_gestao_catalogo where id=(cfg->>'catalogo_id')::uuid;
    originais:=r.dados#>'{nota,dados_fiscais,nota,det}';
    select e#>>'{prod,xProd}' into descricao_origem from jsonb_array_elements(case when jsonb_typeof(originais)='array' then originais else jsonb_build_array(originais) end) e where e->>'@nItem'=linha->>'numero';
    q:=(linha->>'quantidade')::numeric;fator:=(cfg->>'fator')::numeric;liquido:=(linha->>'bruto')::numeric-(linha->>'desconto')::numeric+(linha->>'acrescimo')::numeric;item_id:=gen_random_uuid();
    insert into public.frota_gestao_nf_itens(id,versao_id,numero_item,codigo_original,descricao_original,descricao_conferida,catalogo_id,natureza,quantidade_compra,unidade_compra,fator_conversao,valor_unitario,bruto,desconto,acrescimo,liquido)
      values(item_id,versao,(linha->>'numero')::integer,coalesce(linha->>'codigo',''),coalesce(descricao_origem,linha->>'descricao'),linha->>'descricao',catalogo.id,catalogo.natureza,q,linha->>'unidade',fator,(linha->>'unitario')::numeric,(linha->>'bruto')::numeric,(linha->>'desconto')::numeric,(linha->>'acrescimo')::numeric,liquido);
    if catalogo.natureza='peca' then
      lote_id:=gen_random_uuid();insert into public.frota_gestao_lotes(id,nf_item_id,catalogo_id,quantidade_origem,custo_total,adquirido_em) values(lote_id,item_id,catalogo.id,q*fator,liquido,(plano->>'emissao')::date);
      insert into public.frota_gestao_movimentos(lote_id,local_id,tipo,quantidade,valor,operacao_atomica,motivo)
        values(lote_id,(cfg->>'local_id')::uuid,'entrada_nf',q*fator,liquido,p_chave,'Aquisição por NF finalizada');
    end if;
    indice:=0;
    for parcela in select * from jsonb_array_elements(cfg->'rateios') loop
      qp:=(parcela->>'quantidade')::numeric;vp:=(parcela->>'valor')::numeric;os_id:=null;os_item:=null;veiculo:=null;
      if parcela->>'destino'='veiculo' then
        veiculo:=(parcela->>'veiculo_id')::uuid;contexto:=plano->'veiculos'->veiculo::text;
        if nullif(parcela->>'os_item_id','') is not null then
          select c into candidato from jsonb_array_elements(public.frota_gestao_candidatas_nf(veiculo,contexto,catalogo.id,cfg->>'manutencao')) c where c->>'item_id'=parcela->>'os_item_id';
          if candidato is null or (candidato->>'pendente')::numeric<qp*fator then raise exception 'Pendência da OS insuficiente após os rateios anteriores. Reveja a distribuição.';end if;
          os_id:=(candidato->>'os_id')::uuid;os_item:=(parcela->>'os_item_id')::uuid;
        else
          os_id:=(criadas->>veiculo::text)::uuid;
          if os_id is null then
            os_id:=gen_random_uuid();select operacao_id into unidade_os from public.veiculos where id=veiculo;
            insert into public.frota_gestao_os(id,veiculo_id,operacao_id,origem,nota_origem_id,chave_criacao,descricao,medidor,contexto_id,periodo_inicio,periodo_fim)
              values(os_id,veiculo,unidade_os,'nota',nota,gen_random_uuid(),'OS originada da NF '||(r.dados#>>'{nota,numero}'),contexto->>'medidor',btrim(contexto->>'contexto'),(contexto->>'inicio')::date,(contexto->>'fim')::date) returning numero into numero_os;
            criadas:=criadas||jsonb_build_object(veiculo::text,os_id);ordens:=ordens||jsonb_build_array(jsonb_build_object('id',os_id,'numero',numero_os::text));
          end if;
          chave_item:=(linha->>'numero')||':'||veiculo::text;os_item:=(itens_criados->>chave_item)::uuid;
          if os_item is null then
            os_item:=gen_random_uuid();insert into public.frota_gestao_os_itens(id,os_id,catalogo_id,descricao,tipo_manutencao,quantidade_prevista,valor_previsto,previsao_informada,executado_em)
              values(os_item,os_id,catalogo.id,linha->>'descricao',cfg->>'manutencao',qp*fator,0,false,case when catalogo.natureza='servico' then nullif(parcela->>'executado_em','')::date else null end);
            itens_criados:=itens_criados||jsonb_build_object(chave_item,os_item);
          else update public.frota_gestao_os_itens set quantidade_prevista=quantidade_prevista+qp*fator where id=os_item;end if;
        end if;
      end if;
      vinculo:=gen_random_uuid();insert into public.frota_gestao_vinculos(id,nf_item_id,os_id,os_item_id,veiculo_id,unidade_custo_id,quantidade,valor_documentado,centro_custo,conta_id,categoria_id,classificacao)
        values(vinculo,item_id,os_id,os_item,veiculo,(parcela->>'unidade_id')::uuid,qp,vp,parcela->>'centro_custo',(parcela->>'conta_id')::uuid,(parcela->>'categoria_id')::uuid,jsonb_build_object('destino',parcela->>'destino','rateio_indice',indice));
      if catalogo.natureza='servico' and veiculo is not null then
        insert into public.frota_gestao_custos(veiculo_id,unidade_custo_id,vinculo_id,origem,valor,executado_em) values(veiculo,(parcela->>'unidade_id')::uuid,vinculo,'servico',vp,(parcela->>'executado_em')::date);
      end if;
      indice:=indice+1;
    end loop;
  end loop;
  if nullif(r.dados->>'referencia','') is not null then insert into public.frota_gestao_referencias(versao_id,url,descricao) values(versao,r.dados->>'referencia','Documento externo conferido');end if;
  finalizada:=clock_timestamp();update public.frota_gestao_rascunhos set finalizado_em=finalizada where id=p_id;
  resultado_final:=jsonb_build_object('nota_id',nota,'versao_id',versao,'operacao_id',p_chave,'ordens',ordens,'finalizada_em',finalizada,
    'rascunho_id',p_id,'numero_nf',r.dados#>>'{nota,numero}','total',resumo->>'total','fornecedor',resumo->>'fornecedor','autor_id',auth.uid());
  update public.frota_gestao_operacoes set resultado=resultado_final where id=p_chave;
  return resultado_final;
end $$;
revoke all on function public.frota_gestao_finalizar_nf(uuid,bigint,uuid,boolean) from public,anon;
grant execute on function public.frota_gestao_finalizar_nf(uuid,bigint,uuid,boolean) to authenticated;

create or replace function public.frota_gestao_recibo_nf(p_id uuid)
returns jsonb language plpgsql stable security definer set search_path=pg_catalog,public as $$
begin
  if not public.frota_gestao_usuario_ativo() then raise exception using errcode='42501',message='Conta inativa ou não autenticada.';end if;
  return (select resultado||jsonb_build_object('autor_id',criado_por,'registrado_em',criado_em) from public.frota_gestao_operacoes where rascunho_id=p_id and tipo='finalizar_nf');
end $$;
revoke all on function public.frota_gestao_recibo_nf(uuid) from public,anon;
grant execute on function public.frota_gestao_recibo_nf(uuid) to authenticated;

create or replace function public.frota_gestao_cadastros_nf()
returns jsonb language plpgsql stable security definer set search_path=pg_catalog,public as $$
begin
  if not public.frota_gestao_usuario_ativo() then raise exception using errcode='42501',message='Conta inativa ou não autenticada.';end if;
  return jsonb_build_object('fornecedores',coalesce((select jsonb_agg(jsonb_build_object('id',fornecedor_id,'nome',razao_social,'documento',documento) order by razao_social) from public.frota_gestao_fornecedores),'[]'::jsonb),
    'catalogo',coalesce((select jsonb_agg(jsonb_build_object('id',id,'nome',descricao,'natureza',natureza,'unidade',unidade_padrao) order by descricao) from public.frota_gestao_catalogo where ativo),'[]'::jsonb),
    'contas',coalesce((select jsonb_agg(jsonb_build_object('id',id,'nome',nome) order by nome) from public.frota_gestao_contas where ativa),'[]'::jsonb),
    'categorias',coalesce((select jsonb_agg(jsonb_build_object('id',id,'nome',nome) order by nome) from public.frota_gestao_categorias where ativa),'[]'::jsonb),
    'centros',coalesce((select jsonb_agg(jsonb_build_object('id',codigo,'nome',nome) order by codigo) from public.frota_centros_custo),'[]'::jsonb),
    'locais',coalesce((select jsonb_agg(jsonb_build_object('id',l.id,'nome',l.nome||' · '||o.nome) order by o.nome,l.nome) from public.frota_gestao_locais l join public.operacoes o on o.id=l.operacao_id where o.ativa),'[]'::jsonb));
end $$;
revoke all on function public.frota_gestao_cadastros_nf() from public,anon;
grant execute on function public.frota_gestao_cadastros_nf() to authenticated;

create or replace function public.frota_gestao_abrir_os(p_chave uuid,p_dados jsonb)
returns jsonb language plpgsql security definer set search_path=pg_catalog,public as $$
declare existente public.frota_gestao_os;veiculo public.veiculos;assinatura text;ordem uuid:=gen_random_uuid();numero_os bigint;item jsonb;q numeric;valor numeric;
begin
  perform public.frota_gestao_exigir_escrita(false);
  if not public.frota_gestao_usuario_ativo() then raise exception using errcode='42501',message='Conta inativa ou não autenticada.';end if;
  if p_chave is null or p_dados is null or jsonb_typeof(p_dados)<>'object' or octet_length(p_dados::text)>1048576 then raise exception 'Dados de abertura inválidos.';end if;
  assinatura:=encode(sha256(convert_to(p_dados::text,'UTF8')),'hex');
  perform pg_advisory_xact_lock(hashtextextended('os-abertura:'||p_chave::text,0));
  select * into existente from public.frota_gestao_os where chave_criacao=p_chave;
  if found then
    if existente.hash_abertura is distinct from assinatura then raise exception 'Chave de abertura reutilizada com dados diferentes.';end if;
    return jsonb_build_object('id',existente.id,'numero',existente.numero::text);
  end if;
  perform pg_advisory_xact_lock(hashtextextended('nf-veiculo:'||(p_dados->>'veiculo_id'),0));
  select * into veiculo from public.veiculos where id=(p_dados->>'veiculo_id')::uuid for share;
  if not found or veiculo.placa is distinct from p_dados->>'placa' or not exists(select 1 from public.operacoes where id=veiculo.operacao_id and ativa) then raise exception 'Confira veículo, placa e unidade operacional.';end if;
  if nullif(btrim(p_dados->>'contexto'),'') is null or length(p_dados->>'contexto')>200 or nullif(btrim(p_dados->>'descricao'),'') is null
    or p_dados->>'medidor' is null or p_dados->>'medidor' not in ('km','horimetro') or coalesce(p_dados->>'inicio','') !~ '^[0-9]{4}-[0-9]{2}-[0-9]{2}$' or coalesce(p_dados->>'fim','') !~ '^[0-9]{4}-[0-9]{2}-[0-9]{2}$'
    or (p_dados->>'fim')::date<(p_dados->>'inicio')::date or jsonb_typeof(p_dados->'itens') is distinct from 'array' or jsonb_array_length(p_dados->'itens') not between 1 and 100 then raise exception 'Confira contexto, descrição, período, medidor e itens da OS.';end if;
  insert into public.frota_gestao_os(id,veiculo_id,operacao_id,origem,chave_criacao,descricao,medidor,contexto_id,periodo_inicio,periodo_fim,hash_abertura)
    values(ordem,veiculo.id,veiculo.operacao_id,'manual',p_chave,p_dados->>'descricao',p_dados->>'medidor',btrim(p_dados->>'contexto'),(p_dados->>'inicio')::date,(p_dados->>'fim')::date,assinatura) returning numero into numero_os;
  for item in select * from jsonb_array_elements(p_dados->'itens') loop
    if not exists(select 1 from public.frota_gestao_catalogo where id=(item->>'catalogo_id')::uuid and ativo) or item->>'manutencao' is null or item->>'manutencao' not in ('preventiva','corretiva') then raise exception 'Confira catálogo e manutenção dos itens da OS.';end if;
    q:=public.frota_gestao_decimal_nf(item->>'quantidade',6);if q<=0 then raise exception 'Quantidade prevista deve ser positiva.';end if;
    valor:=case when nullif(item->>'valor','') is null then 0 else public.frota_gestao_decimal_nf(item->>'valor',2) end;
    insert into public.frota_gestao_os_itens(os_id,catalogo_id,descricao,tipo_manutencao,quantidade_prevista,valor_previsto,previsao_informada)
      values(ordem,(item->>'catalogo_id')::uuid,(select descricao from public.frota_gestao_catalogo where id=(item->>'catalogo_id')::uuid),item->>'manutencao',q,valor,nullif(item->>'valor','') is not null);
  end loop;
  return jsonb_build_object('id',ordem,'numero',numero_os::text);
end $$;
revoke all on function public.frota_gestao_abrir_os(uuid,jsonb) from public,anon;
grant execute on function public.frota_gestao_abrir_os(uuid,jsonb) to authenticated;

create or replace function public.frota_gestao_preparacao_nf()
returns jsonb language plpgsql stable security definer set search_path=pg_catalog,public as $$
declare anterior jsonb;
begin
  anterior:=public.frota_gestao_preparacao_rascunhos();
  perform periodo_inicio,periodo_fim,hash_abertura from public.frota_gestao_os where false;
  perform previsao_informada from public.frota_gestao_os_itens where false;
  perform rascunho_id from public.frota_gestao_operacoes where false;
  return jsonb_build_object('contrato','03','disponivel',anterior->>'contrato'='02' and (anterior->>'funcoes_disponiveis')::boolean and (anterior->>'expiracao_agendada')::boolean
    and has_function_privilege('authenticated','public.frota_gestao_finalizar_nf(uuid,bigint,uuid,boolean)','EXECUTE')
    and has_function_privilege('authenticated','public.frota_gestao_conferir_nf(uuid,bigint)','EXECUTE')
    and has_function_privilege('authenticated','public.frota_gestao_cadastros_nf()','EXECUTE')
    and has_function_privilege('authenticated','public.frota_gestao_recibo_nf(uuid)','EXECUTE')
    and has_function_privilege('authenticated','public.frota_gestao_abrir_os(uuid,jsonb)','EXECUTE'));
end $$;
revoke all on function public.frota_gestao_preparacao_nf() from public,anon;
grant execute on function public.frota_gestao_preparacao_nf() to authenticated;
