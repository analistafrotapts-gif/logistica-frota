-- Origem: SQL 89 do módulo Gestão da Frota (extraído do laboratório, sem alterações de lógica).
-- PREPARADO, NÃO EXECUTADO. Aplicação manual após 88; consultar BANCO-CICLO-01.md.
-- (begin/commit removidos: o Supabase CLI já executa cada migration em uma transação)
do $$
begin
  if to_regprocedure('public.frota_gestao_preparacao_nf()') is null
    or to_regprocedure('public.frota_gestao_decimal_nf(text,integer)') is null then
    raise exception 'Instale e verifique 84 a 88 antes do Ciclo 04.';
  end if;
end $$;

-- Ampliação restrita ao domínio novo, sem converter ou excluir registros.
alter table public.frota_gestao_operacoes drop constraint if exists frota_gestao_operacoes_tipo_check;
alter table public.frota_gestao_operacoes add constraint frota_gestao_operacoes_tipo_check
  check(tipo in ('finalizar_nf','reservar','liberar','aplicar','transferir','estornar','corrigir','cancelar','ajustar','devolver','encerrar_os'));
alter table public.frota_gestao_estornos add column if not exists destino_fisico text;
alter table public.frota_gestao_estornos add column if not exists local_destino_id uuid references public.frota_gestao_locais(id);
alter table public.frota_gestao_estornos add column if not exists referencia_fiscal text;
do $$
begin
  if not exists(select 1 from pg_constraint where conrelid='public.frota_gestao_estornos'::regclass and conname='frota_gestao_estorno_destino') then
    alter table public.frota_gestao_estornos add constraint frota_gestao_estorno_destino check(
      destino_fisico is null or
      (destino_fisico='estoque' and retorno_fisico_confirmado and local_destino_id is not null) or
      (destino_fisico in ('fornecedor','sem_retorno') and not retorno_fisico_confirmado and local_destino_id is null
        and (destino_fisico<>'fornecedor' or nullif(btrim(referencia_fiscal),'') is not null)));
  end if;
end $$;
create index if not exists frota_gestao_reservas_os on public.frota_gestao_reservas(os_item_id);
create index if not exists frota_gestao_estornos_aplicacao on public.frota_gestao_estornos(aplicacao_id);

create or replace function public.frota_gestao_preservar_estoque()
returns trigger language plpgsql set search_path=pg_catalog,public as $$
begin
  raise exception 'Histórico de estoque e custos é imutável. Registre operação compensatória.';
end $$;
revoke all on function public.frota_gestao_preservar_estoque() from public,anon,authenticated;
do $$
declare tabela text;
begin
  foreach tabela in array array['movimentos','aplicacoes','estornos','custos'] loop
    execute format('drop trigger if exists preservar_estoque on public.%I','frota_gestao_'||tabela);
    execute format('create trigger preservar_estoque before update or delete on public.%I for each row execute function public.frota_gestao_preservar_estoque()','frota_gestao_'||tabela);
  end loop;
end $$;

create or replace function public.frota_gestao_validar_encerramento()
returns trigger language plpgsql set search_path=pg_catalog,public as $$
begin
  if new.estado='encerrada' and exists(select 1 from public.frota_gestao_reservas r
    join public.frota_gestao_os_itens i on i.id=r.os_item_id where i.os_id=new.id and r.quantidade>r.aplicada+r.liberada) then
    raise exception 'OS com reservas pendentes: aplique ou libere antes de encerrar.';
  end if;
  return new;
end $$;
revoke all on function public.frota_gestao_validar_encerramento() from public,anon,authenticated;
drop trigger if exists validar_encerramento on public.frota_gestao_os;
create trigger validar_encerramento before update on public.frota_gestao_os for each row execute function public.frota_gestao_validar_encerramento();

