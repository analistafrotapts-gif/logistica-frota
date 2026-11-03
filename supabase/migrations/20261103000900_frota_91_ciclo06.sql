-- Origem: SQL 91 do módulo Gestão da Frota (extraído do laboratório, sem alterações de lógica).
-- CICLO 06. PREPARADO, NÃO EXECUTADO NO SUPABASE. Manualmente após 90 completo.
-- (begin/commit removidos: o Supabase CLI já executa cada migration em uma transação)
do $$ begin
  if to_regprocedure('public.frota_gestao_preparacao_gerencial()') is null then raise exception 'Confira 84 a 90 antes do 91.';end if;
end $$;
alter table public.frota_gestao_nf_itens add column if not exists origem_efeito_id uuid references public.frota_gestao_nf_itens(id);
alter table public.frota_gestao_nf_versoes add column if not exists tipo_cancelamento text;
alter table public.frota_gestao_nf_versoes add column if not exists referencia_cancelamento text;
alter table public.frota_gestao_custos add column if not exists operacao_corretiva_id uuid references public.frota_gestao_operacoes(id);
create unique index if not exists frota_gestao_compensacao_fiscal_unica on public.frota_gestao_custos(custo_estornado_id) where operacao_corretiva_id is not null;
create unique index if not exists frota_gestao_versao_sucessora_unica on public.frota_gestao_nf_versoes(anterior_id) where anterior_id is not null;
do $$ begin
  if not exists(select 1 from pg_constraint where conrelid='public.frota_gestao_nf_versoes'::regclass and conname='frota_gestao_cancelamento_comprovado') then
    alter table public.frota_gestao_nf_versoes add constraint frota_gestao_cancelamento_comprovado check(
      (estado='finalizada' and tipo_cancelamento is null and referencia_cancelamento is null) or
      (estado='cancelada' and tipo_cancelamento is not null and tipo_cancelamento in ('fiscal_comprovado','lancamento_interno') and
       (tipo_cancelamento='lancamento_interno' or nullif(btrim(referencia_cancelamento),'') is not null)));
  end if;
end $$;

create or replace function public.frota_gestao_candidatas_revisao(p_veiculo uuid,p_contexto jsonb,p_catalogo uuid,p_manutencao text,p_excluir uuid)
returns jsonb language plpgsql stable security definer set search_path=pg_catalog,public as $$
begin
  return coalesce((select jsonb_agg(jsonb_build_object('item_id',c.id,'os_id',c.os_id,'numero',c.numero::text,'estado',c.estado,'pendente',c.pendente::text) order by c.numero,c.id)
    from (select i.id,i.os_id,o.numero,o.estado,i.quantidade_prevista-coalesce((select sum(v.quantidade*n.fator_conversao)
      from public.frota_gestao_vinculos v join public.frota_gestao_nf_itens n on n.id=v.nf_item_id
      join public.frota_gestao_nf_versoes f on f.id=n.versao_id where v.os_item_id=i.id and f.estado='finalizada' and f.nota_id is distinct from p_excluir and not exists(select 1 from public.frota_gestao_nf_versoes nv where nv.nota_id=f.nota_id and nv.numero_versao>f.numero_versao)),0) as pendente
      from public.frota_gestao_os_itens i join public.frota_gestao_os o on o.id=i.os_id
      join public.operacoes op on op.id=o.operacao_id and op.ativa
      where o.veiculo_id=p_veiculo and o.estado in ('aberta','em_execucao','encerrada')
        and btrim(o.contexto_id)=btrim(p_contexto->>'contexto') and o.medidor=p_contexto->>'medidor' and o.periodo_inicio<=(p_contexto->>'fim')::date and o.periodo_fim>=(p_contexto->>'inicio')::date
        and i.catalogo_id=p_catalogo and i.tipo_manutencao=p_manutencao) c where c.pendente>0),'[]'::jsonb);
end $$;
revoke all on function public.frota_gestao_candidatas_revisao(uuid,jsonb,uuid,text,uuid) from public,anon,authenticated;
create or replace function public.frota_gestao_candidatas_nf(p_veiculo uuid,p_contexto jsonb,p_catalogo uuid,p_manutencao text)
returns jsonb language sql stable security definer set search_path=pg_catalog,public as $$
 select public.frota_gestao_candidatas_revisao(p_veiculo,p_contexto,p_catalogo,p_manutencao,null)
$$;
revoke all on function public.frota_gestao_candidatas_nf(uuid,jsonb,uuid,text) from public,anon,authenticated;

create or replace function public.frota_gestao_validar_correcao(p_nota uuid,p_dados jsonb)
returns jsonb language plpgsql security definer set search_path=pg_catalog,public as $$
declare r public.frota_gestao_rascunhos; d jsonb; plano jsonb; linha jsonb; cfg jsonb; parcela jsonb; contexto jsonb;
  fornecedor public.frota_gestao_fornecedores; catalogo public.frota_gestao_catalogo; veiculo public.veiculos;
  q numeric; fator numeric; bruto numeric; desconto numeric; acrescimo numeric; liquido numeric; preco numeric;
  soma numeric:=0; soma_q numeric; soma_v numeric; qp numeric; vp numeric; candidatas jsonb; escolhida jsonb;
  pendencias jsonb:='[]'; linhas jsonb:='[]'; rateios jsonb; indice integer; identidade text; numero_fiscal text; serie_fiscal text; chave text; emissao date;
begin
  if not public.frota_gestao_usuario_ativo() then raise exception using errcode='42501',message='Conta inativa ou não autenticada.'; end if;
  d:=p_dados;plano:=d->'finalizacao';
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
  if exists(select 1 from public.frota_gestao_notas n where n.id<>p_nota and (n.identidade_fiscal=identidade or n.chave_acesso=chave
    or (n.fornecedor_id=fornecedor.fornecedor_id and ltrim(btrim(n.numero),'0')=ltrim(numero_fiscal,'0') and ltrim(btrim(n.serie),'0')=ltrim(serie_fiscal,'0')))) then raise exception 'Nota fiscal já lançada. Não finalize uma duplicidade.'; end if;
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
        candidatas:=public.frota_gestao_candidatas_revisao(veiculo.id,contexto,catalogo.id,cfg->>'manutencao',p_nota);
        if nullif(parcela->>'os_item_id','') is null and jsonb_array_length(candidatas)=0 and not exists(select 1 from public.operacoes where id=veiculo.operacao_id and ativa) then raise exception 'Nova OS exige unidade operacional atual e ativa no cadastro do veículo.';end if;
        if nullif(parcela->>'os_item_id','') is not null then
          select c into escolhida from jsonb_array_elements(candidatas) c where c->>'item_id'=parcela->>'os_item_id';
          if escolhida is null or (escolhida->>'pendente')::numeric<qp*fator then pendencias:=pendencias||jsonb_build_array('Item '||(linha->>'numero')||': OS incompatível ou faturamento pendente insuficiente.');
          elsif catalogo.natureza='servico' and not exists(select 1 from public.frota_gestao_os where id=(escolhida->>'os_id')::uuid and (parcela->>'executado_em')::date between periodo_inicio and periodo_fim) then pendencias:=pendencias||jsonb_build_array('Data do serviço fora do período da OS selecionada.');end if;
        elsif jsonb_array_length(candidatas)>0 then pendencias:=pendencias||jsonb_build_array('Item '||(linha->>'numero')||': confira as OS existentes antes de criar outra; divida faturamentos parciais se necessário.');end if;
        if nullif(parcela->>'os_item_id','') is null and jsonb_array_length(candidatas)=0 and exists(select 1 from public.frota_gestao_os o
          where o.nota_origem_id=p_nota and o.veiculo_id=veiculo.id and o.origem='nota') then
          pendencias:=pendencias||jsonb_build_array('Item '||(linha->>'numero')||': já existe OS automática deste veículo/NF sem item compatível. Abra OS antecipada adequada e selecione seu item; a correção não altera o escopo operacional da OS anterior.');
        end if;
        if nullif(parcela->>'os_item_id','') is null and exists(select 1 from public.frota_gestao_os o join public.frota_gestao_os_itens oi on oi.os_id=o.id
          where o.veiculo_id=veiculo.id and o.estado in ('aberta','em_execucao','encerrada') and oi.catalogo_id=catalogo.id
            and (nullif(btrim(o.contexto_id),'') is null or o.periodo_inicio is null or o.periodo_fim is null or (btrim(o.contexto_id)=btrim(contexto->>'contexto') and o.medidor<>contexto->>'medidor'))
            and oi.quantidade_prevista>coalesce((select sum(v.quantidade*ni.fator_conversao) from public.frota_gestao_vinculos v join public.frota_gestao_nf_itens ni on ni.id=v.nf_item_id
              join public.frota_gestao_nf_versoes nv on nv.id=ni.versao_id where v.os_item_id=oi.id and nv.estado='finalizada' and nv.nota_id<>p_nota and not exists(select 1 from public.frota_gestao_nf_versoes ult where ult.nota_id=nv.nota_id and ult.numero_versao>nv.numero_versao)),0)) then
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
  return jsonb_build_object('contrato','06','total',soma::text,'fornecedor',fornecedor.razao_social,'linhas',linhas,'pendencias',pendencias);
