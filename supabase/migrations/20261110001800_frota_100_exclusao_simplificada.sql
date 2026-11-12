-- MANUAL, após 99 revisado. Exclusão lógica integral, sem apagar histórico físico.
-- Substitui duas unicidades globais do contrato 95 por validação ativa sob advisory locks.
-- Não executar/reaplicar 95–99 depois deste arquivo sem revisar e reaplicar 100 por último.
create table if not exists public.frota_gestao_exclusoes_simplificadas (
 id uuid primary key default gen_random_uuid(),nota_id uuid not null unique references public.frota_gestao_lancamentos(id),
 base_id uuid not null,chave uuid not null unique,motivo text not null check(length(btrim(motivo)) between 5 and 1000),
 criado_por uuid not null references public.perfis(id),criado_em timestamptz not null default clock_timestamp(),recibo jsonb not null
);
alter table public.frota_gestao_exclusoes_simplificadas enable row level security;
revoke all on public.frota_gestao_exclusoes_simplificadas from public,anon,authenticated;
grant select on public.frota_gestao_exclusoes_simplificadas to authenticated;
drop policy if exists leitura_ativa on public.frota_gestao_exclusoes_simplificadas;
create policy leitura_ativa on public.frota_gestao_exclusoes_simplificadas for select to authenticated using(public.frota_gestao_usuario_ativo());
drop trigger if exists preservar_original on public.frota_gestao_exclusoes_simplificadas;
create trigger preservar_original before update or delete on public.frota_gestao_exclusoes_simplificadas for each row execute function public.frota_gestao_snapshot_simplificado();
drop trigger if exists registrar_auditoria on public.frota_gestao_exclusoes_simplificadas;
create trigger registrar_auditoria after insert on public.frota_gestao_exclusoes_simplificadas for each row execute function public.frota_gestao_auditar();

create or replace function public.frota_gestao_lancamento_ativo(p_id uuid)
returns boolean language sql stable security definer set search_path=pg_catalog,public as $$
 select public.frota_gestao_usuario_ativo() and not exists(select 1 from public.frota_gestao_exclusoes_simplificadas where nota_id=p_id);
$$;
revoke all on function public.frota_gestao_lancamento_ativo(uuid) from public,anon,authenticated;
grant execute on function public.frota_gestao_lancamento_ativo(uuid) to authenticated;

create or replace view public.frota_gestao_lancamentos_vigentes with (security_barrier=true,security_invoker=true) as
select n.id,coalesce(e.id,n.versao_id) versao_id,n.rascunho_id,n.chave,n.revisao,
 coalesce(e.hbf->>'numero_nf',n.numero) numero,coalesce(e.hbf->>'serie',n.serie) serie,
 coalesce(e.hbf->>'documento_fornecedor',n.documento_fornecedor) documento_fornecedor,
 coalesce(e.hbf->>'fornecedor',n.fornecedor) fornecedor,
 case when e.id is null then n.chave_fiscal else nullif(e.hbf->>'chave_acesso','') end chave_fiscal,
 coalesce((e.dados->>'unidadeFiscal')::uuid,n.unidade_fiscal_id) unidade_fiscal_id,
 coalesce((e.hbf->>'emissao_nf')::date,n.emissao) emissao,
 coalesce((e.hbf->>'total')::numeric,n.total) total,coalesce(e.dados,n.dados) dados,coalesce(e.hbf,n.hbf) hbf,
 coalesce(e.recibo,n.recibo) recibo,n.finalizada_em,n.criado_por
from public.frota_gestao_lancamentos n
left join lateral (select * from public.frota_gestao_edicoes_simplificadas x where x.nota_id=n.id order by x.numero_versao desc limit 1) e on true
where public.frota_gestao_usuario_ativo() and public.frota_gestao_lancamento_ativo(n.id);

