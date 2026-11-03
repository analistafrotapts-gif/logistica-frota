-- Origem: SQL 95 do módulo Gestão da Frota (extraído do laboratório, sem alterações de lógica).
-- Execução MANUAL após 92 e 84 -> 85 -> 86 -> 87 -> 88 -> 89 -> 90 -> 91 verificados.
-- 93/94 são de outro módulo e não são dependências. Não instala nem libera produção.
-- Contrato próprio: preserva documentos/cadastros anteriores sem os converter.
-- (begin/commit removidos: o Supabase CLI já executa cada migration em uma transação)
create table if not exists public.frota_gestao_lancamentos (
 id uuid primary key default gen_random_uuid(), versao_id uuid not null unique default gen_random_uuid(),
 rascunho_id uuid not null unique references public.frota_gestao_rascunhos(id),
 chave uuid not null unique, revisao bigint not null, numero text not null, serie text not null,
 documento_fornecedor text not null check(documento_fornecedor ~ '^([0-9]{11}|[0-9]{14})$'),
 fornecedor text not null check(btrim(fornecedor)<>''), chave_fiscal text unique,
 unidade_fiscal_id uuid not null references public.operacoes(id), emissao date not null,
 total numeric(18,2) not null check(total>=0), dados jsonb not null, hbf jsonb not null, recibo jsonb not null,
 finalizada_em timestamptz not null default clock_timestamp(), criado_por uuid not null references public.perfis(id),
 unique(documento_fornecedor,serie,numero)
);
create table if not exists public.frota_gestao_lancamento_os (
 id uuid primary key default gen_random_uuid(), lancamento_id uuid not null references public.frota_gestao_lancamentos(id) deferrable initially deferred,
 veiculo_id uuid not null references public.veiculos(id), numero bigint not null unique,
 estado text not null default 'aberta' check(estado='aberta'), criado_por uuid not null references public.perfis(id),
 criado_em timestamptz not null default clock_timestamp(), unique(lancamento_id,veiculo_id)
);
create table if not exists public.frota_gestao_lancamento_lotes (
 id uuid primary key default gen_random_uuid(), lancamento_id uuid not null references public.frota_gestao_lancamentos(id) deferrable initially deferred,
 parcela_id text not null, descricao text not null, unidade text not null,
 quantidade numeric(20,6) not null check(quantidade>0), valor numeric(18,2) not null check(valor>=0),
 unidade_fiscal_id uuid not null references public.operacoes(id),
 criado_por uuid not null references public.perfis(id), criado_em timestamptz not null default clock_timestamp(),
 unique(lancamento_id,parcela_id)
 -- Centro de custo pertence à aplicação futura, não à aquisição para estoque.
);
create or replace function public.frota_gestao_snapshot_simplificado()
returns trigger language plpgsql set search_path=pg_catalog,public as $$
begin raise exception 'Lançamentos confirmados e entradas originais são históricos imutáveis.';end $$;
revoke all on function public.frota_gestao_snapshot_simplificado() from public,anon,authenticated;
do $$ declare nome text;begin
 foreach nome in array array['lancamentos','lancamento_os','lancamento_lotes'] loop
  execute format('alter table public.%I enable row level security','frota_gestao_'||nome);
  execute format('revoke all on public.%I from public,anon,authenticated','frota_gestao_'||nome);
  execute format('grant select on public.%I to authenticated','frota_gestao_'||nome);
  execute format('drop policy if exists leitura_ativa on public.%I','frota_gestao_'||nome);
  execute format('create policy leitura_ativa on public.%I for select to authenticated using(public.frota_gestao_usuario_ativo())','frota_gestao_'||nome);
  execute format('drop trigger if exists registrar_auditoria on public.%I','frota_gestao_'||nome);
  execute format('create trigger registrar_auditoria after insert or update or delete on public.%I for each row execute function public.frota_gestao_auditar()','frota_gestao_'||nome);
  execute format('drop trigger if exists preservar_original on public.%I','frota_gestao_'||nome);
  execute format('create trigger preservar_original before update or delete on public.%I for each row execute function public.frota_gestao_snapshot_simplificado()','frota_gestao_'||nome);
 end loop;
end $$;

