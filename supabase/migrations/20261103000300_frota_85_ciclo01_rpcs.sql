-- Origem: SQL 85 do módulo Gestão da Frota (extraído do laboratório, sem alterações de lógica).
-- NOVO, NÃO EXECUTADO. Executar somente após 84 e conferência do guia.
-- As RPCs estão preparadas; a interface deste ciclo NÃO as chama.
-- (begin/commit removidos: o Supabase CLI já executa cada migration em uma transação)
create or replace function public.frota_gestao_salvar_rascunho(p_id uuid,p_dados jsonb)
returns jsonb language plpgsql security definer set search_path=pg_catalog,public as $$
declare registro public.frota_gestao_rascunhos;
begin
  perform public.frota_gestao_exigir_escrita(false);
  if not public.frota_gestao_usuario_ativo() then raise exception using errcode='42501',message='Entre com um usuário ativo do portal.'; end if;
  if p_id is null or p_dados is null or jsonb_typeof(p_dados)<>'object' or pg_column_size(p_dados)>1048576 then
    raise exception 'Rascunho inválido ou maior que 1 MB.';
  end if;
  -- O mesmo bloqueio deve ser adquirido pela finalização futura. Reenvio atrasado não reabre a NF.
  perform pg_advisory_xact_lock(hashtextextended(p_id::text,0));
  select * into registro from public.frota_gestao_rascunhos where id=p_id for update;
  if found and registro.finalizado_em is not null then raise exception 'Esta nota já foi finalizada; abra uma nova versão.'; end if;
  if not found and exists(select 1 from public.frota_gestao_auditoria where entidade='frota_gestao_rascunhos' and registro_id=p_id) then
    raise exception 'Rascunho expirado. Inicie outro lançamento.';
  end if;
  insert into public.frota_gestao_rascunhos(id,dados,atualizado_por,atualizado_em)
    values(p_id,p_dados,auth.uid(),clock_timestamp())
    on conflict(id) do update set dados=excluded.dados,atualizado_por=excluded.atualizado_por,atualizado_em=excluded.atualizado_em
    returning * into registro;
  return jsonb_build_object('id',registro.id,'atualizado_em',registro.atualizado_em,'atualizado_por',registro.atualizado_por);
end $$;
revoke all on function public.frota_gestao_salvar_rascunho(uuid,jsonb) from public,anon;
grant execute on function public.frota_gestao_salvar_rascunho(uuid,jsonb) to authenticated;

create or replace function public.frota_gestao_expirar_rascunhos()
returns integer language plpgsql security definer set search_path=pg_catalog,public as $$
declare quantidade integer;
begin
  perform public.frota_gestao_exigir_escrita(true);
  delete from public.frota_gestao_rascunhos where finalizado_em is null and atualizado_em < clock_timestamp()-interval '7 days';
  get diagnostics quantidade=row_count;
  return quantidade;
end $$;
revoke all on function public.frota_gestao_expirar_rascunhos() from public,anon,authenticated;
grant execute on function public.frota_gestao_expirar_rascunhos() to service_role;
-- Nenhum cron é instalado automaticamente. O agendamento é dependência explícita do próximo ciclo.
