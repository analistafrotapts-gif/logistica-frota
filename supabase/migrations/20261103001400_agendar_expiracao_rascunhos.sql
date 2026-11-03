-- Agenda a limpeza de rascunhos inativos a cada 15 minutos (pg_cron do Supabase).
-- A tela de preparação confere exatamente este job: nome, agenda e comando.
-- A rotina só remove algo depois que as escritas forem ativadas (ver README).
create extension if not exists pg_cron;

do $$
begin
  if exists (select 1 from cron.job where jobname = 'frota_gestao_expirar_rascunhos') then
    perform cron.unschedule('frota_gestao_expirar_rascunhos');
  end if;
  perform cron.schedule('frota_gestao_expirar_rascunhos', '*/15 * * * *',
    'select public.frota_gestao_expirar_rascunhos();');
end $$;