create or replace function public.frota_gestao_saldo_lote(p_lote uuid,p_local uuid)
returns table(fisico numeric,reservado numeric,valor numeric)
language sql stable security definer set search_path=pg_catalog,public as $$
  select coalesce((select sum(case when tipo in ('entrada_nf','transferencia_entrada','ajuste_entrada','retorno_fisico') then quantidade else -quantidade end)
    from public.frota_gestao_movimentos where lote_id=p_lote and local_id=p_local),0),
    coalesce((select sum(quantidade-aplicada-liberada) from public.frota_gestao_reservas where lote_id=p_lote and local_id=p_local),0),
    coalesce((select sum(case when tipo in ('entrada_nf','transferencia_entrada','ajuste_entrada','retorno_fisico') then valor else -valor end)
    from public.frota_gestao_movimentos where lote_id=p_lote and local_id=p_local),0)
$$;
revoke all on function public.frota_gestao_saldo_lote(uuid,uuid) from public,anon,authenticated;

-- Centavos residuais pertencem à última baixa do saldo do mesmo lote/local.
create or replace function public.frota_gestao_valorar_baixa(p_quantidade numeric,p_saldo numeric,p_valor numeric)
returns numeric language plpgsql immutable set search_path=pg_catalog,public as $$
begin
  if p_quantidade<=0 or p_saldo<p_quantidade or p_valor<0 then raise exception 'Quantidade ou valor de estoque inconsistente.';end if;
  return case when p_quantidade=p_saldo then p_valor else round(p_valor*p_quantidade/p_saldo,2) end;
end $$;
revoke all on function public.frota_gestao_valorar_baixa(numeric,numeric,numeric) from public,anon,authenticated;

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

create or replace function public.frota_gestao_recibo_estoque(p_chave uuid)
returns jsonb language plpgsql stable security definer set search_path=pg_catalog,public as $$
begin
  if not public.frota_gestao_usuario_ativo() then raise exception using errcode='42501',message='Conta inativa ou não autenticada.';end if;
  return (select resultado from public.frota_gestao_operacoes where id=p_chave and tipo in ('reservar','liberar','aplicar','transferir','ajustar','devolver','estornar','encerrar_os'));
end $$;
revoke all on function public.frota_gestao_recibo_estoque(uuid) from public,anon;
grant execute on function public.frota_gestao_recibo_estoque(uuid) to authenticated;

create or replace function public.frota_gestao_preparacao_estoque()
returns jsonb language plpgsql stable security definer set search_path=pg_catalog,public as $$
begin
  if not public.frota_gestao_usuario_ativo() then raise exception using errcode='42501',message='Conta inativa ou não autenticada.';end if;
  perform destino_fisico,local_destino_id,referencia_fiscal from public.frota_gestao_estornos where false;
  return jsonb_build_object('contrato','04','disponivel',
    has_function_privilege('authenticated','public.frota_gestao_operar_estoque(uuid,jsonb,boolean)','EXECUTE')
    and has_function_privilege('authenticated','public.frota_gestao_consultar_estoque(jsonb,integer)','EXECUTE')
    and has_function_privilege('authenticated','public.frota_gestao_opcoes_estoque(text,integer)','EXECUTE')
    and has_function_privilege('authenticated','public.frota_gestao_recibo_estoque(uuid)','EXECUTE'));
end $$;
revoke all on function public.frota_gestao_preparacao_estoque() from public,anon;
grant execute on function public.frota_gestao_preparacao_estoque() to authenticated;

