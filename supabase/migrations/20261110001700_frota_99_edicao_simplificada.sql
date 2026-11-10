-- MANUAL: após 95, 96, 97 e 98 revisados e seus predecessores. Não libera a chave 92.
-- Preserva originais, OS e lotes anteriores; edição cria nova versão auditável.
create table if not exists public.frota_gestao_edicoes_simplificadas (
 id uuid primary key, nota_id uuid not null references public.frota_gestao_lancamentos(id),
 numero_versao integer not null check(numero_versao>=2), base_id uuid not null,
 chave uuid not null unique, dados jsonb not null, hbf jsonb not null, recibo jsonb not null,
 motivo text not null check(length(btrim(motivo)) between 5 and 1000),
 criado_por uuid not null references public.perfis(id), criado_em timestamptz not null default clock_timestamp(),
 unique(nota_id,numero_versao)
);
alter table public.frota_gestao_edicoes_simplificadas enable row level security;
revoke all on public.frota_gestao_edicoes_simplificadas from public,anon,authenticated;
grant select on public.frota_gestao_edicoes_simplificadas to authenticated;
drop policy if exists leitura_ativa on public.frota_gestao_edicoes_simplificadas;
create policy leitura_ativa on public.frota_gestao_edicoes_simplificadas for select to authenticated using(public.frota_gestao_usuario_ativo());
drop trigger if exists preservar_original on public.frota_gestao_edicoes_simplificadas;
create trigger preservar_original before update or delete on public.frota_gestao_edicoes_simplificadas for each row execute function public.frota_gestao_snapshot_simplificado();
drop trigger if exists registrar_auditoria on public.frota_gestao_edicoes_simplificadas;
create trigger registrar_auditoria after insert on public.frota_gestao_edicoes_simplificadas for each row execute function public.frota_gestao_auditar();

create or replace view public.frota_gestao_lancamentos_vigentes with (security_barrier=true) as
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
where public.frota_gestao_usuario_ativo();
create or replace view public.frota_gestao_lotes_vigentes with (security_barrier=true) as
select l.* from public.frota_gestao_lancamento_lotes l join public.frota_gestao_lancamentos_vigentes n on n.id=l.lancamento_id
where exists(select 1 from jsonb_array_elements(n.hbf->'linhas') h where h->>'id'=l.parcela_id);
revoke all on public.frota_gestao_lancamentos_vigentes,public.frota_gestao_lotes_vigentes from public,anon,authenticated;
grant select on public.frota_gestao_lancamentos_vigentes,public.frota_gestao_lotes_vigentes to authenticated;