-- Duplicidade fiscal entre o contrato anterior do novo módulo e o simplificado.
-- Não altera ACL/RLS nem consulta ou modifica tabelas Gestran.
create or replace function public.frota_gestao_identidade_simplificada()
returns trigger language plpgsql security definer set search_path=pg_catalog,public as $$
declare doc text; num text; ser text; chave_nf text;
begin
 if tg_table_name='frota_gestao_lancamentos' then
  doc:=new.documento_fornecedor;chave_nf:=new.chave_fiscal;
 else select documento into doc from public.frota_gestao_fornecedores where fornecedor_id=new.fornecedor_id;chave_nf:=new.chave_acesso;end if;
 num:=ltrim(btrim(new.numero),'0');ser:=ltrim(btrim(new.serie),'0');
 perform pg_advisory_xact_lock(hashtextextended('frota-identidade:'||doc||':'||ser||':'||num,0));
 if chave_nf is not null then perform pg_advisory_xact_lock(hashtextextended('frota-chave:'||chave_nf,0));end if;
 if tg_table_name='frota_gestao_lancamentos' then
  if exists(select 1 from public.frota_gestao_notas n join public.frota_gestao_fornecedores f on f.fornecedor_id=n.fornecedor_id where
   (f.documento=doc and ltrim(btrim(n.numero),'0')=num and ltrim(btrim(n.serie),'0')=ser) or n.chave_acesso=chave_nf) then raise exception 'NF já registrada no contrato anterior.';end if;
 else
  if exists(select 1 from public.frota_gestao_lancamentos n where (n.documento_fornecedor=doc and n.numero=num and n.serie=ser) or n.chave_fiscal=chave_nf) then raise exception 'NF já registrada no lançamento simplificado.';end if;
 end if;
 return new;
end $$;
revoke all on function public.frota_gestao_identidade_simplificada() from public,anon,authenticated;
drop trigger if exists identidade_entre_contratos on public.frota_gestao_notas;
create trigger identidade_entre_contratos before insert on public.frota_gestao_notas for each row execute function public.frota_gestao_identidade_simplificada();
drop trigger if exists identidade_entre_contratos on public.frota_gestao_lancamentos;
create trigger identidade_entre_contratos before insert on public.frota_gestao_lancamentos for each row execute function public.frota_gestao_identidade_simplificada();

-- Somente leitura: valida os campos efetivamente presentes nas quatro telas novas.
create or replace function public.frota_gestao_validar_simplificado(p_dados jsonb,p_id uuid,p_revisao bigint)
returns jsonb language plpgsql stable security definer set search_path=pg_catalog,public as $$
<<conferencia>>
declare d jsonb; n jsonb; h jsonb; l jsonb; item jsonb; p jsonb;
 soma numeric:=0; bruto numeric; desconto numeric; acrescimo numeric; liquido numeric; q numeric; v numeric;
 soma_q numeric; soma_v numeric; soma_d numeric; numero text; serie text; documento text; placa text; veiculo uuid;
 ids text[]:='{}'; item_ids text[]:='{}'; qtd integer; linhas jsonb:='[]'; relatorio jsonb;
