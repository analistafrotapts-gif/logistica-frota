-- Origem: SQL 86 do módulo Gestão da Frota (extraído do laboratório, sem alterações de lógica).
-- CORRETIVO 01.1, NÃO EXECUTADO NO SUPABASE. Ordem: 84 -> 85 -> 86.
-- Não reaplicar 84/85 depois deste corretivo. Guia: docs/gestao-frota/BANCO-CICLO-01.md.
-- (begin/commit removidos: o Supabase CLI já executa cada migration em uma transação)

alter table public.frota_gestao_rascunhos add column if not exists revisao bigint not null default 1;
alter table public.frota_gestao_os add column if not exists contexto_id text;

-- Nova medida: tamanho de jsonb::text UTF-8, compartilhada com o cliente.
-- A nova constraint é validada ANTES de retirar somente o antigo limite binário.
do $$
declare restricao record;
begin
  if not exists(select 1 from pg_constraint where conrelid='public.frota_gestao_rascunhos'::regclass and conname='frota_gestao_rascunho_texto_limite') then
    alter table public.frota_gestao_rascunhos add constraint frota_gestao_rascunho_texto_limite
      check(octet_length(convert_to(dados::text,'UTF8'))<=1048576);
  end if;
  for restricao in select conname from pg_constraint where conrelid='public.frota_gestao_rascunhos'::regclass
    and contype='c' and regexp_replace(pg_get_constraintdef(oid),'[[:space:]()]','','g')='CHECKpg_column_sizedados<=1048576' loop
    execute format('alter table public.frota_gestao_rascunhos drop constraint %I',restricao.conname);
  end loop;
end $$;

create unique index if not exists frota_gestao_nf_item_versao on public.frota_gestao_nf_itens(id,versao_id);
do $$
begin
  if not exists(select 1 from pg_constraint where conrelid='public.frota_gestao_ajustes'::regclass and conname='frota_gestao_ajuste_mesma_versao') then
    alter table public.frota_gestao_ajustes add constraint frota_gestao_ajuste_mesma_versao
      foreign key(item_id,versao_id) references public.frota_gestao_nf_itens(id,versao_id);
  end if;
  if not exists(select 1 from pg_constraint where conrelid='public.frota_gestao_nf_versoes'::regclass and conname='frota_gestao_versao_sem_autorreferencia') then
    alter table public.frota_gestao_nf_versoes add constraint frota_gestao_versao_sem_autorreferencia check(anterior_id is distinct from id);
  end if;
  if not exists(select 1 from pg_constraint where conrelid='public.frota_gestao_rascunhos'::regclass and conname='frota_gestao_revisao_positiva') then
    alter table public.frota_gestao_rascunhos add constraint frota_gestao_revisao_positiva check(revisao>0);
  end if;
end $$;

-- NaN passa em comparações de positividade do PostgreSQL; rejeitá-lo explicitamente.
do $$
declare campo record; nome_restricao text;
begin
  for campo in select table_name,column_name from information_schema.columns
    where table_schema='public' and left(table_name,13)='frota_gestao_' and data_type='numeric' loop
    nome_restricao:='fg_finito_'||campo.column_name;
    if not exists(select 1 from pg_constraint where conrelid=format('public.%I',campo.table_name)::regclass and conname=nome_restricao) then
      execute format('alter table public.%I add constraint %I check (%I is null or (%I<>''NaN''::numeric and %I<>''Infinity''::numeric and %I<>''-Infinity''::numeric))',
        campo.table_name,nome_restricao,campo.column_name,campo.column_name,campo.column_name,campo.column_name);
    end if;
  end loop;
end $$;

create or replace function public.frota_gestao_validar_versao()
returns trigger language plpgsql security definer set search_path=pg_catalog,public as $$
begin
  if tg_op<>'INSERT' then raise exception 'Versões fiscais são imutáveis. Registre uma nova versão.'; end if;
  if new.numero_versao>1 and not exists(select 1 from public.frota_gestao_nf_versoes
    where id=new.anterior_id and nota_id=new.nota_id and numero_versao=new.numero_versao-1) then
    raise exception 'A versão anterior deve pertencer à mesma NF e ser imediatamente precedente.';
  end if;
  return new;
