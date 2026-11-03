-- Origem: SQL 84 do módulo Gestão da Frota (extraído do laboratório, sem alterações de lógica).
-- NOVO, NÃO EXECUTADO. Guia obrigatório: docs/gestao-frota/BANCO-CICLO-01.md.
-- Domínio próprio; não altera dados, policies ou funções dos módulos antigos.
-- (begin/commit removidos: o Supabase CLI já executa cada migration em uma transação)

do $$
declare dependencia record;
begin
  for dependencia in select * from (values
    ('perfis','id'), ('perfis','ativo'), ('perfis','senha_provisoria'),
    ('veiculos','id'), ('operacoes','id'), ('frota_fornecedores','id'),
    ('frota_centros_custo','codigo')
  ) as requisitos(tabela,coluna) loop
    if not exists (select 1 from information_schema.columns
      where table_schema='public' and table_name=dependencia.tabela and column_name=dependencia.coluna) then
      raise exception 'Pré-requisito ausente: public.%.%. Confira o schema; não reaplique SQLs antigos às cegas.', dependencia.tabela, dependencia.coluna;
    end if;
  end loop;
end $$;

create or replace function public.frota_gestao_usuario_ativo()
returns boolean language sql stable security definer set search_path=pg_catalog,public as $$
  select exists(select 1 from public.perfis where id=auth.uid() and ativo and not senha_provisoria)
$$;
revoke all on function public.frota_gestao_usuario_ativo() from public,anon;
grant execute on function public.frota_gestao_usuario_ativo() to authenticated;