begin
 if not public.frota_gestao_usuario_ativo() then raise exception using errcode='42501',message='Conta ativa e senha definitiva necessárias.';end if;
 if p_dados is null or jsonb_typeof(p_dados)<>'object' or p_dados->>'formato' is distinct from '1'
  or octet_length(convert_to(p_dados::text,'UTF8'))>1048576 then raise exception 'Confira os dados do lançamento; limite de 1 MiB de informações estruturadas.';end if;
 d:=p_dados;n:=d->'nota';h:=n#>'{dados_fiscais,conferencia_hbf}';
 if jsonb_typeof(n->'itens') is distinct from 'array' or jsonb_array_length(n->'itens') not between 1 and 1000
  or jsonb_typeof(h->'linhas') is distinct from 'array' or jsonb_array_length(h->'linhas') not between 1 and 10000 then raise exception 'Confira os itens e as linhas do HBF antes de finalizar.';end if;
 numero:=ltrim(btrim(n->>'numero'),'0');serie:=ltrim(btrim(coalesce(n->>'serie','')),'0');
 documento:=regexp_replace(n->>'documento_fornecedor','[^0-9]','','g');
 if coalesce(numero,'') !~ '^[0-9]{1,20}$' or coalesce(serie,'') !~ '^[0-9]{0,20}$'
  or coalesce(documento,'') !~ '^([0-9]{11}|[0-9]{14})$' or nullif(btrim(n->>'fornecedor'),'') is null then raise exception 'Confira número, série e identificação do fornecedor.';end if;
 if nullif(n->>'chave','') is not null and (n->>'chave') !~ '^[0-9]{44}$' then raise exception 'Confira a chave fiscal ou deixe vazia quando não existir.';end if;
 if coalesce(substring(n->>'emissao',1,10),'') !~ '^[0-9]{4}-[0-9]{2}-[0-9]{2}$' then raise exception 'Confira a data de emissão.';end if;
 perform substring(n->>'emissao',1,10)::date;
 if not exists(select 1 from public.operacoes where id=nullif(d->>'unidadeFiscal','')::uuid and ativa) then raise exception 'Selecione Patos ou Sumé na unidade fiscal.';end if;
 if exists(select 1 from public.frota_gestao_lancamentos where (documento_fornecedor=conferencia.documento and frota_gestao_lancamentos.numero=conferencia.numero and frota_gestao_lancamentos.serie=conferencia.serie)
  or chave_fiscal=nullif(n->>'chave','')) then raise exception 'NF já lançada. Consulte a Central de Notas.';end if;
 if exists(select 1 from public.frota_gestao_notas a join public.frota_gestao_fornecedores f on f.fornecedor_id=a.fornecedor_id
  where (f.documento=conferencia.documento and ltrim(btrim(a.numero),'0')=conferencia.numero and ltrim(btrim(a.serie),'0')=conferencia.serie) or a.chave_acesso=nullif(n->>'chave','')) then raise exception 'NF já registrada no histórico anterior do módulo.';end if;
 for item in select * from jsonb_array_elements(n->'itens') loop
  if coalesce(item->>'numero','') !~ '^[1-9][0-9]{0,5}$' or item->>'numero'=any(item_ids) or nullif(btrim(item->>'descricao'),'') is null then raise exception 'Confira a identificação dos itens fiscais.';end if;
  item_ids:=array_append(item_ids,item->>'numero');
  q:=public.frota_gestao_decimal_nf(item->>'quantidade',6);
  perform public.frota_gestao_decimal_nf(item->>'unitario',10);
  bruto:=public.frota_gestao_decimal_nf(item->>'bruto',2);desconto:=public.frota_gestao_decimal_nf(item->>'desconto',2);acrescimo:=public.frota_gestao_decimal_nf(item->>'acrescimo',2);liquido:=bruto-desconto+acrescimo;
  if q<=0 or liquido<0 or nullif(btrim(item->>'unidade'),'') is null then raise exception 'Confira quantidades, unidades e valores dos itens.';end if;
  soma_q:=0;soma_v:=0;soma_d:=0;qtd:=0;
  for l in select * from jsonb_array_elements(h->'linhas') where split_part(value->>'id',':',1)=item->>'numero' loop
   if coalesce(l->>'id','') !~ '^[1-9][0-9]{0,5}:[0-9]+$' or l->>'id'=any(ids) then raise exception 'Linha HBF ausente ou repetida.';end if;
   ids:=array_append(ids,l->>'id');qtd:=qtd+1;
   p:=d#>array['finalizacao','itens',item->>'numero','rateios',split_part(l->>'id',':',2)];
   if p is null then raise exception 'A linha HBF não corresponde à alocação conferida.';end if;
   if coalesce(l->>'classificacao','')<>coalesce(p->>'classificacao','') or length(coalesce(l->>'classificacao',''))>80 then raise exception 'Confira a classificação da linha na alocação.';end if;
   soma_q:=soma_q+public.frota_gestao_decimal_nf(p->>'quantidade',6);
   v:=public.frota_gestao_decimal_nf(l->>'valor_total',2);soma_v:=soma_v+v;soma_d:=soma_d+public.frota_gestao_decimal_nf(l->>'desconto',2);
   if public.frota_gestao_decimal_nf(p->>'quantidade',6)<=0 or v<>public.frota_gestao_decimal_nf(p->>'valor',2) then raise exception 'Confira as quantidades e os valores de cada destino.';end if;
   if public.frota_gestao_decimal_nf(l->>'servicos',2)+public.frota_gestao_decimal_nf(l->>'pecas',2)+public.frota_gestao_decimal_nf(l->>'lavagem',2)+public.frota_gestao_decimal_nf(l->>'pneus',2)+public.frota_gestao_decimal_nf(l->>'oleo_lubrificante',2)-public.frota_gestao_decimal_nf(l->>'desconto',2)<>v then raise exception 'Linha do HBF não conciliada.';end if;
   if coalesce(l->>'conta_codigo','') not in ('4120512','4120503','4120508','4120501','4120506','4120504','4120509','4120510','4120511','4120301','4120302','4110502','4120505','4120701','4120702')
    or nullif(btrim(l->>'pecas_servicos'),'') is null then raise exception 'Selecione a conta e confira a descrição da linha HBF.';end if;
   if d#>>array['finalizacao','itens',item->>'numero','manutencao'] not in ('preventiva','corretiva') or d#>>array['finalizacao','itens',item->>'numero','manutencao'] is null then raise exception 'Selecione Preventivo ou Corretivo na alocação.';end if;
   placa:=l->>'veiculo';veiculo:=null;
   if placa<>'Estoque' then
    select id into veiculo from public.veiculos where upper(regexp_replace(veiculos.placa,'[^A-Za-z0-9]','','g'))=upper(regexp_replace(conferencia.placa,'[^A-Za-z0-9]','','g'));
    if veiculo is null then raise exception 'Selecione uma placa cadastrada ou Estoque.';end if;
    if coalesce(l->>'centro_custo','') not in ('Administrativo 501','Armazém 301','Entrega 201','Puxada 101','Vendas 401') then raise exception 'Selecione a Unidade de Negócio da placa.';end if;
   elsif placa is null then raise exception 'Selecione placa ou Estoque.';end if;
  end loop;
  if qtd=0 or soma_q<>q or soma_v<>liquido or soma_d<>desconto then raise exception 'Quantidades, descontos ou valores do item % não conciliam com a NF.',item->>'numero';end if;
  soma:=soma+liquido;
 end loop;
 if cardinality(ids)<>jsonb_array_length(h->'linhas') or soma<>public.frota_gestao_decimal_nf(n->>'total',2) then raise exception 'HBF, itens e total da NF não conciliados.';end if;
 return jsonb_build_object('contrato','simplificado-01','rascunho_id',p_id,'revisao',p_revisao::text,'total',soma::text,'fornecedor',n->>'fornecedor',
  'placas',(select coalesce(jsonb_agg(distinct x->>'veiculo'),'[]') from jsonb_array_elements(h->'linhas') x where x->>'veiculo'<>'Estoque'),
  'entradas_estoque',(select count(*) from jsonb_array_elements(h->'linhas') x where x->>'veiculo'='Estoque'));