end $$;
revoke all on function public.frota_gestao_validar_versao() from public,anon,authenticated;
drop trigger if exists conferir_versao on public.frota_gestao_nf_versoes;
create trigger conferir_versao before insert or update or delete on public.frota_gestao_nf_versoes
  for each row execute function public.frota_gestao_validar_versao();

create or replace function public.frota_gestao_preservar_item_fiscal()
returns trigger language plpgsql set search_path=pg_catalog,public as $$
begin raise exception 'Dados de versão fiscal são imutáveis. Registre uma nova versão.'; end $$;
revoke all on function public.frota_gestao_preservar_item_fiscal() from public,anon,authenticated;
do $$
declare nome text;
begin
  foreach nome in array array['frota_gestao_nf_itens','frota_gestao_ajustes'] loop
    execute format('drop trigger if exists preservar_item_fiscal on public.%I',nome);
    execute format('create trigger preservar_item_fiscal before update or delete on public.%I for each row execute function public.frota_gestao_preservar_item_fiscal()',nome);
  end loop;
end $$;

create or replace function public.frota_gestao_conferir_relacionamentos()
returns trigger language plpgsql security definer set search_path=pg_catalog,public as $$
declare item public.frota_gestao_nf_itens; lote public.frota_gestao_lotes;
  vinculo public.frota_gestao_vinculos; aplicacao public.frota_gestao_aplicacoes;
  custo public.frota_gestao_custos; veiculo uuid;
begin
  if tg_table_name='frota_gestao_nf_itens' then
    if new.catalogo_id is not null and not exists(select 1 from public.frota_gestao_catalogo where id=new.catalogo_id and natureza=new.natureza) then
      raise exception 'A natureza da linha fiscal deve corresponder ao catálogo selecionado.';
    end if;
  elsif tg_table_name='frota_gestao_vinculos' then
    select * into item from public.frota_gestao_nf_itens where id=new.nf_item_id;
    if new.os_item_id is not null and not exists(select 1 from public.frota_gestao_os_itens
      where id=new.os_item_id and os_id=new.os_id and catalogo_id is not distinct from item.catalogo_id) then
      raise exception 'A linha fiscal e o item da OS devem possuir o mesmo catálogo.';
    end if;
  elsif tg_table_name='frota_gestao_lotes' then
    select * into item from public.frota_gestao_nf_itens where id=new.nf_item_id;
    if not found or item.natureza<>'peca' or item.catalogo_id is distinct from new.catalogo_id then
      raise exception 'Lote deve identificar a peça e o catálogo da linha fiscal de origem.';
    end if;
  elsif tg_table_name='frota_gestao_reservas' or tg_table_name='frota_gestao_aplicacoes' then
    select * into lote from public.frota_gestao_lotes where id=new.lote_id;
    if not found or not exists(select 1 from public.frota_gestao_os_itens where id=new.os_item_id and catalogo_id=lote.catalogo_id) then
      raise exception 'O lote e o item da OS devem representar a mesma peça cadastrada.';
    end if;
  elsif tg_table_name='frota_gestao_custos' then
    if new.origem='servico' then
      select * into vinculo from public.frota_gestao_vinculos where id=new.vinculo_id;
      if not found or vinculo.veiculo_id is distinct from new.veiculo_id or vinculo.unidade_custo_id<>new.unidade_custo_id
        or not exists(select 1 from public.frota_gestao_nf_itens where id=vinculo.nf_item_id and natureza='servico') then
        raise exception 'Custo de serviço incompatível com o vínculo fiscal, veículo ou unidade.';
      end if;
    elsif new.origem='peca_aplicada' then
      select * into aplicacao from public.frota_gestao_aplicacoes where id=new.aplicacao_id;
      select o.veiculo_id into veiculo from public.frota_gestao_os_itens i join public.frota_gestao_os o on o.id=i.os_id where i.id=aplicacao.os_item_id;
      if aplicacao.id is null or veiculo is distinct from new.veiculo_id or new.valor<>aplicacao.custo then
        raise exception 'Custo da peça deve corresponder à aplicação e ao veículo da OS.';
      end if;
    elsif new.origem='estorno' then
      select * into custo from public.frota_gestao_custos where id=new.custo_estornado_id;
      if not found or custo.origem='estorno' or custo.veiculo_id<>new.veiculo_id or custo.unidade_custo_id<>new.unidade_custo_id or -new.valor>custo.valor then
        raise exception 'Estorno incompatível com o lançamento de custo original.';
      end if;
    end if;
  end if;
  return new;