-- Os validadores continuam validando quantidades, rateios, cadastro e valores.
-- Apenas as identidades de lançamentos excluídos deixam de impedir novo lançamento.
do $$ declare assinatura text;fonte text;begin
 foreach assinatura in array array['frota_gestao_validar_simplificado(jsonb,uuid,bigint)','frota_gestao_validar_edicao_simplificada(jsonb,uuid,bigint)'] loop
  fonte:=pg_get_functiondef(('public.'||assinatura)::regprocedure);
  fonte:=regexp_replace(fonte,'frota_gestao_lancamentos\M','frota_gestao_lancamentos_vigentes','g');
  if position('frota_gestao_lancamento_ativo(e.nota_id)' in fonte)=0 then
   if position('e.nota_id<>p_id and' in fonte)=0 then raise exception 'Validador 99 divergente. Instalação 100 cancelada.';end if;
   fonte:=replace(fonte,'e.nota_id<>p_id and','e.nota_id<>p_id and public.frota_gestao_lancamento_ativo(e.nota_id) and');
  end if;execute fonte;
 end loop;
end $$;

-- Uma edição atrasada não pode reativar um lançamento excluído.
do $$ declare fonte text;alvo text:=' select * into atual from public.frota_gestao_lancamentos_vigentes where id=p_id;';begin
 fonte:=pg_get_functiondef('public.frota_gestao_confirmar_edicao_simplificada(uuid,uuid,uuid,jsonb,text,boolean)'::regprocedure);
 if position('Lançamento apagado' in fonte)=0 then
  if position(alvo in fonte)=0 then raise exception 'Confirmação 99 divergente; instalação 100 cancelada.';end if;
  execute replace(fonte,alvo,alvo||' if not found then raise exception ''Lançamento apagado; a edição não foi gravada.'';end if;');
 end if;
end $$;