end $$;
revoke all on function public.frota_gestao_validar_simplificado(jsonb,uuid,bigint) from public,anon,authenticated;
create or replace function public.frota_gestao_conferir_simplificado(p_id uuid,p_revisao bigint)
returns jsonb language plpgsql stable security definer set search_path=pg_catalog,public as $$
declare r public.frota_gestao_rascunhos;
begin
 if not public.frota_gestao_usuario_ativo() then raise exception using errcode='42501',message='Conta ativa necessária.';end if;
 select * into r from public.frota_gestao_rascunhos where id=p_id;
 if not found or r.finalizado_em is not null or r.atualizado_em<clock_timestamp()-interval '7 days' or r.revisao is distinct from p_revisao then raise exception 'Conferência ausente, alterada ou já finalizada.';end if;
 return public.frota_gestao_validar_simplificado(r.dados,p_id,p_revisao);
end $$;
revoke all on function public.frota_gestao_conferir_simplificado(uuid,bigint) from public,anon;
grant execute on function public.frota_gestao_conferir_simplificado(uuid,bigint) to authenticated;

create or replace function public.frota_gestao_finalizar_simplificado(p_id uuid,p_revisao bigint,p_chave uuid,p_confirmado boolean)
returns jsonb language plpgsql security definer set search_path=pg_catalog,public as $$
declare r public.frota_gestao_rascunhos; anterior public.frota_gestao_lancamentos; d jsonb;n jsonb;l jsonb;p jsonb;resumo jsonb;hbf jsonb;linhas jsonb:='[]';
 nota uuid:=gen_random_uuid();versao uuid:=gen_random_uuid();oid uuid;vid uuid;numero_os bigint;ordens jsonb:='[]';criadas jsonb:='{}';resultado jsonb;momento timestamptz:=clock_timestamp();