-- Paginação no servidor: nem histórico nem seletores dependem do teto PostgREST.
create or replace function public.frota_gestao_opcoes_estoque(p_busca text,p_pagina integer)
returns jsonb language plpgsql stable security definer set search_path=pg_catalog,public as $$
declare itens jsonb;total bigint;
begin
  if not public.frota_gestao_usuario_ativo() then raise exception using errcode='42501',message='Conta inativa ou não autenticada.';end if;
  if p_pagina is null or p_pagina<0 or length(coalesce(p_busca,''))>100 then raise exception 'Página ou busca inválida.';end if;
  select count(*) into total from public.frota_gestao_os o join public.veiculos v on v.id=o.veiculo_id where o.numero::text ilike '%'||coalesce(p_busca,'')||'%' or v.placa ilike '%'||coalesce(p_busca,'')||'%';
  select coalesce(jsonb_agg(x.dados order by x.numero desc),'[]') into itens from (
    select o.numero,jsonb_build_object('id',o.id,'numero',o.numero::text,'estado',o.estado,'veiculo_id',v.id,'placa',v.placa,'unidade_id',o.operacao_id,
      'itens',coalesce((select jsonb_agg(jsonb_build_object('id',i.id,'catalogo_id',i.catalogo_id,'descricao',i.descricao,'natureza',c.natureza) order by i.id) from public.frota_gestao_os_itens i left join public.frota_gestao_catalogo c on c.id=i.catalogo_id where i.os_id=o.id),'[]')) dados
    from public.frota_gestao_os o join public.veiculos v on v.id=o.veiculo_id
    where o.numero::text ilike '%'||coalesce(p_busca,'')||'%' or v.placa ilike '%'||coalesce(p_busca,'')||'%'
    order by o.numero desc limit 25 offset p_pagina::bigint*25) x;
  return jsonb_build_object('ordens',itens,'total',total,
    'unidades',coalesce((select jsonb_agg(jsonb_build_object('id',id,'nome',nome) order by nome) from public.operacoes where ativa),'[]'),
    'locais',coalesce((select jsonb_agg(jsonb_build_object('id',l.id,'nome',u.nome||' · '||l.nome,'unidade_id',u.id) order by u.nome,l.nome) from public.frota_gestao_locais l join public.operacoes u on u.id=l.operacao_id where u.ativa),'[]'),
    'produtos',coalesce((select jsonb_agg(jsonb_build_object('id',id,'nome',codigo||' · '||descricao,'unidade',unidade_padrao) order by codigo) from public.frota_gestao_catalogo where natureza='peca'),'[]'));
end $$;
revoke all on function public.frota_gestao_opcoes_estoque(text,integer) from public,anon;
grant execute on function public.frota_gestao_opcoes_estoque(text,integer) to authenticated;

create or replace function public.frota_gestao_consultar_estoque(p_filtros jsonb,p_pagina integer)
returns jsonb language plpgsql stable security definer set search_path=pg_catalog,public as $$
declare modo text:=coalesce(p_filtros->>'modo','saldos');total bigint;linhas jsonb;
  unidade uuid:=nullif(p_filtros->>'unidade_id','')::uuid;produto uuid:=nullif(p_filtros->>'produto_id','')::uuid;
  lote uuid:=nullif(p_filtros->>'lote_id','')::uuid;ordem uuid:=nullif(p_filtros->>'os_id','')::uuid;