end $$;
revoke all on function public.frota_gestao_validar_correcao(uuid,jsonb) from public,anon,authenticated;

-- Reconstrói as escolhas de OS efetivamente confirmadas, inclusive OS automáticas.
create or replace function public.frota_gestao_dados_versao(p_versao uuid)
returns jsonb language plpgsql stable security definer set search_path=pg_catalog,public as $$
declare d jsonb;itens jsonb;
begin
 select dados_fiscais into d from public.frota_gestao_nf_versoes where id=p_versao;
 select coalesce(jsonb_object_agg(i.numero_item::text,cfg.dados||jsonb_build_object('rateios',
  (select coalesce(jsonb_agg(p.value||jsonb_build_object('os_item_id',coalesce(v.os_item_id::text,'')) order by p.ordinality),'[]')
   from jsonb_array_elements(cfg.dados->'rateios') with ordinality p(value,ordinality)
   left join public.frota_gestao_vinculos v on v.nf_item_id=i.id and v.classificacao->>'rateio_indice'=(p.ordinality-1)::text))),'{}') into itens
 from public.frota_gestao_nf_itens i cross join lateral(select d#>array['finalizacao','itens',i.numero_item::text] dados) cfg where i.versao_id=p_versao;
 return jsonb_set(d,'{finalizacao,itens}',itens);
end $$;
revoke all on function public.frota_gestao_dados_versao(uuid) from public,anon,authenticated;

create or replace function public.frota_gestao_assinatura_item(p_dados jsonb,p_numero text)
returns jsonb language sql immutable set search_path=pg_catalog,public as $$
 select jsonb_build_object('cfg',(p_dados#>array['finalizacao','itens',p_numero])-'fator'-'rateios'||jsonb_build_object(
  'fator',(p_dados#>>array['finalizacao','itens',p_numero,'fator'])::numeric,
  'rateios',(select jsonb_agg(r.value-'quantidade'-'valor'||jsonb_build_object('quantidade',(r.value->>'quantidade')::numeric,'valor',(r.value->>'valor')::numeric) order by r.ordinality)
    from jsonb_array_elements(p_dados#>array['finalizacao','itens',p_numero,'rateios']) with ordinality r(value,ordinality))),
  'quantidade',(i->>'quantidade')::numeric,'unidade',upper(btrim(i->>'unidade')),'liquido',(i->>'bruto')::numeric-(i->>'desconto')::numeric+(i->>'acrescimo')::numeric,
  'contextos',(select coalesce(jsonb_object_agg(v,p_dados#>array['finalizacao','veiculos',v]),'{}') from
    (select distinct r->>'veiculo_id' v from jsonb_array_elements(p_dados#>array['finalizacao','itens',p_numero,'rateios']) r where r->>'destino'='veiculo') veiculos))
 from jsonb_array_elements(p_dados#>'{nota,itens}') i where i->>'numero'=p_numero
$$;
revoke all on function public.frota_gestao_assinatura_item(jsonb,text) from public,anon,authenticated;

-- Recebe o snapshot reconstruído uma vez por operação, evitando reler todas as linhas por item.
create or replace function public.frota_gestao_manter_item(p_anterior jsonb,p_dados jsonb,p_numero text,p_natureza text)
returns boolean language sql immutable set search_path=pg_catalog,public as $$
 select coalesce(public.frota_gestao_assinatura_item(p_anterior,p_numero)=public.frota_gestao_assinatura_item(p_dados,p_numero)
  and (p_natureza='servico' or (p_anterior#>>'{finalizacao,emissao}')::date=(p_dados#>>'{finalizacao,emissao}')::date),false)
$$;
revoke all on function public.frota_gestao_manter_item(jsonb,jsonb,text,text) from public,anon,authenticated;

create or replace function public.frota_gestao_conferir_revisao(p_versao uuid,p_tipo text,p_dados jsonb,p_referencia text)
returns jsonb language plpgsql security definer set search_path=pg_catalog,public as $$
declare v public.frota_gestao_nf_versoes; n public.frota_gestao_notas; i record; lote public.frota_gestao_lotes;
 resumo jsonb:='{}';bloqueios jsonb:='[]';impactos jsonb:='[]';manter boolean; item_origem uuid; saldo record; reserva numeric; movimentos bigint;
 valor numeric;saida numeric;encaminhado boolean; assinatura text; dados_atuais jsonb;
 novos_efeitos jsonb:='[]';linha_nova jsonb;cfg_nova jsonb;natureza_nova text;
begin
 if not public.frota_gestao_usuario_ativo() then raise exception using errcode='42501',message='Conta inativa ou não autenticada.';end if;
 if p_tipo is null or p_tipo not in ('corrigir','fiscal_comprovado','lancamento_interno') then raise exception 'Selecione correção ou o tipo de cancelamento.';end if;
 select * into v from public.frota_gestao_nf_versoes where id=p_versao;
 if not found then raise exception 'Versão não encontrada.';end if;
 if v.estado<>'finalizada' or exists(select 1 from public.frota_gestao_nf_versoes where nota_id=v.nota_id and numero_versao>v.numero_versao) then raise exception 'A versão mudou ou foi cancelada. Recarregue a NF.';end if;
 select * into n from public.frota_gestao_notas where id=v.nota_id;
 dados_atuais:=public.frota_gestao_dados_versao(v.id);
 if p_tipo='corrigir' then
  if p_dados is null or jsonb_typeof(p_dados)<>'object' or p_dados->>'formato' is distinct from '1' or p_dados->'conferido' is distinct from 'true'::jsonb
    or octet_length(p_dados::text)>1048576 then raise exception 'Dados estruturados da correção inválidos, não conferidos ou maiores que 1 MiB.';end if;
  if p_dados#>'{nota,dados_fiscais}' is distinct from v.dados_fiscais#>'{nota,dados_fiscais}' then
    raise exception 'Os dados extraídos do documento original são preservados. Informe as correções nos campos conferidos e referencie o novo documento.';
  end if;
  if p_dados#>>'{nota,numero}' is distinct from v.dados_fiscais#>>'{nota,numero}' or p_dados#>>'{nota,serie}' is distinct from v.dados_fiscais#>>'{nota,serie}'
    or p_dados#>>'{nota,chave}' is distinct from v.dados_fiscais#>>'{nota,chave}' or p_dados#>>'{nota,documento_fornecedor}' is distinct from v.dados_fiscais#>>'{nota,documento_fornecedor}'
    or p_dados#>>'{finalizacao,fornecedor_id}' is distinct from n.fornecedor_id::text or p_dados->>'unidadeFiscal' is distinct from n.unidade_fiscal_id::text then
    raise exception 'Identidade fiscal e unidade fiscal são imutáveis; outro documento exige lançamento próprio.';
  end if;
  resumo:=public.frota_gestao_validar_correcao(n.id,p_dados);bloqueios:=coalesce(resumo->'pendencias','[]');
  if p_dados-'etapa'-'destinos'-'conferido'=dados_atuais-'etapa'-'destinos'-'conferido' then
    bloqueios:=bloqueios||jsonb_build_array('Não há alterações na proposta. Não crie outra versão para repetir o mesmo lançamento.');
  end if;
  if (p_dados#>'{nota,itens}' is distinct from dados_atuais#>'{nota,itens}' or p_dados#>>'{finalizacao,emissao}' is distinct from dados_atuais#>>'{finalizacao,emissao}')
    and nullif(btrim(p_dados->>'referencia'),'') is null then bloqueios:=bloqueios||jsonb_build_array('Correção de itens/dados fiscais exige referência HTTPS permanente ao documento conferido.');end if;
 else
  if p_dados is not null then raise exception 'Cancelamento não recebe dados corretivos.';end if;
 end if;
 if p_tipo='fiscal_comprovado' and (coalesce(p_referencia,'') !~ '^https://[^[:space:]@]+$' or p_referencia ~* '(token|signature|expires|x-amz|x-goog|sig)=') then
  bloqueios:=bloqueios||jsonb_build_array('Cancelamento fiscal exige link HTTPS permanente para comprovação. O portal não consulta nem declara autorização da SEFAZ.');
 end if;
 if length(coalesce(p_referencia,''))>2000 then raise exception 'Referência de cancelamento excede 2000 caracteres.';end if;
 for i in select * from public.frota_gestao_nf_itens where versao_id=v.id order by numero_item loop
  manter:=p_tipo='corrigir' and coalesce(public.frota_gestao_manter_item(dados_atuais,p_dados,i.numero_item::text,i.natureza),false);
  item_origem:=coalesce(i.origem_efeito_id,i.id);lote:=null;reserva:=0;movimentos:=0;valor:=0;saida:=0;
  if i.natureza='peca' then
   select * into lote from public.frota_gestao_lotes where nf_item_id=item_origem;
   if not found then bloqueios:=bloqueios||jsonb_build_array('Item '||i.numero_item||': lote de origem não verificável.');
   else
    select coalesce(sum(quantidade-aplicada-liberada),0) into reserva from public.frota_gestao_reservas where lote_id=lote.id;
    select count(*) into movimentos from public.frota_gestao_movimentos where lote_id=lote.id and tipo<>'entrada_nf';
    if not manter and (reserva>0 or movimentos>0 or exists(select 1 from public.frota_gestao_aplicacoes where lote_id=lote.id)) then
     bloqueios:=bloqueios||jsonb_build_array('Item '||i.numero_item||' / lote '||lote.id||': reservas pendentes='||reserva||'; movimentos posteriores='||movimentos||'. Aplicações, transferências, devoluções e ajustes exigem regularização; este ciclo não reverte essas cadeias automaticamente.');
    end if;
    if not manter then
     select * into saldo from public.frota_gestao_saldo_lote(lote.id,(select local_id from public.frota_gestao_movimentos where lote_id=lote.id and tipo='entrada_nf'));
     if saldo.fisico is distinct from lote.quantidade_origem or saldo.valor is distinct from lote.custo_total then bloqueios:=bloqueios||jsonb_build_array('Item '||i.numero_item||': saldo não coincide com a aquisição original.');end if;
     saida:=lote.custo_total;
    end if;
   end if;
  elsif not manter then
   select coalesce(sum(c.valor),0) into valor from public.frota_gestao_custos c join public.frota_gestao_vinculos f on f.id=c.vinculo_id where f.nf_item_id=item_origem and c.origem='servico';
   if exists(select 1 from public.frota_gestao_custos c join public.frota_gestao_vinculos f on f.id=c.vinculo_id where f.nf_item_id=item_origem and exists(select 1 from public.frota_gestao_custos e where e.custo_estornado_id=c.id)) then
    bloqueios:=bloqueios||jsonb_build_array('Item '||i.numero_item||': custo jé compensado; origem requer conferência.');
   end if;
  end if;
  impactos:=impactos||jsonb_build_array(jsonb_build_object('item',i.numero_item,'natureza',i.natureza,'acao',case when manter then 'preservar efeitos' else 'compensar efeitos anteriores' end,
    'lote_id',lote.id,'reservado',reserva::text,'movimentos_posteriores',movimentos,'estorno_servicos',valor::text,'saida_estoque',saida::text));
 end loop;
 if p_tipo='corrigir' then
  for linha_nova in select * from jsonb_array_elements(p_dados#>'{nota,itens}') loop
   cfg_nova:=p_dados#>array['finalizacao','itens',linha_nova->>'numero'];
   select natureza into natureza_nova from public.frota_gestao_catalogo where id=(cfg_nova->>'catalogo_id')::uuid;
   if not public.frota_gestao_manter_item(dados_atuais,p_dados,linha_nova->>'numero',natureza_nova) then
    novos_efeitos:=novos_efeitos||jsonb_build_array(jsonb_build_object('item',linha_nova->>'numero','natureza',natureza_nova,
     'quantidade_estoque',case when natureza_nova='peca' then ((linha_nova->>'quantidade')::numeric*(cfg_nova->>'fator')::numeric)::text else '0' end,
     'valor_entrada',case when natureza_nova='peca' then ((linha_nova->>'bruto')::numeric-(linha_nova->>'desconto')::numeric+(linha_nova->>'acrescimo')::numeric)::text else '0' end,
     'custo_servicos',case when natureza_nova='servico' then (select coalesce(sum((p->>'valor')::numeric),0)::text from jsonb_array_elements(cfg_nova->'rateios') p where p->>'destino'='veiculo') else '0' end));
   end if;
  end loop;
 end if;
 select exists(select 1 from public.frota_gestao_hbf h join public.frota_gestao_nf_versoes f on f.id=h.versao_id where f.nota_id=n.id and h.estado='emitido' and h.encaminhamento='encaminhado') into encaminhado;
 resumo:=resumo||jsonb_build_object('contrato','06','versao_id',v.id,'numero_versao',v.numero_versao,'tipo',p_tipo,'total_anterior',v.total::text,'impactos',impactos,'novos_efeitos',novos_efeitos,'bloqueios',bloqueios,'novo_envio_necessario',encaminhado);
 assinatura:=encode(sha256(convert_to(jsonb_build_object('versao',v.id,'tipo',p_tipo,'dados',p_dados,'referencia',p_referencia,'resumo',resumo)::text,'UTF8')),'hex');
 return resumo||jsonb_build_object('hash_conferencia',assinatura);
end $$;
revoke all on function public.frota_gestao_conferir_revisao(uuid,text,jsonb,text) from public,anon;
grant execute on function public.frota_gestao_conferir_revisao(uuid,text,jsonb,text) to authenticated;

create or replace function public.frota_gestao_confirmar_revisao(p_versao uuid,p_tipo text,p_dados jsonb,p_referencia text,p_motivo text,p_chave uuid,p_hash text,p_confirmado boolean)
returns jsonb language plpgsql security definer set search_path=pg_catalog,public as $$
declare anterior public.frota_gestao_nf_versoes;op public.frota_gestao_operacoes;nota uuid;versao uuid:=gen_random_uuid();rascunho uuid:=gen_random_uuid();
 assinatura text;resumo jsonb;resultado_final jsonb;r public.frota_gestao_rascunhos;plano jsonb;linha jsonb;cfg jsonb;parcela jsonb;contexto jsonb;candidato jsonb;
 item_id uuid;lote_id uuid;vinculo uuid;os_id uuid;os_item uuid;veiculo uuid;unidade_os uuid;numero_os bigint;catalogo public.frota_gestao_catalogo;
 criadas jsonb:='{}';itens_criados jsonb:='{}';ordens jsonb:='[]';qp numeric;vp numeric;liquido numeric;q numeric;fator numeric;indice integer;chave_item text;originais jsonb;descricao_origem text;
 dados_anteriores jsonb;i public.frota_gestao_nf_itens;antigo_item public.frota_gestao_nf_itens;item_origem uuid;manter boolean;lote public.frota_gestao_lotes;custo_anterior record;
begin
  perform public.frota_gestao_exigir_escrita(false);
 if not public.frota_gestao_usuario_ativo() then raise exception using errcode='42501',message='Conta inativa ou não autenticada.';end if;
 if current_setting('transaction_isolation')<>'read committed' then raise exception 'Correção/cancelamento exige READ COMMITTED.';end if;
 if p_chave is null or p_confirmado is distinct from true or length(btrim(coalesce(p_motivo,''))) not between 5 and 2000 then raise exception 'Confirmação explícita, chave e justificativa de 5 a 2000 caracteres são obrigatórias.';end if;
 assinatura:=encode(sha256(convert_to(jsonb_build_object('versao',p_versao,'tipo',p_tipo,'dados',p_dados,'referencia',p_referencia,'motivo',p_motivo,'hash',p_hash)::text,'UTF8')),'hex');
 perform pg_advisory_xact_lock(hashtextextended('nf-operacao:'||p_chave::text,0));
 select * into op from public.frota_gestao_operacoes where id=p_chave;
 if found then
  if op.tipo not in ('corrigir','cancelar') or op.hash_entrada<>assinatura then raise exception 'Chave reutilizada com dados diferentes.';end if;
  return op.resultado;
 end if;
 select nota_id into nota from public.frota_gestao_nf_versoes where id=p_versao;
 if nota is null then raise exception 'Versão não encontrada.';end if;
 -- Mesma linha de identidade fiscal usada por emissão/encaminhamento HBF.
 perform 1 from public.frota_gestao_notas where id=nota for update;
 select * into anterior from public.frota_gestao_nf_versoes where id=p_versao;
 dados_anteriores:=public.frota_gestao_dados_versao(p_versao);
 if anterior.estado<>'finalizada' or exists(select 1 from public.frota_gestao_nf_versoes v where v.nota_id=nota and v.numero_versao>anterior.numero_versao) then
  raise exception 'A versão mudou ou foi cancelada. Recarregue a NF.';
 end if;
 -- Veículo -> OS -> item -> lote, na ordem dos ciclos 03 e 04.
 for veiculo in select distinct id from (
  select v.veiculo_id id from public.frota_gestao_vinculos v join public.frota_gestao_nf_itens ni on ni.id=v.nf_item_id where ni.versao_id=p_versao and v.veiculo_id is not null
  union select nullif(p->>'veiculo_id','')::uuid from jsonb_each(p_dados#>'{finalizacao,itens}') it cross join lateral jsonb_array_elements(it.value->'rateios') p where p->>'destino'='veiculo') destinos where id is not null order by id loop
  perform pg_advisory_xact_lock(hashtextextended('nf-veiculo:'||veiculo::text,0));
  perform 1 from public.veiculos where id=veiculo for share;
  perform 1 from public.frota_gestao_os where veiculo_id=veiculo order by id for update;
  perform 1 from public.frota_gestao_os_itens oi where oi.os_id in(select o.id from public.frota_gestao_os o where o.veiculo_id=veiculo) order by oi.id for update;
 end loop;
 perform 1 from public.frota_gestao_fornecedores where fornecedor_id=(p_dados#>>'{finalizacao,fornecedor_id}')::uuid for share;
 perform 1 from public.frota_gestao_catalogo where id in(select (it.value->>'catalogo_id')::uuid from jsonb_each(p_dados#>'{finalizacao,itens}') it) order by id for share;
 for lote_id in select l.id from public.frota_gestao_lotes l join public.frota_gestao_nf_itens ni on coalesce(ni.origem_efeito_id,ni.id)=l.nf_item_id where ni.versao_id=p_versao order by l.id loop
  perform pg_advisory_xact_lock(hashtextextended('frota-estoque-lote:'||lote_id::text,0));
  perform 1 from public.frota_gestao_lotes where id=lote_id for update;
 end loop;
 resumo:=public.frota_gestao_conferir_revisao(p_versao,p_tipo,p_dados,p_referencia);
 if p_hash is distinct from resumo->>'hash_conferencia' then raise exception 'Os dados ou impactos mudaram. Confira novamente antes de confirmar.';end if;
 if jsonb_array_length(resumo->'bloqueios')>0 then raise exception '%',resumo->'bloqueios';end if;
 insert into public.frota_gestao_operacoes(id,tipo,hash_entrada,resultado) values(p_chave,case when p_tipo='corrigir' then 'corrigir' else 'cancelar' end,assinatura,'{}');
 -- Apenas efeitos diferentes são compensados; origens retidas permanecem rastreáveis.
 for i in select * from public.frota_gestao_nf_itens where versao_id=p_versao order by numero_item loop
  if p_tipo='corrigir' and coalesce(public.frota_gestao_manter_item(dados_anteriores,p_dados,i.numero_item::text,i.natureza),false) then continue;end if;
  item_origem:=coalesce(i.origem_efeito_id,i.id);
  if i.natureza='peca' then
   select * into lote from public.frota_gestao_lotes where nf_item_id=item_origem;
   insert into public.frota_gestao_movimentos(lote_id,local_id,tipo,quantidade,valor,operacao_atomica,motivo)
    select lote.id,m.local_id,'ajuste_saida',lote.quantidade_origem,lote.custo_total,p_chave,p_motivo from public.frota_gestao_movimentos m where m.lote_id=lote.id and m.tipo='entrada_nf';
  else
   for custo_anterior in select custo.* from public.frota_gestao_custos custo join public.frota_gestao_vinculos f on f.id=custo.vinculo_id where f.nf_item_id=item_origem and custo.origem='servico' loop
    insert into public.frota_gestao_custos(veiculo_id,unidade_custo_id,custo_estornado_id,origem,valor,executado_em,operacao_corretiva_id)
     values(custo_anterior.veiculo_id,custo_anterior.unidade_custo_id,custo_anterior.id,'estorno',-custo_anterior.valor,custo_anterior.executado_em,p_chave);
   end loop;
  end if;
 end loop;
 r.dados:=case when p_tipo='corrigir' then p_dados else public.frota_gestao_dados_versao(p_versao) end;
 plano:=r.dados->'finalizacao';
 insert into public.frota_gestao_rascunhos(id,dados,finalizado_em) values(rascunho,r.dados,clock_timestamp());
 insert into public.frota_gestao_nf_versoes(id,nota_id,rascunho_id,numero_versao,anterior_id,estado,emissao,total,dados_fiscais,motivo,tipo_cancelamento,referencia_cancelamento)
 values(versao,nota,rascunho,anterior.numero_versao+1,anterior.id,case when p_tipo='corrigir' then 'finalizada' else 'cancelada' end,
 (plano->>'emissao')::date,case when p_tipo='corrigir' then (resumo->>'total')::numeric else anterior.total end,r.dados,p_motivo,
 case when p_tipo<>'corrigir' then p_tipo end,case when p_tipo<>'corrigir' then nullif(btrim(p_referencia),'') end);
 if p_tipo='corrigir' then
  for linha in select * from jsonb_array_elements(r.dados#>'{nota,itens}') loop
    cfg:=plano->'itens'->(linha->>'numero');select * into catalogo from public.frota_gestao_catalogo where id=(cfg->>'catalogo_id')::uuid;
    originais:=r.dados#>'{nota,dados_fiscais,nota,det}';
    select e#>>'{prod,xProd}' into descricao_origem from jsonb_array_elements(case when jsonb_typeof(originais)='array' then originais else jsonb_build_array(originais) end) e where e->>'@nItem'=linha->>'numero';
    q:=(linha->>'quantidade')::numeric;fator:=(cfg->>'fator')::numeric;liquido:=(linha->>'bruto')::numeric-(linha->>'desconto')::numeric+(linha->>'acrescimo')::numeric;item_id:=gen_random_uuid();
    insert into public.frota_gestao_nf_itens(id,versao_id,numero_item,codigo_original,descricao_original,descricao_conferida,catalogo_id,natureza,quantidade_compra,unidade_compra,fator_conversao,valor_unitario,bruto,desconto,acrescimo,liquido,origem_efeito_id)
      values(item_id,versao,(linha->>'numero')::integer,coalesce(linha->>'codigo',''),coalesce(descricao_origem,linha->>'descricao'),linha->>'descricao',catalogo.id,catalogo.natureza,q,linha->>'unidade',fator,(linha->>'unitario')::numeric,(linha->>'bruto')::numeric,(linha->>'desconto')::numeric,(linha->>'acrescimo')::numeric,liquido,(select coalesce(ni.origem_efeito_id,ni.id) from public.frota_gestao_nf_itens ni where ni.versao_id=anterior.id and ni.numero_item=(linha->>'numero')::integer and public.frota_gestao_manter_item(dados_anteriores,r.dados,linha->>'numero',catalogo.natureza)));
    manter:=public.frota_gestao_manter_item(dados_anteriores,r.dados,linha->>'numero',catalogo.natureza);
    select ni.* into antigo_item from public.frota_gestao_nf_itens ni where ni.versao_id=anterior.id and ni.numero_item=(linha->>'numero')::integer;
    if manter then
      insert into public.frota_gestao_vinculos(nf_item_id,os_id,os_item_id,veiculo_id,unidade_custo_id,quantidade,valor_documentado,centro_custo,conta_id,categoria_id,classificacao)
        select item_id,f.os_id,f.os_item_id,f.veiculo_id,f.unidade_custo_id,f.quantidade,f.valor_documentado,f.centro_custo,f.conta_id,f.categoria_id,f.classificacao from public.frota_gestao_vinculos f where f.nf_item_id=antigo_item.id;
      continue;
    end if;
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
            if exists(select 1 from public.frota_gestao_os where nota_origem_id=nota and veiculo_id=veiculo and origem='nota') then raise exception 'Já existe OS automática para este veículo/NF. Selecione item compatível ou abra OS antecipada adequada.';end if;
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

 else
  -- O cancelamento também possui cópia fiscal íntegra, sem novos efeitos.
  for i in select * from public.frota_gestao_nf_itens where versao_id=p_versao order by numero_item loop
   item_id:=gen_random_uuid();
   insert into public.frota_gestao_nf_itens(id,versao_id,numero_item,codigo_original,descricao_original,descricao_conferida,catalogo_id,natureza,quantidade_compra,unidade_compra,fator_conversao,valor_unitario,bruto,desconto,acrescimo,liquido,origem_efeito_id)
    values(item_id,versao,i.numero_item,i.codigo_original,i.descricao_original,i.descricao_conferida,i.catalogo_id,i.natureza,i.quantidade_compra,i.unidade_compra,i.fator_conversao,i.valor_unitario,i.bruto,i.desconto,i.acrescimo,i.liquido,coalesce(i.origem_efeito_id,i.id));
   insert into public.frota_gestao_vinculos(nf_item_id,os_id,os_item_id,veiculo_id,unidade_custo_id,quantidade,valor_documentado,centro_custo,conta_id,categoria_id,classificacao)
    select item_id,f.os_id,f.os_item_id,f.veiculo_id,f.unidade_custo_id,f.quantidade,f.valor_documentado,f.centro_custo,f.conta_id,f.categoria_id,f.classificacao from public.frota_gestao_vinculos f where f.nf_item_id=i.id;
  end loop;
 end if;
 if nullif(r.dados->>'referencia','') is not null then insert into public.frota_gestao_referencias(versao_id,url,descricao) values(versao,r.dados->>'referencia','Documento externo conferido na revisão');end if;
 if p_tipo='fiscal_comprovado' then insert into public.frota_gestao_referencias(versao_id,url,descricao) values(versao,p_referencia,'Comprovação de cancelamento fiscal informada pelo responsável');end if;
 resultado_final:=jsonb_build_object('contrato','06','operacao_id',p_chave,'nota_id',nota,'versao_id',versao,'anterior_id',p_versao,'numero_versao',anterior.numero_versao+1,
  'tipo',p_tipo,'autor_id',auth.uid(),'confirmado_em',clock_timestamp(),'ordens',ordens,'impactos',resumo->'impactos','novo_envio_necessario',resumo->'novo_envio_necessario');
 update public.frota_gestao_operacoes set resultado=resultado_final where id=p_chave;
 return resultado_final;
end $$;
revoke all on function public.frota_gestao_confirmar_revisao(uuid,text,jsonb,text,text,uuid,text,boolean) from public,anon;
grant execute on function public.frota_gestao_confirmar_revisao(uuid,text,jsonb,text,text,uuid,text,boolean) to authenticated;

-- Reaplica o operador 89 com uma guarda de vigência após o mesmo lock de lote.
create or replace function public.frota_gestao_operar_estoque(p_chave uuid,p_dados jsonb,p_confirmado boolean)
returns jsonb language plpgsql security definer set search_path=pg_catalog,public as $$
declare
  tipo text:=p_dados->>'tipo';assinatura text;anterior public.frota_gestao_operacoes;
  lote public.frota_gestao_lotes;reserva public.frota_gestao_reservas;aplicacao public.frota_gestao_aplicacoes;
  ordem public.frota_gestao_os;item public.frota_gestao_os_itens;custo_original public.frota_gestao_custos;
  lote_id uuid:=nullif(p_dados->>'lote_id','')::uuid;local_id uuid:=nullif(p_dados->>'local_id','')::uuid;
  destino uuid:=nullif(p_dados->>'destino_id','')::uuid;item_id uuid:=nullif(p_dados->>'os_item_id','')::uuid;
  reserva_id uuid:=nullif(p_dados->>'reserva_id','')::uuid;aplicacao_id uuid:=nullif(p_dados->>'aplicacao_id','')::uuid;
  ordem_id uuid:=nullif(p_dados->>'os_id','')::uuid;veiculo uuid;unidade uuid;unidade_destino uuid;
  unidade_financeira uuid:=nullif(p_dados->>'unidade_custo_id','')::uuid;
  q numeric;v numeric:=0;saldo record;q_estornada numeric;v_estornado numeric;data_real date;
  registro uuid:=gen_random_uuid();movimento text;motivo text:=btrim(coalesce(p_dados->>'motivo',''));
  referencia text:=nullif(btrim(p_dados->>'referencia_fiscal'),'');destino_fisico text:=p_dados->>'destino_fisico';recibo_resultado jsonb;
begin
  perform public.frota_gestao_exigir_escrita(false);
  if not public.frota_gestao_usuario_ativo() then raise exception using errcode='42501',message='Conta inativa ou não autenticada.';end if;
  if current_setting('transaction_isolation')<>'read committed' then raise exception 'Operações de estoque exigem isolamento READ COMMITTED.';end if;
  if p_chave is null or p_confirmado is distinct from true or jsonb_typeof(p_dados) is distinct from 'object' or octet_length(p_dados::text)>16384
    or tipo is null or tipo not in ('reservar','liberar','aplicar','transferir','ajustar','devolver','estornar','encerrar_os') then raise exception 'Confira os dados e a confirmação explícita da operação.';end if;
  assinatura:=encode(sha256(convert_to(jsonb_build_object('contrato','04','dados',p_dados)::text,'UTF8')),'hex');
  perform pg_advisory_xact_lock(hashtextextended('frota-estoque-op:'||p_chave::text,0));
  select * into anterior from public.frota_gestao_operacoes where id=p_chave;
  if found then
    if anterior.tipo is distinct from tipo or anterior.hash_entrada is distinct from assinatura then raise exception 'Chave reutilizada com dados diferentes.';end if;
    return anterior.resultado;
  end if;
  if motivo='' or length(motivo)>2000 then raise exception 'Justificativa obrigatória, até 2000 caracteres.';end if;
  if tipo<>'encerrar_os' then
    q:=public.frota_gestao_decimal_nf(p_dados->>'quantidade',6);
    if q<=0 then raise exception 'Quantidade deve ser positiva.';end if;
  end if;
  -- As referências fornecidas devem corresponder à reserva/aplicação original.
  if tipo in ('liberar','aplicar') and reserva_id is not null then
    select * into reserva from public.frota_gestao_reservas where id=reserva_id;
    if not found or lote_id is distinct from reserva.lote_id or local_id is distinct from reserva.local_id or item_id is distinct from reserva.os_item_id then raise exception 'Reserva, item, lote e local não correspondem.';end if;
  elsif tipo='liberar' then raise exception 'Selecione a reserva a liberar.';
  end if;
  if tipo='estornar' then
    select * into aplicacao from public.frota_gestao_aplicacoes where id=aplicacao_id;
    if not found or lote_id is distinct from aplicacao.lote_id or local_id is distinct from aplicacao.local_id or item_id is distinct from aplicacao.os_item_id then raise exception 'Aplicação, item, lote e local não correspondem.';end if;
  end if;
  if tipo in ('reservar','liberar','aplicar','estornar','encerrar_os') then
    if tipo<>'encerrar_os' then
      select * into item from public.frota_gestao_os_itens where id=item_id;
      if not found or ordem_id is distinct from item.os_id then raise exception 'Item não pertence à OS informada.';end if;
    end if;
    select veiculo_id into veiculo from public.frota_gestao_os where id=ordem_id;
    if not found then raise exception 'OS não encontrada.';end if;
    -- Mesma ordem de bloqueio do finalizador 88: veículo, OS, item e depois lote.
    perform pg_advisory_xact_lock(hashtextextended('nf-veiculo:'||veiculo::text,0));
    select * into ordem from public.frota_gestao_os where id=ordem_id for update;
    if ordem.veiculo_id is distinct from nullif(p_dados->>'veiculo_id','')::uuid
      or not exists(select 1 from public.veiculos where id=ordem.veiculo_id and placa=p_dados->>'placa') then raise exception 'Confira veículo e placa da OS.';end if;
    if tipo in ('reservar','aplicar','encerrar_os') and ordem.estado not in ('aberta','em_execucao') then raise exception 'OS não está aberta para esta operação.';end if;
    if tipo<>'encerrar_os' then perform 1 from public.frota_gestao_os_itens where id=item_id for update;end if;
    if not exists(select 1 from public.operacoes where id=ordem.operacao_id and ativa) then raise exception 'Unidade da OS inativa.';end if;
  end if;
  if tipo='encerrar_os' then
    if exists(select 1 from public.frota_gestao_reservas r join public.frota_gestao_os_itens i on i.id=r.os_item_id where i.os_id=ordem_id and r.quantidade>r.aplicada+r.liberada) then
      raise exception 'OS com reservas pendentes: aplique ou libere as peças antes de encerrar.';
    end if;
  else
    perform pg_advisory_xact_lock(hashtextextended('frota-estoque-lote:'||lote_id::text,0));
    select * into lote from public.frota_gestao_lotes where id=lote_id for update;
    if not found then raise exception 'Lote não encontrado.';end if;
    if not exists(select 1 from public.frota_gestao_nf_itens ativo join public.frota_gestao_nf_versoes atual on atual.id=ativo.versao_id
      join public.frota_gestao_nf_itens origem on origem.id=lote.nf_item_id join public.frota_gestao_nf_versoes inicial on inicial.id=origem.versao_id
      where atual.nota_id=inicial.nota_id and atual.estado='finalizada' and coalesce(ativo.origem_efeito_id,ativo.id)=lote.nf_item_id
        and not exists(select 1 from public.frota_gestao_nf_versoes nv where nv.nota_id=atual.nota_id and nv.numero_versao>atual.numero_versao)) then
      raise exception 'Lote de versão substituída sem efeitos retidos, ou de lançamento cancelado. Operação bloqueada.';
    end if;
    if not exists(select 1 from public.frota_gestao_nf_itens i join public.frota_gestao_nf_versoes n on n.id=i.versao_id
      where i.id=lote.nf_item_id and n.estado='finalizada' and i.natureza='peca' and i.catalogo_id=lote.catalogo_id
        and i.quantidade_compra*i.fator_conversao=lote.quantidade_origem and i.liquido=lote.custo_total)
      or not exists(select 1 from public.frota_gestao_movimentos m where m.lote_id=lote.id and m.tipo='entrada_nf'
        and m.quantidade=lote.quantidade_origem and m.valor=lote.custo_total) then raise exception 'Lote sem aquisição fiscal e entrada original conciliadas.';end if;
    select l.operacao_id into unidade from public.frota_gestao_locais l join public.operacoes o on o.id=l.operacao_id where l.id=local_id and o.ativa;
    if not found then raise exception 'Local ou unidade de origem inválida.';end if;
    if tipo in ('reservar','aplicar') then
      if lote.catalogo_id is distinct from item.catalogo_id then raise exception 'Produto do lote incompatível com o item da OS.';end if;
      if not exists(select 1 from public.frota_gestao_catalogo where id=lote.catalogo_id and ativo and natureza='peca') then raise exception 'Produto inativo ou não é peça.';end if;
    end if;
    select * into saldo from public.frota_gestao_saldo_lote(lote_id,local_id);
    if saldo.fisico<0 or saldo.reservado<0 or saldo.reservado>saldo.fisico or saldo.valor<0 or (saldo.fisico=0 and saldo.valor<>0) then raise exception 'Saldo inconsistente: solicite conferência do histórico antes de operar.';end if;
    if reserva_id is not null and tipo in ('aplicar','liberar') then
      select * into reserva from public.frota_gestao_reservas where id=reserva_id for update;
      if q>reserva.quantidade-reserva.aplicada-reserva.liberada then raise exception 'Quantidade superior à reserva pendente.';end if;
    end if;
    if tipo in ('reservar','transferir','devolver') or (tipo='ajustar' and p_dados->>'sentido'='saida') or (tipo='aplicar' and reserva_id is null) then
      if q>saldo.fisico-saldo.reservado then raise exception 'Saldo disponível insuficiente.';end if;
    end if;
    if tipo='aplicar' and q>saldo.fisico then raise exception 'Saldo físico insuficiente.';end if;
    if tipo in ('aplicar','transferir','devolver') or (tipo='ajustar' and p_dados->>'sentido'='saida') then
      v:=public.frota_gestao_valorar_baixa(q,saldo.fisico,saldo.valor);
    end if;
    if tipo in ('transferir','devolver') and referencia is null then raise exception 'Informe a referência da documentação fiscal aplicável.';end if;
    if tipo='transferir' then
      select l.operacao_id into unidade_destino from public.frota_gestao_locais l join public.operacoes o on o.id=l.operacao_id where l.id=destino and o.ativa;
      if not found or unidade_destino=unidade then raise exception 'Selecione local de outra unidade ativa.';end if;
    end if;
    if tipo='ajustar' then
      if p_dados->>'sentido' is null or p_dados->>'sentido' not in ('entrada','saida') then raise exception 'Informe o sentido do ajuste.';end if;
      if p_dados->>'sentido'='entrada' then v:=round(lote.custo_total*q/lote.quantidade_origem,2);end if;
    end if;
    if tipo in ('aplicar','estornar') then
      if tipo='aplicar' and not exists(select 1 from public.operacoes where id=unidade_financeira and ativa) then raise exception 'Selecione a unidade responsável pelo custo da aplicação.';end if;
      if coalesce(p_dados->>'data','') !~ '^[0-9]{4}-[0-9]{2}-[0-9]{2}$' then raise exception 'Informe a data efetiva.';end if;
      data_real:=(p_dados->>'data')::date;
      if data_real>(clock_timestamp() at time zone 'America/Sao_Paulo')::date or data_real<lote.adquirido_em or (tipo='estornar' and data_real<aplicacao.aplicada_em) then raise exception 'Data efetiva incompatível com aquisição, aplicação ou data atual.';end if;
    end if;
    if tipo='estornar' then
      perform 1 from public.frota_gestao_aplicacoes where id=aplicacao_id for update;
      select coalesce(sum(e.quantidade),0),coalesce(sum(e.valor),0) into q_estornada,v_estornado from public.frota_gestao_estornos e where e.aplicacao_id=aplicacao.id;
      if q>aplicacao.quantidade-q_estornada then raise exception 'Quantidade superior à aplicação ainda não estornada.';end if;
      v:=public.frota_gestao_valorar_baixa(q,aplicacao.quantidade-q_estornada,aplicacao.custo-v_estornado);
      select c.* into custo_original from public.frota_gestao_custos c where c.aplicacao_id=aplicacao.id and c.origem='peca_aplicada';
      if not found or custo_original.veiculo_id is distinct from ordem.veiculo_id or custo_original.valor is distinct from aplicacao.custo then raise exception 'Custo da aplicação não encontrado ou incompatível com a OS.';end if;
      if destino_fisico is null or destino_fisico not in ('estoque','fornecedor','sem_retorno') then raise exception 'Identifique o destino físico da peça.';end if;
      if destino_fisico='estoque' then
        if p_dados->'apta_disponivel' is distinct from 'true'::jsonb then raise exception 'Confirme a disponibilidade física e aptidão para uso.';end if;
        if not exists(select 1 from public.frota_gestao_locais l join public.operacoes o on o.id=l.operacao_id where l.id=destino and o.ativa) then raise exception 'Local de retorno inválido.';end if;
      elsif destino is not null or p_dados->'apta_disponivel'='true'::jsonb then raise exception 'Sem retorno ao estoque: não informe local nem confirme disponibilidade.';
      end if;
      if destino_fisico='fornecedor' and referencia is null then raise exception 'Informe a referência fiscal da devolução ao fornecedor.';end if;
      if destino_fisico='sem_retorno' and (nullif(btrim(p_dados->>'destino_descricao'),'') is null or length(p_dados->>'destino_descricao')>1000) then raise exception 'Descreva o destino físico da peça sem retorno ao estoque, até 1000 caracteres.';end if;
    end if;
  end if;
  insert into public.frota_gestao_operacoes(id,tipo,hash_entrada,resultado) values(p_chave,tipo,assinatura,'{}');
  if tipo='reservar' then
    insert into public.frota_gestao_reservas(id,lote_id,local_id,os_item_id,quantidade) values(registro,lote_id,local_id,item_id,q);
  elsif tipo='liberar' then
    update public.frota_gestao_reservas set liberada=liberada+q,estado=case when aplicada+liberada+q=quantidade then 'liberada' else 'ativa' end where id=reserva_id;
    registro:=reserva_id;
  elsif tipo='aplicar' then
    insert into public.frota_gestao_aplicacoes(id,lote_id,local_id,os_item_id,reserva_id,quantidade,custo,aplicada_em,chave_idempotencia)
      values(registro,lote_id,local_id,item_id,reserva_id,q,v,data_real,p_chave);
    insert into public.frota_gestao_movimentos(lote_id,local_id,tipo,quantidade,valor,operacao_atomica,aplicacao_id,motivo)
      values(lote_id,local_id,'aplicacao',q,v,p_chave,registro,motivo);
    insert into public.frota_gestao_custos(veiculo_id,unidade_custo_id,aplicacao_id,origem,valor,executado_em)
      values(ordem.veiculo_id,unidade_financeira,registro,'peca_aplicada',v,data_real);
    if reserva_id is not null then
      update public.frota_gestao_reservas set aplicada=aplicada+q,estado=case when aplicada+liberada+q=quantidade then 'aplicada' else 'ativa' end where id=reserva_id;
    end if;
  elsif tipo='transferir' then
    insert into public.frota_gestao_movimentos(lote_id,local_id,tipo,quantidade,valor,operacao_atomica,motivo,referencia_fiscal)
      values(lote_id,local_id,'transferencia_saida',q,v,p_chave,motivo,referencia),(lote_id,destino,'transferencia_entrada',q,v,p_chave,motivo,referencia);
    registro:=p_chave;
  elsif tipo in ('ajustar','devolver') then
    movimento:=case when tipo='devolver' then 'devolucao' when p_dados->>'sentido'='entrada' then 'ajuste_entrada' else 'ajuste_saida' end;
    insert into public.frota_gestao_movimentos(id,lote_id,local_id,tipo,quantidade,valor,operacao_atomica,motivo,referencia_fiscal)
      values(registro,lote_id,local_id,movimento,q,v,p_chave,motivo,referencia);
  elsif tipo='estornar' then
    insert into public.frota_gestao_estornos(id,aplicacao_id,quantidade,valor,retorno_fisico_confirmado,motivo,chave_idempotencia,destino_fisico,local_destino_id,referencia_fiscal)
      values(registro,aplicacao.id,q,v,destino_fisico='estoque',case when destino_fisico='sem_retorno' then motivo||' · Destino físico: '||btrim(p_dados->>'destino_descricao') else motivo end,p_chave,destino_fisico,destino,referencia);
    insert into public.frota_gestao_custos(veiculo_id,unidade_custo_id,estorno_id,custo_estornado_id,origem,valor,executado_em)
      values(custo_original.veiculo_id,custo_original.unidade_custo_id,registro,custo_original.id,'estorno',-v,data_real);
    if destino_fisico='estoque' then
      insert into public.frota_gestao_movimentos(lote_id,local_id,tipo,quantidade,valor,operacao_atomica,estorno_id,motivo)
        values(lote_id,destino,'retorno_fisico',q,v,p_chave,registro,motivo);
    end if;
  elsif tipo='encerrar_os' then
    update public.frota_gestao_os set estado='encerrada',encerrada_em=clock_timestamp() where id=ordem_id;
    registro:=ordem_id;
  end if;
  recibo_resultado:=jsonb_build_object('contrato','04','operacao_id',p_chave,'tipo',tipo,'registro_id',registro,
    'quantidade',coalesce(q,0)::text,'valor',v::text,'autor_id',auth.uid(),'confirmada_em',clock_timestamp(),'motivo',motivo,
    'dados',p_dados,'unidade_id',coalesce(unidade,ordem.operacao_id),'unidade_destino_id',unidade_destino,'produto_id',lote.catalogo_id);
  update public.frota_gestao_operacoes set resultado=recibo_resultado where id=p_chave;
  return recibo_resultado;
end $$;
revoke all on function public.frota_gestao_operar_estoque(uuid,jsonb,boolean) from public,anon;
grant execute on function public.frota_gestao_operar_estoque(uuid,jsonb,boolean) to authenticated;

create index if not exists frota_gestao_operacoes_versao_resultado on public.frota_gestao_operacoes((resultado->>'versao_id')) where tipo in ('corrigir','cancelar');
create or replace function public.frota_gestao_consultar_revisoes(p_nota uuid,p_pagina integer,p_versao uuid)
returns jsonb language plpgsql stable security definer set search_path=pg_catalog,public as $$
declare selecionada public.frota_gestao_nf_versoes;vigente public.frota_gestao_nf_versoes;lista jsonb;
begin
 if not public.frota_gestao_usuario_ativo() then raise exception using errcode='42501',message='Conta inativa ou não autenticada.';end if;
 if p_pagina is null or p_pagina<0 then raise exception 'Página inválida.';end if;
 select * into vigente from public.frota_gestao_nf_versoes where nota_id=p_nota order by numero_versao desc limit 1;
 if not found then raise exception 'NF não encontrada.';end if;
 select * into selecionada from public.frota_gestao_nf_versoes where nota_id=p_nota and id=coalesce(p_versao,vigente.id);
 if not found then raise exception 'Versão não pertence à NF.';end if;
 select coalesce(jsonb_agg(dados order by numero_versao desc),'[]') into lista from
 (select v.numero_versao,to_jsonb(v)-'dados_fiscais'||jsonb_build_object('total',v.total::text,'operacao',(select o.resultado from public.frota_gestao_operacoes o
   where o.tipo in ('corrigir','cancelar') and o.resultado->>'versao_id'=v.id::text limit 1)) dados
  from public.frota_gestao_nf_versoes v where v.nota_id=p_nota order by numero_versao desc limit 10 offset p_pagina::bigint*10) pagina;
 return jsonb_build_object('contrato','06','nota',(select to_jsonb(n) from public.frota_gestao_notas n where id=p_nota),'vigente_id',vigente.id,
 'total',(select count(*) from public.frota_gestao_nf_versoes where nota_id=p_nota),'versoes',lista,
 'selecionada',to_jsonb(selecionada)-'dados_fiscais'||jsonb_build_object('total',selecionada.total::text,'dados',public.frota_gestao_dados_versao(selecionada.id),
   'dados_anteriores',case when selecionada.anterior_id is not null then public.frota_gestao_dados_versao(selecionada.anterior_id) end,'referencias',
   coalesce((select jsonb_agg(to_jsonb(r) order by criado_em,id) from public.frota_gestao_referencias r where r.versao_id=selecionada.id),'[]')));
end $$;
revoke all on function public.frota_gestao_consultar_revisoes(uuid,integer,uuid) from public,anon;
grant execute on function public.frota_gestao_consultar_revisoes(uuid,integer,uuid) to authenticated;

create or replace function public.frota_gestao_recibo_revisao(p_chave uuid)
returns jsonb language plpgsql stable security definer set search_path=pg_catalog,public as $$
begin
 if not public.frota_gestao_usuario_ativo() then raise exception using errcode='42501',message='Conta inativa ou não autenticada.';end if;
 return (select resultado from public.frota_gestao_operacoes where id=p_chave and tipo in ('corrigir','cancelar'));
end $$;
revoke all on function public.frota_gestao_recibo_revisao(uuid) from public,anon;
grant execute on function public.frota_gestao_recibo_revisao(uuid) to authenticated;

create or replace function public.frota_gestao_preparacao_revisoes()
returns jsonb language plpgsql stable security definer set search_path=pg_catalog,public as $$
begin
 if not public.frota_gestao_usuario_ativo() then raise exception using errcode='42501',message='Conta inativa ou não autenticada.';end if;
 perform origem_efeito_id from public.frota_gestao_nf_itens where false;
 perform tipo_cancelamento,referencia_cancelamento from public.frota_gestao_nf_versoes where false;
 return jsonb_build_object('contrato','06','disponivel',
 has_function_privilege('authenticated','public.frota_gestao_conferir_revisao(uuid,text,jsonb,text)','EXECUTE') and
 has_function_privilege('authenticated','public.frota_gestao_confirmar_revisao(uuid,text,jsonb,text,text,uuid,text,boolean)','EXECUTE') and
 has_function_privilege('authenticated','public.frota_gestao_consultar_revisoes(uuid,integer,uuid)','EXECUTE') and
 has_function_privilege('authenticated','public.frota_gestao_recibo_revisao(uuid)','EXECUTE'));
end $$;
revoke all on function public.frota_gestao_preparacao_revisoes() from public,anon;
grant execute on function public.frota_gestao_preparacao_revisoes() to authenticated;

create or replace function public.frota_gestao_proteger_compensacao()
returns trigger language plpgsql security definer set search_path=pg_catalog,public as $$
declare raiz public.frota_gestao_custos;
begin
 if new.operacao_corretiva_id is not null then
  select * into raiz from public.frota_gestao_custos where id=new.custo_estornado_id for update;
  if raiz.origem is distinct from 'servico' or new.origem<>'estorno' or new.valor is distinct from -raiz.valor
   or exists(select 1 from public.frota_gestao_custos where custo_estornado_id=raiz.id)
   or not exists(select 1 from public.frota_gestao_operacoes where id=new.operacao_corretiva_id and tipo in ('corrigir','cancelar')) then
   raise exception 'Compensação fiscal deve anular uma única vez o custo integral do serviço original.';
  end if;
 end if;
 return new;
end $$;
revoke all on function public.frota_gestao_proteger_compensacao() from public,anon,authenticated;
drop trigger if exists proteger_compensacao on public.frota_gestao_custos;
create trigger proteger_compensacao before insert on public.frota_gestao_custos for each row execute function public.frota_gestao_proteger_compensacao();

create or replace function public.frota_gestao_validar_origem_efeito()
returns trigger language plpgsql security definer set search_path=pg_catalog,public as $$
begin
 if new.origem_efeito_id is not null and not exists(select 1 from public.frota_gestao_nf_itens i
  join public.frota_gestao_nf_versoes anterior on anterior.id=i.versao_id join public.frota_gestao_nf_versoes atual on atual.id=new.versao_id
  where i.id=new.origem_efeito_id and i.origem_efeito_id is null and atual.nota_id=anterior.nota_id and atual.numero_versao>anterior.numero_versao
   and i.natureza=new.natureza and i.catalogo_id=new.catalogo_id and i.quantidade_compra=new.quantidade_compra and i.fator_conversao=new.fator_conversao and i.liquido=new.liquido) then
  raise exception 'Origem de efeitos deve pertencer à mesma NF e preservar natureza, quantidade, catálogo e líquido.';
 end if;
 return new;
end $$;
revoke all on function public.frota_gestao_validar_origem_efeito() from public,anon,authenticated;
drop trigger if exists validar_origem_efeito on public.frota_gestao_nf_itens;
create trigger validar_origem_efeito before insert on public.frota_gestao_nf_itens for each row execute function public.frota_gestao_validar_origem_efeito();

do $$ declare tabela text;begin
 foreach tabela in array array['vinculos','lotes','referencias'] loop
  execute format('drop trigger if exists preservar_historico_fiscal on public.%I','frota_gestao_'||tabela);
  execute format('create trigger preservar_historico_fiscal before update or delete on public.%I for each row execute function public.frota_gestao_preservar_item_fiscal()','frota_gestao_'||tabela);
 end loop;
end $$;
-- A conferência inicial também ignora versões substituídas no diagnóstico de OS sem contexto.
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
              join public.frota_gestao_nf_versoes nv on nv.id=ni.versao_id where v.os_item_id=oi.id and nv.estado='finalizada' and not exists(select 1 from public.frota_gestao_nf_versoes atual where atual.nota_id=nv.nota_id and atual.numero_versao>nv.numero_versao)),0)) then
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