end $$;
revoke all on function public.frota_gestao_conferir_relacionamentos() from public,anon,authenticated;
do $$
declare nome text;
begin
  foreach nome in array array['frota_gestao_nf_itens','frota_gestao_vinculos','frota_gestao_lotes','frota_gestao_reservas','frota_gestao_aplicacoes','frota_gestao_custos'] loop
    execute format('drop trigger if exists conferir_relacionamentos on public.%I',nome);
    execute format('create trigger conferir_relacionamentos before insert or update on public.%I for each row execute function public.frota_gestao_conferir_relacionamentos()',nome);
  end loop;
end $$;

-- Rascunho é transitório: auditoria guarda metadados, sem copiar seu conteúdo.
-- Eventos já existentes não são apagados nem reescritos.
create or replace function public.frota_gestao_auditar()
returns trigger language plpgsql security definer set search_path=pg_catalog,public as $$
declare anterior jsonb; seguinte jsonb; identificador uuid;
begin
  if tg_op<>'INSERT' then anterior:=to_jsonb(old); end if;
  if tg_op<>'DELETE' then seguinte:=to_jsonb(new); end if;
  if tg_op='UPDATE' and anterior=seguinte then return null; end if;
  identificador:=coalesce((seguinte->>'id')::uuid,(anterior->>'id')::uuid,(seguinte->>'fornecedor_id')::uuid,(anterior->>'fornecedor_id')::uuid);
  if tg_table_name='frota_gestao_rascunhos' then
    anterior:=anterior-'dados'; seguinte:=seguinte-'dados';
  end if;
  insert into public.frota_gestao_auditoria(entidade,registro_id,acao,antes,depois,autor_id)
    values(tg_table_name,identificador,tg_op,anterior,seguinte,auth.uid());
  return null;
end $$;
revoke all on function public.frota_gestao_auditar() from public,anon,authenticated;

create or replace function public.frota_gestao_preparacao()
returns jsonb language plpgsql stable security definer set search_path=pg_catalog,public as $$
declare agendada boolean:=false;
begin
  if not public.frota_gestao_usuario_ativo() then raise exception using errcode='42501',message='Conta inativa ou não autenticada.'; end if;
  if to_regclass('cron.job') is not null then
    begin
      execute $consulta$select exists(select 1 from cron.job where jobname='frota_gestao_expirar_rascunhos'
        and active and database=current_database() and schedule='*/15 * * * *'
        and btrim(command)='select public.frota_gestao_expirar_rascunhos();'
        and has_function_privilege(username,'public.frota_gestao_expirar_rascunhos()','EXECUTE'))$consulta$ into agendada;
    exception when insufficient_privilege then agendada:=false;
    end;
  end if;
  return jsonb_build_object('contrato','01.1','expiracao_agendada',agendada);
end $$;
revoke all on function public.frota_gestao_preparacao() from public,anon;
grant execute on function public.frota_gestao_preparacao() to authenticated;

-- Auxiliar interno: a futura finalização deve adquirir este mesmo bloqueio
-- e marcar finalizado_em somente ao concluir TODOS os efeitos na transação.
create or replace function public.frota_gestao_travar_rascunho(p_id uuid,p_revisao bigint)
returns public.frota_gestao_rascunhos language plpgsql security definer set search_path=pg_catalog,public as $$
declare registro public.frota_gestao_rascunhos;
begin
  if not public.frota_gestao_usuario_ativo() then raise exception using errcode='42501',message='Conta inativa ou não autenticada.'; end if;
  perform pg_advisory_xact_lock(hashtextextended(p_id::text,0));
  select * into registro from public.frota_gestao_rascunhos where id=p_id for update;
  if not found or registro.finalizado_em is not null then raise exception 'Rascunho ausente ou já finalizado.'; end if;
  if p_revisao is null or registro.revisao<>p_revisao then raise exception 'O rascunho mudou. Recarregue a versão atual antes de finalizar.'; end if;
  return registro;
end $$;
revoke all on function public.frota_gestao_travar_rascunho(uuid,bigint) from public,anon,authenticated;

