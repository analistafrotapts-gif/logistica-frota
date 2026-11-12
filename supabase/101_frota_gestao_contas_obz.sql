-- MANUAL: depois de 99 revisado e 100. Não reaplicar os predecessores depois deste SQL.
-- Amplia somente o contrato simplificado. Não altera registros nem o histórico Gestran.
begin;
set local lock_timeout='5s';
set local statement_timeout='60s';
do $$ declare assinatura text;fonte text;begin
 if to_regclass('public.frota_gestao_exclusoes_simplificadas') is null then
  raise exception 'Instale e verifique os SQLs 99 e 100 antes do SQL 101.';
 end if;
 foreach assinatura in array array[
  'public.frota_gestao_validar_simplificado(jsonb,uuid,bigint)',
  'public.frota_gestao_validar_edicao_simplificada(jsonb,uuid,bigint)',
  'public.frota_gestao_aplicar_simplificado(uuid,jsonb,boolean)'
 ] loop
  fonte:=pg_get_functiondef(to_regprocedure(assinatura));
  if fonte is null or position('frota_gestao_lancamentos_vigentes' in fonte)=0 and position('frota_gestao_lotes_vigentes' in fonte)=0 then
   raise exception 'Dependencia divergente de 99/100: %',assinatura;
  end if;
  if position('not in (''preventiva'',''corretiva'',''obz'')' in fonte)=0 then
   if position('not in (''preventiva'',''corretiva'')' in fonte)=0 then
    raise exception 'Validacao de tipo divergente: %',assinatura;
   end if;
   fonte:=replace(fonte,'not in (''preventiva'',''corretiva'')','not in (''preventiva'',''corretiva'',''obz'')');
  end if;
  fonte:=replace(fonte,'Selecione Preventivo ou Corretivo','Selecione Preventivo, Corretivo ou Contas de OBZ');
  execute fonte;
 end loop;
end $$;

-- Conserva NULL nas aplicações antigas; nenhuma classificação retroativa é presumida.
do $$ declare definicao text;begin
 select pg_get_constraintdef(oid) into definicao from pg_constraint
 where conrelid='public.frota_gestao_lancamento_aplicacoes'::regclass
 and conname='frota_gestao_lancamento_aplicacoes_manutencao_check' and contype='c';
 if definicao is null or position('manutencao' in definicao)=0
  or position('preventiva' in definicao)=0 or position('corretiva' in definicao)=0 then
  raise exception 'Constraint de manutencao do SQL 96 divergente; instalacao cancelada.';
 end if;
end $$;
alter table public.frota_gestao_lancamento_aplicacoes
 drop constraint frota_gestao_lancamento_aplicacoes_manutencao_check;
alter table public.frota_gestao_lancamento_aplicacoes
 add constraint frota_gestao_lancamento_aplicacoes_manutencao_check
 check (manutencao in ('preventiva','corretiva','obz'));

-- CREATE OR REPLACE conserva ACLs, mas as intenções de acesso ficam explícitas.
revoke all on function public.frota_gestao_validar_simplificado(jsonb,uuid,bigint),
 public.frota_gestao_validar_edicao_simplificada(jsonb,uuid,bigint) from public,anon,authenticated;
revoke all on function public.frota_gestao_aplicar_simplificado(uuid,jsonb,boolean) from public,anon;
grant execute on function public.frota_gestao_aplicar_simplificado(uuid,jsonb,boolean) to authenticated;
notify pgrst,'reload schema';
commit;
