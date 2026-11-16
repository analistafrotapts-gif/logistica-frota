-- PREPARAÇÃO LOCAL. Instalação manual futura após 105. Não altera NFs, custos ou registros legados.
begin;
set local lock_timeout='5s';
set local statement_timeout='60s';
do $$ begin
 if to_regprocedure('public.frota_gestao_retornar_estoque(uuid,uuid,text,boolean)') is null then raise exception 'Instale e verifique SQL105 antes de 106.';end if;
end $$;
create table if not exists public.frota_gestao_pneus_alinhamentos (
 id uuid primary key default gen_random_uuid(),chave uuid not null unique,fonte text not null check(length(fonte) between 10 and 220),
 numero_versao integer not null check(numero_versao>0),dados jsonb not null,pedido jsonb not null,
 motivo text not null check(length(btrim(motivo)) between 5 and 1000),
 criado_por uuid not null references public.perfis(id),criado_em timestamptz not null default clock_timestamp(),unique(fonte,numero_versao)
);
alter table public.frota_gestao_pneus_alinhamentos enable row level security;
revoke all on public.frota_gestao_pneus_alinhamentos from public,anon,authenticated;
grant select on public.frota_gestao_pneus_alinhamentos to authenticated;
drop policy if exists leitura_ativa on public.frota_gestao_pneus_alinhamentos;
create policy leitura_ativa on public.frota_gestao_pneus_alinhamentos for select to authenticated using(public.frota_gestao_usuario_ativo());
drop trigger if exists preservar_original on public.frota_gestao_pneus_alinhamentos;
create trigger preservar_original before update or delete on public.frota_gestao_pneus_alinhamentos for each row execute function public.frota_gestao_snapshot_simplificado();
drop trigger if exists registrar_auditoria on public.frota_gestao_pneus_alinhamentos;
create trigger registrar_auditoria after insert on public.frota_gestao_pneus_alinhamentos for each row execute function public.frota_gestao_auditar();

-- A fonte é a versão da NF: correção/exclusão financeira reflete imediatamente nesta leitura.
create or replace view public.frota_gestao_pneus_fontes with (security_barrier=true,security_invoker=true) as
select 'nf:'||n.id::text||':'||n.versao_id::text||':'||(l->>'veiculo_id')||':'||substring(l->>'centro_custo' from '[0-9]{3}$') fonte,n.id nota_id,n.versao_id,
 n.momento criado_em,p.nome autor,
 jsonb_build_object('veiculo_id',l->>'veiculo_id','placa',l->>'veiculo',
 'centro_custo',substring(l->>'centro_custo' from '[0-9]{3}$'),
 'data',substring(n.hbf->>'emissao_nf',1,10),'numero_nf',n.hbf->>'numero_nf',
 'fornecedor',n.hbf->>'fornecedor','valor',sum((l->>'valor_total')::numeric)::text,'observacao',string_agg(l->>'pecas_servicos','; ' order by l->>'id')) dados,
 exists(select 1 from public.frota_gestao_lancamentos_vigentes v where v.id=n.id and v.versao_id=n.versao_id) vigente,
 case when exists(select 1 from public.frota_gestao_exclusoes_simplificadas x where x.nota_id=n.id) then 'NF excluída'
 when not exists(select 1 from public.frota_gestao_lancamentos_vigentes v where v.id=n.id and v.versao_id=n.versao_id) then 'NF substituída' else 'NF vigente' end situacao
from (
 select id,versao_id,hbf,finalizada_em momento,criado_por from public.frota_gestao_lancamentos
 union all select nota_id,id,hbf,criado_em,criado_por from public.frota_gestao_edicoes_simplificadas
) n cross join lateral jsonb_array_elements(n.hbf->'linhas') l join public.perfis p on p.id=n.criado_por
where public.frota_gestao_usuario_ativo()
 and coalesce(l->>'veiculo_id','') ~ '^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$'
 and translate(lower(coalesce(l->>'classificacao','')),'áàãâéêíóôõúüç','aaaaeeiooouuc') ~ '(^|[^a-z])(alinhamento|balanceamento)([^a-z]|$)'