-- A trava compartilhada também verifica versões após eventual espera por outra conexão.
create or replace function public.frota_gestao_identidade_simplificada()
returns trigger language plpgsql security definer set search_path=pg_catalog,public as $$
declare doc text;num text;ser text;chave_nf text;
begin
 if tg_table_name='frota_gestao_lancamentos' then doc:=new.documento_fornecedor;chave_nf:=new.chave_fiscal;
 else select documento into doc from public.frota_gestao_fornecedores where fornecedor_id=new.fornecedor_id;chave_nf:=new.chave_acesso;end if;
 num:=ltrim(btrim(new.numero),'0');ser:=ltrim(btrim(new.serie),'0');
 perform pg_advisory_xact_lock(hashtextextended('frota-identidade:'||doc||':'||ser||':'||num,0));
 if chave_nf is not null then perform pg_advisory_xact_lock(hashtextextended('frota-chave:'||chave_nf,0));end if;
 if exists(select 1 from public.frota_gestao_edicoes_simplificadas e where e.nota_id<>new.id and
 ((regexp_replace(e.dados#>>'{nota,documento_fornecedor}','[^0-9]','','g')=doc and ltrim(btrim(e.dados#>>'{nota,numero}'),'0')=num and ltrim(btrim(coalesce(e.dados#>>'{nota,serie}','')),'0')=ser)
 or nullif(e.dados#>>'{nota,chave}','')=chave_nf)) then raise exception 'NF já registrada em uma versão do lançamento.';end if;
 if tg_table_name='frota_gestao_lancamentos' then
  if exists(select 1 from public.frota_gestao_notas n join public.frota_gestao_fornecedores f on f.fornecedor_id=n.fornecedor_id where
   (f.documento=doc and ltrim(btrim(n.numero),'0')=num and ltrim(btrim(n.serie),'0')=ser) or n.chave_acesso=chave_nf) then raise exception 'NF já registrada no contrato anterior.';end if;
 else
  if exists(select 1 from public.frota_gestao_lancamentos n where (n.documento_fornecedor=doc and n.numero=num and n.serie=ser) or n.chave_fiscal=chave_nf) then raise exception 'NF já registrada no lançamento simplificado.';end if;
 end if;
 return new;
end $$;
revoke all on function public.frota_gestao_identidade_simplificada() from public,anon,authenticated;

-- A validação 95/98 continua sendo a fonte das regras financeiras e de cadastro.
do $$ declare fonte text; original text; substituto text; extra text;
begin
 fonte:=replace(pg_get_functiondef('public.frota_gestao_validar_simplificado(jsonb,uuid,bigint)'::regprocedure),chr(13),'');
 extra:=$texto$
 if exists(select 1 from public.frota_gestao_edicoes_simplificadas e where e.nota_id<>p_id and
 ((regexp_replace(e.dados#>>'{nota,documento_fornecedor}','[^0-9]','','g')=conferencia.documento
 and ltrim(btrim(e.dados#>>'{nota,numero}'),'0')=conferencia.numero and ltrim(btrim(coalesce(e.dados#>>'{nota,serie}','')),'0')=conferencia.serie)
 or nullif(e.dados#>>'{nota,chave}','')=nullif(n->>'chave',''))) then raise exception 'NF já registrada em uma versão anterior. Consulte a Central.';end if;
 $texto$;
 if position('frota_gestao_edicoes_simplificadas' in fonte)=0 then
  if position(' for item in select' in fonte)=0 then raise exception 'Validador 95/98 divergente. Confira os scripts antes de instalar 99.';end if;
  fonte:=replace(fonte,' for item in select',extra||' for item in select');execute fonte;
 end if;
 original:=$texto$if exists(select 1 from public.frota_gestao_lancamentos where (documento_fornecedor=conferencia.documento and frota_gestao_lancamentos.numero=conferencia.numero and frota_gestao_lancamentos.serie=conferencia.serie)
  or chave_fiscal=nullif(n->>'chave',''))$texto$;
 substituto:=$texto$if exists(select 1 from public.frota_gestao_lancamentos where id<>p_id and ((documento_fornecedor=conferencia.documento and frota_gestao_lancamentos.numero=conferencia.numero and frota_gestao_lancamentos.serie=conferencia.serie)
  or chave_fiscal=nullif(n->>'chave','')))$texto$;
 if position(original in fonte)=0 then raise exception 'Verificação de identidade do SQL 95 divergente. Instalação 99 cancelada.';end if;
 fonte:=replace(replace(fonte,'public.frota_gestao_validar_simplificado(','public.frota_gestao_validar_edicao_simplificada('),original,substituto);execute fonte;
end $$;
revoke all on function public.frota_gestao_validar_edicao_simplificada(jsonb,uuid,bigint) from public,anon,authenticated;

create or replace function public.frota_gestao_carregar_edicao_simplificada(p_id uuid)
returns jsonb language plpgsql stable security definer set search_path=pg_catalog,public as $$
declare n public.frota_gestao_lancamentos_vigentes; historico jsonb;
begin
 if not public.frota_gestao_usuario_ativo() then raise exception using errcode='42501',message='Conta ativa necessária.';end if;
 select * into n from public.frota_gestao_lancamentos_vigentes where id=p_id;
 if not found then raise exception 'Lançamento não encontrado.';end if;
 select jsonb_agg(to_jsonb(x) order by x.numero_versao desc) into historico from (
  select 1 numero_versao,a.versao_id,a.hbf,a.finalizada_em criado_em,p.nome autor,'Lançamento original' motivo,a.dados from public.frota_gestao_lancamentos a join public.perfis p on p.id=a.criado_por where a.id=p_id
  union all select e.numero_versao,e.id,e.hbf,e.criado_em,p.nome,e.motivo,e.dados from public.frota_gestao_edicoes_simplificadas e join public.perfis p on p.id=e.criado_por where e.nota_id=p_id
 ) x;
 return jsonb_build_object('contrato','edicao-simplificada-01','registro',to_jsonb(n)||jsonb_build_object('total',n.total::text),
  'bloqueio',case when exists(select 1 from public.frota_gestao_lancamento_aplicacoes a join public.frota_gestao_lancamento_lotes l on l.id=a.lote_id where l.lancamento_id=p_id) then 'Esta NF possui peças já aplicadas. A edição depende de um fluxo de estorno controlado para preservar estoque e custos.' else null end,'historico',historico);
end $$;
revoke all on function public.frota_gestao_carregar_edicao_simplificada(uuid) from public,anon;
grant execute on function public.frota_gestao_carregar_edicao_simplificada(uuid) to authenticated;

create or replace function public.frota_gestao_recibo_edicao_simplificada(p_id uuid,p_chave uuid)
returns jsonb language plpgsql stable security definer set search_path=pg_catalog,public as $$
begin
 if not public.frota_gestao_usuario_ativo() then raise exception using errcode='42501',message='Conta ativa necessária.';end if;
 if p_id is null or p_chave is null then raise exception 'Identificação da solicitação inválida.';end if;
 return (select recibo from public.frota_gestao_edicoes_simplificadas where nota_id=p_id and chave=p_chave);
end $$;
revoke all on function public.frota_gestao_recibo_edicao_simplificada(uuid,uuid) from public,anon;
grant execute on function public.frota_gestao_recibo_edicao_simplificada(uuid,uuid) to authenticated;

create or replace function public.frota_gestao_confirmar_edicao_simplificada(p_id uuid,p_base uuid,p_chave uuid,p_dados jsonb,p_motivo text,p_confirmado boolean)
returns jsonb language plpgsql security definer set search_path=pg_catalog,public as $$
declare atual public.frota_gestao_lancamentos_vigentes; anterior public.frota_gestao_edicoes_simplificadas;
 n jsonb;hbf jsonb;l jsonb;p jsonb;linhas jsonb:='[]';versao uuid:=gen_random_uuid();numero_versao integer;vid uuid;numero_os bigint;resultado jsonb;momento timestamptz:=clock_timestamp();
begin
 perform public.frota_gestao_exigir_escrita(false);
 if not public.frota_gestao_usuario_ativo() then raise exception using errcode='42501',message='Conta ativa necessária.';end if;
 if p_id is null or p_base is null or p_chave is null or p_confirmado is distinct from true or length(btrim(coalesce(p_motivo,''))) not between 5 and 1000 then raise exception 'Confira a edição, informe o motivo e confirme as alterações.';end if;
 perform pg_advisory_xact_lock(hashtextextended('frota-edicao-chave:'||p_chave::text,0));
 select * into anterior from public.frota_gestao_edicoes_simplificadas where chave=p_chave;
 if found then
  if anterior.nota_id<>p_id or anterior.base_id<>p_base or anterior.dados is distinct from p_dados or anterior.motivo<>p_motivo then raise exception 'Solicitação já confirmada com outros dados.';end if;
  return anterior.recibo;
 end if;
 perform 1 from public.frota_gestao_lancamentos where id=p_id for update;
 if not found then raise exception 'Lançamento não encontrado.';end if;
 select * into atual from public.frota_gestao_lancamentos_vigentes where id=p_id;
 if atual.versao_id<>p_base then raise exception 'Este lançamento foi editado por outra sessão. Reabra a consulta para editar a versão atual.';end if;
 perform 1 from public.frota_gestao_lancamento_lotes where lancamento_id=p_id order by id for update;
 if exists(select 1 from public.frota_gestao_lancamento_aplicacoes a join public.frota_gestao_lancamento_lotes t on t.id=a.lote_id where t.lancamento_id=p_id) then raise exception 'Esta NF possui peças já aplicadas. A edição requer estorno controlado; nenhum saldo ou custo foi alterado.';end if;
 n:=p_dados->'nota';
 perform pg_advisory_xact_lock(hashtextextended('frota-identidade:'||regexp_replace(n->>'documento_fornecedor','[^0-9]','','g')||':'||ltrim(btrim(coalesce(n->>'serie','')),'0')||':'||ltrim(btrim(n->>'numero'),'0'),0));
 if nullif(n->>'chave','') is not null then perform pg_advisory_xact_lock(hashtextextended('frota-chave:'||(n->>'chave'),0));end if;
 perform public.frota_gestao_validar_edicao_simplificada(p_dados,p_id,1);
 numero_versao:=coalesce((atual.hbf->>'numero_versao')::integer,1)+1;
 hbf:=atual.hbf||jsonb_build_object('emissao_id',p_chave,'versao_id',versao,'numero_versao',numero_versao,
  'numero_nf',n->>'numero','serie',n->>'serie','chave_acesso',nullif(n->>'chave',''),'fornecedor',n->>'fornecedor','documento_fornecedor',n->>'documento_fornecedor',
  'unidade_fiscal',(select nome from public.operacoes where id=(p_dados->>'unidadeFiscal')::uuid),'emissao_nf',substring(n->>'emissao',1,10),'gerado_em',momento,
  'autor',(select nome from public.perfis where id=auth.uid()),'autor_id',auth.uid(),'total',n->>'total',
  'desconto',(select sum((x->>'desconto')::numeric)::text from jsonb_array_elements(n->'itens') x),'acrescimo',(select sum((x->>'acrescimo')::numeric)::text from jsonb_array_elements(n->'itens') x));
 for l in select * from jsonb_array_elements(n#>'{dados_fiscais,conferencia_hbf,linhas}') loop
  p:=p_dados#>array['finalizacao','itens',split_part(l->>'id',':',1),'rateios',split_part(l->>'id',':',2)];
  l:=l||jsonb_build_object('numero_nf',n->>'numero','quantidade',p->>'quantidade','unidade',(select x->>'unidade' from jsonb_array_elements(n->'itens') x where x->>'numero'=split_part(l->>'id',':',1)),
   'manutencao',p_dados#>>array['finalizacao','itens',split_part(l->>'id',':',1),'manutencao']);
  if l->>'veiculo'<>'Estoque' then
   select id into vid from public.frota_gestao_veiculos where upper(regexp_replace(placa,'[^A-Za-z0-9]','','g'))=upper(regexp_replace(l->>'veiculo','[^A-Za-z0-9]','','g'));
   select numero into numero_os from public.frota_gestao_lancamento_os where lancamento_id=p_id and veiculo_id=vid;
   if not found then
    select nextval(pg_get_serial_sequence('public.frota_gestao_os','numero')::regclass) into numero_os;
    insert into public.frota_gestao_lancamento_os(lancamento_id,veiculo_id,numero,criado_por) values(p_id,vid,numero_os,auth.uid());
   end if;
   l:=l||jsonb_build_object('veiculo_id',vid,'numero_os',numero_os::text);
  else
   l:=l||jsonb_build_object('numero_os','—','centro_custo','Estoque','centro_custo_operacional',null,'veiculo_id',null);
   insert into public.frota_gestao_lancamento_lotes(lancamento_id,parcela_id,descricao,unidade,quantidade,valor,unidade_fiscal_id,criado_por)
    values(p_id,versao::text||':'||(l->>'id'),l->>'pecas_servicos',l->>'unidade',(p->>'quantidade')::numeric,(l->>'valor_total')::numeric,(p_dados->>'unidadeFiscal')::uuid,auth.uid());
  end if;
  linhas:=linhas||jsonb_build_array(l||jsonb_build_object('id',versao::text||':'||(l->>'id')));
 end loop;
 hbf:=hbf||jsonb_build_object('linhas',linhas);
 resultado:=jsonb_build_object('contrato','edicao-simplificada-01','nota_id',p_id,'versao_id',versao,'operacao_id',p_chave,'numero_versao',numero_versao,'confirmado_em',momento);
 insert into public.frota_gestao_edicoes_simplificadas(id,nota_id,numero_versao,base_id,chave,dados,hbf,recibo,motivo,criado_por)
 values(versao,p_id,numero_versao,p_base,p_chave,p_dados,hbf,resultado,p_motivo,auth.uid());
 return resultado;
end $$;
revoke all on function public.frota_gestao_confirmar_edicao_simplificada(uuid,uuid,uuid,jsonb,text,boolean) from public,anon;
grant execute on function public.frota_gestao_confirmar_edicao_simplificada(uuid,uuid,uuid,jsonb,text,boolean) to authenticated;

-- Leituras financeiras passam a considerar somente a versão vigente. Reaplicar 95–98 exige reaplicar 99.
do $$ declare assinatura text;fonte text;begin
 foreach assinatura in array array['frota_gestao_listar_simplificado()','frota_gestao_lotes_simplificado()','frota_gestao_estoque_simplificado()','frota_gestao_custos_simplificados()','frota_gestao_dashboard_simplificado()'] loop
  fonte:=pg_get_functiondef(('public.'||assinatura)::regprocedure);
  fonte:=regexp_replace(fonte,'public[.]frota_gestao_lancamentos\M','public.frota_gestao_lancamentos_vigentes','g');
  fonte:=regexp_replace(fonte,'public[.]frota_gestao_lancamento_lotes\M','public.frota_gestao_lotes_vigentes','g');execute fonte;
 end loop;
 fonte:=pg_get_functiondef('public.frota_gestao_aplicar_simplificado(uuid,jsonb,boolean)'::regprocedure);
 if position('frota_gestao_lotes_vigentes' in fonte)=0 then
  fonte:=replace(fonte,' select * into lote from',
   ' perform 1 from public.frota_gestao_lancamentos where id=(select lancamento_id from public.frota_gestao_lancamento_lotes where id=(p_dados->>''lote_id'')::uuid) for update; select * into lote from');
  fonte:=replace(fonte,' select id,placa into veiculo,placa_atual',
   ' if not exists(select 1 from public.frota_gestao_lotes_vigentes where id=lote.id) then raise exception ''Esta entrada pertence a uma versão anterior. Atualize o estoque.'';end if; select id,placa into veiculo,placa_atual');
  if position('Esta entrada pertence' in fonte)=0 then raise exception 'Função de aplicação 96/98 divergente. Instalação 99 cancelada.';end if;execute fonte;
 end if;
end $$;
notify pgrst,'reload schema';