create table if not exists public.frota_gestao_fornecedores (
  fornecedor_id uuid primary key references public.frota_fornecedores(id) on delete restrict,
  documento text not null unique check(documento ~ '^([0-9]{11}|[0-9]{14})$'),
  razao_social text not null check(btrim(razao_social)<>''),
  criado_por uuid not null default auth.uid() references public.perfis(id),
  criado_em timestamptz not null default now()
);
create table if not exists public.frota_gestao_catalogo (
  id uuid primary key default gen_random_uuid(), codigo text not null unique,
  descricao text not null check(btrim(descricao)<>''),
  natureza text not null check(natureza in ('peca','servico')),
  unidade_padrao text not null check(btrim(unidade_padrao)<>''), ativo boolean not null default true,
  criado_por uuid not null default auth.uid() references public.perfis(id), criado_em timestamptz not null default now()
);
create table if not exists public.frota_gestao_contas (
  id uuid primary key default gen_random_uuid(), codigo text not null unique, nome text not null, ativa boolean not null default true
);
create table if not exists public.frota_gestao_categorias (
  id uuid primary key default gen_random_uuid(), codigo text not null unique, nome text not null,
  coluna_hbf text check(coluna_hbf in ('servicos','pecas','lavagem','pneus','oleo_lubrificante')),
  ativa boolean not null default true
);
-- Operações futuras registram o resultado na mesma transação das movimentações.
create table if not exists public.frota_gestao_operacoes (
  id uuid primary key, tipo text not null check(tipo in ('finalizar_nf','reservar','aplicar','transferir','estornar','corrigir','cancelar','ajustar','devolver','encerrar_os')),
  hash_entrada text not null, resultado jsonb not null,
  criado_por uuid not null default auth.uid() references public.perfis(id), criado_em timestamptz not null default now()
);
create table if not exists public.frota_gestao_rascunhos (
  id uuid primary key default gen_random_uuid(), dados jsonb not null check(jsonb_typeof(dados)='object'),
  atualizado_por uuid not null default auth.uid() references public.perfis(id),
  atualizado_em timestamptz not null default clock_timestamp(), finalizado_em timestamptz,
  check(pg_column_size(dados)<=1048576)
);
create index if not exists frota_gestao_rascunhos_expiracao on public.frota_gestao_rascunhos(atualizado_em) where finalizado_em is null;
create table if not exists public.frota_gestao_notas (
  id uuid primary key default gen_random_uuid(), identidade_fiscal text not null unique check(btrim(identidade_fiscal)<>''),
  fornecedor_id uuid not null references public.frota_fornecedores(id),
  numero text not null check(btrim(numero)<>''), serie text not null default '',
  chave_acesso text unique, unidade_fiscal_id uuid not null references public.operacoes(id),
  criado_por uuid not null default auth.uid() references public.perfis(id), criado_em timestamptz not null default now(),
  check(chave_acesso is null or chave_acesso ~ '^[0-9]{44}$')
);
create table if not exists public.frota_gestao_nf_versoes (
  id uuid primary key default gen_random_uuid(), nota_id uuid not null references public.frota_gestao_notas(id),
  rascunho_id uuid not null unique references public.frota_gestao_rascunhos(id),
  numero_versao integer not null check(numero_versao>0), anterior_id uuid,
  estado text not null check(estado in ('finalizada','cancelada')),
  emissao date not null, total numeric(18,2) not null check(total>=0),
  dados_fiscais jsonb not null, motivo text not null check(btrim(motivo)<>''),
  finalizada_em timestamptz not null default now(),
  criado_por uuid not null default auth.uid() references public.perfis(id), criado_em timestamptz not null default now(),
  unique(nota_id,numero_versao), unique(id,nota_id),
  foreign key(anterior_id,nota_id) references public.frota_gestao_nf_versoes(id,nota_id),
  check((numero_versao=1 and anterior_id is null) or (numero_versao>1 and anterior_id is not null))
);
create table if not exists public.frota_gestao_nf_itens (
  id uuid primary key default gen_random_uuid(), versao_id uuid not null references public.frota_gestao_nf_versoes(id),
  numero_item integer not null check(numero_item>0), codigo_original text not null default '',
  descricao_original text not null, descricao_conferida text not null,
  catalogo_id uuid references public.frota_gestao_catalogo(id),
  natureza text not null check(natureza in ('peca','servico')),
  quantidade_compra numeric(20,6) not null check(quantidade_compra>0), unidade_compra text not null,
  fator_conversao numeric(20,8) not null check(fator_conversao>0),
  valor_unitario numeric(24,10) not null check(valor_unitario>=0),
  bruto numeric(18,2) not null check(bruto>=0), desconto numeric(18,2) not null default 0 check(desconto>=0),
  acrescimo numeric(18,2) not null default 0 check(acrescimo>=0),
  liquido numeric(18,2) not null check(liquido>=0),
  check(liquido=bruto-desconto+acrescimo), unique(versao_id,numero_item)
);
create table if not exists public.frota_gestao_ajustes (
  id uuid primary key default gen_random_uuid(), versao_id uuid not null references public.frota_gestao_nf_versoes(id),
  item_id uuid references public.frota_gestao_nf_itens(id),
  tipo text not null check(tipo in ('desconto','acrescimo','despesa','tributo_informativo')),
  descricao text not null, valor numeric(18,2) not null check(valor>=0),
  criterio text not null, distribuicao jsonb not null,
  -- O detalhe explica os agregados dos itens; não somar novamente ao total.
  compoe_agregados boolean not null
);
create table if not exists public.frota_gestao_os (
  id uuid primary key default gen_random_uuid(), numero bigint generated always as identity unique,
  veiculo_id uuid not null references public.veiculos(id), operacao_id uuid not null references public.operacoes(id),
  estado text not null default 'aberta' check(estado in ('aberta','em_execucao','encerrada','cancelada')),
  origem text not null check(origem in ('manual','nota')), nota_origem_id uuid references public.frota_gestao_notas(id),
  chave_criacao uuid not null unique, descricao text not null,
  medidor text not null check(medidor in ('km','horimetro')), leitura_medidor numeric(20,3) check(leitura_medidor>=0),
  encerrada_em timestamptz, motivo_cancelamento text,
  criado_por uuid not null default auth.uid() references public.perfis(id), criado_em timestamptz not null default now(),
  check((origem='manual' and nota_origem_id is null) or (origem='nota' and nota_origem_id is not null)),
  check((estado='encerrada')=(encerrada_em is not null)), unique(id,veiculo_id)
);
create unique index if not exists frota_gestao_os_automatica_unica on public.frota_gestao_os(nota_origem_id,veiculo_id) where origem='nota';
create index if not exists frota_gestao_os_compatibilidade on public.frota_gestao_os(veiculo_id,estado,criado_em);
create table if not exists public.frota_gestao_os_itens (
  id uuid primary key default gen_random_uuid(), os_id uuid not null references public.frota_gestao_os(id),
  catalogo_id uuid references public.frota_gestao_catalogo(id), descricao text not null,
  tipo_manutencao text not null check(tipo_manutencao in ('preventiva','corretiva')),
  quantidade_prevista numeric(20,6) not null check(quantidade_prevista>0),
  valor_previsto numeric(18,2) not null check(valor_previsto>=0), executado_em date,
  unique(id,os_id)
);
create index if not exists frota_gestao_os_itens_os on public.frota_gestao_os_itens(os_id);
create table if not exists public.frota_gestao_vinculos (
  id uuid primary key default gen_random_uuid(), nf_item_id uuid not null references public.frota_gestao_nf_itens(id),
  os_id uuid, os_item_id uuid, veiculo_id uuid references public.veiculos(id),
  unidade_custo_id uuid not null references public.operacoes(id), quantidade numeric(20,6) not null check(quantidade>0),
  valor_documentado numeric(18,2) not null check(valor_documentado>=0),
  centro_custo text references public.frota_centros_custo(codigo),
  conta_id uuid references public.frota_gestao_contas(id), categoria_id uuid references public.frota_gestao_categorias(id),
  classificacao jsonb not null default '{}'::jsonb,
  foreign key(os_item_id,os_id) references public.frota_gestao_os_itens(id,os_id),
  foreign key(os_id,veiculo_id) references public.frota_gestao_os(id,veiculo_id),
  check((os_id is null and os_item_id is null) or (os_id is not null and os_item_id is not null and veiculo_id is not null))
);
create index if not exists frota_gestao_vinculos_item on public.frota_gestao_vinculos(nf_item_id);
create index if not exists frota_gestao_vinculos_os on public.frota_gestao_vinculos(os_item_id);
create table if not exists public.frota_gestao_locais (
  id uuid primary key default gen_random_uuid(), operacao_id uuid not null references public.operacoes(id),
  nome text not null, unique(operacao_id,nome)
);
create table if not exists public.frota_gestao_lotes (
  id uuid primary key default gen_random_uuid(), nf_item_id uuid not null unique references public.frota_gestao_nf_itens(id),
  catalogo_id uuid not null references public.frota_gestao_catalogo(id),
  quantidade_origem numeric(20,6) not null check(quantidade_origem>0),
  custo_total numeric(18,2) not null check(custo_total>=0), adquirido_em date not null
);
create index if not exists frota_gestao_lotes_antigos on public.frota_gestao_lotes(catalogo_id,adquirido_em,id);
create table if not exists public.frota_gestao_reservas (
  id uuid primary key default gen_random_uuid(), lote_id uuid not null references public.frota_gestao_lotes(id),
  local_id uuid not null references public.frota_gestao_locais(id), os_item_id uuid not null references public.frota_gestao_os_itens(id),
  quantidade numeric(20,6) not null check(quantidade>0), aplicada numeric(20,6) not null default 0 check(aplicada>=0),
  liberada numeric(20,6) not null default 0 check(liberada>=0),
  estado text not null default 'ativa' check(estado in ('ativa','aplicada','liberada')),
  criado_por uuid not null default auth.uid() references public.perfis(id), criado_em timestamptz not null default now(),
  check(aplicada+liberada<=quantidade), unique(id,lote_id,local_id,os_item_id),
  check((estado='ativa' and aplicada+liberada<quantidade) or (estado<>'ativa' and aplicada+liberada=quantidade))
);
create index if not exists frota_gestao_reservas_ativas on public.frota_gestao_reservas(lote_id,local_id) where estado='ativa';
create table if not exists public.frota_gestao_aplicacoes (
  id uuid primary key default gen_random_uuid(), lote_id uuid not null references public.frota_gestao_lotes(id),
  local_id uuid not null references public.frota_gestao_locais(id), os_item_id uuid not null references public.frota_gestao_os_itens(id),
  reserva_id uuid, quantidade numeric(20,6) not null check(quantidade>0), custo numeric(18,2) not null check(custo>=0),
  aplicada_em date not null, chave_idempotencia uuid not null unique,
  criado_por uuid not null default auth.uid() references public.perfis(id), criado_em timestamptz not null default now(),
  foreign key(reserva_id,lote_id,local_id,os_item_id) references public.frota_gestao_reservas(id,lote_id,local_id,os_item_id)
);
create table if not exists public.frota_gestao_estornos (
  id uuid primary key default gen_random_uuid(), aplicacao_id uuid not null references public.frota_gestao_aplicacoes(id),
  quantidade numeric(20,6) not null check(quantidade>0), valor numeric(18,2) not null check(valor>=0),
  retorno_fisico_confirmado boolean not null, motivo text not null check(btrim(motivo)<>''),
  chave_idempotencia uuid not null unique,
  criado_por uuid not null default auth.uid() references public.perfis(id), criado_em timestamptz not null default now()
);
create table if not exists public.frota_gestao_movimentos (
  id uuid primary key default gen_random_uuid(), lote_id uuid not null references public.frota_gestao_lotes(id),
  local_id uuid not null references public.frota_gestao_locais(id),
  tipo text not null check(tipo in ('entrada_nf','aplicacao','transferencia_entrada','transferencia_saida','ajuste_entrada','ajuste_saida','devolucao','retorno_fisico')),
  quantidade numeric(20,6) not null check(quantidade>0), valor numeric(18,2) not null check(valor>=0),
  operacao_atomica uuid not null references public.frota_gestao_operacoes(id),
  estorno_de uuid references public.frota_gestao_movimentos(id),
  aplicacao_id uuid references public.frota_gestao_aplicacoes(id), estorno_id uuid references public.frota_gestao_estornos(id),
  motivo text not null check(btrim(motivo)<>''), referencia_fiscal text,
  criado_por uuid not null default auth.uid() references public.perfis(id), criado_em timestamptz not null default now(),
  check(tipo<>'aplicacao' or aplicacao_id is not null),
  check(tipo<>'retorno_fisico' or estorno_id is not null),
  check(tipo not in ('transferencia_entrada','transferencia_saida','devolucao') or nullif(btrim(referencia_fiscal),'') is not null)
);
create index if not exists frota_gestao_movimentos_saldo on public.frota_gestao_movimentos(lote_id,local_id,criado_em);
create unique index if not exists frota_gestao_entrada_unica on public.frota_gestao_movimentos(lote_id) where tipo='entrada_nf';
create unique index if not exists frota_gestao_baixa_unica on public.frota_gestao_movimentos(aplicacao_id) where tipo='aplicacao';
create unique index if not exists frota_gestao_retorno_unico on public.frota_gestao_movimentos(estorno_id) where tipo='retorno_fisico';
create table if not exists public.frota_gestao_custos (
  id uuid primary key default gen_random_uuid(), veiculo_id uuid not null references public.veiculos(id),
  unidade_custo_id uuid not null references public.operacoes(id),
  vinculo_id uuid references public.frota_gestao_vinculos(id), aplicacao_id uuid references public.frota_gestao_aplicacoes(id),
  estorno_id uuid references public.frota_gestao_estornos(id),
  custo_estornado_id uuid references public.frota_gestao_custos(id),
  origem text not null check(origem in ('servico','peca_aplicada','estorno')),
  valor numeric(18,2) not null, executado_em date not null,
  criado_por uuid not null default auth.uid() references public.perfis(id), criado_em timestamptz not null default now(),
  check((origem='servico' and vinculo_id is not null and aplicacao_id is null and estorno_id is null and custo_estornado_id is null and valor>=0)
    or (origem='peca_aplicada' and aplicacao_id is not null and vinculo_id is null and estorno_id is null and custo_estornado_id is null and valor>=0)
    or (origem='estorno' and custo_estornado_id is not null and vinculo_id is null and aplicacao_id is null and valor<=0))
);
create unique index if not exists frota_gestao_custo_servico_unico on public.frota_gestao_custos(vinculo_id) where origem='servico';
create unique index if not exists frota_gestao_custo_aplicacao_unico on public.frota_gestao_custos(aplicacao_id) where origem='peca_aplicada';
create unique index if not exists frota_gestao_custo_estorno_unico on public.frota_gestao_custos(estorno_id) where origem='estorno';
create index if not exists frota_gestao_custos_periodo on public.frota_gestao_custos(veiculo_id,executado_em,unidade_custo_id);
create table if not exists public.frota_gestao_referencias (
  id uuid primary key default gen_random_uuid(), versao_id uuid not null references public.frota_gestao_nf_versoes(id),
  url text not null check(url ~ '^https://[^[:space:]]+$'), descricao text not null,
  identificador_externo text, hash_arquivo text,
  criado_por uuid not null default auth.uid() references public.perfis(id), criado_em timestamptz not null default now()
);
create index if not exists frota_gestao_referencias_versao on public.frota_gestao_referencias(versao_id);
create table if not exists public.frota_gestao_hbf (
  id uuid primary key default gen_random_uuid(), versao_id uuid not null references public.frota_gestao_nf_versoes(id),
  versao_modelo text not null, dados jsonb not null,
  estado text not null default 'emitido' check(estado in ('emitido','invalidado')),
  encaminhamento text not null default 'nao_informado' check(encaminhamento in ('nao_informado','encaminhado')),
  encaminhado_por uuid references public.perfis(id), encaminhado_em timestamptz,
  criado_por uuid not null default auth.uid() references public.perfis(id), criado_em timestamptz not null default now(),
  check((encaminhamento='encaminhado' and encaminhado_por is not null and encaminhado_em is not null)
    or (encaminhamento='nao_informado' and encaminhado_por is null and encaminhado_em is null))
);
create table if not exists public.frota_gestao_auditoria (
  id bigint generated always as identity primary key, entidade text not null, registro_id uuid not null,
  acao text not null, antes jsonb, depois jsonb,
  autor_id uuid references public.perfis(id), ocorrido_em timestamptz not null default clock_timestamp()
);
revoke all on sequence public.frota_gestao_os_numero_seq, public.frota_gestao_auditoria_id_seq from public,anon,authenticated;
create index if not exists frota_gestao_auditoria_registro on public.frota_gestao_auditoria(entidade,registro_id,ocorrido_em);