group by n.id,n.versao_id,n.momento,n.hbf,p.nome,l->>'veiculo_id',l->>'veiculo',substring(l->>'centro_custo' from '[0-9]{3}$');
revoke all on public.frota_gestao_pneus_fontes from public,anon,authenticated;
grant select on public.frota_gestao_pneus_fontes to authenticated;

create or replace function public.frota_gestao_alinhamentos()
returns jsonb language plpgsql stable security definer set search_path=pg_catalog,public as $$
declare registros jsonb;historico jsonb;veiculos jsonb;
begin
 if not public.frota_gestao_usuario_ativo() then raise exception using errcode='42501',message='Conta ativa necessária.';end if;
 select coalesce(jsonb_agg(to_jsonb(r) order by r.dados->>'data' desc,r.fonte),'[]') into registros from (
  select f.fonte,'nf'::text origem,f.nota_id,coalesce(a.dados,f.dados) dados,a.id revisao_id,
   coalesce(a.criado_em,f.criado_em) atualizado_em,coalesce(p.nome,f.autor) autor,a.id is null data_sugerida
  from public.frota_gestao_pneus_fontes f
  left join lateral (select * from public.frota_gestao_pneus_alinhamentos x where x.fonte=f.fonte order by numero_versao desc limit 1) a on true
  left join public.perfis p on p.id=a.criado_por where f.vigente
  union all
  select a.fonte,'manual',null::uuid,a.dados,a.id,a.criado_em,p.nome,false from public.frota_gestao_pneus_alinhamentos a
  join public.perfis p on p.id=a.criado_por where a.fonte like 'manual:%' and not exists(select 1 from public.frota_gestao_pneus_alinhamentos b where b.fonte=a.fonte and b.numero_versao>a.numero_versao)
 ) r;
 select coalesce(jsonb_agg(to_jsonb(e) order by e.data desc,e.id),'[]') into historico from (
  select f.fonte id,f.fonte,'Importação automática da NF'::text evento,f.dados,f.criado_em data,f.autor,
   'Data sugerida pela emissão da NF'::text motivo,f.situacao
  from public.frota_gestao_pneus_fontes f
  union all
  select a.id::text,a.fonte,case when a.numero_versao=1 and a.fonte like 'manual:%' then 'Lançamento manual' else 'Correção do registro' end,
   a.dados,a.criado_em,p.nome,a.motivo,case when a.fonte like 'manual:%' then 'Registro manual' else coalesce(f.situacao,'Origem indisponível') end
  from public.frota_gestao_pneus_alinhamentos a join public.perfis p on p.id=a.criado_por left join public.frota_gestao_pneus_fontes f on f.fonte=a.fonte
 ) e;
 select coalesce(jsonb_agg(to_jsonb(v) order by placa),'[]') into veiculos from public.frota_gestao_veiculos v;
 return jsonb_build_object('contrato','alinhamentos-01','registros',registros,'historico',historico,'veiculos',veiculos,'consultado_em',statement_timestamp());
end $$;
revoke all on function public.frota_gestao_alinhamentos() from public,anon;
grant execute on function public.frota_gestao_alinhamentos() to authenticated;