begin
 perform public.frota_gestao_exigir_escrita(false);
 if not public.frota_gestao_usuario_ativo() then raise exception using errcode='42501',message='Conta ativa e senha definitiva necessárias.';end if;
 if (public.frota_gestao_preparacao_simplificado()->>'disponivel') is distinct from 'true' then raise exception 'SQL 95 ou permissões não preparados. Nenhum lançamento foi confirmado.';end if;
 if p_confirmado is distinct from true or p_chave is null or p_id is null or p_revisao is null then raise exception 'Confirme o lançamento e preserve a chave da solicitação.';end if;
 perform pg_advisory_xact_lock(hashtextextended('frota-simplificado:'||p_id::text,0));
 perform pg_advisory_xact_lock(hashtextextended('frota-simplificado-chave:'||p_chave::text,0));
 select * into anterior from public.frota_gestao_lancamentos where chave=p_chave;
 if found then
  if anterior.rascunho_id<>p_id or anterior.revisao<>p_revisao then raise exception 'Chave já utilizada por outro conteúdo.';end if;
  return anterior.recibo;
 end if;
 r:=public.frota_gestao_travar_rascunho(p_id,p_revisao);
 resumo:=public.frota_gestao_conferir_simplificado(p_id,p_revisao);d:=r.dados;n:=d->'nota';
 -- Mesmo namespace de numeração das OS anteriores, sem alterar seus registros.
 hbf:=jsonb_build_object('contrato','05','modelo','hbf-01','preliminar',false,'emissao_id',p_chave,'versao_id',versao,'numero_versao',1,'nota_id',nota,
  'numero_nf',n->>'numero','serie',n->>'serie','chave_acesso',nullif(n->>'chave',''),'fornecedor',n->>'fornecedor','documento_fornecedor',n->>'documento_fornecedor',
  'unidade_fiscal',(select nome from public.operacoes where id=(d->>'unidadeFiscal')::uuid),'emissao_nf',substring(n->>'emissao',1,10),'finalizada_em',momento,
  'autor',(select nome from public.perfis where id=auth.uid()),'autor_id',auth.uid(),'gerado_em',momento,'total',n->>'total',
  'desconto',(select sum((x->>'desconto')::numeric)::text from jsonb_array_elements(n->'itens') x),'acrescimo',(select sum((x->>'acrescimo')::numeric)::text from jsonb_array_elements(n->'itens') x),'referencias','[]'::jsonb);
 for l in select * from jsonb_array_elements(n#>'{dados_fiscais,conferencia_hbf,linhas}') loop
  p:=d#>array['finalizacao','itens',split_part(l->>'id',':',1),'rateios',split_part(l->>'id',':',2)];vid:=null;oid:=null;
  if l->>'veiculo'<>'Estoque' then
   select id into vid from public.veiculos where upper(regexp_replace(placa,'[^A-Za-z0-9]','','g'))=upper(regexp_replace(l->>'veiculo','[^A-Za-z0-9]','','g'));
   oid:=(criadas->>vid::text)::uuid;
   if oid is null then
    oid:=gen_random_uuid();select nextval(pg_get_serial_sequence('public.frota_gestao_os','numero')::regclass) into numero_os;
    insert into public.frota_gestao_lancamento_os(id,lancamento_id,veiculo_id,numero,criado_por) values(oid,nota,vid,numero_os,auth.uid());
    criadas:=criadas||jsonb_build_object(vid::text,oid);ordens:=ordens||jsonb_build_array(jsonb_build_object('id',oid,'numero',numero_os::text));
   else select numero into numero_os from public.frota_gestao_lancamento_os where id=oid;end if;
   l:=l||jsonb_build_object('numero_os',numero_os::text,'veiculo_id',vid);
  else
   l:=l||jsonb_build_object('numero_os','—','centro_custo','Estoque','centro_custo_operacional',null);
   insert into public.frota_gestao_lancamento_lotes(lancamento_id,parcela_id,descricao,unidade,quantidade,valor,unidade_fiscal_id,criado_por)
    values(nota,l->>'id',l->>'pecas_servicos',(select x->>'unidade' from jsonb_array_elements(n->'itens') x where x->>'numero'=split_part(l->>'id',':',1)),(p->>'quantidade')::numeric,(l->>'valor_total')::numeric,(d->>'unidadeFiscal')::uuid,auth.uid());
  end if;
  linhas:=linhas||jsonb_build_array(l||jsonb_build_object('quantidade',p->>'quantidade','manutencao',d#>>array['finalizacao','itens',split_part(l->>'id',':',1),'manutencao']));
 end loop;
 hbf:=hbf||jsonb_build_object('linhas',linhas);
 resultado:=jsonb_build_object('nota_id',nota,'versao_id',versao,'operacao_id',p_chave,'rascunho_id',p_id,'numero_nf',n->>'numero','total',n->>'total','fornecedor',n->>'fornecedor','autor_id',auth.uid(),'ordens',ordens,'finalizada_em',momento);
 insert into public.frota_gestao_lancamentos(id,versao_id,rascunho_id,chave,revisao,numero,serie,documento_fornecedor,fornecedor,chave_fiscal,unidade_fiscal_id,emissao,total,dados,hbf,recibo,finalizada_em,criado_por)
 values(nota,versao,p_id,p_chave,p_revisao,ltrim(btrim(n->>'numero'),'0'),ltrim(btrim(coalesce(n->>'serie','')),'0'),regexp_replace(n->>'documento_fornecedor','[^0-9]','','g'),n->>'fornecedor',nullif(n->>'chave',''),(d->>'unidadeFiscal')::uuid,substring(n->>'emissao',1,10)::date,(n->>'total')::numeric,d,hbf,resultado,momento,auth.uid());
 update public.frota_gestao_rascunhos set finalizado_em=momento where id=p_id;
 return resultado;
end $$;
revoke all on function public.frota_gestao_finalizar_simplificado(uuid,bigint,uuid,boolean) from public,anon;
grant execute on function public.frota_gestao_finalizar_simplificado(uuid,bigint,uuid,boolean) to authenticated;

-- Conferir não grava. O único registro técnico é criado na confirmação final,
-- na mesma transação da NF/OS/estoque; qualquer falha desfaz também esse registro.
create or replace function public.frota_gestao_conferir_envio(p_dados jsonb,p_chave uuid)
returns jsonb language plpgsql stable security definer set search_path=pg_catalog,public as $$
begin
 if p_chave is null then raise exception 'Identificador do lançamento necessário.';end if;
 return public.frota_gestao_validar_simplificado(p_dados,p_chave,1);
end $$;
revoke all on function public.frota_gestao_conferir_envio(jsonb,uuid) from public,anon;
grant execute on function public.frota_gestao_conferir_envio(jsonb,uuid) to authenticated;
create or replace function public.frota_gestao_finalizar_envio(p_dados jsonb,p_chave uuid,p_confirmado boolean)
returns jsonb language plpgsql security definer set search_path=pg_catalog,public as $$
declare anterior public.frota_gestao_lancamentos; revisao_atual bigint;
begin
 perform public.frota_gestao_exigir_escrita(false);
 if not public.frota_gestao_usuario_ativo() then raise exception using errcode='42501',message='Conta ativa necessária.';end if;
 if p_chave is null or p_confirmado is distinct from true then raise exception 'Confirme explicitamente o lançamento.';end if;
 perform pg_advisory_xact_lock(hashtextextended('frota-envio:'||p_chave::text,0));
 select * into anterior from public.frota_gestao_lancamentos where chave=p_chave;
 if found then
  if anterior.dados is distinct from p_dados then raise exception 'Solicitação já confirmada com dados diferentes.';end if;
  return anterior.recibo;
 end if;
 perform public.frota_gestao_validar_simplificado(p_dados,p_chave,1);
 insert into public.frota_gestao_rascunhos(id,dados) values(p_chave,p_dados) returning revisao into revisao_atual;
 return public.frota_gestao_finalizar_simplificado(p_chave,revisao_atual,p_chave,true);
end $$;
revoke all on function public.frota_gestao_finalizar_envio(jsonb,uuid,boolean) from public,anon;
grant execute on function public.frota_gestao_finalizar_envio(jsonb,uuid,boolean) to authenticated;

create or replace function public.frota_gestao_recibo_simplificado(p_id uuid)
returns jsonb language plpgsql stable security definer set search_path=pg_catalog,public as $$
begin if not public.frota_gestao_usuario_ativo() then raise exception using errcode='42501',message='Conta inativa.';end if;
 return (select recibo from public.frota_gestao_lancamentos where rascunho_id=p_id);end $$;
create or replace function public.frota_gestao_listar_simplificado()
returns jsonb language plpgsql stable security definer set search_path=pg_catalog,public as $$
begin if not public.frota_gestao_usuario_ativo() then raise exception using errcode='42501',message='Conta inativa.';end if;
 return coalesce((select jsonb_agg(to_jsonb(x) order by x.finalizada_em desc,x.id) from (select id,versao_id,numero,serie,fornecedor,finalizada_em,total::text,hbf from public.frota_gestao_lancamentos)x),'[]');end $$;
create or replace function public.frota_gestao_lotes_simplificado()
returns jsonb language plpgsql stable security definer set search_path=pg_catalog,public as $$
begin if not public.frota_gestao_usuario_ativo() then raise exception using errcode='42501',message='Conta inativa.';end if;
 return coalesce((select jsonb_agg(to_jsonb(x) order by x.criado_em desc,x.id) from (select l.id,n.numero,l.descricao,l.unidade,l.quantidade::text,l.valor::text,l.criado_em,o.nome unidade_fiscal from public.frota_gestao_lancamento_lotes l join public.frota_gestao_lancamentos n on n.id=l.lancamento_id join public.operacoes o on o.id=l.unidade_fiscal_id)x),'[]');end $$;
create or replace function public.frota_gestao_preparacao_simplificado()
returns jsonb language sql stable security definer set search_path=pg_catalog,public as $$
 select jsonb_build_object('contrato','simplificado-01','sem_rascunho',true,'disponivel',public.frota_gestao_usuario_ativo() and pg_get_serial_sequence('public.frota_gestao_os','numero') is not null
 and (select count(*)=3 from pg_class c join pg_namespace n on n.oid=c.relnamespace where n.nspname='public' and c.relname in ('frota_gestao_lancamentos','frota_gestao_lancamento_os','frota_gestao_lancamento_lotes')
 and c.relrowsecurity and has_table_privilege('authenticated',c.oid,'SELECT') and not has_table_privilege('authenticated',c.oid,'INSERT,UPDATE,DELETE,TRUNCATE'))
   and coalesce(has_function_privilege('authenticated',to_regprocedure('public.frota_gestao_conferir_envio(jsonb,uuid)'),'EXECUTE'),false)
   and coalesce(has_function_privilege('authenticated',to_regprocedure('public.frota_gestao_finalizar_envio(jsonb,uuid,boolean)'),'EXECUTE'),false)
   and not coalesce(has_function_privilege('anon',to_regprocedure('public.frota_gestao_finalizar_envio(jsonb,uuid,boolean)'),'EXECUTE'),true)
   and coalesce(has_function_privilege('authenticated',to_regprocedure('public.frota_gestao_finalizar_simplificado(uuid,bigint,uuid,boolean)'),'EXECUTE'),false)
 and not coalesce(has_function_privilege('anon',to_regprocedure('public.frota_gestao_finalizar_simplificado(uuid,bigint,uuid,boolean)'),'EXECUTE'),true))
$$;
revoke all on function public.frota_gestao_recibo_simplificado(uuid),public.frota_gestao_listar_simplificado(),public.frota_gestao_lotes_simplificado(),public.frota_gestao_preparacao_simplificado() from public,anon;
grant execute on function public.frota_gestao_recibo_simplificado(uuid),public.frota_gestao_listar_simplificado(),public.frota_gestao_lotes_simplificado(),public.frota_gestao_preparacao_simplificado() to authenticated;
notify pgrst,'reload schema';
