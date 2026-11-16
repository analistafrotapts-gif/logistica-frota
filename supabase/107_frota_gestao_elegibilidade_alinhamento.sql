-- PREPARAÇÃO LOCAL: após 106. Não altera cadastro legado, NFs, custos ou serviços registrados.
begin;
set local lock_timeout='5s';
set local statement_timeout='60s';
do $$ begin
 if to_regprocedure('public.frota_gestao_alinhamentos()') is null then raise exception 'Instale e verifique SQL106 antes de 107.';end if;
end $$;
create table if not exists public.frota_gestao_pneus_elegibilidade (
 id uuid primary key default gen_random_uuid(),chave uuid not null unique,ordem bigint generated always as identity,
 veiculo_id uuid not null references public.veiculos(id),elegivel boolean not null,
 criado_por uuid not null references public.perfis(id),criado_em timestamptz not null default clock_timestamp()
);
create index if not exists frota_gestao_pneus_elegibilidade_veiculo on public.frota_gestao_pneus_elegibilidade(veiculo_id,ordem desc);
alter table public.frota_gestao_pneus_elegibilidade enable row level security;
revoke all on public.frota_gestao_pneus_elegibilidade from public,anon,authenticated;
grant select on public.frota_gestao_pneus_elegibilidade to authenticated;
revoke all on sequence public.frota_gestao_pneus_elegibilidade_ordem_seq from public,anon,authenticated;
drop policy if exists leitura_ativa on public.frota_gestao_pneus_elegibilidade;
create policy leitura_ativa on public.frota_gestao_pneus_elegibilidade for select to authenticated using(public.frota_gestao_usuario_ativo());
drop trigger if exists preservar_original on public.frota_gestao_pneus_elegibilidade;
create trigger preservar_original before update or delete on public.frota_gestao_pneus_elegibilidade for each row execute function public.frota_gestao_snapshot_simplificado();
drop trigger if exists registrar_auditoria on public.frota_gestao_pneus_elegibilidade;
create trigger registrar_auditoria after insert on public.frota_gestao_pneus_elegibilidade for each row execute function public.frota_gestao_auditar();

create or replace function public.frota_gestao_salvar_elegibilidade_alinhamento(p_chave uuid,p_veiculo uuid,p_elegivel boolean)
returns jsonb language plpgsql security definer set search_path=pg_catalog,public as $$
declare anterior public.frota_gestao_pneus_elegibilidade;
begin
 perform public.frota_gestao_exigir_escrita(false);
 if not public.frota_gestao_usuario_ativo() then raise exception using errcode='42501',message='Conta ativa necessária.';end if;
 if p_chave is null or p_veiculo is null or p_elegivel is null then raise exception 'Confira veículo e elegibilidade.';end if;
 perform pg_advisory_xact_lock(hashtextextended('frota-pneus-elegibilidade-op:'||p_chave::text,0));
 select * into anterior from public.frota_gestao_pneus_elegibilidade where chave=p_chave;
 if found then
  if anterior.veiculo_id<>p_veiculo or anterior.elegivel<>p_elegivel then raise exception 'Solicitação já confirmada com outros dados.';end if;
  return to_jsonb(anterior);
 end if;
 perform pg_advisory_xact_lock(hashtextextended('frota-pneus-elegibilidade-veiculo:'||p_veiculo::text,0));
 if not exists(select 1 from public.frota_gestao_veiculos where id=p_veiculo) then raise exception 'Veículo indisponível no cadastro atual.';end if;
 insert into public.frota_gestao_pneus_elegibilidade(chave,veiculo_id,elegivel,criado_por)
 values(p_chave,p_veiculo,p_elegivel,auth.uid()) returning * into anterior;
 return to_jsonb(anterior);
end $$;
revoke all on function public.frota_gestao_salvar_elegibilidade_alinhamento(uuid,uuid,boolean) from public,anon;
grant execute on function public.frota_gestao_salvar_elegibilidade_alinhamento(uuid,uuid,boolean) to authenticated;

-- Conserva a forma da consulta do 106 e acrescenta somente as opções de elegibilidade.
do $$ declare fonte text;antes text;depois text;begin
 fonte:=pg_get_functiondef('public.frota_gestao_alinhamentos()'::regprocedure);
 if position('elegibilidade_editavel' in fonte)=0 then
  antes:='select coalesce(jsonb_agg(to_jsonb(v) order by placa),''[]'') into veiculos from public.frota_gestao_veiculos v;';
  depois:=$a$select coalesce(jsonb_agg(to_jsonb(v)||jsonb_build_object('alinhamento_elegivel',coalesce(e.elegivel,true),'elegibilidade_atualizada_em',e.criado_em,'elegibilidade_autor',p.nome) order by v.placa),'[]') into veiculos
 from public.frota_gestao_veiculos v
 left join lateral (select * from public.frota_gestao_pneus_elegibilidade x where x.veiculo_id=v.id order by x.ordem desc limit 1) e on true
 left join public.perfis p on p.id=e.criado_por;$a$;
  if position(antes in fonte)=0 or position('''contrato'',''alinhamentos-01''' in fonte)=0 then raise exception 'Consulta106 divergente; nenhuma alteração instalada.';end if;
  fonte:=replace(fonte,antes,depois);
  fonte:=replace(fonte,'''contrato'',''alinhamentos-01''','''contrato'',''alinhamentos-01'',''elegibilidade_editavel'',true');execute fonte;
 end if;
end $$;
notify pgrst,'reload schema';
commit;