create or replace function public.frota_gestao_auditar()
returns trigger language plpgsql security definer set search_path=pg_catalog,public as $$
declare anterior jsonb; seguinte jsonb; identificador uuid;
begin
  if tg_op<>'INSERT' then anterior:=to_jsonb(old); end if;
  if tg_op<>'DELETE' then seguinte:=to_jsonb(new); end if;
  identificador:=coalesce((seguinte->>'id')::uuid,(anterior->>'id')::uuid,
    (seguinte->>'fornecedor_id')::uuid,(anterior->>'fornecedor_id')::uuid);
  insert into public.frota_gestao_auditoria(entidade,registro_id,acao,antes,depois,autor_id)
    values(tg_table_name,identificador,tg_op,anterior,seguinte,auth.uid());
  return null;
end $$;
revoke all on function public.frota_gestao_auditar() from public,anon,authenticated;

-- Nenhuma escrita operacional fica disponível antes das funções transacionais.
-- A lista explícita impede atingir tabelas antigas ou criadas por outro ciclo.
do $$
declare nome text;
begin
  foreach nome in array array['fornecedores','catalogo','contas','categorias','operacoes','rascunhos','notas','nf_versoes','nf_itens','ajustes','os','os_itens','vinculos','locais','lotes','reservas','aplicacoes','estornos','movimentos','custos','referencias','hbf','auditoria'] loop
    execute format('alter table public.%I enable row level security','frota_gestao_'||nome);
    execute format('revoke all on table public.%I from public, anon, authenticated','frota_gestao_'||nome);
    execute format('grant select on table public.%I to authenticated','frota_gestao_'||nome);
    execute format('drop policy if exists usuario_ativo_le on public.%I','frota_gestao_'||nome);
    execute format('create policy usuario_ativo_le on public.%I for select to authenticated using (public.frota_gestao_usuario_ativo())','frota_gestao_'||nome);
    if nome<>'auditoria' then
      execute format('drop trigger if exists registrar_auditoria on public.%I','frota_gestao_'||nome);
      execute format('create trigger registrar_auditoria after insert or update or delete on public.%I for each row execute function public.frota_gestao_auditar()','frota_gestao_'||nome);
    end if;
  end loop;
end $$;