create or replace function public.frota_gestao_identidade_simplificada()
returns trigger language plpgsql security definer set search_path=pg_catalog,public as $$
declare doc text;num text;ser text;chave_nf text;
begin
 if tg_table_name='frota_gestao_lancamentos' then doc:=new.documento_fornecedor;chave_nf:=new.chave_fiscal;
 else select documento into doc from public.frota_gestao_fornecedores where fornecedor_id=new.fornecedor_id;chave_nf:=new.chave_acesso;end if;
 num:=ltrim(btrim(new.numero),'0');ser:=ltrim(btrim(new.serie),'0');
 perform pg_advisory_xact_lock(hashtextextended('frota-identidade:'||doc||':'||ser||':'||num,0));
 if chave_nf is not null then perform pg_advisory_xact_lock(hashtextextended('frota-chave:'||chave_nf,0));end if;
 if exists(select 1 from public.frota_gestao_edicoes_simplificadas e where e.nota_id<>new.id and public.frota_gestao_lancamento_ativo(e.nota_id) and
 ((regexp_replace(e.dados#>>'{nota,documento_fornecedor}','[^0-9]','','g')=doc and ltrim(btrim(e.dados#>>'{nota,numero}'),'0')=num and ltrim(btrim(coalesce(e.dados#>>'{nota,serie}','')),'0')=ser)
 or nullif(e.dados#>>'{nota,chave}','')=chave_nf)) then raise exception 'NF já registrada em uma versão do lançamento.';end if;
 if exists(select 1 from public.frota_gestao_lancamentos n where n.id<>new.id and public.frota_gestao_lancamento_ativo(n.id) and
 ((n.documento_fornecedor=doc and ltrim(btrim(n.numero),'0')=num and ltrim(btrim(n.serie),'0')=ser) or n.chave_fiscal=chave_nf)) then raise exception 'NF já registrada no lançamento simplificado.';end if;
 if tg_table_name='frota_gestao_lancamentos' and exists(select 1 from public.frota_gestao_notas n join public.frota_gestao_fornecedores f on f.fornecedor_id=n.fornecedor_id where
 (f.documento=doc and ltrim(btrim(n.numero),'0')=num and ltrim(btrim(n.serie),'0')=ser) or n.chave_acesso=chave_nf) then raise exception 'NF já registrada no contrato anterior.';end if;
 return new;
end $$;
revoke all on function public.frota_gestao_identidade_simplificada() from public,anon,authenticated;

-- Exclusivamente constraints UNIQUE destas colunas, sem CASCADE. PK/FKs permanecem.
do $$ declare c record;begin
 for c in select k.conname from pg_constraint k where k.conrelid='public.frota_gestao_lancamentos'::regclass and k.contype='u'
 and (select array_agg(a.attname::text order by a.attname) from unnest(k.conkey) x join pg_attribute a on a.attrelid=k.conrelid and a.attnum=x)
 in (array['chave_fiscal']::text[],array['documento_fornecedor','numero','serie']::text[])
 loop execute format('alter table public.frota_gestao_lancamentos drop constraint %I',c.conname);end loop;
 if not exists(select 1 from pg_trigger where tgrelid='public.frota_gestao_lancamentos'::regclass and tgname='identidade_entre_contratos' and tgenabled='O') then raise exception 'Trigger de identidade ausente; instalação cancelada.';end if;
end $$;

create or replace function public.frota_gestao_apagar_simplificado(p_id uuid,p_base uuid,p_chave uuid,p_motivo text,p_confirmado boolean)
returns jsonb language plpgsql security definer set search_path=pg_catalog,public as $$
declare anterior public.frota_gestao_exclusoes_simplificadas;n public.frota_gestao_lancamentos_vigentes;resultado jsonb;
begin
 perform public.frota_gestao_exigir_escrita(false);
 if not public.frota_gestao_usuario_ativo() then raise exception using errcode='42501',message='Conta ativa necessária.';end if;
 if p_id is null or p_base is null or p_chave is null or p_confirmado is distinct from true or length(btrim(coalesce(p_motivo,''))) not between 5 and 1000 then raise exception 'Informe motivo e confirme a exclusão integral.';end if;
 perform pg_advisory_xact_lock(hashtextextended('frota-exclusao-chave:'||p_chave::text,0));
 select * into anterior from public.frota_gestao_exclusoes_simplificadas where chave=p_chave;
 if found then
  if anterior.nota_id<>p_id or anterior.base_id<>p_base or anterior.motivo<>p_motivo then raise exception 'Solicitação já utilizada com outros dados.';end if;
  return anterior.recibo;
 end if;
 perform 1 from public.frota_gestao_lancamentos where id=p_id for update;
 select * into n from public.frota_gestao_lancamentos_vigentes where id=p_id;
 if not found then raise exception 'Lançamento inexistente ou já apagado. Atualize a Central.';end if;
 if n.versao_id<>p_base then raise exception 'O lançamento foi editado por outra sessão. Atualize antes de apagar.';end if;
 perform 1 from public.frota_gestao_lancamento_lotes where lancamento_id=p_id order by id for update;
 resultado:=jsonb_build_object('contrato','exclusao-simplificada-01','nota_id',p_id,'operacao_id',p_chave,'confirmado_em',clock_timestamp());
 insert into public.frota_gestao_exclusoes_simplificadas(nota_id,base_id,chave,motivo,criado_por,recibo) values(p_id,p_base,p_chave,p_motivo,auth.uid(),resultado);
 return resultado;
end $$;
revoke all on function public.frota_gestao_apagar_simplificado(uuid,uuid,uuid,text,boolean) from public,anon;
grant execute on function public.frota_gestao_apagar_simplificado(uuid,uuid,uuid,text,boolean) to authenticated;

create or replace function public.frota_gestao_recibo_exclusao_simplificada(p_id uuid,p_chave uuid)
returns jsonb language plpgsql stable security definer set search_path=pg_catalog,public as $$
begin
 if not public.frota_gestao_usuario_ativo() then raise exception using errcode='42501',message='Conta ativa necessária.';end if;
 return (select recibo from public.frota_gestao_exclusoes_simplificadas where nota_id=p_id and chave=p_chave);
end $$;
revoke all on function public.frota_gestao_recibo_exclusao_simplificada(uuid,uuid) from public,anon;
grant execute on function public.frota_gestao_recibo_exclusao_simplificada(uuid,uuid) to authenticated;
notify pgrst,'reload schema';