begin
  if not public.frota_gestao_usuario_ativo() then raise exception using errcode='42501',message='Conta inativa ou não autenticada.';end if;
  if p_pagina is null or p_pagina<0 or modo not in ('saldos','movimentos','reservas','aplicacoes','operacoes') then raise exception 'Consulta inválida.';end if;
  with base as materialized (
    select l.id lote_id,l.catalogo_id,l.adquirido_em,l.custo_total,l.quantidade_origem,c.descricao,c.unidade_padrao,n.numero numero_nf,n.serie,n.id nota_id,
      a.id local_id,a.nome local_nome,u.id unidade_id,u.nome unidade_nome
    from public.frota_gestao_lotes l join public.frota_gestao_catalogo c on c.id=l.catalogo_id
    join public.frota_gestao_nf_itens i on i.id=l.nf_item_id join public.frota_gestao_nf_versoes v on v.id=i.versao_id join public.frota_gestao_notas n on n.id=v.nota_id
    join public.frota_gestao_locais a on exists(select 1 from public.frota_gestao_movimentos m where m.lote_id=l.id and m.local_id=a.id)
    join public.operacoes u on u.id=a.operacao_id
    where (unidade is null or u.id=unidade) and (produto is null or l.catalogo_id=produto) and (lote is null or l.id=lote)
  ), registros as (
    select b.adquirido_em::timestamptz momento,b.lote_id::text||b.local_id::text chave,
      to_jsonb(b)||jsonb_build_object('fisico',s.fisico::text,'reservado',s.reservado::text,'disponivel',(s.fisico-s.reservado)::text,'valor',s.valor::text,'unitario',(b.custo_total/b.quantidade_origem)::text) dados
      from base b cross join lateral public.frota_gestao_saldo_lote(b.lote_id,b.local_id) s where modo='saldos'
      and (coalesce((p_filtros->>'somente_disponiveis')::boolean,false)=false or s.fisico>s.reservado)
    union all
    select m.criado_em,m.id::text,to_jsonb(b)||to_jsonb(m)||jsonb_build_object('quantidade',m.quantidade::text,'valor',m.valor::text,'autor',p.nome)
      from base b join public.frota_gestao_movimentos m on m.lote_id=b.lote_id and m.local_id=b.local_id left join public.perfis p on p.id=m.criado_por
      where modo='movimentos' and (nullif(p_filtros->>'tipo','') is null or m.tipo=p_filtros->>'tipo')
    union all
    select r.criado_em,r.id::text,to_jsonb(b)||to_jsonb(r)||jsonb_build_object('quantidade',r.quantidade::text,'pendente',(r.quantidade-r.aplicada-r.liberada)::text,'os_id',o.id,'os_numero',o.numero::text,'os_estado',o.estado,'placa',v.placa,'veiculo_id',o.veiculo_id,'autor',p.nome)
      from base b join public.frota_gestao_reservas r on r.lote_id=b.lote_id and r.local_id=b.local_id
      join public.frota_gestao_os_itens i on i.id=r.os_item_id join public.frota_gestao_os o on o.id=i.os_id join public.veiculos v on v.id=o.veiculo_id left join public.perfis p on p.id=r.criado_por
      where modo='reservas' and (ordem is null or o.id=ordem)
    union all
    select a.criado_em,a.id::text,to_jsonb(b)||to_jsonb(a)||jsonb_build_object('quantidade',a.quantidade::text,'valor',a.custo::text,'pendente',(a.quantidade-coalesce((select sum(e.quantidade) from public.frota_gestao_estornos e where e.aplicacao_id=a.id),0))::text,'os_id',o.id,'os_numero',o.numero::text,'os_estado',o.estado,'placa',v.placa,'veiculo_id',o.veiculo_id,'autor',p.nome)
      from base b join public.frota_gestao_aplicacoes a on a.lote_id=b.lote_id and a.local_id=b.local_id
      join public.frota_gestao_os_itens i on i.id=a.os_item_id join public.frota_gestao_os o on o.id=i.os_id join public.veiculos v on v.id=o.veiculo_id left join public.perfis p on p.id=a.criado_por
      where modo='aplicacoes' and (ordem is null or o.id=ordem)
    union all
    select a.criado_em,a.id::text,a.resultado||jsonb_build_object('autor',p.nome) from public.frota_gestao_operacoes a left join public.perfis p on p.id=a.criado_por
      where modo='operacoes' and a.tipo in ('reservar','liberar','aplicar','transferir','ajustar','devolver','estornar','encerrar_os')
      and (unidade is null or a.resultado->>'unidade_id'=unidade::text or a.resultado->>'unidade_destino_id'=unidade::text)
      and (produto is null or a.resultado->>'produto_id'=produto::text)
      and (lote is null or a.resultado->'dados'->>'lote_id'=lote::text)
      and (ordem is null or a.resultado->'dados'->>'os_id'=ordem::text)
  ), pagina as (select dados from registros order by case when modo='saldos' then momento end asc,momento desc,chave limit 25 offset p_pagina::bigint*25)
  select (select count(*) from registros),coalesce((select jsonb_agg(dados) from pagina),'[]') into total,linhas;
  return jsonb_build_object('contrato','04','total',total,'linhas',linhas);
end $$;
revoke all on function public.frota_gestao_consultar_estoque(jsonb,integer) from public,anon;
grant execute on function public.frota_gestao_consultar_estoque(jsonb,integer) to authenticated;