create or replace function public.frota_gestao_salvar_alinhamento(p_chave uuid,p_fonte text,p_dados jsonb,p_motivo text,p_confirmado boolean)
returns jsonb language plpgsql security definer set search_path=pg_catalog,public as $$
declare anterior public.frota_gestao_pneus_alinhamentos;pedido jsonb;vid uuid;placa_atual text;dados jsonb;versao integer;dia date;nota uuid;
begin
 perform public.frota_gestao_exigir_escrita(false);
 if not public.frota_gestao_usuario_ativo() then raise exception using errcode='42501',message='Conta ativa necessária.';end if;
 if p_chave is null or p_confirmado is distinct from true or p_fonte is null or length(p_fonte)>220 or p_dados is null or jsonb_typeof(p_dados)<>'object' or octet_length(p_dados::text)>8192 or p_motivo is null or length(btrim(p_motivo)) not between 5 and 1000 then raise exception 'Confira o lançamento e informe um motivo com 5 a 1000 caracteres.';end if;
 pedido:=jsonb_build_object('fonte',p_fonte,'dados',p_dados,'motivo',p_motivo);
 perform pg_advisory_xact_lock(hashtextextended('frota-alinhamento-chave:'||p_chave::text,0));
 select * into anterior from public.frota_gestao_pneus_alinhamentos where chave=p_chave;
 if found then if anterior.pedido<>pedido then raise exception 'Chave já confirmada com outros dados.';end if;return jsonb_build_object('id',anterior.id,'chave',anterior.chave,'fonte',anterior.fonte,'confirmado_em',anterior.criado_em);end if;
 if p_fonte like 'nf:%' then
  select nota_id into nota from public.frota_gestao_pneus_fontes where fonte=p_fonte and vigente;
  if nota is null then raise exception 'A NF foi editada ou excluída. Atualize antes de corrigir o registro.';end if;
  perform 1 from public.frota_gestao_lancamentos where id=nota for update;
  if not exists(select 1 from public.frota_gestao_pneus_fontes where fonte=p_fonte and vigente) then raise exception 'A versão da NF mudou. Atualize a consulta.';end if;
 elsif p_fonte !~ '^manual:[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$' then raise exception 'Origem do lançamento inválida.';end if;
 perform pg_advisory_xact_lock(hashtextextended('frota-alinhamento-fonte:'||p_fonte,0));
 select id,placa into vid,placa_atual from public.frota_gestao_veiculos where id=(p_dados->>'veiculo_id')::uuid;
 if vid is null then raise exception 'Selecione um veículo cadastrado.';end if;
 if coalesce(p_dados->>'data','') !~ '^[0-9]{4}-[0-9]{2}-[0-9]{2}$' then raise exception 'Informe a data realizada.';end if;
 dia:=(p_dados->>'data')::date;
 if dia>(clock_timestamp() at time zone 'America/Sao_Paulo')::date then raise exception 'A data realizada não pode estar no futuro.';end if;
 if coalesce(p_dados->>'centro_custo','') not in ('101','201','301','401','501') or coalesce(btrim(p_dados->>'fornecedor'),'')='' or length(p_dados->>'fornecedor')>200 or length(coalesce(p_dados->>'numero_nf',''))>60 or length(coalesce(p_dados->>'observacao',''))>2000 then raise exception 'Confira centro de custo, fornecedor, número da NF e observação.';end if;
 if coalesce(p_dados->>'valor','') !~ '^[0-9]{1,14}(\.[0-9]{1,2})?$' then raise exception 'Informe um valor monetário válido.';end if;
 dados:=jsonb_build_object('veiculo_id',vid,'placa',placa_atual,'data',dia::text,'centro_custo',p_dados->>'centro_custo','fornecedor',btrim(p_dados->>'fornecedor'),'numero_nf',coalesce(btrim(p_dados->>'numero_nf'),''),'valor',((p_dados->>'valor')::numeric(18,2))::text,'observacao',coalesce(p_dados->>'observacao',''));
 select coalesce(max(numero_versao),0)+1 into versao from public.frota_gestao_pneus_alinhamentos where fonte=p_fonte;
 insert into public.frota_gestao_pneus_alinhamentos(chave,fonte,numero_versao,dados,pedido,motivo,criado_por)
 values(p_chave,p_fonte,versao,dados,pedido,btrim(p_motivo),auth.uid()) returning * into anterior;
 return jsonb_build_object('id',anterior.id,'chave',anterior.chave,'fonte',anterior.fonte,'confirmado_em',anterior.criado_em);
end $$;
revoke all on function public.frota_gestao_salvar_alinhamento(uuid,text,jsonb,text,boolean) from public,anon;
grant execute on function public.frota_gestao_salvar_alinhamento(uuid,text,jsonb,text,boolean) to authenticated;
notify pgrst,'reload schema';
commit;