create or replace function public.frota_gestao_salvar_rascunho(p_id uuid,p_dados jsonb)
returns jsonb language plpgsql security definer set search_path=pg_catalog,public as $$
declare registro public.frota_gestao_rascunhos; alterado boolean:=true;
begin
  perform public.frota_gestao_exigir_escrita(false);
  if not public.frota_gestao_usuario_ativo() then raise exception using errcode='42501',message='Entre com um usuário ativo do portal.'; end if;
  if not (public.frota_gestao_preparacao()->>'expiracao_agendada')::boolean then raise exception 'O salvamento depende do agendamento de expiração verificado.'; end if;
  if p_id is null or p_dados is null or jsonb_typeof(p_dados)<>'object' or p_dados->>'formato' is distinct from '1'
    or jsonb_typeof(p_dados->'nota') is distinct from 'object' or octet_length(convert_to(p_dados::text,'UTF8'))>1048576 then
    raise exception 'Rascunho inválido ou com dados estruturados acima de 1 MiB.';
  end if;
  perform pg_advisory_xact_lock(hashtextextended(p_id::text,0));
  select * into registro from public.frota_gestao_rascunhos where id=p_id for update;
  if found then
    if registro.finalizado_em is not null then raise exception 'Esta nota já foi finalizada; abra uma nova versão.'; end if;
    if registro.atualizado_em<clock_timestamp()-interval '7 days' then raise exception 'Rascunho expirado. Inicie outro lançamento.'; end if;
    if registro.dados=p_dados then alterado:=false;
    else
      update public.frota_gestao_rascunhos set dados=p_dados,atualizado_por=auth.uid(),atualizado_em=clock_timestamp(),revisao=revisao+1
        where id=p_id returning * into registro;
    end if;
  else
    if exists(select 1 from public.frota_gestao_auditoria where entidade='frota_gestao_rascunhos' and registro_id=p_id) then raise exception 'Rascunho expirado. Inicie outro lançamento.'; end if;
    insert into public.frota_gestao_rascunhos(id,dados,atualizado_por,atualizado_em)
      values(p_id,p_dados,auth.uid(),clock_timestamp()) returning * into registro;
  end if;
  return jsonb_build_object('id',registro.id,'atualizado_em',registro.atualizado_em,'atualizado_por',registro.atualizado_por,'revisao',registro.revisao::text,'alterado',alterado);
end $$;
revoke all on function public.frota_gestao_salvar_rascunho(uuid,jsonb) from public,anon;
grant execute on function public.frota_gestao_salvar_rascunho(uuid,jsonb) to authenticated;

create or replace function public.frota_gestao_carregar_rascunho(p_id uuid)
returns jsonb language plpgsql stable security definer set search_path=pg_catalog,public as $$
declare registro public.frota_gestao_rascunhos;
begin
  if not public.frota_gestao_usuario_ativo() then raise exception using errcode='42501',message='Conta inativa ou não autenticada.'; end if;
  select * into registro from public.frota_gestao_rascunhos where id=p_id;
  if not found then return null; end if;
  if registro.finalizado_em is null and registro.atualizado_em<statement_timestamp()-interval '7 days' then return null; end if;
  return to_jsonb(registro)||jsonb_build_object('revisao',registro.revisao::text);
end $$;
revoke all on function public.frota_gestao_carregar_rascunho(uuid) from public,anon;
grant execute on function public.frota_gestao_carregar_rascunho(uuid) to authenticated;

create or replace function public.frota_gestao_expirar_rascunhos()
returns integer language plpgsql security definer set search_path=pg_catalog,public as $$
declare registro record; quantidade integer:=0;
begin
  perform public.frota_gestao_exigir_escrita(true);
  for registro in select id from public.frota_gestao_rascunhos
    where finalizado_em is null and atualizado_em<clock_timestamp()-interval '7 days' for update skip locked loop
    if pg_try_advisory_xact_lock(hashtextextended(registro.id::text,0)) then
      delete from public.frota_gestao_rascunhos where id=registro.id and finalizado_em is null and atualizado_em<clock_timestamp()-interval '7 days';
      if found then quantidade:=quantidade+1; end if;
    end if;
  end loop;
  return quantidade;
end $$;
revoke all on function public.frota_gestao_expirar_rascunhos() from public,anon,authenticated;
grant execute on function public.frota_gestao_expirar_rascunhos() to service_role;
