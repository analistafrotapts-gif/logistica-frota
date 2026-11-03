-- GERADO por ferramentas/juntar-migrations.mjs. Não edite à mão.
-- Instalação completa do banco, para rodar UMA vez num projeto Supabase novo.
begin;

-- ===== 20261103000000_base_portal.sql =====
-- Base do portal: tabelas que o módulo Gestão da Frota pressupõe existirem
-- (no sistema original vinham dos "módulos antigos"). Instalação nova do zero.

-- O Supabase concede, por padrão, ALL em tabelas/funções novas do schema public
-- para anon e authenticated. O módulo foi escrito e testado num Postgres sem
-- esse padrão, com GRANTs explícitos. Removemos o padrão para que valham
-- apenas as permissões declaradas nas migrations.
alter default privileges for role postgres in schema public revoke all on tables from anon, authenticated;
alter default privileges for role postgres in schema public revoke all on sequences from anon, authenticated;
alter default privileges for role postgres in schema public revoke all on functions from anon, authenticated, public;

-- Perfis: um por usuário do Supabase Auth. Nasce DESATIVADO: mesmo que o cadastro
-- público do Supabase fique ligado por engano, ninguém entra sem o administrador
-- liberar (perfis.ativo = true).
create table public.perfis (
  id uuid primary key references auth.users(id) on delete cascade,
  nome text not null check (btrim(nome) <> ''),
  email text,
  ativo boolean not null default false,
  senha_provisoria boolean not null default true,
  criado_em timestamptz not null default now()
);

-- Todo usuário criado no Supabase Auth ganha um perfil desativado com senha provisória.
create function public.perfis_criar_do_usuario()
returns trigger language plpgsql security definer set search_path = pg_catalog, public as $$
begin
  insert into public.perfis (id, nome, email)
  values (new.id, coalesce(nullif(btrim(new.raw_user_meta_data->>'nome'), ''), split_part(new.email, '@', 1), 'Usuário'), new.email)
  on conflict (id) do nothing;
  return new;
end $$;
revoke all on function public.perfis_criar_do_usuario() from public, anon, authenticated;
create trigger perfis_criar_do_usuario after insert on auth.users
  for each row execute function public.perfis_criar_do_usuario();

-- Chamado pela tela de login depois que o usuário troca a senha provisória.
create function public.perfil_confirmar_senha_definitiva()
returns void language sql security definer set search_path = pg_catalog, public as $$
  update public.perfis set senha_provisoria = false where id = auth.uid();
$$;
revoke all on function public.perfil_confirmar_senha_definitiva() from public, anon;
grant execute on function public.perfil_confirmar_senha_definitiva() to authenticated;

create function public.perfil_ativo()
returns boolean language sql stable security definer set search_path = pg_catalog, public as $$
  select exists (select 1 from public.perfis where id = auth.uid() and ativo and not senha_provisoria);
$$;
revoke all on function public.perfil_ativo() from public, anon;
grant execute on function public.perfil_ativo() to authenticated;

alter table public.perfis enable row level security;
grant select on public.perfis to authenticated;
create policy proprio_perfil on public.perfis for select to authenticated using (id = auth.uid());

-- Unidades operacionais (filiais).
create table public.operacoes (
  id uuid primary key default gen_random_uuid(),
  nome text not null unique check (btrim(nome) <> ''),
  ativa boolean not null default true
);

create table public.frota_centros_custo (
  codigo text primary key check (btrim(codigo) <> ''),
  nome text not null check (btrim(nome) <> '')
);

create table public.veiculos (
  id uuid primary key default gen_random_uuid(),
  placa text not null unique check (btrim(placa) <> ''),
  operacao_id uuid not null references public.operacoes(id),
  centro_custo text references public.frota_centros_custo(codigo)
);

-- Identidade dos fornecedores; os dados ficam em frota_gestao_fornecedores.
create table public.frota_fornecedores (
  id uuid primary key default gen_random_uuid()
);

do $$
declare tabela text;
begin
  foreach tabela in array array['operacoes', 'frota_centros_custo', 'veiculos', 'frota_fornecedores'] loop
    execute format('alter table public.%I enable row level security', tabela);
    execute format('grant select on public.%I to authenticated', tabela);
    execute format('create policy usuario_ativo_le on public.%I for select to authenticated using (public.perfil_ativo())', tabela);
  end loop;
end $$;

-- ===== 20261103000100_frota_92_ativacao_controlada.sql =====
-- Origem: SQL 92 do módulo Gestão da Frota (extraído do laboratório, sem alterações de lógica).
-- PREPARADO, NAO EXECUTADO. Ler IMPLANTACAO-CONTROLADA.md antes de instalar.
-- Instalar ANTES de 84 em instalacao nova; em banco existente, aplicar antes
-- de expor o modulo e sem reaplicar predecessores. Nao habilita gravacoes.
-- (begin/commit removidos: o Supabase CLI já executa cada migration em uma transação)

create schema if not exists frota_gestao_privado;
revoke all on schema frota_gestao_privado from public,anon,authenticated,service_role;
create table if not exists frota_gestao_privado.ativacao (
  id boolean primary key default true check(id),
  escritas_liberadas boolean not null default false,
  contrato_verificado smallint not null default 0 check(contrato_verificado in (0,91)),
  verificado_em timestamptz,
  evidencia text,
  chave_sha256 text check(chave_sha256 ~ '^[0-9a-f]{64}$'),
  expiracao_liberada boolean not null default false
);
revoke all on table frota_gestao_privado.ativacao from public,anon,authenticated,service_role;
alter table frota_gestao_privado.ativacao enable row level security;
insert into frota_gestao_privado.ativacao(id) values(true) on conflict(id) do nothing;

create or replace function public.frota_gestao_contrato_completo()
returns boolean language sql stable security definer set search_path=pg_catalog,public as $$
  select coalesce(bool_and(to_regprocedure('public.'||assinatura) is not null),false) and
    (select count(*)=8 and bool_and(p.prosrc ~* '\mbegin\M[[:space:]]+perform public.frota_gestao_exigir_escrita\((true|false)\);')
      from pg_proc p join pg_namespace n on n.oid=p.pronamespace where n.nspname='public' and p.proname in
        ('frota_gestao_salvar_rascunho','frota_gestao_expirar_rascunhos','frota_gestao_finalizar_nf',
         'frota_gestao_abrir_os','frota_gestao_operar_estoque','frota_gestao_emitir_hbf',
         'frota_gestao_encaminhar_hbf','frota_gestao_confirmar_revisao')) from (values
    ('frota_gestao_preparacao_rascunhos()'),('frota_gestao_preparacao_nf()'),
    ('frota_gestao_preparacao_estoque()'),('frota_gestao_preparacao_gerencial()'),
    ('frota_gestao_preparacao_revisoes()'),('frota_gestao_salvar_rascunho(uuid,jsonb)'),
    ('frota_gestao_finalizar_nf(uuid,bigint,uuid,boolean)'),('frota_gestao_abrir_os(uuid,jsonb)'),
    ('frota_gestao_operar_estoque(uuid,jsonb,boolean)'),('frota_gestao_emitir_hbf(uuid,uuid,boolean)'),
    ('frota_gestao_encaminhar_hbf(uuid,boolean)'),
    ('frota_gestao_confirmar_revisao(uuid,text,jsonb,text,text,uuid,text,boolean)')
  ) requisitos(assinatura)
$$;
revoke all on function public.frota_gestao_contrato_completo() from public,anon,authenticated,service_role;

create or replace function public.frota_gestao_exigir_escrita(p_expiracao boolean default false)
returns void language plpgsql security definer set search_path=pg_catalog,public as $$
declare controle frota_gestao_privado.ativacao; cabecalhos jsonb; chave text; papel text;
begin
  select * into controle from frota_gestao_privado.ativacao where id for share;
  if not found or not controle.escritas_liberadas or controle.contrato_verificado<>91
    or controle.verificado_em is null or nullif(btrim(controle.evidencia),'') is null
    or controle.chave_sha256 is null or not public.frota_gestao_contrato_completo() then
    raise exception using errcode='42501',message='Gestao da Frota em modo somente leitura. Ativacao nao comprovada.';
  end if;
  papel:=current_setting('role',true);
  if p_expiracao and controle.expiracao_liberada and
    (papel in ('postgres','supabase_admin','service_role') or
      (papel='none' and session_user in ('postgres','supabase_admin'))) then return; end if;
  begin
    cabecalhos:=coalesce(nullif(current_setting('request.headers',true),''),'{}')::jsonb;
  exception when others then
    raise exception using errcode='42501',message='Chave de servidor ausente ou invalida.';
  end;
  chave:=cabecalhos->>'x-frota-gestao-chave';
  if chave is null or chave !~ '^[0-9a-fA-F]{64,128}$' or
    encode(sha256(convert_to(chave,'UTF8')),'hex') is distinct from controle.chave_sha256 then
    raise exception using errcode='42501',message='Chave de servidor ausente ou invalida.';
  end if;
end $$;
revoke all on function public.frota_gestao_exigir_escrita(boolean) from public,anon,authenticated,service_role;

create or replace function public.frota_gestao_estado_ativacao()
returns jsonb language plpgsql stable security definer set search_path=pg_catalog,public as $$
declare controle frota_gestao_privado.ativacao; completo boolean;
begin
  if to_regprocedure('public.frota_gestao_usuario_ativo()') is null then
    return jsonb_build_object('contrato',92,'liberado',false,'completo',false);
  end if;
  if not public.frota_gestao_usuario_ativo() then raise exception using errcode='42501',message='Sessao ativa necessaria.';end if;
  select * into controle from frota_gestao_privado.ativacao where id;
  completo:=public.frota_gestao_contrato_completo();
  return jsonb_build_object('contrato',92,'completo',coalesce(completo,false),
    'liberado',coalesce(controle.escritas_liberadas and controle.contrato_verificado=91 and
      controle.verificado_em is not null and nullif(btrim(controle.evidencia),'') is not null and
      controle.chave_sha256 is not null and completo,false));
end $$;
revoke all on function public.frota_gestao_estado_ativacao() from public,anon;
grant execute on function public.frota_gestao_estado_ativacao() to authenticated;

-- Instala a guarda nas versoes historicas conhecidas de um banco ja instalado.
-- A lista de hashes abaixo e gerada a partir do contrato declarado e dos SQLs
-- revisados; funcao desconhecida provoca rollback em vez de sobrescrever drift.
do $corretivo$
declare rotina record; corpo text; definicao text;
begin
  for rotina in select p.oid,p.proname,p.prosrc,p.oid::regprocedure::text assinatura from pg_proc p
    join pg_namespace n on n.oid=p.pronamespace where n.nspname='public' and p.proname in ('frota_gestao_salvar_rascunho','frota_gestao_expirar_rascunhos','frota_gestao_finalizar_nf','frota_gestao_abrir_os','frota_gestao_operar_estoque','frota_gestao_emitir_hbf','frota_gestao_encaminhar_hbf','frota_gestao_confirmar_revisao') loop
    if md5(replace(rotina.prosrc,chr(13),'')) not in ('0c610386665d1a958e1ed8d638975389','1dd0e2510e4e160349f7503a6fd6f137','2662013b8b967d318105d67903811eba','2af33c5066380de1c27f47a21ed67678','35da0748b5ae2906c049ee6504f7b09b','3b70b8cf16514ef06a288048dd1fa451','421566b460330fd2f96fb2e415f2bfcd','54da9bd8d347461658f68da630bdb103','55bba9673cd278ad147891489b6faa09','6107bd7efa821c900d143a254ae0f634','79d1fab4065b2a8f30c7964725b9de82','7eb2430f149cb5aac57926f7dcbf0be9','83297d6e71c6bf8cf0ec9fbf729c8207','a03e4d65de5db5e2df540d5e10cd907f','bce38dd8e8e4b54e9d0ddfd8587c67d0','c46348e9f8e50f2eb3e71ece7f750201','cecb097befb8620ed149eab82af58057','dd07c22cda0bbeb794088426ea1b1a85','ed8ee4ec617ae3d0e3f6b5a4575fdf62','f784c0bacb22544177e2e58217776922','f8b27452adb1d3f3e91899059f161ee5','fbda00de6f55382c729a4b05b4113a8f') then
      raise exception 'Definicao desconhecida de %. Interrompa e revise o drift antes de instalar 92.',rotina.assinatura;
    end if;
    if position('perform public.frota_gestao_exigir_escrita(' in rotina.prosrc)=0 then
      corpo:=regexp_replace(rotina.prosrc,'\mbegin\M','begin'||chr(10)||'  perform public.frota_gestao_exigir_escrita('||
        case when rotina.proname='frota_gestao_expirar_rascunhos' then 'true' else 'false' end||');','i');
      definicao:=pg_get_functiondef(rotina.oid);
      if corpo=rotina.prosrc then raise exception 'Corpo nao reconhecido: %',rotina.assinatura;end if;
      execute replace(definicao,rotina.prosrc,corpo);
    end if;
    execute format('revoke all on function %s from public,anon',rotina.assinatura);
  end loop;
end $corretivo$;

-- ===== 20261103000200_frota_84_ciclo01_dominio.sql =====
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

-- ===== 20261103000300_frota_85_ciclo01_rpcs.sql =====
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

-- ===== 20261103000400_frota_86_ciclo01_corretivo.sql =====
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

-- ===== 20261103000500_frota_87_ciclo02.sql =====
-- Origem: SQL 87 do módulo Gestão da Frota (extraído do laboratório, sem alterações de lógica).
-- CICLO 02. Preparado para execução MANUAL após 84 -> 85 -> 86 conferidos.
-- Não instala cron, não modifica dados nem permissões dos módulos antigos.
-- (begin/commit removidos: o Supabase CLI já executa cada migration em uma transação)

create index if not exists frota_gestao_rascunhos_listagem
  on public.frota_gestao_rascunhos(atualizado_em desc,id desc) where finalizado_em is null;

create or replace function public.frota_gestao_listar_rascunhos(p_pagina integer default 1,p_tamanho integer default 25,p_id uuid default null)
returns jsonb language plpgsql stable security definer set search_path=pg_catalog,public as $$
declare resultado jsonb;
begin
  if not public.frota_gestao_usuario_ativo() then raise exception using errcode='42501',message='Conta inativa ou não autenticada.'; end if;
  if p_pagina is null or p_pagina<1 or p_pagina>1000000 or p_tamanho is null or p_tamanho<1 or p_tamanho>50 then
    raise exception 'Paginação inválida.';
  end if;
  with elegiveis as materialized (
    select r.id,r.revisao,r.atualizado_em,r.atualizado_por
    from public.frota_gestao_rascunhos r
    where r.finalizado_em is null and r.atualizado_em>=statement_timestamp()-interval '7 days'
      and (p_id is null or r.id=p_id)
  ), pagina as (
    select * from elegiveis order by atualizado_em desc,id desc
    limit p_tamanho offset ((p_pagina-1)::bigint*p_tamanho)
  )
  select jsonb_build_object('pagina',p_pagina,'tamanho',p_tamanho,
    'total',(select count(*)::text from elegiveis),
    'itens',coalesce((select jsonb_agg(jsonb_build_object(
      'id',r.id,'numero',coalesce(d.dados#>>'{nota,numero}',''),
      'serie',coalesce(d.dados#>>'{nota,serie}',''),'fornecedor',coalesce(d.dados#>>'{nota,fornecedor}',''),
      'documento_fornecedor',coalesce(d.dados#>>'{nota,documento_fornecedor}',''),
      'total',coalesce(d.dados#>>'{nota,total}',''),'unidade_fiscal_id',coalesce(d.dados->>'unidadeFiscal',''),
      'atualizado_em',r.atualizado_em,'expira_em',r.atualizado_em+interval '7 days',
      'atualizado_por',r.atualizado_por,'atualizado_por_nome',p.nome,'revisao',r.revisao::text
    ) order by r.atualizado_em desc,r.id desc)
    from pagina r join public.frota_gestao_rascunhos d on d.id=r.id
    left join public.perfis p on p.id=r.atualizado_por),'[]'::jsonb)) into resultado;
  return resultado;
end $$;
revoke all on function public.frota_gestao_listar_rascunhos(integer,integer,uuid) from public,anon;
grant execute on function public.frota_gestao_listar_rascunhos(integer,integer,uuid) to authenticated;

-- Apenas um aviso: duas conferências podem coexistir. Não mesclar nem excluir automaticamente.
create or replace function public.frota_gestao_duplicidades_rascunho(p_id uuid,p_chave text,p_documento text,p_numero text,p_serie text,p_unidade uuid)
returns jsonb language plpgsql stable security definer set search_path=pg_catalog,public as $$
declare criterio text; resultado jsonb;
begin
  if not public.frota_gestao_usuario_ativo() then raise exception using errcode='42501',message='Conta inativa ou não autenticada.'; end if;
  if p_chave ~ '^[0-9]{44}$' then criterio:='chave';
  elsif coalesce(p_chave,'')='' and p_documento ~ '^([0-9]{11}|[0-9]{14})$'
    and p_numero ~ '^[0-9]{1,12}$' and p_serie ~ '^[0-9]{1,3}$' and p_unidade is not null then criterio:='identificacao';
  else return jsonb_build_object('criterio',null,'total','0','itens','[]'::jsonb); end if;
  with coincidentes as materialized (
    select r.id,coalesce(r.dados#>>'{nota,numero}','') as numero,r.atualizado_em from public.frota_gestao_rascunhos r
    where r.finalizado_em is null and r.atualizado_em>=statement_timestamp()-interval '7 days'
      and (p_id is null or r.id<>p_id)
      and ((criterio='chave' and btrim(r.dados#>>'{nota,chave}')=p_chave)
        or (criterio='identificacao' and btrim(coalesce(r.dados#>>'{nota,chave}',''))=''
          and regexp_replace(r.dados#>>'{nota,documento_fornecedor}','[^0-9]','','g')=p_documento
          and btrim(r.dados#>>'{nota,numero}') ~ '^[0-9]{1,12}$' and ltrim(btrim(r.dados#>>'{nota,numero}'),'0')=ltrim(p_numero,'0')
          and btrim(r.dados#>>'{nota,serie}') ~ '^[0-9]{1,3}$' and ltrim(btrim(r.dados#>>'{nota,serie}'),'0')=ltrim(p_serie,'0')
          and r.dados->>'unidadeFiscal'=p_unidade::text))
  ), pagina as (select * from coincidentes order by atualizado_em desc,id desc limit 10)
  select jsonb_build_object('criterio',criterio,'total',(select count(*)::text from coincidentes),
    'itens',coalesce((select jsonb_agg(jsonb_build_object('id',r.id,'numero',r.numero,
      'atualizado_em',r.atualizado_em) order by r.atualizado_em desc,r.id desc) from pagina r),'[]'::jsonb)) into resultado;
  return resultado;
end $$;
revoke all on function public.frota_gestao_duplicidades_rascunho(uuid,text,text,text,text,uuid) from public,anon;
grant execute on function public.frota_gestao_duplicidades_rascunho(uuid,text,text,text,text,uuid) to authenticated;

create or replace function public.frota_gestao_preparacao_rascunhos()
returns jsonb language plpgsql stable security definer set search_path=pg_catalog,public as $$
declare anterior jsonb; funcoes boolean;
begin
  if not public.frota_gestao_usuario_ativo() then raise exception using errcode='42501',message='Conta inativa ou não autenticada.'; end if;
  anterior:=public.frota_gestao_preparacao();
  select bool_and(coalesce(has_function_privilege('authenticated',to_regprocedure(assinatura),'EXECUTE'),false)) into funcoes
    from unnest(array['public.frota_gestao_salvar_rascunho(uuid,jsonb)',
      'public.frota_gestao_carregar_rascunho(uuid)',
      'public.frota_gestao_listar_rascunhos(integer,integer,uuid)',
      'public.frota_gestao_duplicidades_rascunho(uuid,text,text,text,text,uuid)']) assinatura;
  -- Valida colunas requeridas sem ler documentos nem alterar dados.
  perform revisao,dados,finalizado_em,atualizado_em,atualizado_por from public.frota_gestao_rascunhos where false;
  perform nome from public.perfis where false;
  return jsonb_build_object('contrato','02','funcoes_disponiveis',funcoes and anterior->>'contrato'='01.1',
    'expiracao_agendada',coalesce((anterior->>'expiracao_agendada')::boolean,false));
end $$;
revoke all on function public.frota_gestao_preparacao_rascunhos() from public,anon;
grant execute on function public.frota_gestao_preparacao_rascunhos() to authenticated;

-- ===== 20261103000600_frota_88_ciclo03.sql =====
-- Origem: SQL 88 do módulo Gestão da Frota (extraído do laboratório, sem alterações de lógica).
-- CICLO 03. Execução MANUAL somente após 84 -> 85 -> 86 -> 87 conferidos.
-- Não instala jobs, não escreve em Gestran/cadastros antigos e não finaliza dados na instalação.
-- (begin/commit removidos: o Supabase CLI já executa cada migration em uma transação)
alter table public.frota_gestao_os add column if not exists periodo_inicio date;
alter table public.frota_gestao_os add column if not exists periodo_fim date;
alter table public.frota_gestao_os add column if not exists hash_abertura text;
alter table public.frota_gestao_os_itens add column if not exists previsao_informada boolean not null default true;
alter table public.frota_gestao_operacoes add column if not exists rascunho_id uuid references public.frota_gestao_rascunhos(id);
create unique index if not exists frota_gestao_finalizacao_rascunho_unica on public.frota_gestao_operacoes(rascunho_id) where tipo='finalizar_nf';
do $$ begin
  if not exists(select 1 from pg_constraint where conrelid='public.frota_gestao_os'::regclass and conname='frota_gestao_os_periodo') then
    alter table public.frota_gestao_os add constraint frota_gestao_os_periodo
      check((periodo_inicio is null and periodo_fim is null) or (periodo_inicio is not null and periodo_fim is not null and periodo_fim>=periodo_inicio));
  end if;
end $$;
-- Impede duplicar a mesma identificação por caminho com chave e por caminho manual.
create unique index if not exists frota_gestao_identificacao_unica on public.frota_gestao_notas
  (fornecedor_id,ltrim(btrim(numero),'0'),ltrim(btrim(serie),'0'));
create unique index if not exists frota_gestao_rateio_unico on public.frota_gestao_vinculos
  (nf_item_id,(classificacao->>'rateio_indice')) where classificacao ? 'rateio_indice';

create or replace function public.frota_gestao_decimal_nf(p_valor text,p_casas integer)
returns numeric language plpgsql immutable set search_path=pg_catalog,public as $$
begin
  if p_valor is null or p_valor !~ ('^[0-9]{1,12}(\.[0-9]{1,'||p_casas||'})?$') then raise exception 'Quantidade ou valor fiscal inválido: use ponto e a precisão permitida.'; end if;
  return p_valor::numeric;
end $$;
revoke all on function public.frota_gestao_decimal_nf(text,integer) from public,anon,authenticated;

create or replace function public.frota_gestao_candidatas_nf(p_veiculo uuid,p_contexto jsonb,p_catalogo uuid,p_manutencao text)
returns jsonb language plpgsql stable security definer set search_path=pg_catalog,public as $$
begin
  return coalesce((select jsonb_agg(jsonb_build_object('item_id',c.id,'os_id',c.os_id,'numero',c.numero::text,'estado',c.estado,'pendente',c.pendente::text) order by c.numero,c.id)
    from (select i.id,i.os_id,o.numero,o.estado,i.quantidade_prevista-coalesce((select sum(v.quantidade*n.fator_conversao)
      from public.frota_gestao_vinculos v join public.frota_gestao_nf_itens n on n.id=v.nf_item_id
      join public.frota_gestao_nf_versoes f on f.id=n.versao_id where v.os_item_id=i.id and f.estado='finalizada'),0) as pendente
      from public.frota_gestao_os_itens i join public.frota_gestao_os o on o.id=i.os_id
      join public.operacoes op on op.id=o.operacao_id and op.ativa
      where o.veiculo_id=p_veiculo and o.estado in ('aberta','em_execucao','encerrada')
        and btrim(o.contexto_id)=btrim(p_contexto->>'contexto') and o.medidor=p_contexto->>'medidor' and o.periodo_inicio<=(p_contexto->>'fim')::date and o.periodo_fim>=(p_contexto->>'inicio')::date
        and i.catalogo_id=p_catalogo and i.tipo_manutencao=p_manutencao) c where c.pendente>0),'[]'::jsonb);
end $$;
revoke all on function public.frota_gestao_candidatas_nf(uuid,jsonb,uuid,text) from public,anon,authenticated;

create or replace function public.frota_gestao_conferir_nf(p_id uuid,p_revisao bigint)
returns jsonb language plpgsql security definer set search_path=pg_catalog,public as $$
declare r public.frota_gestao_rascunhos; d jsonb; plano jsonb; linha jsonb; cfg jsonb; parcela jsonb; contexto jsonb;
  fornecedor public.frota_gestao_fornecedores; catalogo public.frota_gestao_catalogo; veiculo public.veiculos;
  q numeric; fator numeric; bruto numeric; desconto numeric; acrescimo numeric; liquido numeric; preco numeric;
  soma numeric:=0; soma_q numeric; soma_v numeric; qp numeric; vp numeric; candidatas jsonb; escolhida jsonb;
  pendencias jsonb:='[]'; linhas jsonb:='[]'; rateios jsonb; indice integer; identidade text; numero_fiscal text; serie_fiscal text; chave text; emissao date;
begin
  if not public.frota_gestao_usuario_ativo() then raise exception using errcode='42501',message='Conta inativa ou não autenticada.'; end if;
  select * into r from public.frota_gestao_rascunhos where id=p_id;
  if not found or r.finalizado_em is not null or r.atualizado_em<clock_timestamp()-interval '7 days' then raise exception 'Rascunho ausente, expirado ou finalizado.'; end if;
  if p_revisao is null or r.revisao<>p_revisao then raise exception 'O rascunho mudou. Recarregue antes de conferir/finalizar.'; end if;
  d:=r.dados;plano:=d->'finalizacao';
  if d->>'formato'<>'1' or jsonb_typeof(plano) is distinct from 'object' or jsonb_typeof(d#>'{nota,itens}') is distinct from 'array'
    or jsonb_array_length(d#>'{nota,itens}') not between 1 and 1000 then raise exception 'Complete os dados e as destinações da conferência.'; end if;
  numero_fiscal:=btrim(d#>>'{nota,numero}');serie_fiscal:=btrim(d#>>'{nota,serie}');chave:=nullif(btrim(d#>>'{nota,chave}'),'');
  if numero_fiscal is null or numero_fiscal !~ '^[0-9]{1,12}$' or serie_fiscal is null or serie_fiscal !~ '^[0-9]{1,3}$' or (chave is not null and chave !~ '^[0-9]{44}$') then raise exception 'Confira número, série e chave fiscal.'; end if;
  if numero_fiscal::numeric=0 then raise exception 'Número fiscal deve ser positivo.';end if;
  if plano->>'emissao' is null or plano->>'emissao' !~ '^[0-9]{4}-[0-9]{2}-[0-9]{2}$' then raise exception 'Confirme a data de emissão.'; end if;
  emissao:=(plano->>'emissao')::date;
  if substring(d#>>'{nota,emissao}',1,10) is distinct from plano->>'emissao' then raise exception 'A data confirmada diverge do cabeçalho da nota.'; end if;
  select * into fornecedor from public.frota_gestao_fornecedores where fornecedor_id=(plano->>'fornecedor_id')::uuid;
  if not found or coalesce(d#>>'{nota,documento_fornecedor}','') !~ '^[0-9 ./-]+$' or fornecedor.documento is distinct from regexp_replace(d#>>'{nota,documento_fornecedor}','[^0-9]','','g') then raise exception 'Selecione um fornecedor cadastrado com CPF/CNPJ correspondente à nota.'; end if;
  if not exists(select 1 from public.operacoes where id=(d->>'unidadeFiscal')::uuid and ativa) then raise exception 'Selecione uma unidade fiscal ativa.'; end if;
  identidade:=coalesce(chave,fornecedor.documento||':'||ltrim(serie_fiscal,'0')||':'||ltrim(numero_fiscal,'0'));
  if exists(select 1 from public.frota_gestao_notas n where n.identidade_fiscal=identidade or n.chave_acesso=chave
    or (n.fornecedor_id=fornecedor.fornecedor_id and ltrim(btrim(n.numero),'0')=ltrim(numero_fiscal,'0') and ltrim(btrim(n.serie),'0')=ltrim(serie_fiscal,'0'))) then raise exception 'Nota fiscal já lançada. Não finalize uma duplicidade.'; end if;
  if nullif(d->>'referencia','') is not null and ((d->>'referencia') !~ '^https://[^[:space:]@]+$' or (d->>'referencia') ~* '(token|signature|expires|x-amz|x-goog|sig)=') then raise exception 'Use referência HTTPS permanente, sem credenciais ou assinatura temporária.'; end if;
  if exists(select 1 from jsonb_array_elements(d#>'{nota,itens}') i group by i->>'numero' having count(*)>1) then raise exception 'Linhas fiscais repetidas.'; end if;
  if (select count(*) from jsonb_object_keys(plano->'itens'))<>jsonb_array_length(d#>'{nota,itens}') then raise exception 'Classifique todas as linhas fiscais, sem itens adicionais.'; end if;
  for linha in select * from jsonb_array_elements(d#>'{nota,itens}') loop
    if coalesce(linha->>'numero','') !~ '^[1-9][0-9]{0,5}$' or nullif(btrim(linha->>'descricao'),'') is null then raise exception 'Item sem número/descrição.'; end if;
    cfg:=plano->'itens'->(linha->>'numero');
    select * into catalogo from public.frota_gestao_catalogo where id=(cfg->>'catalogo_id')::uuid and ativo;
    if not found then raise exception 'Selecione catálogo ativo para o item %.',linha->>'numero'; end if;
    if cfg->>'manutencao' is null or cfg->>'manutencao' not in ('preventiva','corretiva') then raise exception 'Confira o tipo de manutenção do item.'; end if;
    q:=public.frota_gestao_decimal_nf(linha->>'quantidade',6);fator:=public.frota_gestao_decimal_nf(cfg->>'fator',8);
    preco:=public.frota_gestao_decimal_nf(linha->>'unitario',10);bruto:=public.frota_gestao_decimal_nf(linha->>'bruto',2);
    desconto:=public.frota_gestao_decimal_nf(linha->>'desconto',2);acrescimo:=public.frota_gestao_decimal_nf(linha->>'acrescimo',2);liquido:=bruto-desconto+acrescimo;
    if q<=0 or fator<=0 or liquido<0 or nullif(btrim(linha->>'unidade'),'') is null or round(q*preco,2)<>bruto or trunc(q*fator,6)<>q*fator then raise exception 'Quantidade, unidade, fator, bruto ou líquido inconsistentes no item %.',linha->>'numero'; end if;
    if catalogo.natureza='servico' and (fator<>1 or upper(btrim(linha->>'unidade'))<>upper(catalogo.unidade_padrao)) then raise exception 'Serviços exigem unidade do catálogo e fator 1.'; end if;
    if catalogo.natureza='peca' and not exists(select 1 from public.frota_gestao_locais l join public.operacoes o on o.id=l.operacao_id where l.id=(cfg->>'local_id')::uuid and o.ativa) then raise exception 'Informe local físico ativo para a entrada integral da peça.'; end if;
    if jsonb_typeof(cfg->'rateios') is distinct from 'array' or jsonb_array_length(cfg->'rateios') not between 1 and 100 then raise exception 'Informe de 1 a 100 destinos para cada linha.'; end if;
    soma_q:=0;soma_v:=0;rateios:='[]';indice:=0;
    for parcela in select * from jsonb_array_elements(cfg->'rateios') loop
      qp:=public.frota_gestao_decimal_nf(parcela->>'quantidade',6);vp:=public.frota_gestao_decimal_nf(parcela->>'valor',2);
      if qp<=0 or trunc(qp*fator,6)<>qp*fator then raise exception 'Quantidade inválida no rateio.'; end if;
      soma_q:=soma_q+qp;soma_v:=soma_v+vp;candidatas:='[]';escolhida:=null;
      if not exists(select 1 from public.operacoes where id=(parcela->>'unidade_id')::uuid and ativa)
        or not exists(select 1 from public.frota_centros_custo where codigo=parcela->>'centro_custo')
        or not exists(select 1 from public.frota_gestao_contas where id=(parcela->>'conta_id')::uuid and ativa)
        or not exists(select 1 from public.frota_gestao_categorias where id=(parcela->>'categoria_id')::uuid and ativa) then raise exception 'Confira unidade de custo, centro, conta e categoria do rateio.'; end if;
      if parcela->>'destino'='veiculo' then
        select * into veiculo from public.veiculos where id=(parcela->>'veiculo_id')::uuid;
        if not found or regexp_replace(upper(veiculo.placa),'[^A-Z0-9]','','g') is distinct from regexp_replace(upper(parcela->>'placa'),'[^A-Z0-9]','','g') then raise exception 'Confira a placa e o cadastro do veículo.'; end if;
        contexto:=plano->'veiculos'->veiculo.id::text;
        if nullif(btrim(contexto->>'contexto'),'') is null or length(contexto->>'contexto')>200 or contexto->>'medidor' not in ('km','horimetro') or contexto->>'medidor' is null
          or coalesce(contexto->>'inicio','') !~ '^[0-9]{4}-[0-9]{2}-[0-9]{2}$' or coalesce(contexto->>'fim','') !~ '^[0-9]{4}-[0-9]{2}-[0-9]{2}$' or (contexto->>'fim')::date<(contexto->>'inicio')::date then raise exception 'Confira contexto, período e medidor do veículo.'; end if;
        if catalogo.natureza='servico' and ((parcela->>'executado_em') is null or parcela->>'executado_em'='' or (parcela->>'executado_em')::date not between (contexto->>'inicio')::date and (contexto->>'fim')::date or (parcela->>'executado_em')::date>current_date) then raise exception 'Informe a data real de execução dentro do período conferido.'; end if;
        candidatas:=public.frota_gestao_candidatas_nf(veiculo.id,contexto,catalogo.id,cfg->>'manutencao');
        if nullif(parcela->>'os_item_id','') is null and jsonb_array_length(candidatas)=0 and not exists(select 1 from public.operacoes where id=veiculo.operacao_id and ativa) then raise exception 'Nova OS exige unidade operacional atual e ativa no cadastro do veículo.';end if;
        if nullif(parcela->>'os_item_id','') is not null then
          select c into escolhida from jsonb_array_elements(candidatas) c where c->>'item_id'=parcela->>'os_item_id';
          if escolhida is null or (escolhida->>'pendente')::numeric<qp*fator then pendencias:=pendencias||jsonb_build_array('Item '||(linha->>'numero')||': OS incompatível ou faturamento pendente insuficiente.');
          elsif catalogo.natureza='servico' and not exists(select 1 from public.frota_gestao_os where id=(escolhida->>'os_id')::uuid and (parcela->>'executado_em')::date between periodo_inicio and periodo_fim) then pendencias:=pendencias||jsonb_build_array('Data do serviço fora do período da OS selecionada.');end if;
        elsif jsonb_array_length(candidatas)>0 then pendencias:=pendencias||jsonb_build_array('Item '||(linha->>'numero')||': confira as OS existentes antes de criar outra; divida faturamentos parciais se necessário.');end if;
        if nullif(parcela->>'os_item_id','') is null and exists(select 1 from public.frota_gestao_os o join public.frota_gestao_os_itens oi on oi.os_id=o.id
          where o.veiculo_id=veiculo.id and o.estado in ('aberta','em_execucao','encerrada') and oi.catalogo_id=catalogo.id
            and (nullif(btrim(o.contexto_id),'') is null or o.periodo_inicio is null or o.periodo_fim is null or (btrim(o.contexto_id)=btrim(contexto->>'contexto') and o.medidor<>contexto->>'medidor'))
            and oi.quantidade_prevista>coalesce((select sum(v.quantidade*ni.fator_conversao) from public.frota_gestao_vinculos v join public.frota_gestao_nf_itens ni on ni.id=v.nf_item_id
              join public.frota_gestao_nf_versoes nv on nv.id=ni.versao_id where v.os_item_id=oi.id and nv.estado='finalizada'),0)) then
          pendencias:=pendencias||jsonb_build_array('Existem OS com pendência e contexto/período ou medidor não verificável. Regularize a conferência antes de propor outra OS.');end if;
      elsif (catalogo.natureza='peca' and parcela->>'destino'='estoque') or (catalogo.natureza='servico' and parcela->>'destino'='pendente') then
        if nullif(parcela->>'veiculo_id','') is not null or nullif(parcela->>'placa','') is not null or nullif(parcela->>'os_item_id','') is not null then raise exception 'Destino sem veículo não pode identificar OS ou placa.'; end if;
      else raise exception 'Destino incompatível com peça/serviço.'; end if;
      rateios:=rateios||jsonb_build_array(jsonb_build_object('indice',indice,'destino',parcela->>'destino','veiculo',coalesce(parcela->>'placa',''),'valor',vp::text,
        'quantidade',qp::text,'centro_custo',parcela->>'centro_custo','conta',(select nome from public.frota_gestao_contas where id=(parcela->>'conta_id')::uuid),
        'categoria',(select nome from public.frota_gestao_categorias where id=(parcela->>'categoria_id')::uuid),'unidade_custo',(select nome from public.operacoes where id=(parcela->>'unidade_id')::uuid),'executado_em',coalesce(parcela->>'executado_em',''),
        'os_item_id',coalesce(parcela->>'os_item_id',''),'acao',case when parcela->>'destino'<>'veiculo' then 'sem_os' when nullif(parcela->>'os_item_id','') is null then 'criar' else 'vincular' end,'candidatas',candidatas));indice:=indice+1;
    end loop;
    if soma_q<>q or soma_v<>liquido then raise exception 'Rateio do item % não concilia quantidade e centavos do líquido.',linha->>'numero';end if;
    soma:=soma+liquido;linhas:=linhas||jsonb_build_array(jsonb_build_object('numero',linha->>'numero','natureza',catalogo.natureza,'liquido',liquido::text,'rateios',rateios));
  end loop;
  if soma<>public.frota_gestao_decimal_nf(d#>>'{nota,total}',2) then raise exception 'Itens, descontos e acréscimos não conciliam com o total da nota. Distribua os ajustes gerais explicitamente.';end if;
  return jsonb_build_object('contrato','03','rascunho_id',r.id,'revisao',r.revisao::text,'total',soma::text,'fornecedor',fornecedor.razao_social,'linhas',linhas,'pendencias',pendencias);
end $$;
revoke all on function public.frota_gestao_conferir_nf(uuid,bigint) from public,anon;
grant execute on function public.frota_gestao_conferir_nf(uuid,bigint) to authenticated;

create or replace function public.frota_gestao_finalizar_nf(p_id uuid,p_revisao bigint,p_chave uuid,p_confirmado boolean)
returns jsonb language plpgsql security definer set search_path=pg_catalog,public as $$
declare r public.frota_gestao_rascunhos; operacao public.frota_gestao_operacoes; resumo jsonb; plano jsonb; linha jsonb; cfg jsonb; parcela jsonb; contexto jsonb; candidato jsonb;
  assinatura text; nota uuid:=gen_random_uuid();versao uuid:=gen_random_uuid();item_id uuid;lote_id uuid;vinculo uuid;os_id uuid;os_item uuid;
  criadas jsonb:='{}';itens_criados jsonb:='{}';ordens jsonb:='[]';resultado_final jsonb;identidade text;veiculo uuid;unidade_os uuid;catalogo public.frota_gestao_catalogo;
  numero_os bigint;qp numeric;vp numeric;liquido numeric;q numeric;fator numeric;indice integer;chave_item text; finalizada timestamptz;originais jsonb;descricao_origem text;
begin
  perform public.frota_gestao_exigir_escrita(false);
  if not public.frota_gestao_usuario_ativo() then raise exception using errcode='42501',message='Conta inativa ou não autenticada.';end if;
  if p_id is null or p_revisao is null or p_chave is null or p_confirmado is distinct from true then raise exception 'A confirmação explícita e a chave da solicitação são obrigatórias.';end if;
  assinatura:=encode(sha256(convert_to(jsonb_build_object('contrato','03','rascunho',p_id,'revisao',p_revisao)::text,'UTF8')),'hex');
  perform pg_advisory_xact_lock(hashtextextended('nf-operacao:'||p_chave::text,0));
  select * into operacao from public.frota_gestao_operacoes where id=p_chave;
  if found then
    if operacao.tipo<>'finalizar_nf' or operacao.hash_entrada<>assinatura then raise exception 'Chave idempotente reutilizada com conteúdo diferente.';end if;
    return operacao.resultado;
  end if;
  if not (public.frota_gestao_preparacao_rascunhos()->>'expiracao_agendada')::boolean then raise exception 'Banco/agendamento de rascunhos não preparado.';end if;
  r:=public.frota_gestao_travar_rascunho(p_id,p_revisao);
  if r.atualizado_em<clock_timestamp()-interval '7 days' or r.dados->'conferido' is distinct from 'true'::jsonb then raise exception 'Rascunho expirado ou conferência não confirmada.';end if;
  plano:=r.dados->'finalizacao';
  perform 1 from public.frota_gestao_fornecedores f where f.fornecedor_id=(plano->>'fornecedor_id')::uuid for share;
  perform 1 from public.frota_gestao_catalogo c where c.id in(select (i.value->>'catalogo_id')::uuid from jsonb_each(plano->'itens') i) order by c.id for share;
  -- Ordem única para todas as NFs dos mesmos veículos; outras transações futuras devem seguir este protocolo.
  for veiculo in select distinct (p->>'veiculo_id')::uuid from jsonb_each(plano->'itens') i
    cross join lateral jsonb_array_elements(i.value->'rateios') p where p->>'destino'='veiculo' order by 1 loop
    perform pg_advisory_xact_lock(hashtextextended('nf-veiculo:'||veiculo::text,0));
    perform 1 from public.veiculos v where v.id=veiculo for share;
    perform 1 from public.frota_gestao_os where veiculo_id=veiculo order by id for update;
    perform 1 from public.frota_gestao_os_itens i where i.os_id in(select o.id from public.frota_gestao_os o where o.veiculo_id=veiculo) order by i.id for update;
  end loop;
  resumo:=public.frota_gestao_conferir_nf(p_id,p_revisao);
  if jsonb_array_length(resumo->'pendencias')>0 then raise exception '%',resumo->'pendencias';end if;
  identidade:=coalesce(nullif(btrim(r.dados#>>'{nota,chave}'),''),(select documento from public.frota_gestao_fornecedores where fornecedor_id=(plano->>'fornecedor_id')::uuid)||':'||ltrim(btrim(r.dados#>>'{nota,serie}'),'0')||':'||ltrim(btrim(r.dados#>>'{nota,numero}'),'0'));
  insert into public.frota_gestao_notas(id,identidade_fiscal,fornecedor_id,numero,serie,chave_acesso,unidade_fiscal_id)
    values(nota,identidade,(plano->>'fornecedor_id')::uuid,btrim(r.dados#>>'{nota,numero}'),btrim(r.dados#>>'{nota,serie}'),nullif(btrim(r.dados#>>'{nota,chave}'),''),(r.dados->>'unidadeFiscal')::uuid);
  insert into public.frota_gestao_nf_versoes(id,nota_id,rascunho_id,numero_versao,estado,emissao,total,dados_fiscais,motivo)
    values(versao,nota,p_id,1,'finalizada',(plano->>'emissao')::date,(resumo->>'total')::numeric,r.dados,'Lançamento inicial conferido');
  insert into public.frota_gestao_operacoes(id,tipo,hash_entrada,resultado,rascunho_id) values(p_chave,'finalizar_nf',assinatura,'{}',p_id);
  for linha in select * from jsonb_array_elements(r.dados#>'{nota,itens}') loop
    cfg:=plano->'itens'->(linha->>'numero');select * into catalogo from public.frota_gestao_catalogo where id=(cfg->>'catalogo_id')::uuid;
    originais:=r.dados#>'{nota,dados_fiscais,nota,det}';
    select e#>>'{prod,xProd}' into descricao_origem from jsonb_array_elements(case when jsonb_typeof(originais)='array' then originais else jsonb_build_array(originais) end) e where e->>'@nItem'=linha->>'numero';
    q:=(linha->>'quantidade')::numeric;fator:=(cfg->>'fator')::numeric;liquido:=(linha->>'bruto')::numeric-(linha->>'desconto')::numeric+(linha->>'acrescimo')::numeric;item_id:=gen_random_uuid();
    insert into public.frota_gestao_nf_itens(id,versao_id,numero_item,codigo_original,descricao_original,descricao_conferida,catalogo_id,natureza,quantidade_compra,unidade_compra,fator_conversao,valor_unitario,bruto,desconto,acrescimo,liquido)
      values(item_id,versao,(linha->>'numero')::integer,coalesce(linha->>'codigo',''),coalesce(descricao_origem,linha->>'descricao'),linha->>'descricao',catalogo.id,catalogo.natureza,q,linha->>'unidade',fator,(linha->>'unitario')::numeric,(linha->>'bruto')::numeric,(linha->>'desconto')::numeric,(linha->>'acrescimo')::numeric,liquido);
    if catalogo.natureza='peca' then
      lote_id:=gen_random_uuid();insert into public.frota_gestao_lotes(id,nf_item_id,catalogo_id,quantidade_origem,custo_total,adquirido_em) values(lote_id,item_id,catalogo.id,q*fator,liquido,(plano->>'emissao')::date);
      insert into public.frota_gestao_movimentos(lote_id,local_id,tipo,quantidade,valor,operacao_atomica,motivo)
        values(lote_id,(cfg->>'local_id')::uuid,'entrada_nf',q*fator,liquido,p_chave,'Aquisição por NF finalizada');
    end if;
    indice:=0;
    for parcela in select * from jsonb_array_elements(cfg->'rateios') loop
      qp:=(parcela->>'quantidade')::numeric;vp:=(parcela->>'valor')::numeric;os_id:=null;os_item:=null;veiculo:=null;
      if parcela->>'destino'='veiculo' then
        veiculo:=(parcela->>'veiculo_id')::uuid;contexto:=plano->'veiculos'->veiculo::text;
        if nullif(parcela->>'os_item_id','') is not null then
          select c into candidato from jsonb_array_elements(public.frota_gestao_candidatas_nf(veiculo,contexto,catalogo.id,cfg->>'manutencao')) c where c->>'item_id'=parcela->>'os_item_id';
          if candidato is null or (candidato->>'pendente')::numeric<qp*fator then raise exception 'Pendência da OS insuficiente após os rateios anteriores. Reveja a distribuição.';end if;
          os_id:=(candidato->>'os_id')::uuid;os_item:=(parcela->>'os_item_id')::uuid;
        else
          os_id:=(criadas->>veiculo::text)::uuid;
          if os_id is null then
            os_id:=gen_random_uuid();select operacao_id into unidade_os from public.veiculos where id=veiculo;
            insert into public.frota_gestao_os(id,veiculo_id,operacao_id,origem,nota_origem_id,chave_criacao,descricao,medidor,contexto_id,periodo_inicio,periodo_fim)
              values(os_id,veiculo,unidade_os,'nota',nota,gen_random_uuid(),'OS originada da NF '||(r.dados#>>'{nota,numero}'),contexto->>'medidor',btrim(contexto->>'contexto'),(contexto->>'inicio')::date,(contexto->>'fim')::date) returning numero into numero_os;
            criadas:=criadas||jsonb_build_object(veiculo::text,os_id);ordens:=ordens||jsonb_build_array(jsonb_build_object('id',os_id,'numero',numero_os::text));
          end if;
          chave_item:=(linha->>'numero')||':'||veiculo::text;os_item:=(itens_criados->>chave_item)::uuid;
          if os_item is null then
            os_item:=gen_random_uuid();insert into public.frota_gestao_os_itens(id,os_id,catalogo_id,descricao,tipo_manutencao,quantidade_prevista,valor_previsto,previsao_informada,executado_em)
              values(os_item,os_id,catalogo.id,linha->>'descricao',cfg->>'manutencao',qp*fator,0,false,case when catalogo.natureza='servico' then nullif(parcela->>'executado_em','')::date else null end);
            itens_criados:=itens_criados||jsonb_build_object(chave_item,os_item);
          else update public.frota_gestao_os_itens set quantidade_prevista=quantidade_prevista+qp*fator where id=os_item;end if;
        end if;
      end if;
      vinculo:=gen_random_uuid();insert into public.frota_gestao_vinculos(id,nf_item_id,os_id,os_item_id,veiculo_id,unidade_custo_id,quantidade,valor_documentado,centro_custo,conta_id,categoria_id,classificacao)
        values(vinculo,item_id,os_id,os_item,veiculo,(parcela->>'unidade_id')::uuid,qp,vp,parcela->>'centro_custo',(parcela->>'conta_id')::uuid,(parcela->>'categoria_id')::uuid,jsonb_build_object('destino',parcela->>'destino','rateio_indice',indice));
      if catalogo.natureza='servico' and veiculo is not null then
        insert into public.frota_gestao_custos(veiculo_id,unidade_custo_id,vinculo_id,origem,valor,executado_em) values(veiculo,(parcela->>'unidade_id')::uuid,vinculo,'servico',vp,(parcela->>'executado_em')::date);
      end if;
      indice:=indice+1;
    end loop;
  end loop;
  if nullif(r.dados->>'referencia','') is not null then insert into public.frota_gestao_referencias(versao_id,url,descricao) values(versao,r.dados->>'referencia','Documento externo conferido');end if;
  finalizada:=clock_timestamp();update public.frota_gestao_rascunhos set finalizado_em=finalizada where id=p_id;
  resultado_final:=jsonb_build_object('nota_id',nota,'versao_id',versao,'operacao_id',p_chave,'ordens',ordens,'finalizada_em',finalizada,
    'rascunho_id',p_id,'numero_nf',r.dados#>>'{nota,numero}','total',resumo->>'total','fornecedor',resumo->>'fornecedor','autor_id',auth.uid());
  update public.frota_gestao_operacoes set resultado=resultado_final where id=p_chave;
  return resultado_final;
end $$;
revoke all on function public.frota_gestao_finalizar_nf(uuid,bigint,uuid,boolean) from public,anon;
grant execute on function public.frota_gestao_finalizar_nf(uuid,bigint,uuid,boolean) to authenticated;

create or replace function public.frota_gestao_recibo_nf(p_id uuid)
returns jsonb language plpgsql stable security definer set search_path=pg_catalog,public as $$
begin
  if not public.frota_gestao_usuario_ativo() then raise exception using errcode='42501',message='Conta inativa ou não autenticada.';end if;
  return (select resultado||jsonb_build_object('autor_id',criado_por,'registrado_em',criado_em) from public.frota_gestao_operacoes where rascunho_id=p_id and tipo='finalizar_nf');
end $$;
revoke all on function public.frota_gestao_recibo_nf(uuid) from public,anon;
grant execute on function public.frota_gestao_recibo_nf(uuid) to authenticated;

create or replace function public.frota_gestao_cadastros_nf()
returns jsonb language plpgsql stable security definer set search_path=pg_catalog,public as $$
begin
  if not public.frota_gestao_usuario_ativo() then raise exception using errcode='42501',message='Conta inativa ou não autenticada.';end if;
  return jsonb_build_object('fornecedores',coalesce((select jsonb_agg(jsonb_build_object('id',fornecedor_id,'nome',razao_social,'documento',documento) order by razao_social) from public.frota_gestao_fornecedores),'[]'::jsonb),
    'catalogo',coalesce((select jsonb_agg(jsonb_build_object('id',id,'nome',descricao,'natureza',natureza,'unidade',unidade_padrao) order by descricao) from public.frota_gestao_catalogo where ativo),'[]'::jsonb),
    'contas',coalesce((select jsonb_agg(jsonb_build_object('id',id,'nome',nome) order by nome) from public.frota_gestao_contas where ativa),'[]'::jsonb),
    'categorias',coalesce((select jsonb_agg(jsonb_build_object('id',id,'nome',nome) order by nome) from public.frota_gestao_categorias where ativa),'[]'::jsonb),
    'centros',coalesce((select jsonb_agg(jsonb_build_object('id',codigo,'nome',nome) order by codigo) from public.frota_centros_custo),'[]'::jsonb),
    'locais',coalesce((select jsonb_agg(jsonb_build_object('id',l.id,'nome',l.nome||' · '||o.nome) order by o.nome,l.nome) from public.frota_gestao_locais l join public.operacoes o on o.id=l.operacao_id where o.ativa),'[]'::jsonb));
end $$;
revoke all on function public.frota_gestao_cadastros_nf() from public,anon;
grant execute on function public.frota_gestao_cadastros_nf() to authenticated;

create or replace function public.frota_gestao_abrir_os(p_chave uuid,p_dados jsonb)
returns jsonb language plpgsql security definer set search_path=pg_catalog,public as $$
declare existente public.frota_gestao_os;veiculo public.veiculos;assinatura text;ordem uuid:=gen_random_uuid();numero_os bigint;item jsonb;q numeric;valor numeric;
begin
  perform public.frota_gestao_exigir_escrita(false);
  if not public.frota_gestao_usuario_ativo() then raise exception using errcode='42501',message='Conta inativa ou não autenticada.';end if;
  if p_chave is null or p_dados is null or jsonb_typeof(p_dados)<>'object' or octet_length(p_dados::text)>1048576 then raise exception 'Dados de abertura inválidos.';end if;
  assinatura:=encode(sha256(convert_to(p_dados::text,'UTF8')),'hex');
  perform pg_advisory_xact_lock(hashtextextended('os-abertura:'||p_chave::text,0));
  select * into existente from public.frota_gestao_os where chave_criacao=p_chave;
  if found then
    if existente.hash_abertura is distinct from assinatura then raise exception 'Chave de abertura reutilizada com dados diferentes.';end if;
    return jsonb_build_object('id',existente.id,'numero',existente.numero::text);
  end if;
  perform pg_advisory_xact_lock(hashtextextended('nf-veiculo:'||(p_dados->>'veiculo_id'),0));
  select * into veiculo from public.veiculos where id=(p_dados->>'veiculo_id')::uuid for share;
  if not found or veiculo.placa is distinct from p_dados->>'placa' or not exists(select 1 from public.operacoes where id=veiculo.operacao_id and ativa) then raise exception 'Confira veículo, placa e unidade operacional.';end if;
  if nullif(btrim(p_dados->>'contexto'),'') is null or length(p_dados->>'contexto')>200 or nullif(btrim(p_dados->>'descricao'),'') is null
    or p_dados->>'medidor' is null or p_dados->>'medidor' not in ('km','horimetro') or coalesce(p_dados->>'inicio','') !~ '^[0-9]{4}-[0-9]{2}-[0-9]{2}$' or coalesce(p_dados->>'fim','') !~ '^[0-9]{4}-[0-9]{2}-[0-9]{2}$'
    or (p_dados->>'fim')::date<(p_dados->>'inicio')::date or jsonb_typeof(p_dados->'itens') is distinct from 'array' or jsonb_array_length(p_dados->'itens') not between 1 and 100 then raise exception 'Confira contexto, descrição, período, medidor e itens da OS.';end if;
  insert into public.frota_gestao_os(id,veiculo_id,operacao_id,origem,chave_criacao,descricao,medidor,contexto_id,periodo_inicio,periodo_fim,hash_abertura)
    values(ordem,veiculo.id,veiculo.operacao_id,'manual',p_chave,p_dados->>'descricao',p_dados->>'medidor',btrim(p_dados->>'contexto'),(p_dados->>'inicio')::date,(p_dados->>'fim')::date,assinatura) returning numero into numero_os;
  for item in select * from jsonb_array_elements(p_dados->'itens') loop
    if not exists(select 1 from public.frota_gestao_catalogo where id=(item->>'catalogo_id')::uuid and ativo) or item->>'manutencao' is null or item->>'manutencao' not in ('preventiva','corretiva') then raise exception 'Confira catálogo e manutenção dos itens da OS.';end if;
    q:=public.frota_gestao_decimal_nf(item->>'quantidade',6);if q<=0 then raise exception 'Quantidade prevista deve ser positiva.';end if;
    valor:=case when nullif(item->>'valor','') is null then 0 else public.frota_gestao_decimal_nf(item->>'valor',2) end;
    insert into public.frota_gestao_os_itens(os_id,catalogo_id,descricao,tipo_manutencao,quantidade_prevista,valor_previsto,previsao_informada)
      values(ordem,(item->>'catalogo_id')::uuid,(select descricao from public.frota_gestao_catalogo where id=(item->>'catalogo_id')::uuid),item->>'manutencao',q,valor,nullif(item->>'valor','') is not null);
  end loop;
  return jsonb_build_object('id',ordem,'numero',numero_os::text);
end $$;
revoke all on function public.frota_gestao_abrir_os(uuid,jsonb) from public,anon;
grant execute on function public.frota_gestao_abrir_os(uuid,jsonb) to authenticated;

create or replace function public.frota_gestao_preparacao_nf()
returns jsonb language plpgsql stable security definer set search_path=pg_catalog,public as $$
declare anterior jsonb;
begin
  anterior:=public.frota_gestao_preparacao_rascunhos();
  perform periodo_inicio,periodo_fim,hash_abertura from public.frota_gestao_os where false;
  perform previsao_informada from public.frota_gestao_os_itens where false;
  perform rascunho_id from public.frota_gestao_operacoes where false;
  return jsonb_build_object('contrato','03','disponivel',anterior->>'contrato'='02' and (anterior->>'funcoes_disponiveis')::boolean and (anterior->>'expiracao_agendada')::boolean
    and has_function_privilege('authenticated','public.frota_gestao_finalizar_nf(uuid,bigint,uuid,boolean)','EXECUTE')
    and has_function_privilege('authenticated','public.frota_gestao_conferir_nf(uuid,bigint)','EXECUTE')
    and has_function_privilege('authenticated','public.frota_gestao_cadastros_nf()','EXECUTE')
    and has_function_privilege('authenticated','public.frota_gestao_recibo_nf(uuid)','EXECUTE')
    and has_function_privilege('authenticated','public.frota_gestao_abrir_os(uuid,jsonb)','EXECUTE'));
end $$;
revoke all on function public.frota_gestao_preparacao_nf() from public,anon;
grant execute on function public.frota_gestao_preparacao_nf() to authenticated;

-- ===== 20261103000700_frota_89_ciclo04.sql =====
-- Origem: SQL 89 do módulo Gestão da Frota (extraído do laboratório, sem alterações de lógica).
-- PREPARADO, NÃO EXECUTADO. Aplicação manual após 88; consultar BANCO-CICLO-01.md.
-- (begin/commit removidos: o Supabase CLI já executa cada migration em uma transação)
do $$
begin
  if to_regprocedure('public.frota_gestao_preparacao_nf()') is null
    or to_regprocedure('public.frota_gestao_decimal_nf(text,integer)') is null then
    raise exception 'Instale e verifique 84 a 88 antes do Ciclo 04.';
  end if;
end $$;

-- Ampliação restrita ao domínio novo, sem converter ou excluir registros.
alter table public.frota_gestao_operacoes drop constraint if exists frota_gestao_operacoes_tipo_check;
alter table public.frota_gestao_operacoes add constraint frota_gestao_operacoes_tipo_check
  check(tipo in ('finalizar_nf','reservar','liberar','aplicar','transferir','estornar','corrigir','cancelar','ajustar','devolver','encerrar_os'));
alter table public.frota_gestao_estornos add column if not exists destino_fisico text;
alter table public.frota_gestao_estornos add column if not exists local_destino_id uuid references public.frota_gestao_locais(id);
alter table public.frota_gestao_estornos add column if not exists referencia_fiscal text;
do $$
begin
  if not exists(select 1 from pg_constraint where conrelid='public.frota_gestao_estornos'::regclass and conname='frota_gestao_estorno_destino') then
    alter table public.frota_gestao_estornos add constraint frota_gestao_estorno_destino check(
      destino_fisico is null or
      (destino_fisico='estoque' and retorno_fisico_confirmado and local_destino_id is not null) or
      (destino_fisico in ('fornecedor','sem_retorno') and not retorno_fisico_confirmado and local_destino_id is null
        and (destino_fisico<>'fornecedor' or nullif(btrim(referencia_fiscal),'') is not null)));
  end if;
end $$;
create index if not exists frota_gestao_reservas_os on public.frota_gestao_reservas(os_item_id);
create index if not exists frota_gestao_estornos_aplicacao on public.frota_gestao_estornos(aplicacao_id);

create or replace function public.frota_gestao_preservar_estoque()
returns trigger language plpgsql set search_path=pg_catalog,public as $$
begin
  raise exception 'Histórico de estoque e custos é imutável. Registre operação compensatória.';
end $$;
revoke all on function public.frota_gestao_preservar_estoque() from public,anon,authenticated;
do $$
declare tabela text;
begin
  foreach tabela in array array['movimentos','aplicacoes','estornos','custos'] loop
    execute format('drop trigger if exists preservar_estoque on public.%I','frota_gestao_'||tabela);
    execute format('create trigger preservar_estoque before update or delete on public.%I for each row execute function public.frota_gestao_preservar_estoque()','frota_gestao_'||tabela);
  end loop;
end $$;

create or replace function public.frota_gestao_validar_encerramento()
returns trigger language plpgsql set search_path=pg_catalog,public as $$
begin
  if new.estado='encerrada' and exists(select 1 from public.frota_gestao_reservas r
    join public.frota_gestao_os_itens i on i.id=r.os_item_id where i.os_id=new.id and r.quantidade>r.aplicada+r.liberada) then
    raise exception 'OS com reservas pendentes: aplique ou libere antes de encerrar.';
  end if;
  return new;
end $$;
revoke all on function public.frota_gestao_validar_encerramento() from public,anon,authenticated;
drop trigger if exists validar_encerramento on public.frota_gestao_os;
create trigger validar_encerramento before update on public.frota_gestao_os for each row execute function public.frota_gestao_validar_encerramento();

create or replace function public.frota_gestao_saldo_lote(p_lote uuid,p_local uuid)
returns table(fisico numeric,reservado numeric,valor numeric)
language sql stable security definer set search_path=pg_catalog,public as $$
  select coalesce((select sum(case when tipo in ('entrada_nf','transferencia_entrada','ajuste_entrada','retorno_fisico') then quantidade else -quantidade end)
    from public.frota_gestao_movimentos where lote_id=p_lote and local_id=p_local),0),
    coalesce((select sum(quantidade-aplicada-liberada) from public.frota_gestao_reservas where lote_id=p_lote and local_id=p_local),0),
    coalesce((select sum(case when tipo in ('entrada_nf','transferencia_entrada','ajuste_entrada','retorno_fisico') then valor else -valor end)
    from public.frota_gestao_movimentos where lote_id=p_lote and local_id=p_local),0)
$$;
revoke all on function public.frota_gestao_saldo_lote(uuid,uuid) from public,anon,authenticated;

-- Centavos residuais pertencem à última baixa do saldo do mesmo lote/local.
create or replace function public.frota_gestao_valorar_baixa(p_quantidade numeric,p_saldo numeric,p_valor numeric)
returns numeric language plpgsql immutable set search_path=pg_catalog,public as $$
begin
  if p_quantidade<=0 or p_saldo<p_quantidade or p_valor<0 then raise exception 'Quantidade ou valor de estoque inconsistente.';end if;
  return case when p_quantidade=p_saldo then p_valor else round(p_valor*p_quantidade/p_saldo,2) end;
end $$;
revoke all on function public.frota_gestao_valorar_baixa(numeric,numeric,numeric) from public,anon,authenticated;

create or replace function public.frota_gestao_operar_estoque(p_chave uuid,p_dados jsonb,p_confirmado boolean)
returns jsonb language plpgsql security definer set search_path=pg_catalog,public as $$
declare
  tipo text:=p_dados->>'tipo';assinatura text;anterior public.frota_gestao_operacoes;
  lote public.frota_gestao_lotes;reserva public.frota_gestao_reservas;aplicacao public.frota_gestao_aplicacoes;
  ordem public.frota_gestao_os;item public.frota_gestao_os_itens;custo_original public.frota_gestao_custos;
  lote_id uuid:=nullif(p_dados->>'lote_id','')::uuid;local_id uuid:=nullif(p_dados->>'local_id','')::uuid;
  destino uuid:=nullif(p_dados->>'destino_id','')::uuid;item_id uuid:=nullif(p_dados->>'os_item_id','')::uuid;
  reserva_id uuid:=nullif(p_dados->>'reserva_id','')::uuid;aplicacao_id uuid:=nullif(p_dados->>'aplicacao_id','')::uuid;
  ordem_id uuid:=nullif(p_dados->>'os_id','')::uuid;veiculo uuid;unidade uuid;unidade_destino uuid;
  unidade_financeira uuid:=nullif(p_dados->>'unidade_custo_id','')::uuid;
  q numeric;v numeric:=0;saldo record;q_estornada numeric;v_estornado numeric;data_real date;
  registro uuid:=gen_random_uuid();movimento text;motivo text:=btrim(coalesce(p_dados->>'motivo',''));
  referencia text:=nullif(btrim(p_dados->>'referencia_fiscal'),'');destino_fisico text:=p_dados->>'destino_fisico';recibo_resultado jsonb;
begin
  perform public.frota_gestao_exigir_escrita(false);
  if not public.frota_gestao_usuario_ativo() then raise exception using errcode='42501',message='Conta inativa ou não autenticada.';end if;
  if current_setting('transaction_isolation')<>'read committed' then raise exception 'Operações de estoque exigem isolamento READ COMMITTED.';end if;
  if p_chave is null or p_confirmado is distinct from true or jsonb_typeof(p_dados) is distinct from 'object' or octet_length(p_dados::text)>16384
    or tipo is null or tipo not in ('reservar','liberar','aplicar','transferir','ajustar','devolver','estornar','encerrar_os') then raise exception 'Confira os dados e a confirmação explícita da operação.';end if;
  assinatura:=encode(sha256(convert_to(jsonb_build_object('contrato','04','dados',p_dados)::text,'UTF8')),'hex');
  perform pg_advisory_xact_lock(hashtextextended('frota-estoque-op:'||p_chave::text,0));
  select * into anterior from public.frota_gestao_operacoes where id=p_chave;
  if found then
    if anterior.tipo is distinct from tipo or anterior.hash_entrada is distinct from assinatura then raise exception 'Chave reutilizada com dados diferentes.';end if;
    return anterior.resultado;
  end if;
  if motivo='' or length(motivo)>2000 then raise exception 'Justificativa obrigatória, até 2000 caracteres.';end if;
  if tipo<>'encerrar_os' then
    q:=public.frota_gestao_decimal_nf(p_dados->>'quantidade',6);
    if q<=0 then raise exception 'Quantidade deve ser positiva.';end if;
  end if;
  -- As referências fornecidas devem corresponder à reserva/aplicação original.
  if tipo in ('liberar','aplicar') and reserva_id is not null then
    select * into reserva from public.frota_gestao_reservas where id=reserva_id;
    if not found or lote_id is distinct from reserva.lote_id or local_id is distinct from reserva.local_id or item_id is distinct from reserva.os_item_id then raise exception 'Reserva, item, lote e local não correspondem.';end if;
  elsif tipo='liberar' then raise exception 'Selecione a reserva a liberar.';
  end if;
  if tipo='estornar' then
    select * into aplicacao from public.frota_gestao_aplicacoes where id=aplicacao_id;
    if not found or lote_id is distinct from aplicacao.lote_id or local_id is distinct from aplicacao.local_id or item_id is distinct from aplicacao.os_item_id then raise exception 'Aplicação, item, lote e local não correspondem.';end if;
  end if;
  if tipo in ('reservar','liberar','aplicar','estornar','encerrar_os') then
    if tipo<>'encerrar_os' then
      select * into item from public.frota_gestao_os_itens where id=item_id;
      if not found or ordem_id is distinct from item.os_id then raise exception 'Item não pertence à OS informada.';end if;
    end if;
    select veiculo_id into veiculo from public.frota_gestao_os where id=ordem_id;
    if not found then raise exception 'OS não encontrada.';end if;
    -- Mesma ordem de bloqueio do finalizador 88: veículo, OS, item e depois lote.
    perform pg_advisory_xact_lock(hashtextextended('nf-veiculo:'||veiculo::text,0));
    select * into ordem from public.frota_gestao_os where id=ordem_id for update;
    if ordem.veiculo_id is distinct from nullif(p_dados->>'veiculo_id','')::uuid
      or not exists(select 1 from public.veiculos where id=ordem.veiculo_id and placa=p_dados->>'placa') then raise exception 'Confira veículo e placa da OS.';end if;
    if tipo in ('reservar','aplicar','encerrar_os') and ordem.estado not in ('aberta','em_execucao') then raise exception 'OS não está aberta para esta operação.';end if;
    if tipo<>'encerrar_os' then perform 1 from public.frota_gestao_os_itens where id=item_id for update;end if;
    if not exists(select 1 from public.operacoes where id=ordem.operacao_id and ativa) then raise exception 'Unidade da OS inativa.';end if;
  end if;
  if tipo='encerrar_os' then
    if exists(select 1 from public.frota_gestao_reservas r join public.frota_gestao_os_itens i on i.id=r.os_item_id where i.os_id=ordem_id and r.quantidade>r.aplicada+r.liberada) then
      raise exception 'OS com reservas pendentes: aplique ou libere as peças antes de encerrar.';
    end if;
  else
    perform pg_advisory_xact_lock(hashtextextended('frota-estoque-lote:'||lote_id::text,0));
    select * into lote from public.frota_gestao_lotes where id=lote_id for update;
    if not found then raise exception 'Lote não encontrado.';end if;
    if not exists(select 1 from public.frota_gestao_nf_itens i join public.frota_gestao_nf_versoes n on n.id=i.versao_id
      where i.id=lote.nf_item_id and n.estado='finalizada' and i.natureza='peca' and i.catalogo_id=lote.catalogo_id
        and i.quantidade_compra*i.fator_conversao=lote.quantidade_origem and i.liquido=lote.custo_total)
      or not exists(select 1 from public.frota_gestao_movimentos m where m.lote_id=lote.id and m.tipo='entrada_nf'
        and m.quantidade=lote.quantidade_origem and m.valor=lote.custo_total) then raise exception 'Lote sem aquisição fiscal e entrada original conciliadas.';end if;
    select l.operacao_id into unidade from public.frota_gestao_locais l join public.operacoes o on o.id=l.operacao_id where l.id=local_id and o.ativa;
    if not found then raise exception 'Local ou unidade de origem inválida.';end if;
    if tipo in ('reservar','aplicar') then
      if lote.catalogo_id is distinct from item.catalogo_id then raise exception 'Produto do lote incompatível com o item da OS.';end if;
      if not exists(select 1 from public.frota_gestao_catalogo where id=lote.catalogo_id and ativo and natureza='peca') then raise exception 'Produto inativo ou não é peça.';end if;
    end if;
    select * into saldo from public.frota_gestao_saldo_lote(lote_id,local_id);
    if saldo.fisico<0 or saldo.reservado<0 or saldo.reservado>saldo.fisico or saldo.valor<0 or (saldo.fisico=0 and saldo.valor<>0) then raise exception 'Saldo inconsistente: solicite conferência do histórico antes de operar.';end if;
    if reserva_id is not null and tipo in ('aplicar','liberar') then
      select * into reserva from public.frota_gestao_reservas where id=reserva_id for update;
      if q>reserva.quantidade-reserva.aplicada-reserva.liberada then raise exception 'Quantidade superior à reserva pendente.';end if;
    end if;
    if tipo in ('reservar','transferir','devolver') or (tipo='ajustar' and p_dados->>'sentido'='saida') or (tipo='aplicar' and reserva_id is null) then
      if q>saldo.fisico-saldo.reservado then raise exception 'Saldo disponível insuficiente.';end if;
    end if;
    if tipo='aplicar' and q>saldo.fisico then raise exception 'Saldo físico insuficiente.';end if;
    if tipo in ('aplicar','transferir','devolver') or (tipo='ajustar' and p_dados->>'sentido'='saida') then
      v:=public.frota_gestao_valorar_baixa(q,saldo.fisico,saldo.valor);
    end if;
    if tipo in ('transferir','devolver') and referencia is null then raise exception 'Informe a referência da documentação fiscal aplicável.';end if;
    if tipo='transferir' then
      select l.operacao_id into unidade_destino from public.frota_gestao_locais l join public.operacoes o on o.id=l.operacao_id where l.id=destino and o.ativa;
      if not found or unidade_destino=unidade then raise exception 'Selecione local de outra unidade ativa.';end if;
    end if;
    if tipo='ajustar' then
      if p_dados->>'sentido' is null or p_dados->>'sentido' not in ('entrada','saida') then raise exception 'Informe o sentido do ajuste.';end if;
      if p_dados->>'sentido'='entrada' then v:=round(lote.custo_total*q/lote.quantidade_origem,2);end if;
    end if;
    if tipo in ('aplicar','estornar') then
      if tipo='aplicar' and not exists(select 1 from public.operacoes where id=unidade_financeira and ativa) then raise exception 'Selecione a unidade responsável pelo custo da aplicação.';end if;
      if coalesce(p_dados->>'data','') !~ '^[0-9]{4}-[0-9]{2}-[0-9]{2}$' then raise exception 'Informe a data efetiva.';end if;
      data_real:=(p_dados->>'data')::date;
      if data_real>(clock_timestamp() at time zone 'America/Sao_Paulo')::date or data_real<lote.adquirido_em or (tipo='estornar' and data_real<aplicacao.aplicada_em) then raise exception 'Data efetiva incompatível com aquisição, aplicação ou data atual.';end if;
    end if;
    if tipo='estornar' then
      perform 1 from public.frota_gestao_aplicacoes where id=aplicacao_id for update;
      select coalesce(sum(e.quantidade),0),coalesce(sum(e.valor),0) into q_estornada,v_estornado from public.frota_gestao_estornos e where e.aplicacao_id=aplicacao.id;
      if q>aplicacao.quantidade-q_estornada then raise exception 'Quantidade superior à aplicação ainda não estornada.';end if;
      v:=public.frota_gestao_valorar_baixa(q,aplicacao.quantidade-q_estornada,aplicacao.custo-v_estornado);
      select c.* into custo_original from public.frota_gestao_custos c where c.aplicacao_id=aplicacao.id and c.origem='peca_aplicada';
      if not found or custo_original.veiculo_id is distinct from ordem.veiculo_id or custo_original.valor is distinct from aplicacao.custo then raise exception 'Custo da aplicação não encontrado ou incompatível com a OS.';end if;
      if destino_fisico is null or destino_fisico not in ('estoque','fornecedor','sem_retorno') then raise exception 'Identifique o destino físico da peça.';end if;
      if destino_fisico='estoque' then
        if p_dados->'apta_disponivel' is distinct from 'true'::jsonb then raise exception 'Confirme a disponibilidade física e aptidão para uso.';end if;
        if not exists(select 1 from public.frota_gestao_locais l join public.operacoes o on o.id=l.operacao_id where l.id=destino and o.ativa) then raise exception 'Local de retorno inválido.';end if;
      elsif destino is not null or p_dados->'apta_disponivel'='true'::jsonb then raise exception 'Sem retorno ao estoque: não informe local nem confirme disponibilidade.';
      end if;
      if destino_fisico='fornecedor' and referencia is null then raise exception 'Informe a referência fiscal da devolução ao fornecedor.';end if;
      if destino_fisico='sem_retorno' and (nullif(btrim(p_dados->>'destino_descricao'),'') is null or length(p_dados->>'destino_descricao')>1000) then raise exception 'Descreva o destino físico da peça sem retorno ao estoque, até 1000 caracteres.';end if;
    end if;
  end if;
  insert into public.frota_gestao_operacoes(id,tipo,hash_entrada,resultado) values(p_chave,tipo,assinatura,'{}');
  if tipo='reservar' then
    insert into public.frota_gestao_reservas(id,lote_id,local_id,os_item_id,quantidade) values(registro,lote_id,local_id,item_id,q);
  elsif tipo='liberar' then
    update public.frota_gestao_reservas set liberada=liberada+q,estado=case when aplicada+liberada+q=quantidade then 'liberada' else 'ativa' end where id=reserva_id;
    registro:=reserva_id;
  elsif tipo='aplicar' then
    insert into public.frota_gestao_aplicacoes(id,lote_id,local_id,os_item_id,reserva_id,quantidade,custo,aplicada_em,chave_idempotencia)
      values(registro,lote_id,local_id,item_id,reserva_id,q,v,data_real,p_chave);
    insert into public.frota_gestao_movimentos(lote_id,local_id,tipo,quantidade,valor,operacao_atomica,aplicacao_id,motivo)
      values(lote_id,local_id,'aplicacao',q,v,p_chave,registro,motivo);
    insert into public.frota_gestao_custos(veiculo_id,unidade_custo_id,aplicacao_id,origem,valor,executado_em)
      values(ordem.veiculo_id,unidade_financeira,registro,'peca_aplicada',v,data_real);
    if reserva_id is not null then
      update public.frota_gestao_reservas set aplicada=aplicada+q,estado=case when aplicada+liberada+q=quantidade then 'aplicada' else 'ativa' end where id=reserva_id;
    end if;
  elsif tipo='transferir' then
    insert into public.frota_gestao_movimentos(lote_id,local_id,tipo,quantidade,valor,operacao_atomica,motivo,referencia_fiscal)
      values(lote_id,local_id,'transferencia_saida',q,v,p_chave,motivo,referencia),(lote_id,destino,'transferencia_entrada',q,v,p_chave,motivo,referencia);
    registro:=p_chave;
  elsif tipo in ('ajustar','devolver') then
    movimento:=case when tipo='devolver' then 'devolucao' when p_dados->>'sentido'='entrada' then 'ajuste_entrada' else 'ajuste_saida' end;
    insert into public.frota_gestao_movimentos(id,lote_id,local_id,tipo,quantidade,valor,operacao_atomica,motivo,referencia_fiscal)
      values(registro,lote_id,local_id,movimento,q,v,p_chave,motivo,referencia);
  elsif tipo='estornar' then
    insert into public.frota_gestao_estornos(id,aplicacao_id,quantidade,valor,retorno_fisico_confirmado,motivo,chave_idempotencia,destino_fisico,local_destino_id,referencia_fiscal)
      values(registro,aplicacao.id,q,v,destino_fisico='estoque',case when destino_fisico='sem_retorno' then motivo||' · Destino físico: '||btrim(p_dados->>'destino_descricao') else motivo end,p_chave,destino_fisico,destino,referencia);
    insert into public.frota_gestao_custos(veiculo_id,unidade_custo_id,estorno_id,custo_estornado_id,origem,valor,executado_em)
      values(custo_original.veiculo_id,custo_original.unidade_custo_id,registro,custo_original.id,'estorno',-v,data_real);
    if destino_fisico='estoque' then
      insert into public.frota_gestao_movimentos(lote_id,local_id,tipo,quantidade,valor,operacao_atomica,estorno_id,motivo)
        values(lote_id,destino,'retorno_fisico',q,v,p_chave,registro,motivo);
    end if;
  elsif tipo='encerrar_os' then
    update public.frota_gestao_os set estado='encerrada',encerrada_em=clock_timestamp() where id=ordem_id;
    registro:=ordem_id;
  end if;
  recibo_resultado:=jsonb_build_object('contrato','04','operacao_id',p_chave,'tipo',tipo,'registro_id',registro,
    'quantidade',coalesce(q,0)::text,'valor',v::text,'autor_id',auth.uid(),'confirmada_em',clock_timestamp(),'motivo',motivo,
    'dados',p_dados,'unidade_id',coalesce(unidade,ordem.operacao_id),'unidade_destino_id',unidade_destino,'produto_id',lote.catalogo_id);
  update public.frota_gestao_operacoes set resultado=recibo_resultado where id=p_chave;
  return recibo_resultado;
end $$;
revoke all on function public.frota_gestao_operar_estoque(uuid,jsonb,boolean) from public,anon;
grant execute on function public.frota_gestao_operar_estoque(uuid,jsonb,boolean) to authenticated;

create or replace function public.frota_gestao_recibo_estoque(p_chave uuid)
returns jsonb language plpgsql stable security definer set search_path=pg_catalog,public as $$
begin
  if not public.frota_gestao_usuario_ativo() then raise exception using errcode='42501',message='Conta inativa ou não autenticada.';end if;
  return (select resultado from public.frota_gestao_operacoes where id=p_chave and tipo in ('reservar','liberar','aplicar','transferir','ajustar','devolver','estornar','encerrar_os'));
end $$;
revoke all on function public.frota_gestao_recibo_estoque(uuid) from public,anon;
grant execute on function public.frota_gestao_recibo_estoque(uuid) to authenticated;

create or replace function public.frota_gestao_preparacao_estoque()
returns jsonb language plpgsql stable security definer set search_path=pg_catalog,public as $$
begin
  if not public.frota_gestao_usuario_ativo() then raise exception using errcode='42501',message='Conta inativa ou não autenticada.';end if;
  perform destino_fisico,local_destino_id,referencia_fiscal from public.frota_gestao_estornos where false;
  return jsonb_build_object('contrato','04','disponivel',
    has_function_privilege('authenticated','public.frota_gestao_operar_estoque(uuid,jsonb,boolean)','EXECUTE')
    and has_function_privilege('authenticated','public.frota_gestao_consultar_estoque(jsonb,integer)','EXECUTE')
    and has_function_privilege('authenticated','public.frota_gestao_opcoes_estoque(text,integer)','EXECUTE')
    and has_function_privilege('authenticated','public.frota_gestao_recibo_estoque(uuid)','EXECUTE'));
end $$;
revoke all on function public.frota_gestao_preparacao_estoque() from public,anon;
grant execute on function public.frota_gestao_preparacao_estoque() to authenticated;

-- Paginação no servidor: nem histórico nem seletores dependem do teto PostgREST.
create or replace function public.frota_gestao_opcoes_estoque(p_busca text,p_pagina integer)
returns jsonb language plpgsql stable security definer set search_path=pg_catalog,public as $$
declare itens jsonb;total bigint;
begin
  if not public.frota_gestao_usuario_ativo() then raise exception using errcode='42501',message='Conta inativa ou não autenticada.';end if;
  if p_pagina is null or p_pagina<0 or length(coalesce(p_busca,''))>100 then raise exception 'Página ou busca inválida.';end if;
  select count(*) into total from public.frota_gestao_os o join public.veiculos v on v.id=o.veiculo_id where o.numero::text ilike '%'||coalesce(p_busca,'')||'%' or v.placa ilike '%'||coalesce(p_busca,'')||'%';
  select coalesce(jsonb_agg(x.dados order by x.numero desc),'[]') into itens from (
    select o.numero,jsonb_build_object('id',o.id,'numero',o.numero::text,'estado',o.estado,'veiculo_id',v.id,'placa',v.placa,'unidade_id',o.operacao_id,
      'itens',coalesce((select jsonb_agg(jsonb_build_object('id',i.id,'catalogo_id',i.catalogo_id,'descricao',i.descricao,'natureza',c.natureza) order by i.id) from public.frota_gestao_os_itens i left join public.frota_gestao_catalogo c on c.id=i.catalogo_id where i.os_id=o.id),'[]')) dados
    from public.frota_gestao_os o join public.veiculos v on v.id=o.veiculo_id
    where o.numero::text ilike '%'||coalesce(p_busca,'')||'%' or v.placa ilike '%'||coalesce(p_busca,'')||'%'
    order by o.numero desc limit 25 offset p_pagina::bigint*25) x;
  return jsonb_build_object('ordens',itens,'total',total,
    'unidades',coalesce((select jsonb_agg(jsonb_build_object('id',id,'nome',nome) order by nome) from public.operacoes where ativa),'[]'),
    'locais',coalesce((select jsonb_agg(jsonb_build_object('id',l.id,'nome',u.nome||' · '||l.nome,'unidade_id',u.id) order by u.nome,l.nome) from public.frota_gestao_locais l join public.operacoes u on u.id=l.operacao_id where u.ativa),'[]'),
    'produtos',coalesce((select jsonb_agg(jsonb_build_object('id',id,'nome',codigo||' · '||descricao,'unidade',unidade_padrao) order by codigo) from public.frota_gestao_catalogo where natureza='peca'),'[]'));
end $$;
revoke all on function public.frota_gestao_opcoes_estoque(text,integer) from public,anon;
grant execute on function public.frota_gestao_opcoes_estoque(text,integer) to authenticated;

create or replace function public.frota_gestao_consultar_estoque(p_filtros jsonb,p_pagina integer)
returns jsonb language plpgsql stable security definer set search_path=pg_catalog,public as $$
declare modo text:=coalesce(p_filtros->>'modo','saldos');total bigint;linhas jsonb;
  unidade uuid:=nullif(p_filtros->>'unidade_id','')::uuid;produto uuid:=nullif(p_filtros->>'produto_id','')::uuid;
  lote uuid:=nullif(p_filtros->>'lote_id','')::uuid;ordem uuid:=nullif(p_filtros->>'os_id','')::uuid;
begin
  if not public.frota_gestao_usuario_ativo() then raise exception using errcode='42501',message='Conta inativa ou não autenticada.';end if;
  if p_pagina is null or p_pagina<0 or modo not in ('saldos','movimentos','reservas','aplicacoes','operacoes') then raise exception 'Consulta inválida.';end if;
  with base as materialized (
    select l.id lote_id,l.catalogo_id,l.adquirido_em,l.custo_total,l.quantidade_origem,c.descricao,c.unidade_padrao,n.numero numero_nf,n.serie,n.id nota_id,
      a.id local_id,a.nome local_nome,u.id unidade_id,u.nome unidade_nome
    from public.frota_gestao_lotes l join public.frota_gestao_catalogo c on c.id=l.catalogo_id
    join public.frota_gestao_nf_itens i on i.id=l.nf_item_id join public.frota_gestao_nf_versoes v on v.id=i.versao_id join public.frota_gestao_notas n on n.id=v.nota_id
    join public.frota_gestao_locais a on exists(select 1 from public.frota_gestao_movimentos m where m.lote_id=l.id and m.local_id=a.id)
    join public.operacoes u on u.id=a.operacao_id
    where (unidade is null or u.id=unidade) and (produto is null or l.catalogo_id=produto) and (lote is null or l.id=lote)
  ), registros as (
    select b.adquirido_em::timestamptz momento,b.lote_id::text||b.local_id::text chave,
      to_jsonb(b)||jsonb_build_object('fisico',s.fisico::text,'reservado',s.reservado::text,'disponivel',(s.fisico-s.reservado)::text,'valor',s.valor::text,'unitario',(b.custo_total/b.quantidade_origem)::text) dados
      from base b cross join lateral public.frota_gestao_saldo_lote(b.lote_id,b.local_id) s where modo='saldos'
      and (coalesce((p_filtros->>'somente_disponiveis')::boolean,false)=false or s.fisico>s.reservado)
    union all
    select m.criado_em,m.id::text,to_jsonb(b)||to_jsonb(m)||jsonb_build_object('quantidade',m.quantidade::text,'valor',m.valor::text,'autor',p.nome)
      from base b join public.frota_gestao_movimentos m on m.lote_id=b.lote_id and m.local_id=b.local_id left join public.perfis p on p.id=m.criado_por
      where modo='movimentos' and (nullif(p_filtros->>'tipo','') is null or m.tipo=p_filtros->>'tipo')
    union all
    select r.criado_em,r.id::text,to_jsonb(b)||to_jsonb(r)||jsonb_build_object('quantidade',r.quantidade::text,'pendente',(r.quantidade-r.aplicada-r.liberada)::text,'os_id',o.id,'os_numero',o.numero::text,'os_estado',o.estado,'placa',v.placa,'veiculo_id',o.veiculo_id,'autor',p.nome)
      from base b join public.frota_gestao_reservas r on r.lote_id=b.lote_id and r.local_id=b.local_id
      join public.frota_gestao_os_itens i on i.id=r.os_item_id join public.frota_gestao_os o on o.id=i.os_id join public.veiculos v on v.id=o.veiculo_id left join public.perfis p on p.id=r.criado_por
      where modo='reservas' and (ordem is null or o.id=ordem)
    union all
    select a.criado_em,a.id::text,to_jsonb(b)||to_jsonb(a)||jsonb_build_object('quantidade',a.quantidade::text,'valor',a.custo::text,'pendente',(a.quantidade-coalesce((select sum(e.quantidade) from public.frota_gestao_estornos e where e.aplicacao_id=a.id),0))::text,'os_id',o.id,'os_numero',o.numero::text,'os_estado',o.estado,'placa',v.placa,'veiculo_id',o.veiculo_id,'autor',p.nome)
      from base b join public.frota_gestao_aplicacoes a on a.lote_id=b.lote_id and a.local_id=b.local_id
      join public.frota_gestao_os_itens i on i.id=a.os_item_id join public.frota_gestao_os o on o.id=i.os_id join public.veiculos v on v.id=o.veiculo_id left join public.perfis p on p.id=a.criado_por
      where modo='aplicacoes' and (ordem is null or o.id=ordem)
    union all
    select a.criado_em,a.id::text,a.resultado||jsonb_build_object('autor',p.nome) from public.frota_gestao_operacoes a left join public.perfis p on p.id=a.criado_por
      where modo='operacoes' and a.tipo in ('reservar','liberar','aplicar','transferir','ajustar','devolver','estornar','encerrar_os')
      and (unidade is null or a.resultado->>'unidade_id'=unidade::text or a.resultado->>'unidade_destino_id'=unidade::text)
      and (produto is null or a.resultado->>'produto_id'=produto::text)
      and (lote is null or a.resultado->'dados'->>'lote_id'=lote::text)
      and (ordem is null or a.resultado->'dados'->>'os_id'=ordem::text)
  ), pagina as (select dados from registros order by case when modo='saldos' then momento end asc,momento desc,chave limit 25 offset p_pagina::bigint*25)
  select (select count(*) from registros),coalesce((select jsonb_agg(dados) from pagina),'[]') into total,linhas;
  return jsonb_build_object('contrato','04','total',total,'linhas',linhas);
end $$;
revoke all on function public.frota_gestao_consultar_estoque(jsonb,integer) from public,anon;
grant execute on function public.frota_gestao_consultar_estoque(jsonb,integer) to authenticated;

-- ===== 20261103000800_frota_90_ciclo05.sql =====
-- Origem: SQL 90 do módulo Gestão da Frota (extraído do laboratório, sem alterações de lógica).
-- PREPARADO, NÃO EXECUTADO. Instalação manual após 89; ver BANCO-CICLO-01.md.
-- (begin/commit removidos: o Supabase CLI já executa cada migration em uma transação)
do $$ begin
  if to_regprocedure('public.frota_gestao_preparacao_estoque()') is null then raise exception 'Confira 84 a 89 completos antes de instalar 90.';end if;
  if exists(select 1 from public.frota_gestao_hbf h join public.frota_gestao_nf_versoes v on v.id=h.versao_id
    where h.estado='emitido' and exists(select 1 from public.frota_gestao_nf_versoes nv where nv.nota_id=v.nota_id and nv.numero_versao>v.numero_versao)) then
    raise exception 'Há HBF emitido de versão fiscal já substituída. Concilie o histórico antes da instalação, sem apagar emissões.';
  end if;
end $$;

-- Uma linha por fato financeiro, inclusive compensações, sem multiplicação pelos rateios.
create or replace view public.frota_gestao_custos_detalhados with(security_invoker=true) as
select c.id,c.origem,c.valor,c.executado_em,c.criado_em,c.custo_estornado_id,
  raiz.origem natureza_custo,c.veiculo_id,v.placa,c.unidade_custo_id,u.nome unidade,
  o.id os_id,o.numero::text numero_os,oi.id os_item_id,oi.tipo_manutencao,oi.descricao componente,
  n.id nota_id,n.numero numero_nf,n.serie,n.fornecedor_id,f.razao_social fornecedor,
  nv.id versao_id,nv.numero_versao,nv.finalizada_em,nv.emissao,
  case when raiz.origem='servico' then vf.categoria_id else cl.categoria_id end categoria_id,
  case when raiz.origem='servico' then vf.centro_custo else cl.centro_custo end centro_custo,
  case when raiz.origem='servico' then vf.conta_id else cl.conta_id end conta_id,
  cat.nome categoria,cc.nome centro_nome,ct.nome conta,ct.codigo conta_codigo,
  a.id aplicacao_id,l.id lote_id,c.estorno_id
from public.frota_gestao_custos c
join public.frota_gestao_custos raiz on raiz.id=coalesce(c.custo_estornado_id,c.id)
join public.veiculos v on v.id=c.veiculo_id join public.operacoes u on u.id=c.unidade_custo_id
left join public.frota_gestao_vinculos vf on vf.id=raiz.vinculo_id
left join public.frota_gestao_aplicacoes a on a.id=raiz.aplicacao_id
left join public.frota_gestao_lotes l on l.id=a.lote_id
join public.frota_gestao_nf_itens ni on ni.id=coalesce(vf.nf_item_id,l.nf_item_id)
join public.frota_gestao_nf_versoes nv on nv.id=ni.versao_id
join public.frota_gestao_notas n on n.id=nv.nota_id
join public.frota_gestao_fornecedores f on f.fornecedor_id=n.fornecedor_id
join public.frota_gestao_os_itens oi on oi.id=coalesce(vf.os_item_id,a.os_item_id)
join public.frota_gestao_os o on o.id=oi.os_id
left join lateral (
  select case when count(distinct coalesce(x.categoria_id::text,'#'))=1 then max(x.categoria_id::text)::uuid end categoria_id,
    case when count(distinct coalesce(x.conta_id::text,'#'))=1 then max(x.conta_id::text)::uuid end conta_id,
    case when count(distinct coalesce(x.centro_custo,'#'))=1 then max(x.centro_custo) end centro_custo
  from public.frota_gestao_vinculos x where x.nf_item_id=ni.id and
    (x.os_item_id=oi.id or (x.os_item_id is null and not exists(select 1 from public.frota_gestao_vinculos ex where ex.nf_item_id=ni.id and ex.os_item_id=oi.id)))
) cl on raiz.origem='peca_aplicada'
left join public.frota_gestao_categorias cat on cat.id=case when raiz.origem='servico' then vf.categoria_id else cl.categoria_id end
left join public.frota_gestao_contas ct on ct.id=case when raiz.origem='servico' then vf.conta_id else cl.conta_id end
left join public.frota_centros_custo cc on cc.codigo=case when raiz.origem='servico' then vf.centro_custo else cl.centro_custo end;
revoke all on public.frota_gestao_custos_detalhados from public,anon,authenticated;

create or replace function public.frota_gestao_ratear_item(p_item uuid,p_total numeric)
returns table(vinculo_id uuid,valor numeric) language sql stable security definer set search_path=pg_catalog,public as $$
  with pesos as (select id,quantidade,sum(quantidade) over() soma from public.frota_gestao_vinculos where nf_item_id=p_item),
  parcelas as (select id,floor(round(p_total*100)*quantidade/soma) base,
    round(p_total*100)*quantidade/soma-floor(round(p_total*100)*quantidade/soma) resto from pesos),
  ordem as (select *,row_number() over(order by resto desc,id) pos,round(p_total*100)-sum(base) over() faltam from parcelas)
  select id,round((base+case when pos<=faltam then 1 else 0 end)/100,2) from ordem
$$;
revoke all on function public.frota_gestao_ratear_item(uuid,numeric) from public,anon,authenticated;

create or replace function public.frota_gestao_filtrar_custos(p_filtros jsonb)
returns setof public.frota_gestao_custos_detalhados language sql stable security definer set search_path=pg_catalog,public as $$
  select c.* from public.frota_gestao_custos_detalhados c
  where c.executado_em between (p_filtros->>'inicio')::date and (p_filtros->>'fim')::date
    and (coalesce(p_filtros->>'unidade_id','')='' or c.unidade_custo_id::text=p_filtros->>'unidade_id')
    and (coalesce(p_filtros->>'veiculo_id','')='' or c.veiculo_id::text=p_filtros->>'veiculo_id')
    and (coalesce(p_filtros->>'fornecedor_id','')='' or c.fornecedor_id::text=p_filtros->>'fornecedor_id')
    and (coalesce(p_filtros->>'manutencao','')='' or c.tipo_manutencao=p_filtros->>'manutencao')
    and (coalesce(p_filtros->>'categoria_id','')='' or coalesce(c.categoria_id::text,'sem_classificacao')=p_filtros->>'categoria_id')
$$;
revoke all on function public.frota_gestao_filtrar_custos(jsonb) from public,anon,authenticated;

create or replace function public.frota_gestao_validar_filtros(p_filtros jsonb)
returns void language plpgsql immutable set search_path=pg_catalog,public as $$
begin
  if jsonb_typeof(p_filtros) is distinct from 'object' or octet_length(p_filtros::text)>4096
    or coalesce(p_filtros->>'inicio','') !~ '^[0-9]{4}-[0-9]{2}-[0-9]{2}$' or coalesce(p_filtros->>'fim','') !~ '^[0-9]{4}-[0-9]{2}-[0-9]{2}$'
    or (p_filtros->>'fim')::date<(p_filtros->>'inicio')::date then raise exception 'Confira o período dos filtros.';end if;
end $$;
revoke all on function public.frota_gestao_validar_filtros(jsonb) from public,anon,authenticated;

create or replace function public.frota_gestao_painel(p_filtros jsonb,p_pagina integer)
returns jsonb language plpgsql stable security definer set search_path=pg_catalog,public as $$
declare resultado jsonb;
begin
  if not public.frota_gestao_usuario_ativo() then raise exception using errcode='42501',message='Conta inativa ou não autenticada.';end if;
  perform public.frota_gestao_validar_filtros(p_filtros);
  if p_pagina is null or p_pagina<0 then raise exception 'Página inválida.';end if;
  with custos as materialized(select * from public.frota_gestao_filtrar_custos(p_filtros)),
  vigentes as materialized(select distinct on(nota_id) * from public.frota_gestao_nf_versoes order by nota_id,numero_versao desc),
  fiscais as materialized(
    select v.*,i.natureza,n.nota_id,n.emissao,n.finalizada_em,nt.fornecedor_id,f.razao_social fornecedor
    from public.frota_gestao_vinculos v join public.frota_gestao_nf_itens i on i.id=v.nf_item_id
    join vigentes n on n.id=i.versao_id and n.estado='finalizada'
    join public.frota_gestao_notas nt on nt.id=n.nota_id join public.frota_gestao_fornecedores f on f.fornecedor_id=nt.fornecedor_id
    left join public.frota_gestao_os_itens oi on oi.id=v.os_item_id
    where (coalesce(p_filtros->>'veiculo_id','')='' or v.veiculo_id::text=p_filtros->>'veiculo_id')
      and (coalesce(p_filtros->>'fornecedor_id','')='' or nt.fornecedor_id::text=p_filtros->>'fornecedor_id')
      and (coalesce(p_filtros->>'manutencao','')='' or oi.tipo_manutencao=p_filtros->>'manutencao')
      and (coalesce(p_filtros->>'categoria_id','')='' or coalesce(v.categoria_id::text,'sem_classificacao')=p_filtros->>'categoria_id')
  ), fiscais_periodo as materialized(select * from fiscais where emissao between (p_filtros->>'inicio')::date and (p_filtros->>'fim')::date
    and (coalesce(p_filtros->>'unidade_id','')='' or unidade_custo_id::text=p_filtros->>'unidade_id')),
  saldos as materialized(
    select m.lote_id,m.local_id,sum(case when m.tipo in ('entrada_nf','transferencia_entrada','ajuste_entrada','retorno_fisico') then m.valor else -m.valor end) valor
    from public.frota_gestao_movimentos m join public.frota_gestao_locais l on l.id=m.local_id
    where (m.criado_em at time zone 'America/Sao_Paulo')::date<=(p_filtros->>'fim')::date
      and (coalesce(p_filtros->>'unidade_id','')='' or l.operacao_id::text=p_filtros->>'unidade_id') group by m.lote_id,m.local_id
  ), estoque as (
    select r.valor from saldos s join public.frota_gestao_lotes l on l.id=s.lote_id
    cross join lateral public.frota_gestao_ratear_item(l.nf_item_id,s.valor) r
    join public.frota_gestao_vinculos f on f.id=r.vinculo_id join public.frota_gestao_nf_itens ni on ni.id=f.nf_item_id
    join public.frota_gestao_nf_versoes nv on nv.id=ni.versao_id join public.frota_gestao_notas nt on nt.id=nv.nota_id
    left join public.frota_gestao_os_itens oi on oi.id=f.os_item_id
    where (coalesce(p_filtros->>'veiculo_id','')='' or f.veiculo_id::text=p_filtros->>'veiculo_id')
      and (coalesce(p_filtros->>'fornecedor_id','')='' or nt.fornecedor_id::text=p_filtros->>'fornecedor_id')
      and (coalesce(p_filtros->>'manutencao','')='' or oi.tipo_manutencao=p_filtros->>'manutencao')
      and (coalesce(p_filtros->>'categoria_id','')='' or coalesce(f.categoria_id::text,'sem_classificacao')=p_filtros->>'categoria_id')
  ), itens_os as materialized(
    select i.*,o.estado,o.id ordem_id from public.frota_gestao_os_itens i join public.frota_gestao_os o on o.id=i.os_id
    where (o.criado_em at time zone 'America/Sao_Paulo')::date between (p_filtros->>'inicio')::date and (p_filtros->>'fim')::date
      and (coalesce(p_filtros->>'unidade_id','')='' or o.operacao_id::text=p_filtros->>'unidade_id')
      and (coalesce(p_filtros->>'veiculo_id','')='' or o.veiculo_id::text=p_filtros->>'veiculo_id')
      and (coalesce(p_filtros->>'manutencao','')='' or i.tipo_manutencao=p_filtros->>'manutencao')
      and ((coalesce(p_filtros->>'fornecedor_id','')='' and coalesce(p_filtros->>'categoria_id','')='')
        or exists(select 1 from fiscais f where f.os_item_id=i.id))
  ), pendencias as (
    select i.*,greatest(i.quantidade_prevista-coalesce((select sum(v.quantidade*ni.fator_conversao) from public.frota_gestao_vinculos v
      join public.frota_gestao_nf_itens ni on ni.id=v.nf_item_id join vigentes nv on nv.id=ni.versao_id and nv.estado='finalizada'
      where v.os_item_id=i.id),0),0) pendente from itens_os i where i.estado<>'cancelada'
  ), detalhe as (select to_jsonb(c)||jsonb_build_object('valor',c.valor::text) dados from custos c order by c.executado_em desc,c.id limit 25 offset p_pagina::bigint*25)
  select jsonb_build_object('contrato','05','indicadores',jsonb_build_object(
    'efetivo',coalesce((select sum(valor) from custos),0)::text,
    'servicos',coalesce((select sum(valor) from custos where natureza_custo='servico'),0)::text,
    'aplicadas',coalesce((select sum(valor) from custos where natureza_custo='peca_aplicada'),0)::text,
    'aquisicoes',coalesce((select sum(valor_documentado) from fiscais_periodo where natureza='peca'),0)::text,
    'estoque',coalesce((select sum(valor) from estoque),0)::text,
    'notas',(select count(distinct nota_id) from fiscais_periodo),
    'abertas',(select count(distinct ordem_id) from itens_os where estado in ('aberta','em_execucao')),
    'concluidas',(select count(distinct ordem_id) from itens_os where estado='encerrada'),
    'previsto_pendente',coalesce((select sum(round(valor_previsto*pendente/quantidade_prevista,2)) from pendencias where previsao_informada),0)::text,
    'previsoes_nao_informadas',(select count(*) from pendencias where not previsao_informada and pendente>0),
    'estornos_quantidade',(select count(*) from custos where origem='estorno'),
    'estornos_valor',coalesce((select -sum(valor) from custos where origem='estorno'),0)::text,
    'sem_classificacao',(select count(*) from custos where categoria_id is null)),
    'mensal',coalesce((select jsonb_agg(to_jsonb(x) order by x.nome) from(select to_char(executado_em,'YYYY-MM') nome,sum(valor)::text valor from custos group by 1)x),'[]'),
    'veiculos',coalesce((select jsonb_agg(to_jsonb(x) order by x.ordem desc,x.nome) from(select placa nome,sum(valor)::text valor,sum(valor) ordem from custos group by placa order by sum(valor) desc,placa limit 10)x),'[]'),
    'fornecedores',coalesce((select jsonb_agg(to_jsonb(x) order by x.ordem desc,x.nome) from(select fornecedor nome,sum(valor_documentado)::text valor,sum(valor_documentado) ordem from fiscais_periodo group by fornecedor_id,fornecedor order by sum(valor_documentado) desc,fornecedor limit 10)x),'[]'),
    'categorias',coalesce((select jsonb_agg(to_jsonb(x) order by x.nome) from(select coalesce(categoria,'Sem classificação') nome,sum(valor)::text valor from custos group by categoria_id,categoria)x),'[]'),
    'manutencoes',coalesce((select jsonb_agg(to_jsonb(x) order by x.nome) from(select tipo_manutencao nome,sum(valor)::text valor,count(distinct os_item_id) quantidade from custos group by tipo_manutencao)x),'[]'),
    'unidades',coalesce((select jsonb_agg(to_jsonb(x) order by x.nome) from(select unidade nome,sum(valor)::text valor from custos group by unidade_custo_id,unidade)x),'[]'),
    'naturezas',coalesce((select jsonb_agg(to_jsonb(x) order by x.nome) from(select natureza_custo nome,sum(valor)::text valor from custos group by natureza_custo)x),'[]'),
    'total',(select count(*) from custos),'linhas',coalesce((select jsonb_agg(dados) from detalhe),'[]')) into resultado;
  return resultado;
end $$;
revoke all on function public.frota_gestao_painel(jsonb,integer) from public,anon;
grant execute on function public.frota_gestao_painel(jsonb,integer) to authenticated;

create or replace function public.frota_gestao_opcoes_gerenciais()
returns jsonb language plpgsql stable security definer set search_path=pg_catalog,public as $$
begin
  if not public.frota_gestao_usuario_ativo() then raise exception using errcode='42501',message='Conta inativa ou não autenticada.';end if;
  return jsonb_build_object('unidades',coalesce((select jsonb_agg(jsonb_build_object('id',id,'nome',nome) order by nome) from public.operacoes),'[]'),
    'veiculos',coalesce((select jsonb_agg(jsonb_build_object('id',id,'nome',placa) order by placa,id) from public.veiculos),'[]'),
    'fornecedores',coalesce((select jsonb_agg(jsonb_build_object('id',fornecedor_id,'nome',razao_social) order by razao_social) from public.frota_gestao_fornecedores),'[]'),
    'categorias',coalesce((select jsonb_agg(jsonb_build_object('id',id,'nome',nome) order by nome) from public.frota_gestao_categorias),'[]'));
end $$;
revoke all on function public.frota_gestao_opcoes_gerenciais() from public,anon;
grant execute on function public.frota_gestao_opcoes_gerenciais() to authenticated;

alter table public.frota_gestao_hbf add column if not exists substituido_por_versao_id uuid references public.frota_gestao_nf_versoes(id);
alter table public.frota_gestao_hbf add column if not exists hash_emissao text;
create index if not exists frota_gestao_hbf_versao on public.frota_gestao_hbf(versao_id,criado_em,id);

create or replace function public.frota_gestao_proteger_hbf()
returns trigger language plpgsql set search_path=pg_catalog,public as $$
begin
  if tg_op='DELETE' then raise exception 'Histórico HBF não pode ser excluído.';end if;
  if new.id<>old.id or new.versao_id<>old.versao_id or new.versao_modelo<>old.versao_modelo or new.dados is distinct from old.dados
    or new.criado_por<>old.criado_por or new.criado_em<>old.criado_em or new.hash_emissao is distinct from old.hash_emissao
    or (old.estado='invalidado' and new.estado<>'invalidado') or (old.encaminhamento='encaminhado' and
      (new.encaminhamento<>old.encaminhamento or new.encaminhado_em is distinct from old.encaminhado_em or new.encaminhado_por is distinct from old.encaminhado_por)) then
    raise exception 'Snapshot HBF e encaminhamento confirmado são imutáveis.';
  end if;
  return new;
end $$;
revoke all on function public.frota_gestao_proteger_hbf() from public,anon,authenticated;
drop trigger if exists proteger_hbf on public.frota_gestao_hbf;
create trigger proteger_hbf before update or delete on public.frota_gestao_hbf for each row execute function public.frota_gestao_proteger_hbf();

create or replace function public.frota_gestao_substituir_hbf()
returns trigger language plpgsql security definer set search_path=pg_catalog,public as $$
begin
  update public.frota_gestao_hbf h set estado='invalidado',substituido_por_versao_id=new.id
    where h.versao_id in (select id from public.frota_gestao_nf_versoes where nota_id=new.nota_id and numero_versao<new.numero_versao)
      and h.estado='emitido';
  return null;
end $$;
revoke all on function public.frota_gestao_substituir_hbf() from public,anon,authenticated;
drop trigger if exists substituir_hbf on public.frota_gestao_nf_versoes;
create trigger substituir_hbf after insert on public.frota_gestao_nf_versoes for each row execute function public.frota_gestao_substituir_hbf();

create or replace function public.frota_gestao_emitir_hbf(p_versao uuid,p_chave uuid,p_confirmado boolean)
returns jsonb language plpgsql security definer set search_path=pg_catalog,public as $$
declare versao public.frota_gestao_nf_versoes;nota public.frota_gestao_notas;anterior public.frota_gestao_hbf;
  linhas jsonb;dados jsonb;assinatura text;autor text;momento timestamptz:=clock_timestamp();total_linhas numeric;
begin
  perform public.frota_gestao_exigir_escrita(false);
  if not public.frota_gestao_usuario_ativo() then raise exception using errcode='42501',message='Conta inativa ou não autenticada.';end if;
  if p_chave is null or p_confirmado is distinct from true then raise exception 'Confirme explicitamente a emissão do HBF.';end if;
  perform pg_advisory_xact_lock(hashtextextended('hbf-emissao:'||p_chave::text,0));
  assinatura:=encode(sha256(convert_to('hbf-01:'||p_versao::text,'UTF8')),'hex');
  select * into anterior from public.frota_gestao_hbf where id=p_chave;
  if found then
    if anterior.hash_emissao is distinct from assinatura then raise exception 'Chave de emissão reutilizada com outra versão.';end if;
    return to_jsonb(anterior);
  end if;
  select * into versao from public.frota_gestao_nf_versoes where id=p_versao;
  if not found then raise exception 'Versão fiscal não encontrada.';end if;
  -- A correção futura precisa usar o mesmo row lock da identidade fiscal.
  select * into nota from public.frota_gestao_notas where id=versao.nota_id for update;
  if versao.estado<>'finalizada' or exists(select 1 from public.frota_gestao_nf_versoes where nota_id=nota.id and numero_versao>versao.numero_versao) then raise exception 'Emita somente para a versão finalizada vigente da NF.';end if;
  if not exists(select 1 from public.frota_gestao_nf_itens where versao_id=p_versao) or exists(
    select 1 from public.frota_gestao_nf_itens i where i.versao_id=p_versao and
      (i.quantidade_compra<>(select coalesce(sum(quantidade),0) from public.frota_gestao_vinculos where nf_item_id=i.id)
       or i.liquido<>(select coalesce(sum(valor_documentado),0) from public.frota_gestao_vinculos where nf_item_id=i.id)))
    or versao.total<>(select coalesce(sum(liquido),0) from public.frota_gestao_nf_itens where versao_id=p_versao) then raise exception 'NF, itens e rateios não conciliam. HBF não emitido.';end if;
  if exists(select 1 from public.frota_gestao_vinculos v join public.frota_gestao_nf_itens i on i.id=v.nf_item_id
    left join public.frota_gestao_categorias c on c.id=v.categoria_id where i.versao_id=p_versao and
      (v.centro_custo is null or v.conta_id is null or c.coluna_hbf is null)) then raise exception 'Complete centro de custo, conta e coluna HBF das categorias de todos os rateios.';end if;
  select jsonb_agg(jsonb_build_object('vinculo_id',v.id,'item',i.numero_item,'veiculo',coalesce(ve.placa,case when v.classificacao->>'destino'='estoque' then 'Estoque' else 'Apropriação pendente' end),
    'numero_os',coalesce(o.numero::text,'—'),'numero_nf',nota.numero,'centro_custo',v.centro_custo||' · '||cc.nome,'conta',ct.codigo||' · '||ct.nome,
    'pecas_servicos',i.descricao_conferida,'quantidade',v.quantidade::text,'unidade',i.unidade_compra,'unidade_custo',u.nome,
    'servicos',case when c.coluna_hbf='servicos' then (v.valor_documentado+d.valor)::text else '0.00' end,
    'pecas',case when c.coluna_hbf='pecas' then (v.valor_documentado+d.valor)::text else '0.00' end,
    'lavagem',case when c.coluna_hbf='lavagem' then (v.valor_documentado+d.valor)::text else '0.00' end,
    'pneus',case when c.coluna_hbf='pneus' then (v.valor_documentado+d.valor)::text else '0.00' end,
    'oleo_lubrificante',case when c.coluna_hbf='oleo_lubrificante' then (v.valor_documentado+d.valor)::text else '0.00' end,
    'desconto',d.valor::text,'valor_total',v.valor_documentado::text,'acrescimo_item',i.acrescimo::text) order by i.numero_item,v.id),sum(v.valor_documentado)
    into linhas,total_linhas
  from public.frota_gestao_nf_itens i join public.frota_gestao_vinculos v on v.nf_item_id=i.id
  join lateral public.frota_gestao_ratear_item(i.id,i.desconto) d on d.vinculo_id=v.id
  left join public.veiculos ve on ve.id=v.veiculo_id left join public.frota_gestao_os o on o.id=v.os_id
  join public.frota_centros_custo cc on cc.codigo=v.centro_custo join public.frota_gestao_contas ct on ct.id=v.conta_id
  join public.frota_gestao_categorias c on c.id=v.categoria_id join public.operacoes u on u.id=v.unidade_custo_id where i.versao_id=p_versao;
  if total_linhas is distinct from versao.total then raise exception 'Linhas HBF não conciliam com a nota.';end if;
  select nome into autor from public.perfis where id=auth.uid();
  dados:=jsonb_build_object('contrato','05','modelo','hbf-01','preliminar',false,'emissao_id',p_chave,'versao_id',p_versao,
    'numero_versao',versao.numero_versao,'nota_id',nota.id,'numero_nf',nota.numero,'serie',nota.serie,'chave_acesso',nota.chave_acesso,
    'fornecedor',(select razao_social from public.frota_gestao_fornecedores where fornecedor_id=nota.fornecedor_id),
    'documento_fornecedor',(select documento from public.frota_gestao_fornecedores where fornecedor_id=nota.fornecedor_id),
    'unidade_fiscal',(select nome from public.operacoes where id=nota.unidade_fiscal_id),'emissao_nf',versao.emissao,'finalizada_em',versao.finalizada_em,
    'autor',autor,'autor_id',auth.uid(),'gerado_em',momento,'total',versao.total::text,'linhas',linhas,
    'desconto',(select sum(desconto)::text from public.frota_gestao_nf_itens where versao_id=p_versao),
    'acrescimo',(select sum(acrescimo)::text from public.frota_gestao_nf_itens where versao_id=p_versao),
    'referencias',coalesce((select jsonb_agg(jsonb_build_object('descricao',descricao,'url',url) order by criado_em,id) from public.frota_gestao_referencias where versao_id=p_versao),'[]'),
    'dados_fiscais',versao.dados_fiscais);
  insert into public.frota_gestao_hbf(id,versao_id,versao_modelo,dados,hash_emissao,criado_em) values(p_chave,p_versao,'hbf-01',dados,assinatura,momento) returning * into anterior;
  return to_jsonb(anterior);
end $$;
revoke all on function public.frota_gestao_emitir_hbf(uuid,uuid,boolean) from public,anon;
grant execute on function public.frota_gestao_emitir_hbf(uuid,uuid,boolean) to authenticated;

create or replace function public.frota_gestao_consultar_hbf(p_id uuid)
returns jsonb language plpgsql stable security definer set search_path=pg_catalog,public as $$
begin
  if not public.frota_gestao_usuario_ativo() then raise exception using errcode='42501',message='Conta inativa ou não autenticada.';end if;
  return (select to_jsonb(h) from public.frota_gestao_hbf h where id=p_id);
end $$;
revoke all on function public.frota_gestao_consultar_hbf(uuid) from public,anon;
grant execute on function public.frota_gestao_consultar_hbf(uuid) to authenticated;

create or replace function public.frota_gestao_encaminhar_hbf(p_id uuid,p_confirmado boolean)
returns jsonb language plpgsql security definer set search_path=pg_catalog,public as $$
declare emissao public.frota_gestao_hbf;
begin
  perform public.frota_gestao_exigir_escrita(false);
  if not public.frota_gestao_usuario_ativo() then raise exception using errcode='42501',message='Conta inativa ou não autenticada.';end if;
  if p_confirmado is distinct from true then raise exception 'Confirme o encaminhamento realizado ao financeiro.';end if;
  select * into emissao from public.frota_gestao_hbf where id=p_id;
  if not found then raise exception 'HBF não encontrado.';end if;
  perform 1 from public.frota_gestao_notas where id=(select nota_id from public.frota_gestao_nf_versoes where id=emissao.versao_id) for update;
  select * into emissao from public.frota_gestao_hbf where id=p_id for update;
  if emissao.estado<>'emitido' then raise exception 'HBF substituído ou invalidado não pode ser encaminhado.';end if;
  if emissao.encaminhamento='nao_informado' then
    update public.frota_gestao_hbf set encaminhamento='encaminhado',encaminhado_por=auth.uid(),encaminhado_em=clock_timestamp() where id=p_id returning * into emissao;
  end if;
  return to_jsonb(emissao);
end $$;
revoke all on function public.frota_gestao_encaminhar_hbf(uuid,boolean) from public,anon;
grant execute on function public.frota_gestao_encaminhar_hbf(uuid,boolean) to authenticated;

create or replace function public.frota_gestao_central_hbf(p_busca text,p_pagina integer)
returns jsonb language plpgsql stable security definer set search_path=pg_catalog,public as $$
declare resultado jsonb;
begin
  if not public.frota_gestao_usuario_ativo() then raise exception using errcode='42501',message='Conta inativa ou não autenticada.';end if;
  if p_pagina is null or p_pagina<0 or length(coalesce(p_busca,''))>100 then raise exception 'Busca inválida.';end if;
  with notas as materialized(select n.*,v.id versao_id,v.numero_versao,v.estado,f.razao_social fornecedor from public.frota_gestao_notas n
    join lateral(select * from public.frota_gestao_nf_versoes where nota_id=n.id order by numero_versao desc limit 1)v on true
    join public.frota_gestao_fornecedores f on f.fornecedor_id=n.fornecedor_id
    where n.numero ilike '%'||coalesce(p_busca,'')||'%' or f.razao_social ilike '%'||coalesce(p_busca,'')||'%'),
  pagina as(select to_jsonb(n)||jsonb_build_object('emissoes',coalesce((select jsonb_agg(to_jsonb(h)-'dados' order by h.criado_em desc,h.id) from public.frota_gestao_hbf h
    join public.frota_gestao_nf_versoes v on v.id=h.versao_id where v.nota_id=n.id),'[]')) dados from notas n order by criado_em desc,id limit 25 offset p_pagina::bigint*25)
  select jsonb_build_object('total',(select count(*) from notas),'linhas',coalesce((select jsonb_agg(dados) from pagina),'[]')) into resultado;
  return resultado;
end $$;
revoke all on function public.frota_gestao_central_hbf(text,integer) from public,anon;
grant execute on function public.frota_gestao_central_hbf(text,integer) to authenticated;

create or replace function public.frota_gestao_preparacao_gerencial()
returns jsonb language plpgsql stable security definer set search_path=pg_catalog,public as $$
begin
  if not public.frota_gestao_usuario_ativo() then raise exception using errcode='42501',message='Conta inativa ou não autenticada.';end if;
  perform substituido_por_versao_id,hash_emissao from public.frota_gestao_hbf where false;
  return jsonb_build_object('contrato','05','disponivel',has_function_privilege('authenticated','public.frota_gestao_painel(jsonb,integer)','EXECUTE')
    and has_function_privilege('authenticated','public.frota_gestao_emitir_hbf(uuid,uuid,boolean)','EXECUTE')
    and has_function_privilege('authenticated','public.frota_gestao_consultar_hbf(uuid)','EXECUTE')
    and has_function_privilege('authenticated','public.frota_gestao_encaminhar_hbf(uuid,boolean)','EXECUTE')
    and has_function_privilege('authenticated','public.frota_gestao_central_hbf(text,integer)','EXECUTE')
    and has_function_privilege('authenticated','public.frota_gestao_opcoes_gerenciais()','EXECUTE'));
end $$;
revoke all on function public.frota_gestao_preparacao_gerencial() from public,anon;
grant execute on function public.frota_gestao_preparacao_gerencial() to authenticated;

-- ===== 20261103000900_frota_91_ciclo06.sql =====
-- Origem: SQL 91 do módulo Gestão da Frota (extraído do laboratório, sem alterações de lógica).
-- CICLO 06. PREPARADO, NÃO EXECUTADO NO SUPABASE. Manualmente após 90 completo.
-- (begin/commit removidos: o Supabase CLI já executa cada migration em uma transação)
do $$ begin
  if to_regprocedure('public.frota_gestao_preparacao_gerencial()') is null then raise exception 'Confira 84 a 90 antes do 91.';end if;
end $$;
alter table public.frota_gestao_nf_itens add column if not exists origem_efeito_id uuid references public.frota_gestao_nf_itens(id);
alter table public.frota_gestao_nf_versoes add column if not exists tipo_cancelamento text;
alter table public.frota_gestao_nf_versoes add column if not exists referencia_cancelamento text;
alter table public.frota_gestao_custos add column if not exists operacao_corretiva_id uuid references public.frota_gestao_operacoes(id);
create unique index if not exists frota_gestao_compensacao_fiscal_unica on public.frota_gestao_custos(custo_estornado_id) where operacao_corretiva_id is not null;
create unique index if not exists frota_gestao_versao_sucessora_unica on public.frota_gestao_nf_versoes(anterior_id) where anterior_id is not null;
do $$ begin
  if not exists(select 1 from pg_constraint where conrelid='public.frota_gestao_nf_versoes'::regclass and conname='frota_gestao_cancelamento_comprovado') then
    alter table public.frota_gestao_nf_versoes add constraint frota_gestao_cancelamento_comprovado check(
      (estado='finalizada' and tipo_cancelamento is null and referencia_cancelamento is null) or
      (estado='cancelada' and tipo_cancelamento is not null and tipo_cancelamento in ('fiscal_comprovado','lancamento_interno') and
       (tipo_cancelamento='lancamento_interno' or nullif(btrim(referencia_cancelamento),'') is not null)));
  end if;
end $$;

create or replace function public.frota_gestao_candidatas_revisao(p_veiculo uuid,p_contexto jsonb,p_catalogo uuid,p_manutencao text,p_excluir uuid)
returns jsonb language plpgsql stable security definer set search_path=pg_catalog,public as $$
begin
  return coalesce((select jsonb_agg(jsonb_build_object('item_id',c.id,'os_id',c.os_id,'numero',c.numero::text,'estado',c.estado,'pendente',c.pendente::text) order by c.numero,c.id)
    from (select i.id,i.os_id,o.numero,o.estado,i.quantidade_prevista-coalesce((select sum(v.quantidade*n.fator_conversao)
      from public.frota_gestao_vinculos v join public.frota_gestao_nf_itens n on n.id=v.nf_item_id
      join public.frota_gestao_nf_versoes f on f.id=n.versao_id where v.os_item_id=i.id and f.estado='finalizada' and f.nota_id is distinct from p_excluir and not exists(select 1 from public.frota_gestao_nf_versoes nv where nv.nota_id=f.nota_id and nv.numero_versao>f.numero_versao)),0) as pendente
      from public.frota_gestao_os_itens i join public.frota_gestao_os o on o.id=i.os_id
      join public.operacoes op on op.id=o.operacao_id and op.ativa
      where o.veiculo_id=p_veiculo and o.estado in ('aberta','em_execucao','encerrada')
        and btrim(o.contexto_id)=btrim(p_contexto->>'contexto') and o.medidor=p_contexto->>'medidor' and o.periodo_inicio<=(p_contexto->>'fim')::date and o.periodo_fim>=(p_contexto->>'inicio')::date
        and i.catalogo_id=p_catalogo and i.tipo_manutencao=p_manutencao) c where c.pendente>0),'[]'::jsonb);
end $$;
revoke all on function public.frota_gestao_candidatas_revisao(uuid,jsonb,uuid,text,uuid) from public,anon,authenticated;
create or replace function public.frota_gestao_candidatas_nf(p_veiculo uuid,p_contexto jsonb,p_catalogo uuid,p_manutencao text)
returns jsonb language sql stable security definer set search_path=pg_catalog,public as $$
 select public.frota_gestao_candidatas_revisao(p_veiculo,p_contexto,p_catalogo,p_manutencao,null)
$$;
revoke all on function public.frota_gestao_candidatas_nf(uuid,jsonb,uuid,text) from public,anon,authenticated;

create or replace function public.frota_gestao_validar_correcao(p_nota uuid,p_dados jsonb)
returns jsonb language plpgsql security definer set search_path=pg_catalog,public as $$
declare r public.frota_gestao_rascunhos; d jsonb; plano jsonb; linha jsonb; cfg jsonb; parcela jsonb; contexto jsonb;
  fornecedor public.frota_gestao_fornecedores; catalogo public.frota_gestao_catalogo; veiculo public.veiculos;
  q numeric; fator numeric; bruto numeric; desconto numeric; acrescimo numeric; liquido numeric; preco numeric;
  soma numeric:=0; soma_q numeric; soma_v numeric; qp numeric; vp numeric; candidatas jsonb; escolhida jsonb;
  pendencias jsonb:='[]'; linhas jsonb:='[]'; rateios jsonb; indice integer; identidade text; numero_fiscal text; serie_fiscal text; chave text; emissao date;
begin
  if not public.frota_gestao_usuario_ativo() then raise exception using errcode='42501',message='Conta inativa ou não autenticada.'; end if;
  d:=p_dados;plano:=d->'finalizacao';
  if d->>'formato'<>'1' or jsonb_typeof(plano) is distinct from 'object' or jsonb_typeof(d#>'{nota,itens}') is distinct from 'array'
    or jsonb_array_length(d#>'{nota,itens}') not between 1 and 1000 then raise exception 'Complete os dados e as destinações da conferência.'; end if;
  numero_fiscal:=btrim(d#>>'{nota,numero}');serie_fiscal:=btrim(d#>>'{nota,serie}');chave:=nullif(btrim(d#>>'{nota,chave}'),'');
  if numero_fiscal is null or numero_fiscal !~ '^[0-9]{1,12}$' or serie_fiscal is null or serie_fiscal !~ '^[0-9]{1,3}$' or (chave is not null and chave !~ '^[0-9]{44}$') then raise exception 'Confira número, série e chave fiscal.'; end if;
  if numero_fiscal::numeric=0 then raise exception 'Número fiscal deve ser positivo.';end if;
  if plano->>'emissao' is null or plano->>'emissao' !~ '^[0-9]{4}-[0-9]{2}-[0-9]{2}$' then raise exception 'Confirme a data de emissão.'; end if;
  emissao:=(plano->>'emissao')::date;
  if substring(d#>>'{nota,emissao}',1,10) is distinct from plano->>'emissao' then raise exception 'A data confirmada diverge do cabeçalho da nota.'; end if;
  select * into fornecedor from public.frota_gestao_fornecedores where fornecedor_id=(plano->>'fornecedor_id')::uuid;
  if not found or coalesce(d#>>'{nota,documento_fornecedor}','') !~ '^[0-9 ./-]+$' or fornecedor.documento is distinct from regexp_replace(d#>>'{nota,documento_fornecedor}','[^0-9]','','g') then raise exception 'Selecione um fornecedor cadastrado com CPF/CNPJ correspondente à nota.'; end if;
  if not exists(select 1 from public.operacoes where id=(d->>'unidadeFiscal')::uuid and ativa) then raise exception 'Selecione uma unidade fiscal ativa.'; end if;
  identidade:=coalesce(chave,fornecedor.documento||':'||ltrim(serie_fiscal,'0')||':'||ltrim(numero_fiscal,'0'));
  if exists(select 1 from public.frota_gestao_notas n where n.id<>p_nota and (n.identidade_fiscal=identidade or n.chave_acesso=chave
    or (n.fornecedor_id=fornecedor.fornecedor_id and ltrim(btrim(n.numero),'0')=ltrim(numero_fiscal,'0') and ltrim(btrim(n.serie),'0')=ltrim(serie_fiscal,'0')))) then raise exception 'Nota fiscal já lançada. Não finalize uma duplicidade.'; end if;
  if nullif(d->>'referencia','') is not null and ((d->>'referencia') !~ '^https://[^[:space:]@]+$' or (d->>'referencia') ~* '(token|signature|expires|x-amz|x-goog|sig)=') then raise exception 'Use referência HTTPS permanente, sem credenciais ou assinatura temporária.'; end if;
  if exists(select 1 from jsonb_array_elements(d#>'{nota,itens}') i group by i->>'numero' having count(*)>1) then raise exception 'Linhas fiscais repetidas.'; end if;
  if (select count(*) from jsonb_object_keys(plano->'itens'))<>jsonb_array_length(d#>'{nota,itens}') then raise exception 'Classifique todas as linhas fiscais, sem itens adicionais.'; end if;
  for linha in select * from jsonb_array_elements(d#>'{nota,itens}') loop
    if coalesce(linha->>'numero','') !~ '^[1-9][0-9]{0,5}$' or nullif(btrim(linha->>'descricao'),'') is null then raise exception 'Item sem número/descrição.'; end if;
    cfg:=plano->'itens'->(linha->>'numero');
    select * into catalogo from public.frota_gestao_catalogo where id=(cfg->>'catalogo_id')::uuid and ativo;
    if not found then raise exception 'Selecione catálogo ativo para o item %.',linha->>'numero'; end if;
    if cfg->>'manutencao' is null or cfg->>'manutencao' not in ('preventiva','corretiva') then raise exception 'Confira o tipo de manutenção do item.'; end if;
    q:=public.frota_gestao_decimal_nf(linha->>'quantidade',6);fator:=public.frota_gestao_decimal_nf(cfg->>'fator',8);
    preco:=public.frota_gestao_decimal_nf(linha->>'unitario',10);bruto:=public.frota_gestao_decimal_nf(linha->>'bruto',2);
    desconto:=public.frota_gestao_decimal_nf(linha->>'desconto',2);acrescimo:=public.frota_gestao_decimal_nf(linha->>'acrescimo',2);liquido:=bruto-desconto+acrescimo;
    if q<=0 or fator<=0 or liquido<0 or nullif(btrim(linha->>'unidade'),'') is null or round(q*preco,2)<>bruto or trunc(q*fator,6)<>q*fator then raise exception 'Quantidade, unidade, fator, bruto ou líquido inconsistentes no item %.',linha->>'numero'; end if;
    if catalogo.natureza='servico' and (fator<>1 or upper(btrim(linha->>'unidade'))<>upper(catalogo.unidade_padrao)) then raise exception 'Serviços exigem unidade do catálogo e fator 1.'; end if;
    if catalogo.natureza='peca' and not exists(select 1 from public.frota_gestao_locais l join public.operacoes o on o.id=l.operacao_id where l.id=(cfg->>'local_id')::uuid and o.ativa) then raise exception 'Informe local físico ativo para a entrada integral da peça.'; end if;
    if jsonb_typeof(cfg->'rateios') is distinct from 'array' or jsonb_array_length(cfg->'rateios') not between 1 and 100 then raise exception 'Informe de 1 a 100 destinos para cada linha.'; end if;
    soma_q:=0;soma_v:=0;rateios:='[]';indice:=0;
    for parcela in select * from jsonb_array_elements(cfg->'rateios') loop
      qp:=public.frota_gestao_decimal_nf(parcela->>'quantidade',6);vp:=public.frota_gestao_decimal_nf(parcela->>'valor',2);
      if qp<=0 or trunc(qp*fator,6)<>qp*fator then raise exception 'Quantidade inválida no rateio.'; end if;
      soma_q:=soma_q+qp;soma_v:=soma_v+vp;candidatas:='[]';escolhida:=null;
      if not exists(select 1 from public.operacoes where id=(parcela->>'unidade_id')::uuid and ativa)
        or not exists(select 1 from public.frota_centros_custo where codigo=parcela->>'centro_custo')
        or not exists(select 1 from public.frota_gestao_contas where id=(parcela->>'conta_id')::uuid and ativa)
        or not exists(select 1 from public.frota_gestao_categorias where id=(parcela->>'categoria_id')::uuid and ativa) then raise exception 'Confira unidade de custo, centro, conta e categoria do rateio.'; end if;
      if parcela->>'destino'='veiculo' then
        select * into veiculo from public.veiculos where id=(parcela->>'veiculo_id')::uuid;
        if not found or regexp_replace(upper(veiculo.placa),'[^A-Z0-9]','','g') is distinct from regexp_replace(upper(parcela->>'placa'),'[^A-Z0-9]','','g') then raise exception 'Confira a placa e o cadastro do veículo.'; end if;
        contexto:=plano->'veiculos'->veiculo.id::text;
        if nullif(btrim(contexto->>'contexto'),'') is null or length(contexto->>'contexto')>200 or contexto->>'medidor' not in ('km','horimetro') or contexto->>'medidor' is null
          or coalesce(contexto->>'inicio','') !~ '^[0-9]{4}-[0-9]{2}-[0-9]{2}$' or coalesce(contexto->>'fim','') !~ '^[0-9]{4}-[0-9]{2}-[0-9]{2}$' or (contexto->>'fim')::date<(contexto->>'inicio')::date then raise exception 'Confira contexto, período e medidor do veículo.'; end if;
        if catalogo.natureza='servico' and ((parcela->>'executado_em') is null or parcela->>'executado_em'='' or (parcela->>'executado_em')::date not between (contexto->>'inicio')::date and (contexto->>'fim')::date or (parcela->>'executado_em')::date>current_date) then raise exception 'Informe a data real de execução dentro do período conferido.'; end if;
        candidatas:=public.frota_gestao_candidatas_revisao(veiculo.id,contexto,catalogo.id,cfg->>'manutencao',p_nota);
        if nullif(parcela->>'os_item_id','') is null and jsonb_array_length(candidatas)=0 and not exists(select 1 from public.operacoes where id=veiculo.operacao_id and ativa) then raise exception 'Nova OS exige unidade operacional atual e ativa no cadastro do veículo.';end if;
        if nullif(parcela->>'os_item_id','') is not null then
          select c into escolhida from jsonb_array_elements(candidatas) c where c->>'item_id'=parcela->>'os_item_id';
          if escolhida is null or (escolhida->>'pendente')::numeric<qp*fator then pendencias:=pendencias||jsonb_build_array('Item '||(linha->>'numero')||': OS incompatível ou faturamento pendente insuficiente.');
          elsif catalogo.natureza='servico' and not exists(select 1 from public.frota_gestao_os where id=(escolhida->>'os_id')::uuid and (parcela->>'executado_em')::date between periodo_inicio and periodo_fim) then pendencias:=pendencias||jsonb_build_array('Data do serviço fora do período da OS selecionada.');end if;
        elsif jsonb_array_length(candidatas)>0 then pendencias:=pendencias||jsonb_build_array('Item '||(linha->>'numero')||': confira as OS existentes antes de criar outra; divida faturamentos parciais se necessário.');end if;
        if nullif(parcela->>'os_item_id','') is null and jsonb_array_length(candidatas)=0 and exists(select 1 from public.frota_gestao_os o
          where o.nota_origem_id=p_nota and o.veiculo_id=veiculo.id and o.origem='nota') then
          pendencias:=pendencias||jsonb_build_array('Item '||(linha->>'numero')||': já existe OS automática deste veículo/NF sem item compatível. Abra OS antecipada adequada e selecione seu item; a correção não altera o escopo operacional da OS anterior.');
        end if;
        if nullif(parcela->>'os_item_id','') is null and exists(select 1 from public.frota_gestao_os o join public.frota_gestao_os_itens oi on oi.os_id=o.id
          where o.veiculo_id=veiculo.id and o.estado in ('aberta','em_execucao','encerrada') and oi.catalogo_id=catalogo.id
            and (nullif(btrim(o.contexto_id),'') is null or o.periodo_inicio is null or o.periodo_fim is null or (btrim(o.contexto_id)=btrim(contexto->>'contexto') and o.medidor<>contexto->>'medidor'))
            and oi.quantidade_prevista>coalesce((select sum(v.quantidade*ni.fator_conversao) from public.frota_gestao_vinculos v join public.frota_gestao_nf_itens ni on ni.id=v.nf_item_id
              join public.frota_gestao_nf_versoes nv on nv.id=ni.versao_id where v.os_item_id=oi.id and nv.estado='finalizada' and nv.nota_id<>p_nota and not exists(select 1 from public.frota_gestao_nf_versoes ult where ult.nota_id=nv.nota_id and ult.numero_versao>nv.numero_versao)),0)) then
          pendencias:=pendencias||jsonb_build_array('Existem OS com pendência e contexto/período ou medidor não verificável. Regularize a conferência antes de propor outra OS.');end if;
      elsif (catalogo.natureza='peca' and parcela->>'destino'='estoque') or (catalogo.natureza='servico' and parcela->>'destino'='pendente') then
        if nullif(parcela->>'veiculo_id','') is not null or nullif(parcela->>'placa','') is not null or nullif(parcela->>'os_item_id','') is not null then raise exception 'Destino sem veículo não pode identificar OS ou placa.'; end if;
      else raise exception 'Destino incompatível com peça/serviço.'; end if;
      rateios:=rateios||jsonb_build_array(jsonb_build_object('indice',indice,'destino',parcela->>'destino','veiculo',coalesce(parcela->>'placa',''),'valor',vp::text,
        'quantidade',qp::text,'centro_custo',parcela->>'centro_custo','conta',(select nome from public.frota_gestao_contas where id=(parcela->>'conta_id')::uuid),
        'categoria',(select nome from public.frota_gestao_categorias where id=(parcela->>'categoria_id')::uuid),'unidade_custo',(select nome from public.operacoes where id=(parcela->>'unidade_id')::uuid),'executado_em',coalesce(parcela->>'executado_em',''),
        'os_item_id',coalesce(parcela->>'os_item_id',''),'acao',case when parcela->>'destino'<>'veiculo' then 'sem_os' when nullif(parcela->>'os_item_id','') is null then 'criar' else 'vincular' end,'candidatas',candidatas));indice:=indice+1;
    end loop;
    if soma_q<>q or soma_v<>liquido then raise exception 'Rateio do item % não concilia quantidade e centavos do líquido.',linha->>'numero';end if;
    soma:=soma+liquido;linhas:=linhas||jsonb_build_array(jsonb_build_object('numero',linha->>'numero','natureza',catalogo.natureza,'liquido',liquido::text,'rateios',rateios));
  end loop;
  if soma<>public.frota_gestao_decimal_nf(d#>>'{nota,total}',2) then raise exception 'Itens, descontos e acréscimos não conciliam com o total da nota. Distribua os ajustes gerais explicitamente.';end if;
  return jsonb_build_object('contrato','06','total',soma::text,'fornecedor',fornecedor.razao_social,'linhas',linhas,'pendencias',pendencias);
end $$;
revoke all on function public.frota_gestao_validar_correcao(uuid,jsonb) from public,anon,authenticated;

-- Reconstrói as escolhas de OS efetivamente confirmadas, inclusive OS automáticas.
create or replace function public.frota_gestao_dados_versao(p_versao uuid)
returns jsonb language plpgsql stable security definer set search_path=pg_catalog,public as $$
declare d jsonb;itens jsonb;
begin
 select dados_fiscais into d from public.frota_gestao_nf_versoes where id=p_versao;
 select coalesce(jsonb_object_agg(i.numero_item::text,cfg.dados||jsonb_build_object('rateios',
  (select coalesce(jsonb_agg(p.value||jsonb_build_object('os_item_id',coalesce(v.os_item_id::text,'')) order by p.ordinality),'[]')
   from jsonb_array_elements(cfg.dados->'rateios') with ordinality p(value,ordinality)
   left join public.frota_gestao_vinculos v on v.nf_item_id=i.id and v.classificacao->>'rateio_indice'=(p.ordinality-1)::text))),'{}') into itens
 from public.frota_gestao_nf_itens i cross join lateral(select d#>array['finalizacao','itens',i.numero_item::text] dados) cfg where i.versao_id=p_versao;
 return jsonb_set(d,'{finalizacao,itens}',itens);
end $$;
revoke all on function public.frota_gestao_dados_versao(uuid) from public,anon,authenticated;

create or replace function public.frota_gestao_assinatura_item(p_dados jsonb,p_numero text)
returns jsonb language sql immutable set search_path=pg_catalog,public as $$
 select jsonb_build_object('cfg',(p_dados#>array['finalizacao','itens',p_numero])-'fator'-'rateios'||jsonb_build_object(
  'fator',(p_dados#>>array['finalizacao','itens',p_numero,'fator'])::numeric,
  'rateios',(select jsonb_agg(r.value-'quantidade'-'valor'||jsonb_build_object('quantidade',(r.value->>'quantidade')::numeric,'valor',(r.value->>'valor')::numeric) order by r.ordinality)
    from jsonb_array_elements(p_dados#>array['finalizacao','itens',p_numero,'rateios']) with ordinality r(value,ordinality))),
  'quantidade',(i->>'quantidade')::numeric,'unidade',upper(btrim(i->>'unidade')),'liquido',(i->>'bruto')::numeric-(i->>'desconto')::numeric+(i->>'acrescimo')::numeric,
  'contextos',(select coalesce(jsonb_object_agg(v,p_dados#>array['finalizacao','veiculos',v]),'{}') from
    (select distinct r->>'veiculo_id' v from jsonb_array_elements(p_dados#>array['finalizacao','itens',p_numero,'rateios']) r where r->>'destino'='veiculo') veiculos))
 from jsonb_array_elements(p_dados#>'{nota,itens}') i where i->>'numero'=p_numero
$$;
revoke all on function public.frota_gestao_assinatura_item(jsonb,text) from public,anon,authenticated;

-- Recebe o snapshot reconstruído uma vez por operação, evitando reler todas as linhas por item.
create or replace function public.frota_gestao_manter_item(p_anterior jsonb,p_dados jsonb,p_numero text,p_natureza text)
returns boolean language sql immutable set search_path=pg_catalog,public as $$
 select coalesce(public.frota_gestao_assinatura_item(p_anterior,p_numero)=public.frota_gestao_assinatura_item(p_dados,p_numero)
  and (p_natureza='servico' or (p_anterior#>>'{finalizacao,emissao}')::date=(p_dados#>>'{finalizacao,emissao}')::date),false)
$$;
revoke all on function public.frota_gestao_manter_item(jsonb,jsonb,text,text) from public,anon,authenticated;

create or replace function public.frota_gestao_conferir_revisao(p_versao uuid,p_tipo text,p_dados jsonb,p_referencia text)
returns jsonb language plpgsql security definer set search_path=pg_catalog,public as $$
declare v public.frota_gestao_nf_versoes; n public.frota_gestao_notas; i record; lote public.frota_gestao_lotes;
 resumo jsonb:='{}';bloqueios jsonb:='[]';impactos jsonb:='[]';manter boolean; item_origem uuid; saldo record; reserva numeric; movimentos bigint;
 valor numeric;saida numeric;encaminhado boolean; assinatura text; dados_atuais jsonb;
 novos_efeitos jsonb:='[]';linha_nova jsonb;cfg_nova jsonb;natureza_nova text;
begin
 if not public.frota_gestao_usuario_ativo() then raise exception using errcode='42501',message='Conta inativa ou não autenticada.';end if;
 if p_tipo is null or p_tipo not in ('corrigir','fiscal_comprovado','lancamento_interno') then raise exception 'Selecione correção ou o tipo de cancelamento.';end if;
 select * into v from public.frota_gestao_nf_versoes where id=p_versao;
 if not found then raise exception 'Versão não encontrada.';end if;
 if v.estado<>'finalizada' or exists(select 1 from public.frota_gestao_nf_versoes where nota_id=v.nota_id and numero_versao>v.numero_versao) then raise exception 'A versão mudou ou foi cancelada. Recarregue a NF.';end if;
 select * into n from public.frota_gestao_notas where id=v.nota_id;
 dados_atuais:=public.frota_gestao_dados_versao(v.id);
 if p_tipo='corrigir' then
  if p_dados is null or jsonb_typeof(p_dados)<>'object' or p_dados->>'formato' is distinct from '1' or p_dados->'conferido' is distinct from 'true'::jsonb
    or octet_length(p_dados::text)>1048576 then raise exception 'Dados estruturados da correção inválidos, não conferidos ou maiores que 1 MiB.';end if;
  if p_dados#>'{nota,dados_fiscais}' is distinct from v.dados_fiscais#>'{nota,dados_fiscais}' then
    raise exception 'Os dados extraídos do documento original são preservados. Informe as correções nos campos conferidos e referencie o novo documento.';
  end if;
  if p_dados#>>'{nota,numero}' is distinct from v.dados_fiscais#>>'{nota,numero}' or p_dados#>>'{nota,serie}' is distinct from v.dados_fiscais#>>'{nota,serie}'
    or p_dados#>>'{nota,chave}' is distinct from v.dados_fiscais#>>'{nota,chave}' or p_dados#>>'{nota,documento_fornecedor}' is distinct from v.dados_fiscais#>>'{nota,documento_fornecedor}'
    or p_dados#>>'{finalizacao,fornecedor_id}' is distinct from n.fornecedor_id::text or p_dados->>'unidadeFiscal' is distinct from n.unidade_fiscal_id::text then
    raise exception 'Identidade fiscal e unidade fiscal são imutáveis; outro documento exige lançamento próprio.';
  end if;
  resumo:=public.frota_gestao_validar_correcao(n.id,p_dados);bloqueios:=coalesce(resumo->'pendencias','[]');
  if p_dados-'etapa'-'destinos'-'conferido'=dados_atuais-'etapa'-'destinos'-'conferido' then
    bloqueios:=bloqueios||jsonb_build_array('Não há alterações na proposta. Não crie outra versão para repetir o mesmo lançamento.');
  end if;
  if (p_dados#>'{nota,itens}' is distinct from dados_atuais#>'{nota,itens}' or p_dados#>>'{finalizacao,emissao}' is distinct from dados_atuais#>>'{finalizacao,emissao}')
    and nullif(btrim(p_dados->>'referencia'),'') is null then bloqueios:=bloqueios||jsonb_build_array('Correção de itens/dados fiscais exige referência HTTPS permanente ao documento conferido.');end if;
 else
  if p_dados is not null then raise exception 'Cancelamento não recebe dados corretivos.';end if;
 end if;
 if p_tipo='fiscal_comprovado' and (coalesce(p_referencia,'') !~ '^https://[^[:space:]@]+$' or p_referencia ~* '(token|signature|expires|x-amz|x-goog|sig)=') then
  bloqueios:=bloqueios||jsonb_build_array('Cancelamento fiscal exige link HTTPS permanente para comprovação. O portal não consulta nem declara autorização da SEFAZ.');
 end if;
 if length(coalesce(p_referencia,''))>2000 then raise exception 'Referência de cancelamento excede 2000 caracteres.';end if;
 for i in select * from public.frota_gestao_nf_itens where versao_id=v.id order by numero_item loop
  manter:=p_tipo='corrigir' and coalesce(public.frota_gestao_manter_item(dados_atuais,p_dados,i.numero_item::text,i.natureza),false);
  item_origem:=coalesce(i.origem_efeito_id,i.id);lote:=null;reserva:=0;movimentos:=0;valor:=0;saida:=0;
  if i.natureza='peca' then
   select * into lote from public.frota_gestao_lotes where nf_item_id=item_origem;
   if not found then bloqueios:=bloqueios||jsonb_build_array('Item '||i.numero_item||': lote de origem não verificável.');
   else
    select coalesce(sum(quantidade-aplicada-liberada),0) into reserva from public.frota_gestao_reservas where lote_id=lote.id;
    select count(*) into movimentos from public.frota_gestao_movimentos where lote_id=lote.id and tipo<>'entrada_nf';
    if not manter and (reserva>0 or movimentos>0 or exists(select 1 from public.frota_gestao_aplicacoes where lote_id=lote.id)) then
     bloqueios:=bloqueios||jsonb_build_array('Item '||i.numero_item||' / lote '||lote.id||': reservas pendentes='||reserva||'; movimentos posteriores='||movimentos||'. Aplicações, transferências, devoluções e ajustes exigem regularização; este ciclo não reverte essas cadeias automaticamente.');
    end if;
    if not manter then
     select * into saldo from public.frota_gestao_saldo_lote(lote.id,(select local_id from public.frota_gestao_movimentos where lote_id=lote.id and tipo='entrada_nf'));
     if saldo.fisico is distinct from lote.quantidade_origem or saldo.valor is distinct from lote.custo_total then bloqueios:=bloqueios||jsonb_build_array('Item '||i.numero_item||': saldo não coincide com a aquisição original.');end if;
     saida:=lote.custo_total;
    end if;
   end if;
  elsif not manter then
   select coalesce(sum(c.valor),0) into valor from public.frota_gestao_custos c join public.frota_gestao_vinculos f on f.id=c.vinculo_id where f.nf_item_id=item_origem and c.origem='servico';
   if exists(select 1 from public.frota_gestao_custos c join public.frota_gestao_vinculos f on f.id=c.vinculo_id where f.nf_item_id=item_origem and exists(select 1 from public.frota_gestao_custos e where e.custo_estornado_id=c.id)) then
    bloqueios:=bloqueios||jsonb_build_array('Item '||i.numero_item||': custo jé compensado; origem requer conferência.');
   end if;
  end if;
  impactos:=impactos||jsonb_build_array(jsonb_build_object('item',i.numero_item,'natureza',i.natureza,'acao',case when manter then 'preservar efeitos' else 'compensar efeitos anteriores' end,
    'lote_id',lote.id,'reservado',reserva::text,'movimentos_posteriores',movimentos,'estorno_servicos',valor::text,'saida_estoque',saida::text));
 end loop;
 if p_tipo='corrigir' then
  for linha_nova in select * from jsonb_array_elements(p_dados#>'{nota,itens}') loop
   cfg_nova:=p_dados#>array['finalizacao','itens',linha_nova->>'numero'];
   select natureza into natureza_nova from public.frota_gestao_catalogo where id=(cfg_nova->>'catalogo_id')::uuid;
   if not public.frota_gestao_manter_item(dados_atuais,p_dados,linha_nova->>'numero',natureza_nova) then
    novos_efeitos:=novos_efeitos||jsonb_build_array(jsonb_build_object('item',linha_nova->>'numero','natureza',natureza_nova,
     'quantidade_estoque',case when natureza_nova='peca' then ((linha_nova->>'quantidade')::numeric*(cfg_nova->>'fator')::numeric)::text else '0' end,
     'valor_entrada',case when natureza_nova='peca' then ((linha_nova->>'bruto')::numeric-(linha_nova->>'desconto')::numeric+(linha_nova->>'acrescimo')::numeric)::text else '0' end,
     'custo_servicos',case when natureza_nova='servico' then (select coalesce(sum((p->>'valor')::numeric),0)::text from jsonb_array_elements(cfg_nova->'rateios') p where p->>'destino'='veiculo') else '0' end));
   end if;
  end loop;
 end if;
 select exists(select 1 from public.frota_gestao_hbf h join public.frota_gestao_nf_versoes f on f.id=h.versao_id where f.nota_id=n.id and h.estado='emitido' and h.encaminhamento='encaminhado') into encaminhado;
 resumo:=resumo||jsonb_build_object('contrato','06','versao_id',v.id,'numero_versao',v.numero_versao,'tipo',p_tipo,'total_anterior',v.total::text,'impactos',impactos,'novos_efeitos',novos_efeitos,'bloqueios',bloqueios,'novo_envio_necessario',encaminhado);
 assinatura:=encode(sha256(convert_to(jsonb_build_object('versao',v.id,'tipo',p_tipo,'dados',p_dados,'referencia',p_referencia,'resumo',resumo)::text,'UTF8')),'hex');
 return resumo||jsonb_build_object('hash_conferencia',assinatura);
end $$;
revoke all on function public.frota_gestao_conferir_revisao(uuid,text,jsonb,text) from public,anon;
grant execute on function public.frota_gestao_conferir_revisao(uuid,text,jsonb,text) to authenticated;

create or replace function public.frota_gestao_confirmar_revisao(p_versao uuid,p_tipo text,p_dados jsonb,p_referencia text,p_motivo text,p_chave uuid,p_hash text,p_confirmado boolean)
returns jsonb language plpgsql security definer set search_path=pg_catalog,public as $$
declare anterior public.frota_gestao_nf_versoes;op public.frota_gestao_operacoes;nota uuid;versao uuid:=gen_random_uuid();rascunho uuid:=gen_random_uuid();
 assinatura text;resumo jsonb;resultado_final jsonb;r public.frota_gestao_rascunhos;plano jsonb;linha jsonb;cfg jsonb;parcela jsonb;contexto jsonb;candidato jsonb;
 item_id uuid;lote_id uuid;vinculo uuid;os_id uuid;os_item uuid;veiculo uuid;unidade_os uuid;numero_os bigint;catalogo public.frota_gestao_catalogo;
 criadas jsonb:='{}';itens_criados jsonb:='{}';ordens jsonb:='[]';qp numeric;vp numeric;liquido numeric;q numeric;fator numeric;indice integer;chave_item text;originais jsonb;descricao_origem text;
 dados_anteriores jsonb;i public.frota_gestao_nf_itens;antigo_item public.frota_gestao_nf_itens;item_origem uuid;manter boolean;lote public.frota_gestao_lotes;custo_anterior record;
begin
  perform public.frota_gestao_exigir_escrita(false);
 if not public.frota_gestao_usuario_ativo() then raise exception using errcode='42501',message='Conta inativa ou não autenticada.';end if;
 if current_setting('transaction_isolation')<>'read committed' then raise exception 'Correção/cancelamento exige READ COMMITTED.';end if;
 if p_chave is null or p_confirmado is distinct from true or length(btrim(coalesce(p_motivo,''))) not between 5 and 2000 then raise exception 'Confirmação explícita, chave e justificativa de 5 a 2000 caracteres são obrigatórias.';end if;
 assinatura:=encode(sha256(convert_to(jsonb_build_object('versao',p_versao,'tipo',p_tipo,'dados',p_dados,'referencia',p_referencia,'motivo',p_motivo,'hash',p_hash)::text,'UTF8')),'hex');
 perform pg_advisory_xact_lock(hashtextextended('nf-operacao:'||p_chave::text,0));
 select * into op from public.frota_gestao_operacoes where id=p_chave;
 if found then
  if op.tipo not in ('corrigir','cancelar') or op.hash_entrada<>assinatura then raise exception 'Chave reutilizada com dados diferentes.';end if;
  return op.resultado;
 end if;
 select nota_id into nota from public.frota_gestao_nf_versoes where id=p_versao;
 if nota is null then raise exception 'Versão não encontrada.';end if;
 -- Mesma linha de identidade fiscal usada por emissão/encaminhamento HBF.
 perform 1 from public.frota_gestao_notas where id=nota for update;
 select * into anterior from public.frota_gestao_nf_versoes where id=p_versao;
 dados_anteriores:=public.frota_gestao_dados_versao(p_versao);
 if anterior.estado<>'finalizada' or exists(select 1 from public.frota_gestao_nf_versoes v where v.nota_id=nota and v.numero_versao>anterior.numero_versao) then
  raise exception 'A versão mudou ou foi cancelada. Recarregue a NF.';
 end if;
 -- Veículo -> OS -> item -> lote, na ordem dos ciclos 03 e 04.
 for veiculo in select distinct id from (
  select v.veiculo_id id from public.frota_gestao_vinculos v join public.frota_gestao_nf_itens ni on ni.id=v.nf_item_id where ni.versao_id=p_versao and v.veiculo_id is not null
  union select nullif(p->>'veiculo_id','')::uuid from jsonb_each(p_dados#>'{finalizacao,itens}') it cross join lateral jsonb_array_elements(it.value->'rateios') p where p->>'destino'='veiculo') destinos where id is not null order by id loop
  perform pg_advisory_xact_lock(hashtextextended('nf-veiculo:'||veiculo::text,0));
  perform 1 from public.veiculos where id=veiculo for share;
  perform 1 from public.frota_gestao_os where veiculo_id=veiculo order by id for update;
  perform 1 from public.frota_gestao_os_itens oi where oi.os_id in(select o.id from public.frota_gestao_os o where o.veiculo_id=veiculo) order by oi.id for update;
 end loop;
 perform 1 from public.frota_gestao_fornecedores where fornecedor_id=(p_dados#>>'{finalizacao,fornecedor_id}')::uuid for share;
 perform 1 from public.frota_gestao_catalogo where id in(select (it.value->>'catalogo_id')::uuid from jsonb_each(p_dados#>'{finalizacao,itens}') it) order by id for share;
 for lote_id in select l.id from public.frota_gestao_lotes l join public.frota_gestao_nf_itens ni on coalesce(ni.origem_efeito_id,ni.id)=l.nf_item_id where ni.versao_id=p_versao order by l.id loop
  perform pg_advisory_xact_lock(hashtextextended('frota-estoque-lote:'||lote_id::text,0));
  perform 1 from public.frota_gestao_lotes where id=lote_id for update;
 end loop;
 resumo:=public.frota_gestao_conferir_revisao(p_versao,p_tipo,p_dados,p_referencia);
 if p_hash is distinct from resumo->>'hash_conferencia' then raise exception 'Os dados ou impactos mudaram. Confira novamente antes de confirmar.';end if;
 if jsonb_array_length(resumo->'bloqueios')>0 then raise exception '%',resumo->'bloqueios';end if;
 insert into public.frota_gestao_operacoes(id,tipo,hash_entrada,resultado) values(p_chave,case when p_tipo='corrigir' then 'corrigir' else 'cancelar' end,assinatura,'{}');
 -- Apenas efeitos diferentes são compensados; origens retidas permanecem rastreáveis.
 for i in select * from public.frota_gestao_nf_itens where versao_id=p_versao order by numero_item loop
  if p_tipo='corrigir' and coalesce(public.frota_gestao_manter_item(dados_anteriores,p_dados,i.numero_item::text,i.natureza),false) then continue;end if;
  item_origem:=coalesce(i.origem_efeito_id,i.id);
  if i.natureza='peca' then
   select * into lote from public.frota_gestao_lotes where nf_item_id=item_origem;
   insert into public.frota_gestao_movimentos(lote_id,local_id,tipo,quantidade,valor,operacao_atomica,motivo)
    select lote.id,m.local_id,'ajuste_saida',lote.quantidade_origem,lote.custo_total,p_chave,p_motivo from public.frota_gestao_movimentos m where m.lote_id=lote.id and m.tipo='entrada_nf';
  else
   for custo_anterior in select custo.* from public.frota_gestao_custos custo join public.frota_gestao_vinculos f on f.id=custo.vinculo_id where f.nf_item_id=item_origem and custo.origem='servico' loop
    insert into public.frota_gestao_custos(veiculo_id,unidade_custo_id,custo_estornado_id,origem,valor,executado_em,operacao_corretiva_id)
     values(custo_anterior.veiculo_id,custo_anterior.unidade_custo_id,custo_anterior.id,'estorno',-custo_anterior.valor,custo_anterior.executado_em,p_chave);
   end loop;
  end if;
 end loop;
 r.dados:=case when p_tipo='corrigir' then p_dados else public.frota_gestao_dados_versao(p_versao) end;
 plano:=r.dados->'finalizacao';
 insert into public.frota_gestao_rascunhos(id,dados,finalizado_em) values(rascunho,r.dados,clock_timestamp());
 insert into public.frota_gestao_nf_versoes(id,nota_id,rascunho_id,numero_versao,anterior_id,estado,emissao,total,dados_fiscais,motivo,tipo_cancelamento,referencia_cancelamento)
 values(versao,nota,rascunho,anterior.numero_versao+1,anterior.id,case when p_tipo='corrigir' then 'finalizada' else 'cancelada' end,
 (plano->>'emissao')::date,case when p_tipo='corrigir' then (resumo->>'total')::numeric else anterior.total end,r.dados,p_motivo,
 case when p_tipo<>'corrigir' then p_tipo end,case when p_tipo<>'corrigir' then nullif(btrim(p_referencia),'') end);
 if p_tipo='corrigir' then
  for linha in select * from jsonb_array_elements(r.dados#>'{nota,itens}') loop
    cfg:=plano->'itens'->(linha->>'numero');select * into catalogo from public.frota_gestao_catalogo where id=(cfg->>'catalogo_id')::uuid;
    originais:=r.dados#>'{nota,dados_fiscais,nota,det}';
    select e#>>'{prod,xProd}' into descricao_origem from jsonb_array_elements(case when jsonb_typeof(originais)='array' then originais else jsonb_build_array(originais) end) e where e->>'@nItem'=linha->>'numero';
    q:=(linha->>'quantidade')::numeric;fator:=(cfg->>'fator')::numeric;liquido:=(linha->>'bruto')::numeric-(linha->>'desconto')::numeric+(linha->>'acrescimo')::numeric;item_id:=gen_random_uuid();
    insert into public.frota_gestao_nf_itens(id,versao_id,numero_item,codigo_original,descricao_original,descricao_conferida,catalogo_id,natureza,quantidade_compra,unidade_compra,fator_conversao,valor_unitario,bruto,desconto,acrescimo,liquido,origem_efeito_id)
      values(item_id,versao,(linha->>'numero')::integer,coalesce(linha->>'codigo',''),coalesce(descricao_origem,linha->>'descricao'),linha->>'descricao',catalogo.id,catalogo.natureza,q,linha->>'unidade',fator,(linha->>'unitario')::numeric,(linha->>'bruto')::numeric,(linha->>'desconto')::numeric,(linha->>'acrescimo')::numeric,liquido,(select coalesce(ni.origem_efeito_id,ni.id) from public.frota_gestao_nf_itens ni where ni.versao_id=anterior.id and ni.numero_item=(linha->>'numero')::integer and public.frota_gestao_manter_item(dados_anteriores,r.dados,linha->>'numero',catalogo.natureza)));
    manter:=public.frota_gestao_manter_item(dados_anteriores,r.dados,linha->>'numero',catalogo.natureza);
    select ni.* into antigo_item from public.frota_gestao_nf_itens ni where ni.versao_id=anterior.id and ni.numero_item=(linha->>'numero')::integer;
    if manter then
      insert into public.frota_gestao_vinculos(nf_item_id,os_id,os_item_id,veiculo_id,unidade_custo_id,quantidade,valor_documentado,centro_custo,conta_id,categoria_id,classificacao)
        select item_id,f.os_id,f.os_item_id,f.veiculo_id,f.unidade_custo_id,f.quantidade,f.valor_documentado,f.centro_custo,f.conta_id,f.categoria_id,f.classificacao from public.frota_gestao_vinculos f where f.nf_item_id=antigo_item.id;
      continue;
    end if;
    if catalogo.natureza='peca' then
      lote_id:=gen_random_uuid();insert into public.frota_gestao_lotes(id,nf_item_id,catalogo_id,quantidade_origem,custo_total,adquirido_em) values(lote_id,item_id,catalogo.id,q*fator,liquido,(plano->>'emissao')::date);
      insert into public.frota_gestao_movimentos(lote_id,local_id,tipo,quantidade,valor,operacao_atomica,motivo)
        values(lote_id,(cfg->>'local_id')::uuid,'entrada_nf',q*fator,liquido,p_chave,'Aquisição por NF finalizada');
    end if;
    indice:=0;
    for parcela in select * from jsonb_array_elements(cfg->'rateios') loop
      qp:=(parcela->>'quantidade')::numeric;vp:=(parcela->>'valor')::numeric;os_id:=null;os_item:=null;veiculo:=null;
      if parcela->>'destino'='veiculo' then
        veiculo:=(parcela->>'veiculo_id')::uuid;contexto:=plano->'veiculos'->veiculo::text;
        if nullif(parcela->>'os_item_id','') is not null then
          select c into candidato from jsonb_array_elements(public.frota_gestao_candidatas_nf(veiculo,contexto,catalogo.id,cfg->>'manutencao')) c where c->>'item_id'=parcela->>'os_item_id';
          if candidato is null or (candidato->>'pendente')::numeric<qp*fator then raise exception 'Pendência da OS insuficiente após os rateios anteriores. Reveja a distribuição.';end if;
          os_id:=(candidato->>'os_id')::uuid;os_item:=(parcela->>'os_item_id')::uuid;
        else
          os_id:=(criadas->>veiculo::text)::uuid;
          if os_id is null then
            if exists(select 1 from public.frota_gestao_os where nota_origem_id=nota and veiculo_id=veiculo and origem='nota') then raise exception 'Já existe OS automática para este veículo/NF. Selecione item compatível ou abra OS antecipada adequada.';end if;
            os_id:=gen_random_uuid();select operacao_id into unidade_os from public.veiculos where id=veiculo;
            insert into public.frota_gestao_os(id,veiculo_id,operacao_id,origem,nota_origem_id,chave_criacao,descricao,medidor,contexto_id,periodo_inicio,periodo_fim)
              values(os_id,veiculo,unidade_os,'nota',nota,gen_random_uuid(),'OS originada da NF '||(r.dados#>>'{nota,numero}'),contexto->>'medidor',btrim(contexto->>'contexto'),(contexto->>'inicio')::date,(contexto->>'fim')::date) returning numero into numero_os;
            criadas:=criadas||jsonb_build_object(veiculo::text,os_id);ordens:=ordens||jsonb_build_array(jsonb_build_object('id',os_id,'numero',numero_os::text));
          end if;
          chave_item:=(linha->>'numero')||':'||veiculo::text;os_item:=(itens_criados->>chave_item)::uuid;
          if os_item is null then
            os_item:=gen_random_uuid();insert into public.frota_gestao_os_itens(id,os_id,catalogo_id,descricao,tipo_manutencao,quantidade_prevista,valor_previsto,previsao_informada,executado_em)
              values(os_item,os_id,catalogo.id,linha->>'descricao',cfg->>'manutencao',qp*fator,0,false,case when catalogo.natureza='servico' then nullif(parcela->>'executado_em','')::date else null end);
            itens_criados:=itens_criados||jsonb_build_object(chave_item,os_item);
          else update public.frota_gestao_os_itens set quantidade_prevista=quantidade_prevista+qp*fator where id=os_item;end if;
        end if;
      end if;
      vinculo:=gen_random_uuid();insert into public.frota_gestao_vinculos(id,nf_item_id,os_id,os_item_id,veiculo_id,unidade_custo_id,quantidade,valor_documentado,centro_custo,conta_id,categoria_id,classificacao)
        values(vinculo,item_id,os_id,os_item,veiculo,(parcela->>'unidade_id')::uuid,qp,vp,parcela->>'centro_custo',(parcela->>'conta_id')::uuid,(parcela->>'categoria_id')::uuid,jsonb_build_object('destino',parcela->>'destino','rateio_indice',indice));
      if catalogo.natureza='servico' and veiculo is not null then
        insert into public.frota_gestao_custos(veiculo_id,unidade_custo_id,vinculo_id,origem,valor,executado_em) values(veiculo,(parcela->>'unidade_id')::uuid,vinculo,'servico',vp,(parcela->>'executado_em')::date);
      end if;
      indice:=indice+1;
    end loop;
  end loop;

 else
  -- O cancelamento também possui cópia fiscal íntegra, sem novos efeitos.
  for i in select * from public.frota_gestao_nf_itens where versao_id=p_versao order by numero_item loop
   item_id:=gen_random_uuid();
   insert into public.frota_gestao_nf_itens(id,versao_id,numero_item,codigo_original,descricao_original,descricao_conferida,catalogo_id,natureza,quantidade_compra,unidade_compra,fator_conversao,valor_unitario,bruto,desconto,acrescimo,liquido,origem_efeito_id)
    values(item_id,versao,i.numero_item,i.codigo_original,i.descricao_original,i.descricao_conferida,i.catalogo_id,i.natureza,i.quantidade_compra,i.unidade_compra,i.fator_conversao,i.valor_unitario,i.bruto,i.desconto,i.acrescimo,i.liquido,coalesce(i.origem_efeito_id,i.id));
   insert into public.frota_gestao_vinculos(nf_item_id,os_id,os_item_id,veiculo_id,unidade_custo_id,quantidade,valor_documentado,centro_custo,conta_id,categoria_id,classificacao)
    select item_id,f.os_id,f.os_item_id,f.veiculo_id,f.unidade_custo_id,f.quantidade,f.valor_documentado,f.centro_custo,f.conta_id,f.categoria_id,f.classificacao from public.frota_gestao_vinculos f where f.nf_item_id=i.id;
  end loop;
 end if;
 if nullif(r.dados->>'referencia','') is not null then insert into public.frota_gestao_referencias(versao_id,url,descricao) values(versao,r.dados->>'referencia','Documento externo conferido na revisão');end if;
 if p_tipo='fiscal_comprovado' then insert into public.frota_gestao_referencias(versao_id,url,descricao) values(versao,p_referencia,'Comprovação de cancelamento fiscal informada pelo responsável');end if;
 resultado_final:=jsonb_build_object('contrato','06','operacao_id',p_chave,'nota_id',nota,'versao_id',versao,'anterior_id',p_versao,'numero_versao',anterior.numero_versao+1,
  'tipo',p_tipo,'autor_id',auth.uid(),'confirmado_em',clock_timestamp(),'ordens',ordens,'impactos',resumo->'impactos','novo_envio_necessario',resumo->'novo_envio_necessario');
 update public.frota_gestao_operacoes set resultado=resultado_final where id=p_chave;
 return resultado_final;
end $$;
revoke all on function public.frota_gestao_confirmar_revisao(uuid,text,jsonb,text,text,uuid,text,boolean) from public,anon;
grant execute on function public.frota_gestao_confirmar_revisao(uuid,text,jsonb,text,text,uuid,text,boolean) to authenticated;

-- Reaplica o operador 89 com uma guarda de vigência após o mesmo lock de lote.
create or replace function public.frota_gestao_operar_estoque(p_chave uuid,p_dados jsonb,p_confirmado boolean)
returns jsonb language plpgsql security definer set search_path=pg_catalog,public as $$
declare
  tipo text:=p_dados->>'tipo';assinatura text;anterior public.frota_gestao_operacoes;
  lote public.frota_gestao_lotes;reserva public.frota_gestao_reservas;aplicacao public.frota_gestao_aplicacoes;
  ordem public.frota_gestao_os;item public.frota_gestao_os_itens;custo_original public.frota_gestao_custos;
  lote_id uuid:=nullif(p_dados->>'lote_id','')::uuid;local_id uuid:=nullif(p_dados->>'local_id','')::uuid;
  destino uuid:=nullif(p_dados->>'destino_id','')::uuid;item_id uuid:=nullif(p_dados->>'os_item_id','')::uuid;
  reserva_id uuid:=nullif(p_dados->>'reserva_id','')::uuid;aplicacao_id uuid:=nullif(p_dados->>'aplicacao_id','')::uuid;
  ordem_id uuid:=nullif(p_dados->>'os_id','')::uuid;veiculo uuid;unidade uuid;unidade_destino uuid;
  unidade_financeira uuid:=nullif(p_dados->>'unidade_custo_id','')::uuid;
  q numeric;v numeric:=0;saldo record;q_estornada numeric;v_estornado numeric;data_real date;
  registro uuid:=gen_random_uuid();movimento text;motivo text:=btrim(coalesce(p_dados->>'motivo',''));
  referencia text:=nullif(btrim(p_dados->>'referencia_fiscal'),'');destino_fisico text:=p_dados->>'destino_fisico';recibo_resultado jsonb;
begin
  perform public.frota_gestao_exigir_escrita(false);
  if not public.frota_gestao_usuario_ativo() then raise exception using errcode='42501',message='Conta inativa ou não autenticada.';end if;
  if current_setting('transaction_isolation')<>'read committed' then raise exception 'Operações de estoque exigem isolamento READ COMMITTED.';end if;
  if p_chave is null or p_confirmado is distinct from true or jsonb_typeof(p_dados) is distinct from 'object' or octet_length(p_dados::text)>16384
    or tipo is null or tipo not in ('reservar','liberar','aplicar','transferir','ajustar','devolver','estornar','encerrar_os') then raise exception 'Confira os dados e a confirmação explícita da operação.';end if;
  assinatura:=encode(sha256(convert_to(jsonb_build_object('contrato','04','dados',p_dados)::text,'UTF8')),'hex');
  perform pg_advisory_xact_lock(hashtextextended('frota-estoque-op:'||p_chave::text,0));
  select * into anterior from public.frota_gestao_operacoes where id=p_chave;
  if found then
    if anterior.tipo is distinct from tipo or anterior.hash_entrada is distinct from assinatura then raise exception 'Chave reutilizada com dados diferentes.';end if;
    return anterior.resultado;
  end if;
  if motivo='' or length(motivo)>2000 then raise exception 'Justificativa obrigatória, até 2000 caracteres.';end if;
  if tipo<>'encerrar_os' then
    q:=public.frota_gestao_decimal_nf(p_dados->>'quantidade',6);
    if q<=0 then raise exception 'Quantidade deve ser positiva.';end if;
  end if;
  -- As referências fornecidas devem corresponder à reserva/aplicação original.
  if tipo in ('liberar','aplicar') and reserva_id is not null then
    select * into reserva from public.frota_gestao_reservas where id=reserva_id;
    if not found or lote_id is distinct from reserva.lote_id or local_id is distinct from reserva.local_id or item_id is distinct from reserva.os_item_id then raise exception 'Reserva, item, lote e local não correspondem.';end if;
  elsif tipo='liberar' then raise exception 'Selecione a reserva a liberar.';
  end if;
  if tipo='estornar' then
    select * into aplicacao from public.frota_gestao_aplicacoes where id=aplicacao_id;
    if not found or lote_id is distinct from aplicacao.lote_id or local_id is distinct from aplicacao.local_id or item_id is distinct from aplicacao.os_item_id then raise exception 'Aplicação, item, lote e local não correspondem.';end if;
  end if;
  if tipo in ('reservar','liberar','aplicar','estornar','encerrar_os') then
    if tipo<>'encerrar_os' then
      select * into item from public.frota_gestao_os_itens where id=item_id;
      if not found or ordem_id is distinct from item.os_id then raise exception 'Item não pertence à OS informada.';end if;
    end if;
    select veiculo_id into veiculo from public.frota_gestao_os where id=ordem_id;
    if not found then raise exception 'OS não encontrada.';end if;
    -- Mesma ordem de bloqueio do finalizador 88: veículo, OS, item e depois lote.
    perform pg_advisory_xact_lock(hashtextextended('nf-veiculo:'||veiculo::text,0));
    select * into ordem from public.frota_gestao_os where id=ordem_id for update;
    if ordem.veiculo_id is distinct from nullif(p_dados->>'veiculo_id','')::uuid
      or not exists(select 1 from public.veiculos where id=ordem.veiculo_id and placa=p_dados->>'placa') then raise exception 'Confira veículo e placa da OS.';end if;
    if tipo in ('reservar','aplicar','encerrar_os') and ordem.estado not in ('aberta','em_execucao') then raise exception 'OS não está aberta para esta operação.';end if;
    if tipo<>'encerrar_os' then perform 1 from public.frota_gestao_os_itens where id=item_id for update;end if;
    if not exists(select 1 from public.operacoes where id=ordem.operacao_id and ativa) then raise exception 'Unidade da OS inativa.';end if;
  end if;
  if tipo='encerrar_os' then
    if exists(select 1 from public.frota_gestao_reservas r join public.frota_gestao_os_itens i on i.id=r.os_item_id where i.os_id=ordem_id and r.quantidade>r.aplicada+r.liberada) then
      raise exception 'OS com reservas pendentes: aplique ou libere as peças antes de encerrar.';
    end if;
  else
    perform pg_advisory_xact_lock(hashtextextended('frota-estoque-lote:'||lote_id::text,0));
    select * into lote from public.frota_gestao_lotes where id=lote_id for update;
    if not found then raise exception 'Lote não encontrado.';end if;
    if not exists(select 1 from public.frota_gestao_nf_itens ativo join public.frota_gestao_nf_versoes atual on atual.id=ativo.versao_id
      join public.frota_gestao_nf_itens origem on origem.id=lote.nf_item_id join public.frota_gestao_nf_versoes inicial on inicial.id=origem.versao_id
      where atual.nota_id=inicial.nota_id and atual.estado='finalizada' and coalesce(ativo.origem_efeito_id,ativo.id)=lote.nf_item_id
        and not exists(select 1 from public.frota_gestao_nf_versoes nv where nv.nota_id=atual.nota_id and nv.numero_versao>atual.numero_versao)) then
      raise exception 'Lote de versão substituída sem efeitos retidos, ou de lançamento cancelado. Operação bloqueada.';
    end if;
    if not exists(select 1 from public.frota_gestao_nf_itens i join public.frota_gestao_nf_versoes n on n.id=i.versao_id
      where i.id=lote.nf_item_id and n.estado='finalizada' and i.natureza='peca' and i.catalogo_id=lote.catalogo_id
        and i.quantidade_compra*i.fator_conversao=lote.quantidade_origem and i.liquido=lote.custo_total)
      or not exists(select 1 from public.frota_gestao_movimentos m where m.lote_id=lote.id and m.tipo='entrada_nf'
        and m.quantidade=lote.quantidade_origem and m.valor=lote.custo_total) then raise exception 'Lote sem aquisição fiscal e entrada original conciliadas.';end if;
    select l.operacao_id into unidade from public.frota_gestao_locais l join public.operacoes o on o.id=l.operacao_id where l.id=local_id and o.ativa;
    if not found then raise exception 'Local ou unidade de origem inválida.';end if;
    if tipo in ('reservar','aplicar') then
      if lote.catalogo_id is distinct from item.catalogo_id then raise exception 'Produto do lote incompatível com o item da OS.';end if;
      if not exists(select 1 from public.frota_gestao_catalogo where id=lote.catalogo_id and ativo and natureza='peca') then raise exception 'Produto inativo ou não é peça.';end if;
    end if;
    select * into saldo from public.frota_gestao_saldo_lote(lote_id,local_id);
    if saldo.fisico<0 or saldo.reservado<0 or saldo.reservado>saldo.fisico or saldo.valor<0 or (saldo.fisico=0 and saldo.valor<>0) then raise exception 'Saldo inconsistente: solicite conferência do histórico antes de operar.';end if;
    if reserva_id is not null and tipo in ('aplicar','liberar') then
      select * into reserva from public.frota_gestao_reservas where id=reserva_id for update;
      if q>reserva.quantidade-reserva.aplicada-reserva.liberada then raise exception 'Quantidade superior à reserva pendente.';end if;
    end if;
    if tipo in ('reservar','transferir','devolver') or (tipo='ajustar' and p_dados->>'sentido'='saida') or (tipo='aplicar' and reserva_id is null) then
      if q>saldo.fisico-saldo.reservado then raise exception 'Saldo disponível insuficiente.';end if;
    end if;
    if tipo='aplicar' and q>saldo.fisico then raise exception 'Saldo físico insuficiente.';end if;
    if tipo in ('aplicar','transferir','devolver') or (tipo='ajustar' and p_dados->>'sentido'='saida') then
      v:=public.frota_gestao_valorar_baixa(q,saldo.fisico,saldo.valor);
    end if;
    if tipo in ('transferir','devolver') and referencia is null then raise exception 'Informe a referência da documentação fiscal aplicável.';end if;
    if tipo='transferir' then
      select l.operacao_id into unidade_destino from public.frota_gestao_locais l join public.operacoes o on o.id=l.operacao_id where l.id=destino and o.ativa;
      if not found or unidade_destino=unidade then raise exception 'Selecione local de outra unidade ativa.';end if;
    end if;
    if tipo='ajustar' then
      if p_dados->>'sentido' is null or p_dados->>'sentido' not in ('entrada','saida') then raise exception 'Informe o sentido do ajuste.';end if;
      if p_dados->>'sentido'='entrada' then v:=round(lote.custo_total*q/lote.quantidade_origem,2);end if;
    end if;
    if tipo in ('aplicar','estornar') then
      if tipo='aplicar' and not exists(select 1 from public.operacoes where id=unidade_financeira and ativa) then raise exception 'Selecione a unidade responsável pelo custo da aplicação.';end if;
      if coalesce(p_dados->>'data','') !~ '^[0-9]{4}-[0-9]{2}-[0-9]{2}$' then raise exception 'Informe a data efetiva.';end if;
      data_real:=(p_dados->>'data')::date;
      if data_real>(clock_timestamp() at time zone 'America/Sao_Paulo')::date or data_real<lote.adquirido_em or (tipo='estornar' and data_real<aplicacao.aplicada_em) then raise exception 'Data efetiva incompatível com aquisição, aplicação ou data atual.';end if;
    end if;
    if tipo='estornar' then
      perform 1 from public.frota_gestao_aplicacoes where id=aplicacao_id for update;
      select coalesce(sum(e.quantidade),0),coalesce(sum(e.valor),0) into q_estornada,v_estornado from public.frota_gestao_estornos e where e.aplicacao_id=aplicacao.id;
      if q>aplicacao.quantidade-q_estornada then raise exception 'Quantidade superior à aplicação ainda não estornada.';end if;
      v:=public.frota_gestao_valorar_baixa(q,aplicacao.quantidade-q_estornada,aplicacao.custo-v_estornado);
      select c.* into custo_original from public.frota_gestao_custos c where c.aplicacao_id=aplicacao.id and c.origem='peca_aplicada';
      if not found or custo_original.veiculo_id is distinct from ordem.veiculo_id or custo_original.valor is distinct from aplicacao.custo then raise exception 'Custo da aplicação não encontrado ou incompatível com a OS.';end if;
      if destino_fisico is null or destino_fisico not in ('estoque','fornecedor','sem_retorno') then raise exception 'Identifique o destino físico da peça.';end if;
      if destino_fisico='estoque' then
        if p_dados->'apta_disponivel' is distinct from 'true'::jsonb then raise exception 'Confirme a disponibilidade física e aptidão para uso.';end if;
        if not exists(select 1 from public.frota_gestao_locais l join public.operacoes o on o.id=l.operacao_id where l.id=destino and o.ativa) then raise exception 'Local de retorno inválido.';end if;
      elsif destino is not null or p_dados->'apta_disponivel'='true'::jsonb then raise exception 'Sem retorno ao estoque: não informe local nem confirme disponibilidade.';
      end if;
      if destino_fisico='fornecedor' and referencia is null then raise exception 'Informe a referência fiscal da devolução ao fornecedor.';end if;
      if destino_fisico='sem_retorno' and (nullif(btrim(p_dados->>'destino_descricao'),'') is null or length(p_dados->>'destino_descricao')>1000) then raise exception 'Descreva o destino físico da peça sem retorno ao estoque, até 1000 caracteres.';end if;
    end if;
  end if;
  insert into public.frota_gestao_operacoes(id,tipo,hash_entrada,resultado) values(p_chave,tipo,assinatura,'{}');
  if tipo='reservar' then
    insert into public.frota_gestao_reservas(id,lote_id,local_id,os_item_id,quantidade) values(registro,lote_id,local_id,item_id,q);
  elsif tipo='liberar' then
    update public.frota_gestao_reservas set liberada=liberada+q,estado=case when aplicada+liberada+q=quantidade then 'liberada' else 'ativa' end where id=reserva_id;
    registro:=reserva_id;
  elsif tipo='aplicar' then
    insert into public.frota_gestao_aplicacoes(id,lote_id,local_id,os_item_id,reserva_id,quantidade,custo,aplicada_em,chave_idempotencia)
      values(registro,lote_id,local_id,item_id,reserva_id,q,v,data_real,p_chave);
    insert into public.frota_gestao_movimentos(lote_id,local_id,tipo,quantidade,valor,operacao_atomica,aplicacao_id,motivo)
      values(lote_id,local_id,'aplicacao',q,v,p_chave,registro,motivo);
    insert into public.frota_gestao_custos(veiculo_id,unidade_custo_id,aplicacao_id,origem,valor,executado_em)
      values(ordem.veiculo_id,unidade_financeira,registro,'peca_aplicada',v,data_real);
    if reserva_id is not null then
      update public.frota_gestao_reservas set aplicada=aplicada+q,estado=case when aplicada+liberada+q=quantidade then 'aplicada' else 'ativa' end where id=reserva_id;
    end if;
  elsif tipo='transferir' then
    insert into public.frota_gestao_movimentos(lote_id,local_id,tipo,quantidade,valor,operacao_atomica,motivo,referencia_fiscal)
      values(lote_id,local_id,'transferencia_saida',q,v,p_chave,motivo,referencia),(lote_id,destino,'transferencia_entrada',q,v,p_chave,motivo,referencia);
    registro:=p_chave;
  elsif tipo in ('ajustar','devolver') then
    movimento:=case when tipo='devolver' then 'devolucao' when p_dados->>'sentido'='entrada' then 'ajuste_entrada' else 'ajuste_saida' end;
    insert into public.frota_gestao_movimentos(id,lote_id,local_id,tipo,quantidade,valor,operacao_atomica,motivo,referencia_fiscal)
      values(registro,lote_id,local_id,movimento,q,v,p_chave,motivo,referencia);
  elsif tipo='estornar' then
    insert into public.frota_gestao_estornos(id,aplicacao_id,quantidade,valor,retorno_fisico_confirmado,motivo,chave_idempotencia,destino_fisico,local_destino_id,referencia_fiscal)
      values(registro,aplicacao.id,q,v,destino_fisico='estoque',case when destino_fisico='sem_retorno' then motivo||' · Destino físico: '||btrim(p_dados->>'destino_descricao') else motivo end,p_chave,destino_fisico,destino,referencia);
    insert into public.frota_gestao_custos(veiculo_id,unidade_custo_id,estorno_id,custo_estornado_id,origem,valor,executado_em)
      values(custo_original.veiculo_id,custo_original.unidade_custo_id,registro,custo_original.id,'estorno',-v,data_real);
    if destino_fisico='estoque' then
      insert into public.frota_gestao_movimentos(lote_id,local_id,tipo,quantidade,valor,operacao_atomica,estorno_id,motivo)
        values(lote_id,destino,'retorno_fisico',q,v,p_chave,registro,motivo);
    end if;
  elsif tipo='encerrar_os' then
    update public.frota_gestao_os set estado='encerrada',encerrada_em=clock_timestamp() where id=ordem_id;
    registro:=ordem_id;
  end if;
  recibo_resultado:=jsonb_build_object('contrato','04','operacao_id',p_chave,'tipo',tipo,'registro_id',registro,
    'quantidade',coalesce(q,0)::text,'valor',v::text,'autor_id',auth.uid(),'confirmada_em',clock_timestamp(),'motivo',motivo,
    'dados',p_dados,'unidade_id',coalesce(unidade,ordem.operacao_id),'unidade_destino_id',unidade_destino,'produto_id',lote.catalogo_id);
  update public.frota_gestao_operacoes set resultado=recibo_resultado where id=p_chave;
  return recibo_resultado;
end $$;
revoke all on function public.frota_gestao_operar_estoque(uuid,jsonb,boolean) from public,anon;
grant execute on function public.frota_gestao_operar_estoque(uuid,jsonb,boolean) to authenticated;

create index if not exists frota_gestao_operacoes_versao_resultado on public.frota_gestao_operacoes((resultado->>'versao_id')) where tipo in ('corrigir','cancelar');
create or replace function public.frota_gestao_consultar_revisoes(p_nota uuid,p_pagina integer,p_versao uuid)
returns jsonb language plpgsql stable security definer set search_path=pg_catalog,public as $$
declare selecionada public.frota_gestao_nf_versoes;vigente public.frota_gestao_nf_versoes;lista jsonb;
begin
 if not public.frota_gestao_usuario_ativo() then raise exception using errcode='42501',message='Conta inativa ou não autenticada.';end if;
 if p_pagina is null or p_pagina<0 then raise exception 'Página inválida.';end if;
 select * into vigente from public.frota_gestao_nf_versoes where nota_id=p_nota order by numero_versao desc limit 1;
 if not found then raise exception 'NF não encontrada.';end if;
 select * into selecionada from public.frota_gestao_nf_versoes where nota_id=p_nota and id=coalesce(p_versao,vigente.id);
 if not found then raise exception 'Versão não pertence à NF.';end if;
 select coalesce(jsonb_agg(dados order by numero_versao desc),'[]') into lista from
 (select v.numero_versao,to_jsonb(v)-'dados_fiscais'||jsonb_build_object('total',v.total::text,'operacao',(select o.resultado from public.frota_gestao_operacoes o
   where o.tipo in ('corrigir','cancelar') and o.resultado->>'versao_id'=v.id::text limit 1)) dados
  from public.frota_gestao_nf_versoes v where v.nota_id=p_nota order by numero_versao desc limit 10 offset p_pagina::bigint*10) pagina;
 return jsonb_build_object('contrato','06','nota',(select to_jsonb(n) from public.frota_gestao_notas n where id=p_nota),'vigente_id',vigente.id,
 'total',(select count(*) from public.frota_gestao_nf_versoes where nota_id=p_nota),'versoes',lista,
 'selecionada',to_jsonb(selecionada)-'dados_fiscais'||jsonb_build_object('total',selecionada.total::text,'dados',public.frota_gestao_dados_versao(selecionada.id),
   'dados_anteriores',case when selecionada.anterior_id is not null then public.frota_gestao_dados_versao(selecionada.anterior_id) end,'referencias',
   coalesce((select jsonb_agg(to_jsonb(r) order by criado_em,id) from public.frota_gestao_referencias r where r.versao_id=selecionada.id),'[]')));
end $$;
revoke all on function public.frota_gestao_consultar_revisoes(uuid,integer,uuid) from public,anon;
grant execute on function public.frota_gestao_consultar_revisoes(uuid,integer,uuid) to authenticated;

create or replace function public.frota_gestao_recibo_revisao(p_chave uuid)
returns jsonb language plpgsql stable security definer set search_path=pg_catalog,public as $$
begin
 if not public.frota_gestao_usuario_ativo() then raise exception using errcode='42501',message='Conta inativa ou não autenticada.';end if;
 return (select resultado from public.frota_gestao_operacoes where id=p_chave and tipo in ('corrigir','cancelar'));
end $$;
revoke all on function public.frota_gestao_recibo_revisao(uuid) from public,anon;
grant execute on function public.frota_gestao_recibo_revisao(uuid) to authenticated;

create or replace function public.frota_gestao_preparacao_revisoes()
returns jsonb language plpgsql stable security definer set search_path=pg_catalog,public as $$
begin
 if not public.frota_gestao_usuario_ativo() then raise exception using errcode='42501',message='Conta inativa ou não autenticada.';end if;
 perform origem_efeito_id from public.frota_gestao_nf_itens where false;
 perform tipo_cancelamento,referencia_cancelamento from public.frota_gestao_nf_versoes where false;
 return jsonb_build_object('contrato','06','disponivel',
 has_function_privilege('authenticated','public.frota_gestao_conferir_revisao(uuid,text,jsonb,text)','EXECUTE') and
 has_function_privilege('authenticated','public.frota_gestao_confirmar_revisao(uuid,text,jsonb,text,text,uuid,text,boolean)','EXECUTE') and
 has_function_privilege('authenticated','public.frota_gestao_consultar_revisoes(uuid,integer,uuid)','EXECUTE') and
 has_function_privilege('authenticated','public.frota_gestao_recibo_revisao(uuid)','EXECUTE'));
end $$;
revoke all on function public.frota_gestao_preparacao_revisoes() from public,anon;
grant execute on function public.frota_gestao_preparacao_revisoes() to authenticated;

create or replace function public.frota_gestao_proteger_compensacao()
returns trigger language plpgsql security definer set search_path=pg_catalog,public as $$
declare raiz public.frota_gestao_custos;
begin
 if new.operacao_corretiva_id is not null then
  select * into raiz from public.frota_gestao_custos where id=new.custo_estornado_id for update;
  if raiz.origem is distinct from 'servico' or new.origem<>'estorno' or new.valor is distinct from -raiz.valor
   or exists(select 1 from public.frota_gestao_custos where custo_estornado_id=raiz.id)
   or not exists(select 1 from public.frota_gestao_operacoes where id=new.operacao_corretiva_id and tipo in ('corrigir','cancelar')) then
   raise exception 'Compensação fiscal deve anular uma única vez o custo integral do serviço original.';
  end if;
 end if;
 return new;
end $$;
revoke all on function public.frota_gestao_proteger_compensacao() from public,anon,authenticated;
drop trigger if exists proteger_compensacao on public.frota_gestao_custos;
create trigger proteger_compensacao before insert on public.frota_gestao_custos for each row execute function public.frota_gestao_proteger_compensacao();

create or replace function public.frota_gestao_validar_origem_efeito()
returns trigger language plpgsql security definer set search_path=pg_catalog,public as $$
begin
 if new.origem_efeito_id is not null and not exists(select 1 from public.frota_gestao_nf_itens i
  join public.frota_gestao_nf_versoes anterior on anterior.id=i.versao_id join public.frota_gestao_nf_versoes atual on atual.id=new.versao_id
  where i.id=new.origem_efeito_id and i.origem_efeito_id is null and atual.nota_id=anterior.nota_id and atual.numero_versao>anterior.numero_versao
   and i.natureza=new.natureza and i.catalogo_id=new.catalogo_id and i.quantidade_compra=new.quantidade_compra and i.fator_conversao=new.fator_conversao and i.liquido=new.liquido) then
  raise exception 'Origem de efeitos deve pertencer à mesma NF e preservar natureza, quantidade, catálogo e líquido.';
 end if;
 return new;
end $$;
revoke all on function public.frota_gestao_validar_origem_efeito() from public,anon,authenticated;
drop trigger if exists validar_origem_efeito on public.frota_gestao_nf_itens;
create trigger validar_origem_efeito before insert on public.frota_gestao_nf_itens for each row execute function public.frota_gestao_validar_origem_efeito();

do $$ declare tabela text;begin
 foreach tabela in array array['vinculos','lotes','referencias'] loop
  execute format('drop trigger if exists preservar_historico_fiscal on public.%I','frota_gestao_'||tabela);
  execute format('create trigger preservar_historico_fiscal before update or delete on public.%I for each row execute function public.frota_gestao_preservar_item_fiscal()','frota_gestao_'||tabela);
 end loop;
end $$;
-- A conferência inicial também ignora versões substituídas no diagnóstico de OS sem contexto.
create or replace function public.frota_gestao_conferir_nf(p_id uuid,p_revisao bigint)
returns jsonb language plpgsql security definer set search_path=pg_catalog,public as $$
declare r public.frota_gestao_rascunhos; d jsonb; plano jsonb; linha jsonb; cfg jsonb; parcela jsonb; contexto jsonb;
  fornecedor public.frota_gestao_fornecedores; catalogo public.frota_gestao_catalogo; veiculo public.veiculos;
  q numeric; fator numeric; bruto numeric; desconto numeric; acrescimo numeric; liquido numeric; preco numeric;
  soma numeric:=0; soma_q numeric; soma_v numeric; qp numeric; vp numeric; candidatas jsonb; escolhida jsonb;
  pendencias jsonb:='[]'; linhas jsonb:='[]'; rateios jsonb; indice integer; identidade text; numero_fiscal text; serie_fiscal text; chave text; emissao date;
begin
  if not public.frota_gestao_usuario_ativo() then raise exception using errcode='42501',message='Conta inativa ou não autenticada.'; end if;
  select * into r from public.frota_gestao_rascunhos where id=p_id;
  if not found or r.finalizado_em is not null or r.atualizado_em<clock_timestamp()-interval '7 days' then raise exception 'Rascunho ausente, expirado ou finalizado.'; end if;
  if p_revisao is null or r.revisao<>p_revisao then raise exception 'O rascunho mudou. Recarregue antes de conferir/finalizar.'; end if;
  d:=r.dados;plano:=d->'finalizacao';
  if d->>'formato'<>'1' or jsonb_typeof(plano) is distinct from 'object' or jsonb_typeof(d#>'{nota,itens}') is distinct from 'array'
    or jsonb_array_length(d#>'{nota,itens}') not between 1 and 1000 then raise exception 'Complete os dados e as destinações da conferência.'; end if;
  numero_fiscal:=btrim(d#>>'{nota,numero}');serie_fiscal:=btrim(d#>>'{nota,serie}');chave:=nullif(btrim(d#>>'{nota,chave}'),'');
  if numero_fiscal is null or numero_fiscal !~ '^[0-9]{1,12}$' or serie_fiscal is null or serie_fiscal !~ '^[0-9]{1,3}$' or (chave is not null and chave !~ '^[0-9]{44}$') then raise exception 'Confira número, série e chave fiscal.'; end if;
  if numero_fiscal::numeric=0 then raise exception 'Número fiscal deve ser positivo.';end if;
  if plano->>'emissao' is null or plano->>'emissao' !~ '^[0-9]{4}-[0-9]{2}-[0-9]{2}$' then raise exception 'Confirme a data de emissão.'; end if;
  emissao:=(plano->>'emissao')::date;
  if substring(d#>>'{nota,emissao}',1,10) is distinct from plano->>'emissao' then raise exception 'A data confirmada diverge do cabeçalho da nota.'; end if;
  select * into fornecedor from public.frota_gestao_fornecedores where fornecedor_id=(plano->>'fornecedor_id')::uuid;
  if not found or coalesce(d#>>'{nota,documento_fornecedor}','') !~ '^[0-9 ./-]+$' or fornecedor.documento is distinct from regexp_replace(d#>>'{nota,documento_fornecedor}','[^0-9]','','g') then raise exception 'Selecione um fornecedor cadastrado com CPF/CNPJ correspondente à nota.'; end if;
  if not exists(select 1 from public.operacoes where id=(d->>'unidadeFiscal')::uuid and ativa) then raise exception 'Selecione uma unidade fiscal ativa.'; end if;
  identidade:=coalesce(chave,fornecedor.documento||':'||ltrim(serie_fiscal,'0')||':'||ltrim(numero_fiscal,'0'));
  if exists(select 1 from public.frota_gestao_notas n where n.identidade_fiscal=identidade or n.chave_acesso=chave
    or (n.fornecedor_id=fornecedor.fornecedor_id and ltrim(btrim(n.numero),'0')=ltrim(numero_fiscal,'0') and ltrim(btrim(n.serie),'0')=ltrim(serie_fiscal,'0'))) then raise exception 'Nota fiscal já lançada. Não finalize uma duplicidade.'; end if;
  if nullif(d->>'referencia','') is not null and ((d->>'referencia') !~ '^https://[^[:space:]@]+$' or (d->>'referencia') ~* '(token|signature|expires|x-amz|x-goog|sig)=') then raise exception 'Use referência HTTPS permanente, sem credenciais ou assinatura temporária.'; end if;
  if exists(select 1 from jsonb_array_elements(d#>'{nota,itens}') i group by i->>'numero' having count(*)>1) then raise exception 'Linhas fiscais repetidas.'; end if;
  if (select count(*) from jsonb_object_keys(plano->'itens'))<>jsonb_array_length(d#>'{nota,itens}') then raise exception 'Classifique todas as linhas fiscais, sem itens adicionais.'; end if;
  for linha in select * from jsonb_array_elements(d#>'{nota,itens}') loop
    if coalesce(linha->>'numero','') !~ '^[1-9][0-9]{0,5}$' or nullif(btrim(linha->>'descricao'),'') is null then raise exception 'Item sem número/descrição.'; end if;
    cfg:=plano->'itens'->(linha->>'numero');
    select * into catalogo from public.frota_gestao_catalogo where id=(cfg->>'catalogo_id')::uuid and ativo;
    if not found then raise exception 'Selecione catálogo ativo para o item %.',linha->>'numero'; end if;
    if cfg->>'manutencao' is null or cfg->>'manutencao' not in ('preventiva','corretiva') then raise exception 'Confira o tipo de manutenção do item.'; end if;
    q:=public.frota_gestao_decimal_nf(linha->>'quantidade',6);fator:=public.frota_gestao_decimal_nf(cfg->>'fator',8);
    preco:=public.frota_gestao_decimal_nf(linha->>'unitario',10);bruto:=public.frota_gestao_decimal_nf(linha->>'bruto',2);
    desconto:=public.frota_gestao_decimal_nf(linha->>'desconto',2);acrescimo:=public.frota_gestao_decimal_nf(linha->>'acrescimo',2);liquido:=bruto-desconto+acrescimo;
    if q<=0 or fator<=0 or liquido<0 or nullif(btrim(linha->>'unidade'),'') is null or round(q*preco,2)<>bruto or trunc(q*fator,6)<>q*fator then raise exception 'Quantidade, unidade, fator, bruto ou líquido inconsistentes no item %.',linha->>'numero'; end if;
    if catalogo.natureza='servico' and (fator<>1 or upper(btrim(linha->>'unidade'))<>upper(catalogo.unidade_padrao)) then raise exception 'Serviços exigem unidade do catálogo e fator 1.'; end if;
    if catalogo.natureza='peca' and not exists(select 1 from public.frota_gestao_locais l join public.operacoes o on o.id=l.operacao_id where l.id=(cfg->>'local_id')::uuid and o.ativa) then raise exception 'Informe local físico ativo para a entrada integral da peça.'; end if;
    if jsonb_typeof(cfg->'rateios') is distinct from 'array' or jsonb_array_length(cfg->'rateios') not between 1 and 100 then raise exception 'Informe de 1 a 100 destinos para cada linha.'; end if;
    soma_q:=0;soma_v:=0;rateios:='[]';indice:=0;
    for parcela in select * from jsonb_array_elements(cfg->'rateios') loop
      qp:=public.frota_gestao_decimal_nf(parcela->>'quantidade',6);vp:=public.frota_gestao_decimal_nf(parcela->>'valor',2);
      if qp<=0 or trunc(qp*fator,6)<>qp*fator then raise exception 'Quantidade inválida no rateio.'; end if;
      soma_q:=soma_q+qp;soma_v:=soma_v+vp;candidatas:='[]';escolhida:=null;
      if not exists(select 1 from public.operacoes where id=(parcela->>'unidade_id')::uuid and ativa)
        or not exists(select 1 from public.frota_centros_custo where codigo=parcela->>'centro_custo')
        or not exists(select 1 from public.frota_gestao_contas where id=(parcela->>'conta_id')::uuid and ativa)
        or not exists(select 1 from public.frota_gestao_categorias where id=(parcela->>'categoria_id')::uuid and ativa) then raise exception 'Confira unidade de custo, centro, conta e categoria do rateio.'; end if;
      if parcela->>'destino'='veiculo' then
        select * into veiculo from public.veiculos where id=(parcela->>'veiculo_id')::uuid;
        if not found or regexp_replace(upper(veiculo.placa),'[^A-Z0-9]','','g') is distinct from regexp_replace(upper(parcela->>'placa'),'[^A-Z0-9]','','g') then raise exception 'Confira a placa e o cadastro do veículo.'; end if;
        contexto:=plano->'veiculos'->veiculo.id::text;
        if nullif(btrim(contexto->>'contexto'),'') is null or length(contexto->>'contexto')>200 or contexto->>'medidor' not in ('km','horimetro') or contexto->>'medidor' is null
          or coalesce(contexto->>'inicio','') !~ '^[0-9]{4}-[0-9]{2}-[0-9]{2}$' or coalesce(contexto->>'fim','') !~ '^[0-9]{4}-[0-9]{2}-[0-9]{2}$' or (contexto->>'fim')::date<(contexto->>'inicio')::date then raise exception 'Confira contexto, período e medidor do veículo.'; end if;
        if catalogo.natureza='servico' and ((parcela->>'executado_em') is null or parcela->>'executado_em'='' or (parcela->>'executado_em')::date not between (contexto->>'inicio')::date and (contexto->>'fim')::date or (parcela->>'executado_em')::date>current_date) then raise exception 'Informe a data real de execução dentro do período conferido.'; end if;
        candidatas:=public.frota_gestao_candidatas_nf(veiculo.id,contexto,catalogo.id,cfg->>'manutencao');
        if nullif(parcela->>'os_item_id','') is null and jsonb_array_length(candidatas)=0 and not exists(select 1 from public.operacoes where id=veiculo.operacao_id and ativa) then raise exception 'Nova OS exige unidade operacional atual e ativa no cadastro do veículo.';end if;
        if nullif(parcela->>'os_item_id','') is not null then
          select c into escolhida from jsonb_array_elements(candidatas) c where c->>'item_id'=parcela->>'os_item_id';
          if escolhida is null or (escolhida->>'pendente')::numeric<qp*fator then pendencias:=pendencias||jsonb_build_array('Item '||(linha->>'numero')||': OS incompatível ou faturamento pendente insuficiente.');
          elsif catalogo.natureza='servico' and not exists(select 1 from public.frota_gestao_os where id=(escolhida->>'os_id')::uuid and (parcela->>'executado_em')::date between periodo_inicio and periodo_fim) then pendencias:=pendencias||jsonb_build_array('Data do serviço fora do período da OS selecionada.');end if;
        elsif jsonb_array_length(candidatas)>0 then pendencias:=pendencias||jsonb_build_array('Item '||(linha->>'numero')||': confira as OS existentes antes de criar outra; divida faturamentos parciais se necessário.');end if;
        if nullif(parcela->>'os_item_id','') is null and exists(select 1 from public.frota_gestao_os o join public.frota_gestao_os_itens oi on oi.os_id=o.id
          where o.veiculo_id=veiculo.id and o.estado in ('aberta','em_execucao','encerrada') and oi.catalogo_id=catalogo.id
            and (nullif(btrim(o.contexto_id),'') is null or o.periodo_inicio is null or o.periodo_fim is null or (btrim(o.contexto_id)=btrim(contexto->>'contexto') and o.medidor<>contexto->>'medidor'))
            and oi.quantidade_prevista>coalesce((select sum(v.quantidade*ni.fator_conversao) from public.frota_gestao_vinculos v join public.frota_gestao_nf_itens ni on ni.id=v.nf_item_id
              join public.frota_gestao_nf_versoes nv on nv.id=ni.versao_id where v.os_item_id=oi.id and nv.estado='finalizada' and not exists(select 1 from public.frota_gestao_nf_versoes atual where atual.nota_id=nv.nota_id and atual.numero_versao>nv.numero_versao)),0)) then
          pendencias:=pendencias||jsonb_build_array('Existem OS com pendência e contexto/período ou medidor não verificável. Regularize a conferência antes de propor outra OS.');end if;
      elsif (catalogo.natureza='peca' and parcela->>'destino'='estoque') or (catalogo.natureza='servico' and parcela->>'destino'='pendente') then
        if nullif(parcela->>'veiculo_id','') is not null or nullif(parcela->>'placa','') is not null or nullif(parcela->>'os_item_id','') is not null then raise exception 'Destino sem veículo não pode identificar OS ou placa.'; end if;
      else raise exception 'Destino incompatível com peça/serviço.'; end if;
      rateios:=rateios||jsonb_build_array(jsonb_build_object('indice',indice,'destino',parcela->>'destino','veiculo',coalesce(parcela->>'placa',''),'valor',vp::text,
        'quantidade',qp::text,'centro_custo',parcela->>'centro_custo','conta',(select nome from public.frota_gestao_contas where id=(parcela->>'conta_id')::uuid),
        'categoria',(select nome from public.frota_gestao_categorias where id=(parcela->>'categoria_id')::uuid),'unidade_custo',(select nome from public.operacoes where id=(parcela->>'unidade_id')::uuid),'executado_em',coalesce(parcela->>'executado_em',''),
        'os_item_id',coalesce(parcela->>'os_item_id',''),'acao',case when parcela->>'destino'<>'veiculo' then 'sem_os' when nullif(parcela->>'os_item_id','') is null then 'criar' else 'vincular' end,'candidatas',candidatas));indice:=indice+1;
    end loop;
    if soma_q<>q or soma_v<>liquido then raise exception 'Rateio do item % não concilia quantidade e centavos do líquido.',linha->>'numero';end if;
    soma:=soma+liquido;linhas:=linhas||jsonb_build_array(jsonb_build_object('numero',linha->>'numero','natureza',catalogo.natureza,'liquido',liquido::text,'rateios',rateios));
  end loop;
  if soma<>public.frota_gestao_decimal_nf(d#>>'{nota,total}',2) then raise exception 'Itens, descontos e acréscimos não conciliam com o total da nota. Distribua os ajustes gerais explicitamente.';end if;
  return jsonb_build_object('contrato','03','rascunho_id',r.id,'revisao',r.revisao::text,'total',soma::text,'fornecedor',fornecedor.razao_social,'linhas',linhas,'pendencias',pendencias);
end $$;
revoke all on function public.frota_gestao_conferir_nf(uuid,bigint) from public,anon;
grant execute on function public.frota_gestao_conferir_nf(uuid,bigint) to authenticated;

-- ===== 20261103001000_frota_95_lancamento_simplificado.sql =====
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

-- ===== 20261103001100_frota_96_estoque_simplificado.sql =====
-- Origem: SQL 96 do módulo Gestão da Frota (extraído do laboratório, sem alterações de lógica).
-- MANUAL, após 95 revisado e seus predecessores. Não libera escritas.
-- Não converte saldos/custos do contrato anterior nem do Gestran.
-- (begin/commit removidos: o Supabase CLI já executa cada migration em uma transação)
create table if not exists public.frota_gestao_lancamento_aplicacoes (
 id uuid primary key default gen_random_uuid(), chave uuid not null unique,
 lote_id uuid not null references public.frota_gestao_lancamento_lotes(id),
 veiculo_id uuid not null references public.veiculos(id), placa text not null,
 centro_custo text not null check(centro_custo in ('501','301','201','101','401')),
 quantidade numeric(20,6) not null check(quantidade>0 and quantidade<1e14),
 valor numeric(18,2) not null check(valor>=0 and valor<1e16), dados jsonb not null,
 criado_por uuid not null references public.perfis(id), criado_em timestamptz not null default clock_timestamp()
);
-- Sem preencher retroativamente: aplicações anteriores conservam sua evidência fiscal.
alter table public.frota_gestao_lancamento_aplicacoes add column if not exists manutencao text check(manutencao in ('preventiva','corretiva'));
create index if not exists frota_gestao_lancamento_aplicacoes_lote on public.frota_gestao_lancamento_aplicacoes(lote_id);
alter table public.frota_gestao_lancamento_aplicacoes enable row level security;
revoke all on public.frota_gestao_lancamento_aplicacoes from public,anon,authenticated;
grant select on public.frota_gestao_lancamento_aplicacoes to authenticated;
drop policy if exists leitura_ativa on public.frota_gestao_lancamento_aplicacoes;
create policy leitura_ativa on public.frota_gestao_lancamento_aplicacoes for select to authenticated using(public.frota_gestao_usuario_ativo());
drop trigger if exists registrar_auditoria on public.frota_gestao_lancamento_aplicacoes;
create trigger registrar_auditoria after insert on public.frota_gestao_lancamento_aplicacoes for each row execute function public.frota_gestao_auditar();
drop trigger if exists preservar_original on public.frota_gestao_lancamento_aplicacoes;
create trigger preservar_original before update or delete on public.frota_gestao_lancamento_aplicacoes for each row execute function public.frota_gestao_snapshot_simplificado();

create or replace function public.frota_gestao_aplicar_simplificado(p_chave uuid,p_dados jsonb,p_confirmado boolean)
returns jsonb language plpgsql security definer set search_path=pg_catalog,public as $$
declare lote public.frota_gestao_lancamento_lotes; anterior public.frota_gestao_lancamento_aplicacoes;
 aplicado numeric; custo numeric; qtd numeric; valor_aplicar numeric; veiculo uuid; placa_atual text;
begin
 perform public.frota_gestao_exigir_escrita(false);
 if not public.frota_gestao_usuario_ativo() then raise exception using errcode='42501',message='Conta ativa necessária.';end if;
 if p_chave is null or p_confirmado is distinct from true then raise exception 'Confirme a aplicação.';end if;
 if p_dados is null or jsonb_typeof(p_dados)<>'object' or octet_length(p_dados::text)>2048 then raise exception 'Dados de aplicação inválidos.';end if;
 perform pg_advisory_xact_lock(hashtextextended('frota-aplicar:'||p_chave::text,0));
 select * into anterior from public.frota_gestao_lancamento_aplicacoes where chave=p_chave;
 if found then
  if anterior.dados is distinct from p_dados then raise exception 'Solicitação já confirmada com outros dados.';end if;
  return to_jsonb(anterior)||jsonb_build_object('quantidade',anterior.quantidade::text,'valor',anterior.valor::text);
 end if;
 if coalesce(p_dados->>'quantidade','')!~'^[0-9]{1,14}(\.[0-9]{1,6})?$' or coalesce(p_dados->>'centro_custo','') not in ('501','301','201','101','401') then raise exception 'Confira quantidade e centro de custo.';end if;
 if coalesce(p_dados->>'manutencao','') not in ('preventiva','corretiva') then raise exception 'Selecione Preventivo ou Corretivo para esta aplicação.';end if;
 qtd:=(p_dados->>'quantidade')::numeric;
 select * into lote from public.frota_gestao_lancamento_lotes where id=(p_dados->>'lote_id')::uuid for update;
 if not found then raise exception 'Entrada de estoque não encontrada.';end if;
 select id,placa into veiculo,placa_atual from public.veiculos where id=(p_dados->>'veiculo_id')::uuid;
 if veiculo is null then raise exception 'Selecione uma placa cadastrada.';end if;
 select coalesce(sum(quantidade),0),coalesce(sum(valor),0) into aplicado,custo from public.frota_gestao_lancamento_aplicacoes where lote_id=lote.id;
 if qtd<=0 or qtd>lote.quantidade-aplicado then raise exception 'Quantidade maior que o saldo disponível ou inválida. Atualize o estoque.';end if;
 -- Custo acumulado arredondado evita perder/somar centavos em aplicações parciais.
 valor_aplicar:=round(lote.valor*(aplicado+qtd)/lote.quantidade,2)-custo;
 insert into public.frota_gestao_lancamento_aplicacoes(chave,lote_id,veiculo_id,placa,centro_custo,quantidade,valor,dados,criado_por,manutencao)
 values(p_chave,lote.id,veiculo,placa_atual,p_dados->>'centro_custo',qtd,valor_aplicar,p_dados,auth.uid(),p_dados->>'manutencao') returning * into anterior;
 return to_jsonb(anterior)||jsonb_build_object('quantidade',anterior.quantidade::text,'valor',anterior.valor::text);
end $$;
revoke all on function public.frota_gestao_aplicar_simplificado(uuid,jsonb,boolean) from public,anon;
grant execute on function public.frota_gestao_aplicar_simplificado(uuid,jsonb,boolean) to authenticated;

create or replace function public.frota_gestao_estoque_simplificado()
returns jsonb language plpgsql stable security definer set search_path=pg_catalog,public as $$
declare lotes jsonb; aplicacoes jsonb; veiculos jsonb;
begin
 if not public.frota_gestao_usuario_ativo() then raise exception using errcode='42501',message='Conta ativa necessária.';end if;
 select coalesce(jsonb_agg(to_jsonb(x) order by x.criado_em desc,x.id),'[]') into lotes from (
  select l.id,l.lancamento_id,n.numero,n.serie,n.fornecedor,l.descricao,l.unidade,l.criado_em,o.nome unidade_fiscal,
   l.quantidade::text quantidade,l.valor::text valor,(l.quantidade-coalesce(a.quantidade,0))::text saldo,
   (l.valor-coalesce(a.valor,0))::text valor_saldo,coalesce(a.quantidade,0)::text quantidade_aplicada,
   coalesce(a.valor,0)::text valor_aplicado,coalesce(h.linha->>'conta','—') conta,coalesce(h.linha->>'conta_codigo','') conta_codigo,coalesce(h.linha->>'manutencao','') manutencao,coalesce(h.linha->>'classificacao','') classificacao
  from public.frota_gestao_lancamento_lotes l join public.frota_gestao_lancamentos n on n.id=l.lancamento_id
  join public.operacoes o on o.id=l.unidade_fiscal_id
  left join lateral (select sum(quantidade) quantidade,sum(valor) valor from public.frota_gestao_lancamento_aplicacoes where lote_id=l.id) a on true
  left join lateral (select linha from jsonb_array_elements(n.hbf->'linhas') linha where linha->>'id'=l.parcela_id) h on true
 ) x;
 select coalesce(jsonb_agg(to_jsonb(x) order by x.criado_em desc,x.id),'[]') into aplicacoes from (
  select a.id,a.chave,a.lote_id,a.veiculo_id,a.placa,a.centro_custo,a.quantidade::text quantidade,a.valor::text valor,a.criado_em,p.nome autor,a.manutencao
  from public.frota_gestao_lancamento_aplicacoes a join public.perfis p on p.id=a.criado_por
 ) x;
 select coalesce(jsonb_agg(jsonb_build_object('id',v.id,'placa',v.placa,'centro_custo',to_jsonb(v)->>'centro_custo') order by v.placa),'[]') into veiculos from public.veiculos v;
 return jsonb_build_object('contrato','estoque-simplificado-01','manutencao_editavel',true,'lotes',lotes,'aplicacoes',aplicacoes,'veiculos',veiculos);
end $$;
revoke all on function public.frota_gestao_estoque_simplificado() from public,anon;
grant execute on function public.frota_gestao_estoque_simplificado() to authenticated;

-- Fonte para o próximo Dashboard: nunca inclui valor ainda parado em estoque.
create or replace function public.frota_gestao_custos_simplificados()
returns jsonb language plpgsql stable security definer set search_path=pg_catalog,public as $$
begin
 if not public.frota_gestao_usuario_ativo() then raise exception using errcode='42501',message='Conta ativa necessária.';end if;
 return coalesce((select jsonb_agg(to_jsonb(x)) from (
  select 'direto' origem,n.id lancamento_id,l->>'id' referencia,(l->>'veiculo_id')::uuid veiculo_id,l->>'veiculo' placa,
   substring(l->>'centro_custo' from '[0-9]{3}$') centro_custo,l->>'valor_total' valor,l->>'quantidade' quantidade,l->>'conta' conta,l->>'manutencao' manutencao,n.finalizada_em reconhecido_em,coalesce(l->>'classificacao','') classificacao
  from public.frota_gestao_lancamentos n cross join lateral jsonb_array_elements(n.hbf->'linhas') l where l->>'veiculo'<>'Estoque'
  union all
  select 'aplicacao',l.lancamento_id,a.id::text,a.veiculo_id,a.placa,a.centro_custo,a.valor::text,a.quantidade::text,h.linha->>'conta',coalesce(a.manutencao,h.linha->>'manutencao'),a.criado_em,coalesce(h.linha->>'classificacao','')
  from public.frota_gestao_lancamento_aplicacoes a join public.frota_gestao_lancamento_lotes l on l.id=a.lote_id
  join public.frota_gestao_lancamentos n on n.id=l.lancamento_id
  left join lateral (select linha from jsonb_array_elements(n.hbf->'linhas') linha where linha->>'id'=l.parcela_id) h on true
 ) x),'[]');
end $$;
revoke all on function public.frota_gestao_custos_simplificados() from public,anon;
grant execute on function public.frota_gestao_custos_simplificados() to authenticated;
notify pgrst,'reload schema';

-- ===== 20261103001200_frota_97_consulta_simplificada.sql =====
-- Origem: SQL 97 do módulo Gestão da Frota (extraído do laboratório, sem alterações de lógica).
-- SOMENTE instalação manual futura, após 95 e 96 revisados e seus predecessores.
-- Acrescenta consulta; não altera dados, tabelas, ACL legada nem libera escritas.
-- (begin/commit removidos: o Supabase CLI já executa cada migration em uma transação)
create or replace function public.frota_gestao_dashboard_simplificado()
returns jsonb language plpgsql stable security definer set search_path=pg_catalog,public as $$
declare custos jsonb; compras jsonb; estoque jsonb;
begin
 if not public.frota_gestao_usuario_ativo() then raise exception using errcode='42501',message='Conta ativa necessária.';end if;
 select coalesce(jsonb_agg(to_jsonb(x) order by x.reconhecido_em desc,x.id),'[]') into custos from (
  select (c->>'origem')||':'||(c->>'lancamento_id')||':'||(c->>'referencia') id,
   c->>'origem' origem,n.id lancamento_id,n.numero,n.serie,n.fornecedor,c->>'referencia' referencia,
   (c->>'veiculo_id')::uuid veiculo_id,c->>'placa' placa,c->>'centro_custo' centro_custo,
   c->>'valor' valor,c->>'quantidade' quantidade,c->>'conta' conta,c->>'classificacao' classificacao,
   c->>'manutencao' manutencao,(c->>'reconhecido_em')::timestamptz reconhecido_em,
   n.unidade_fiscal_id,o.nome unidade_fiscal,h.linha->>'unidade' unidade,h.linha->>'pecas_servicos' descricao,
   h.linha->>'conta_codigo' conta_codigo,os.numero::text numero_os
  from jsonb_array_elements(public.frota_gestao_custos_simplificados()) c
  join public.frota_gestao_lancamentos n on n.id=(c->>'lancamento_id')::uuid
  join public.operacoes o on o.id=n.unidade_fiscal_id
  left join public.frota_gestao_lancamento_aplicacoes a on a.id=case when c->>'origem'='aplicacao' then (c->>'referencia')::uuid end
  left join public.frota_gestao_lancamento_lotes l on l.id=a.lote_id
  left join lateral (select linha from jsonb_array_elements(n.hbf->'linhas') linha where linha->>'id'=coalesce(l.parcela_id,c->>'referencia')) h on true
  left join public.frota_gestao_lancamento_os os on os.lancamento_id=n.id and os.veiculo_id=(c->>'veiculo_id')::uuid
 ) x;
 select coalesce(jsonb_agg(to_jsonb(x) order by x.reconhecido_em desc,x.id),'[]') into compras from (
  select n.id::text||':'||(h->>'id') id,n.id lancamento_id,n.numero,n.fornecedor,n.finalizada_em reconhecido_em,
   n.unidade_fiscal_id,o.nome unidade_fiscal,h->>'veiculo_id' veiculo_id,h->>'veiculo' placa,
   substring(h->>'centro_custo' from '[0-9]{3}$') centro_custo,h->>'quantidade' quantidade,h->>'unidade' unidade,
   h->>'valor_total' valor,h->>'classificacao' classificacao,h->>'conta_codigo' conta_codigo,h->>'conta' conta,
   h->>'manutencao' manutencao,h->>'pecas_servicos' descricao
  from public.frota_gestao_lancamentos n join public.operacoes o on o.id=n.unidade_fiscal_id
  cross join lateral jsonb_array_elements(n.hbf->'linhas') h
 ) x;
 estoque:=public.frota_gestao_estoque_simplificado();
 return jsonb_build_object('contrato','dashboard-simplificado-01','custos',custos,'compras',compras,
  'estoque',estoque->'lotes','consultado_em',statement_timestamp());
end $$;
revoke all on function public.frota_gestao_dashboard_simplificado() from public,anon;
grant execute on function public.frota_gestao_dashboard_simplificado() to authenticated;
notify pgrst,'reload schema';

-- ===== 20261103001300_frota_98_cadastros.sql =====
-- Origem: SQL 98 do módulo Gestão da Frota (extraído do laboratório, sem alterações de lógica).
-- MANUAL após 97, 96 e 95 revisados. Não libera escritas nem instala dados da planilha.
-- (begin/commit removidos: o Supabase CLI já executa cada migration em uma transação)
create table if not exists public.frota_gestao_cadastros (
 id uuid primary key default gen_random_uuid(),tipo text not null check(tipo in ('veiculos','fornecedores','contas','classificacoes')),
 chave text not null,dados jsonb not null,criado_por uuid references public.perfis(id),
 atualizado_por uuid references public.perfis(id),criado_em timestamptz not null default now(),atualizado_em timestamptz not null default now(),unique(tipo,chave)
);
create table if not exists public.frota_gestao_cadastro_operacoes (
 id uuid primary key,dados jsonb not null,recibo jsonb not null,autor_id uuid not null references public.perfis(id),criado_em timestamptz not null default now()
);
do $$ declare tabela text;begin
 foreach tabela in array array['frota_gestao_cadastros','frota_gestao_cadastro_operacoes'] loop
  execute format('alter table public.%I enable row level security',tabela);
  execute format('revoke all on public.%I from public,anon,authenticated',tabela);
  execute format('grant select on public.%I to authenticated',tabela);
  execute format('drop policy if exists leitura_ativa on public.%I',tabela);
  execute format('create policy leitura_ativa on public.%I for select to authenticated using(public.frota_gestao_usuario_ativo())',tabela);
 end loop;
end $$;
drop trigger if exists registrar_auditoria on public.frota_gestao_cadastros;
create trigger registrar_auditoria after insert or update or delete on public.frota_gestao_cadastros for each row execute function public.frota_gestao_auditar();
drop trigger if exists preservar_original on public.frota_gestao_cadastro_operacoes;
create trigger preservar_original before update or delete on public.frota_gestao_cadastro_operacoes for each row execute function public.frota_gestao_snapshot_simplificado();
create or replace view public.frota_gestao_veiculos with (security_barrier=true) as
 select v.id,coalesce(c.dados->>'placa',v.placa) placa,
 coalesce((c.dados->>'unidade_id')::uuid,v.operacao_id) operacao_id,
 coalesce(c.dados->>'centro_custo',to_jsonb(v)->>'centro_custo') centro_custo
 from public.veiculos v left join public.frota_gestao_cadastros c on c.id=v.id and c.tipo='veiculos'
 where public.frota_gestao_usuario_ativo();
revoke all on public.frota_gestao_veiculos from public,anon,authenticated;
grant select on public.frota_gestao_veiculos to authenticated;

create or replace function public.frota_gestao_listar_cadastros()
returns jsonb language plpgsql stable security definer set search_path=pg_catalog,public as $$
begin
 if not public.frota_gestao_usuario_ativo() then raise exception using errcode='42501',message='Conta ativa necessária.';end if;
 return jsonb_build_object('contrato','cadastros-01','registros',coalesce((select jsonb_agg(to_jsonb(c)) from (
  select id,tipo,chave,dados,atualizado_em from public.frota_gestao_cadastros
  union all select f.fornecedor_id,'fornecedores',f.documento,jsonb_build_object('nome',f.razao_social,'documento',f.documento,'local',''),f.criado_em from public.frota_gestao_fornecedores f where not exists(select 1 from public.frota_gestao_cadastros c where c.id=f.fornecedor_id)
 )c),'[]'),
 'veiculos',coalesce((select jsonb_agg(to_jsonb(v) order by placa) from public.frota_gestao_veiculos v),'[]'),
 'unidades',coalesce((select jsonb_agg(jsonb_build_object('id',id,'nome',nome) order by nome) from public.operacoes where ativa),'[]'));
end $$;
revoke all on function public.frota_gestao_listar_cadastros() from public,anon;
grant execute on function public.frota_gestao_listar_cadastros() to authenticated;

create or replace function public.frota_gestao_salvar_cadastro(p_chave uuid,p_tipo text,p_id uuid,p_dados jsonb)
returns jsonb language plpgsql security definer set search_path=pg_catalog,public as $$
declare identificador uuid;chave_cadastro text;pedido jsonb;anterior public.frota_gestao_cadastros;resposta jsonb;recibo_anterior public.frota_gestao_cadastro_operacoes;
begin
 perform public.frota_gestao_exigir_escrita(false);
 if not public.frota_gestao_usuario_ativo() then raise exception using errcode='42501',message='Conta ativa necessária.';end if;
 if p_chave is null or p_tipo not in ('veiculos','fornecedores','contas','classificacoes') or p_tipo is null or p_dados is null or jsonb_typeof(p_dados)<>'object' or octet_length(p_dados::text)>4096 then raise exception 'Cadastro inválido.';end if;
 pedido:=jsonb_build_object('tipo',p_tipo,'id',p_id,'dados',p_dados);
 perform pg_advisory_xact_lock(hashtextextended('frota-cadastro-op:'||p_chave::text,0));
 select * into recibo_anterior from public.frota_gestao_cadastro_operacoes where id=p_chave;
 if found then if recibo_anterior.dados<>pedido then raise exception 'Chave já confirmada com outros dados.';end if;return recibo_anterior.recibo;end if;
 if p_tipo='veiculos' then
  chave_cadastro:=upper(regexp_replace(p_dados->>'placa','[^A-Za-z0-9]','','g'));
  if coalesce(chave_cadastro,'')!~'^[A-Z0-9]{3,10}$' or coalesce(p_dados->>'centro_custo','') not in ('101','201','301','401','501') then raise exception 'Confira placa e centro de custo.';end if;
  if not exists(select 1 from public.operacoes where id=(p_dados->>'unidade_id')::uuid and ativa) then raise exception 'Selecione uma unidade cadastrada e ativa.';end if;
  p_dados:=jsonb_build_object('placa',chave_cadastro,'centro_custo',p_dados->>'centro_custo','unidade_id',p_dados->>'unidade_id');
 elsif p_tipo='fornecedores' then
  chave_cadastro:=regexp_replace(p_dados->>'documento','[^0-9]','','g');
  if coalesce(chave_cadastro,'')!~'^([0-9]{11}|[0-9]{14})$' then raise exception 'Informe CPF com 11 ou CNPJ com 14 dígitos.';end if;
  if coalesce(btrim(p_dados->>'nome'),'')='' or length(p_dados->>'nome')>200 or length(coalesce(p_dados->>'local',''))>250 then raise exception 'Confira nome e local do fornecedor.';end if;
  p_dados:=jsonb_build_object('documento',chave_cadastro,'nome',btrim(p_dados->>'nome'),'local',coalesce(btrim(p_dados->>'local'),''));
 elsif p_tipo='contas' then
  chave_cadastro:=btrim(p_dados->>'codigo');
  if coalesce(chave_cadastro,'')!~'^[0-9]{3,20}$' or coalesce(btrim(p_dados->>'nome'),'')='' or length(p_dados->>'nome')>160 then raise exception 'Confira número e nome da conta.';end if;
  p_dados:=jsonb_build_object('codigo',chave_cadastro,'nome',btrim(p_dados->>'nome'),'categoria',coalesce(p_dados->>'categoria',''),'busca',coalesce(p_dados->>'busca',''));
 else
  chave_cadastro:=lower(btrim(p_dados->>'nome'));
  if coalesce(chave_cadastro,'')='' or length(chave_cadastro)>80 then raise exception 'Informe a classificação com até 80 caracteres.';end if;
  p_dados:=jsonb_build_object('nome',btrim(p_dados->>'nome'));
 end if;
 perform pg_advisory_xact_lock(hashtextextended('frota-cadastro:'||p_tipo||':'||chave_cadastro,0));
 identificador:=coalesce(p_id,gen_random_uuid());
 if p_id is not null then
  select * into anterior from public.frota_gestao_cadastros where id=p_id and tipo=p_tipo for update;
  if not found and not((p_tipo='veiculos' and exists(select 1 from public.veiculos where id=p_id)) or (p_tipo='fornecedores' and exists(select 1 from public.frota_gestao_fornecedores where fornecedor_id=p_id))) then raise exception 'Cadastro não encontrado para edição.';end if;
 end if;
 if exists(select 1 from public.frota_gestao_cadastros where tipo=p_tipo and chave=chave_cadastro and id<>identificador) then raise exception 'Cadastro já existente. Use Editar.';end if;
 if p_tipo='fornecedores' and exists(select 1 from public.frota_gestao_fornecedores f where f.documento=chave_cadastro and f.fornecedor_id<>identificador and not exists(select 1 from public.frota_gestao_cadastros c where c.id=f.fornecedor_id)) then raise exception 'Fornecedor já existente. Use Editar.';end if;
 if p_tipo='veiculos' then
  if exists(select 1 from public.frota_gestao_veiculos where upper(regexp_replace(placa,'[^A-Za-z0-9]','','g'))=chave_cadastro and id<>identificador) then raise exception 'Placa já cadastrada. Use Editar.';end if;
  if not exists(select 1 from public.veiculos where id=identificador) then
   -- Novos registros mínimos não devem entrar silenciosamente na operação legada.
   if exists(select 1 from pg_attribute where attrelid='public.veiculos'::regclass and attname='status' and not attisdropped) then
    execute 'insert into public.veiculos(id,placa,operacao_id,centro_custo,status) values($1,$2,$3,$4,''inativo'')' using identificador,chave_cadastro,(p_dados->>'unidade_id')::uuid,p_dados->>'centro_custo';
   else insert into public.veiculos(id,placa,operacao_id,centro_custo) values(identificador,chave_cadastro,(p_dados->>'unidade_id')::uuid,p_dados->>'centro_custo');end if;
  end if;
 end if;
 insert into public.frota_gestao_cadastros(id,tipo,chave,dados,criado_por,atualizado_por) values(identificador,p_tipo,chave_cadastro,p_dados,auth.uid(),auth.uid())
 on conflict(id) do update set chave=excluded.chave,dados=excluded.dados,atualizado_por=auth.uid(),atualizado_em=clock_timestamp();
 resposta:=jsonb_build_object('id',identificador,'chave',p_chave,'tipo',p_tipo,'dados',p_dados,'confirmado_em',clock_timestamp());
 insert into public.frota_gestao_cadastro_operacoes(id,dados,recibo,autor_id) values(p_chave,pedido,resposta,auth.uid());
 return resposta;
end $$;
revoke all on function public.frota_gestao_salvar_cadastro(uuid,text,uuid,jsonb) from public,anon;
grant execute on function public.frota_gestao_salvar_cadastro(uuid,text,uuid,jsonb) to authenticated;
-- CATALOGOS_PADRAO
create or replace function public.frota_gestao_importar_veiculos(p_chave uuid,p_linhas jsonb)
returns jsonb language plpgsql security definer set search_path=pg_catalog,public as $$
declare linha jsonb;oid uuid;vid uuid;i integer:=0;resposta jsonb;pedido jsonb;anterior public.frota_gestao_cadastro_operacoes;
begin
 perform public.frota_gestao_exigir_escrita(false);
 if not public.frota_gestao_usuario_ativo() then raise exception using errcode='42501',message='Conta ativa necessária.';end if;
 if p_chave is null or jsonb_typeof(p_linhas)<>'array' or p_linhas is null or jsonb_array_length(p_linhas)<1 or jsonb_array_length(p_linhas)>1000 or octet_length(p_linhas::text)>1048576 then raise exception 'Confira as linhas da planilha.';end if;
 if exists(select 1 from jsonb_array_elements(p_linhas) l group by upper(regexp_replace(l->>'placa','[^A-Za-z0-9]','','g')) having count(*)>1) then raise exception 'Placa repetida na planilha.';end if;
 pedido:=jsonb_build_object('tipo','importacao_veiculos','linhas',p_linhas);
 perform pg_advisory_xact_lock(hashtextextended('frota-cadastro-op:'||p_chave::text,0));
 select * into anterior from public.frota_gestao_cadastro_operacoes where id=p_chave;
 if found then if anterior.dados<>pedido then raise exception 'Solicitação já usada com outra planilha.';end if;return anterior.recibo;end if;
 for linha in select * from jsonb_array_elements(p_linhas) loop
  i:=i+1;vid:=null;oid:=null;
  if coalesce(linha->>'unidade','') not in ('Patos','Sumé') then raise exception 'Unidade inválida na linha %.',i;end if;
  select id into oid from public.operacoes where ativa and translate(lower(nome),'áàãâéêíóôõúüç','aaaaeeiooouuc') like '%'||translate(lower(linha->>'unidade'),'áàãâéêíóôõúüç','aaaaeeiooouuc')||'%';
  if oid is null or (select count(*) from public.operacoes where ativa and translate(lower(nome),'áàãâéêíóôõúüç','aaaaeeiooouuc') like '%'||translate(lower(linha->>'unidade'),'áàãâéêíóôõúüç','aaaaeeiooouuc')||'%')<>1 then raise exception 'Unidade não identificada de forma única na linha %.',i;end if;
  select id into vid from public.frota_gestao_veiculos where upper(regexp_replace(placa,'[^A-Za-z0-9]','','g'))=upper(regexp_replace(linha->>'placa','[^A-Za-z0-9]','','g'));
  perform public.frota_gestao_salvar_cadastro(md5(p_chave::text||':'||i::text)::uuid,'veiculos',vid,jsonb_build_object('placa',linha->>'placa','centro_custo',linha->>'centro_custo','unidade_id',oid));
 end loop;
 resposta:=jsonb_build_object('chave',p_chave,'quantidade',i,'confirmado_em',clock_timestamp());
 insert into public.frota_gestao_cadastro_operacoes(id,dados,recibo,autor_id) values(p_chave,pedido,resposta,auth.uid());
 return resposta;
end $$;
revoke all on function public.frota_gestao_importar_veiculos(uuid,jsonb) from public,anon;
grant execute on function public.frota_gestao_importar_veiculos(uuid,jsonb) to authenticated;
-- INICIO_CATALOGOS
insert into public.frota_gestao_cadastros(id,tipo,chave,dados) values
('5e3cddf8-10b0-4000-8000-87ac93ad987b','contas','4120512','{"codigo":"4120512","nome":"Sinistro a Terceiros","busca":"acidente dano terceiro sinistro"}'::jsonb),
('19f627fe-fd2d-4000-8000-cc7571831e33','contas','4120503','{"codigo":"4120503","nome":"Peças preventiva","categoria":"pecas","busca":"peca peças preventiva preventivo prev"}'::jsonb),
('cfe24ad6-9d63-4000-8000-41beb2e6b7b3','contas','4120508','{"codigo":"4120508","nome":"Peças corretivas","categoria":"pecas","busca":"peca peças corretiva corretivo corr"}'::jsonb),
('5d2058a3-3cda-4000-8000-7bc61f939f88','contas','4120501','{"codigo":"4120501","nome":"Serviços preventivo","categoria":"servicos","busca":"servico serviços preventiva preventivo prev"}'::jsonb),
('cc57ee1d-4bf0-4000-8000-b355fc980cd8','contas','4120506','{"codigo":"4120506","nome":"Serviços corretivos","categoria":"servicos","busca":"servico serviços corretiva corretivo corr"}'::jsonb),
('7506c0e3-25da-4000-8000-196e85e3d2e1','contas','4120504','{"codigo":"4120504","nome":"Pneus","categoria":"pneus","busca":"pneu pneus"}'::jsonb),
('731bdf0c-a255-4000-8000-dec1519104c7','contas','4120509','{"codigo":"4120509","nome":"Pneus, câmaras e recauchutagem RN/Promotor","categoria":"pneus","busca":"pneu camara recapagem recauchutagem rn promotor"}'::jsonb),
('aa8e4962-79b7-4000-8000-d98c44b32b1f','contas','4120510','{"codigo":"4120510","nome":"Pneus, câmaras e recauchutagem frota leve","categoria":"pneus","busca":"pneu camara recapagem recauchutagem leve"}'::jsonb),
('6877f9f1-d189-4000-8000-be9d69e3bc5c','contas','4120511','{"codigo":"4120511","nome":"Pneus, câmaras e recauchutagem empilhadeira","categoria":"pneus","busca":"pneu camara recapagem recauchutagem empilhadeira"}'::jsonb),
('9fd1cf4c-81fd-4000-8000-4dd129c54d7d','contas','4120301','{"codigo":"4120301","nome":"Combustível","busca":"combustivel abastecimento diesel gasolina etanol"}'::jsonb),
('a0e2da39-ae48-4000-8000-d9d4187f5442','contas','4120302','{"codigo":"4120302","nome":"Óleo e lubrificantes","categoria":"oleo_lubrificante","busca":"oleo lubrificante lubrificacao"}'::jsonb),
('ff6559b0-ea45-4000-8000-6b878c367a66','contas','4110502','{"codigo":"4110502","nome":"Vale transporte","busca":"vale transporte passagem vt"}'::jsonb),
('7669c961-75f0-4000-8000-1966fab1f2b1','contas','4120505','{"codigo":"4120505","nome":"Lavagem de veículos","categoria":"lavagem","busca":"lavagem lavar limpeza veiculo"}'::jsonb),
('a347b1d1-f5be-4000-8000-dcbfb4af747e','contas','4120701','{"codigo":"4120701","nome":"Entrega com terceiros","busca":"entrega terceiro frete"}'::jsonb),
('027aaef6-1829-4000-8000-965e0dc8d854','contas','4120702','{"codigo":"4120702","nome":"Puxada com terceiros","busca":"puxada terceiro frete"}'::jsonb),
('0b6fafa8-c99e-4000-8000-bed6e0bac0d2','classificacoes','elétrico','{"nome":"Elétrico"}'::jsonb),
('b69d453f-3866-4000-8000-e420493a12df','classificacoes','eletrônica e diagnóstico','{"nome":"Eletrônica e diagnóstico"}'::jsonb),
('64970a52-5df9-4000-8000-688786238ce6','classificacoes','bateria','{"nome":"Bateria"}'::jsonb),
('81b1c708-8f6c-4000-8000-22bb85ae8f80','classificacoes','alternador','{"nome":"Alternador"}'::jsonb),
('e9893c06-9a6a-4000-8000-1a286f16fe55','classificacoes','motor de partida','{"nome":"Motor de partida"}'::jsonb),
('8b180a24-fe3f-4000-8000-1c4949d0a918','classificacoes','iluminação','{"nome":"Iluminação"}'::jsonb),
('d82d82e3-72e0-4000-8000-20699462b5bc','classificacoes','óleo e lubrificantes','{"nome":"Óleo e lubrificantes"}'::jsonb),
('68e03273-7330-4000-8000-ab3efe5e6055','classificacoes','filtros','{"nome":"Filtros"}'::jsonb),
('1b5f1193-4edb-4000-8000-f8ab77a098a3','classificacoes','pneus','{"nome":"Pneus"}'::jsonb),
('cf51a538-f858-4000-8000-b21d2c3f6181','classificacoes','compras de pneus','{"nome":"Compras de Pneus"}'::jsonb),
('da4517ba-599e-4000-8000-9b5bd3d3da04','classificacoes','recapagens de pneus','{"nome":"Recapagens de Pneus"}'::jsonb),
('7f53114b-9a13-4000-8000-7978dd23680f','classificacoes','consertos de pneus','{"nome":"Consertos de Pneus"}'::jsonb),
('d92edf7c-f67e-4000-8000-1f28770b7e89','classificacoes','câmaras de ar','{"nome":"Câmaras de ar"}'::jsonb),
('be89967f-475c-4000-8000-01e39ec466b3','classificacoes','rodas e aros','{"nome":"Rodas e aros"}'::jsonb),
('a1d898e0-a53f-4000-8000-93426aacff8c','classificacoes','alinhamento e balanceamento','{"nome":"Alinhamento e balanceamento"}'::jsonb),
('3a817ad9-76fd-4000-8000-06a5be8525b2','classificacoes','combustível','{"nome":"Combustível"}'::jsonb),
('f291852c-0b2a-4000-8000-f32bb7792cf7','classificacoes','injeção e alimentação','{"nome":"Injeção e alimentação"}'::jsonb),
('8ac100ed-484b-4000-8000-7821f9772d7e','classificacoes','arrefecimento','{"nome":"Arrefecimento"}'::jsonb),
('7188d7a8-ee8a-4000-8000-15652cc53613','classificacoes','motor','{"nome":"Motor"}'::jsonb),
('fe6bf9f2-1d97-4000-8000-521586ac4fb3','classificacoes','correias e tensores','{"nome":"Correias e tensores"}'::jsonb),
('abdb84a7-3c7c-4000-8000-b99c67e42fb7','classificacoes','escapamento','{"nome":"Escapamento"}'::jsonb),
('648a70d1-31d8-4000-8000-ee547cf6d0fd','classificacoes','freios','{"nome":"Freios"}'::jsonb),
('5214818c-1039-4000-8000-53e24fbfdcf0','classificacoes','lona de freio','{"nome":"Lona de freio"}'::jsonb),
('313edd11-e0a1-4000-8000-2a19e2303862','classificacoes','pastilhas e discos','{"nome":"Pastilhas e discos"}'::jsonb),
('face3b58-35c3-4000-8000-b23cf962da7c','classificacoes','sistema pneumático','{"nome":"Sistema pneumático"}'::jsonb),
('2edccec2-3a96-4000-8000-788e3d0c3933','classificacoes','suspensão','{"nome":"Suspensão"}'::jsonb),
('dae95caf-c3d5-4000-8000-6909c060e30b','classificacoes','molas e feixes','{"nome":"Molas e feixes"}'::jsonb),
('c2f4976b-d72b-4000-8000-651b82d2fdea','classificacoes','amortecedores','{"nome":"Amortecedores"}'::jsonb),
('2e66b219-458c-4000-8000-50e717066382','classificacoes','direção','{"nome":"Direção"}'::jsonb),
('79fdaa0f-46b7-4000-8000-1127432ca774','classificacoes','embreagem','{"nome":"Embreagem"}'::jsonb),
('4e319cfa-7eca-4000-8000-c978835f1673','classificacoes','câmbio','{"nome":"Câmbio"}'::jsonb),
('805f956b-3024-4000-8000-c3ab0d95d7fd','classificacoes','diferencial','{"nome":"Diferencial"}'::jsonb),
('eeb0e639-2acf-4000-8000-cf0e297146d4','classificacoes','transmissão e cardã','{"nome":"Transmissão e cardã"}'::jsonb),
('0cdc89b7-5dc1-4000-8000-03e0aa817094','classificacoes','rolamentos e cubos','{"nome":"Rolamentos e cubos"}'::jsonb),
('258bdbf2-518d-4000-8000-1436b1f32c4a','classificacoes','retentores e vedações','{"nome":"Retentores e vedações"}'::jsonb),
('1a36656f-61ff-4000-8000-90f624be1fb9','classificacoes','sistema hidráulico','{"nome":"Sistema hidráulico"}'::jsonb),
('dfee5151-1c3a-4000-8000-4fa2e8fc09c6','classificacoes','ar-condicionado','{"nome":"Ar-condicionado"}'::jsonb),
('6c951c13-c274-4000-8000-8eadde414351','classificacoes','cabine e interior','{"nome":"Cabine e interior"}'::jsonb),
('3d194156-e4c2-4000-8000-1e3a9ac07afc','classificacoes','vidros e retrovisores','{"nome":"Vidros e retrovisores"}'::jsonb),
('ea5d7097-e4f8-4000-8000-28fb7ce761a1','classificacoes','carroceria','{"nome":"Carroceria"}'::jsonb),
('1118d36a-5704-4000-8000-b9466e068d0d','classificacoes','chassi','{"nome":"Chassi"}'::jsonb),
('716c5a5d-2ccb-4000-8000-1ba1f65e6807','classificacoes','implementos e baú','{"nome":"Implementos e baú"}'::jsonb),
('f62b39b9-425c-4000-8000-e09b1c2b2a0d','classificacoes','funilaria','{"nome":"Funilaria"}'::jsonb),
('f57d776d-1b0d-4000-8000-f525477b2490','classificacoes','pintura','{"nome":"Pintura"}'::jsonb),
('511bae94-78e7-4000-8000-4c1bd8d80270','classificacoes','solda','{"nome":"Solda"}'::jsonb),
('6fd97792-8a34-4000-8000-48a71c6da288','classificacoes','lavagem','{"nome":"Lavagem"}'::jsonb),
('add0e980-a6d6-4000-8000-7ef89c3fedc3','classificacoes','higienização','{"nome":"Higienização"}'::jsonb),
('c075c765-e180-4000-8000-95c15c66da19','classificacoes','tapeçaria','{"nome":"Tapeçaria"}'::jsonb),
('88fef021-6eba-4000-8000-2b8eccd751a1','classificacoes','acessórios','{"nome":"Acessórios"}'::jsonb),
('10c7f3d4-e95a-4000-8000-6ce0ca7f2a53','classificacoes','rastreamento e telemetria','{"nome":"Rastreamento e telemetria"}'::jsonb),
('89cab3e0-f0df-4000-8000-88ca4362006d','classificacoes','mão de obra mecânica','{"nome":"Mão de obra mecânica"}'::jsonb),
('aa41a6de-33c3-4000-8000-ea283233055a','classificacoes','mão de obra elétrica','{"nome":"Mão de obra elétrica"}'::jsonb),
('30aee124-dc9c-4000-8000-4cfa49cbe0fb','classificacoes','socorro e guincho','{"nome":"Socorro e guincho"}'::jsonb),
('a4dd04dd-89f8-4000-8000-109219b8656d','classificacoes','inspeção e vistoria','{"nome":"Inspeção e vistoria"}'::jsonb),
('ab6375a4-246d-4000-8000-9123819cbfc9','classificacoes','documentação e taxas','{"nome":"Documentação e taxas"}'::jsonb),
('9f363569-e6ae-4000-8000-3a57a516788c','classificacoes','sinistro','{"nome":"Sinistro"}'::jsonb),
('af48981d-c8f6-4000-8000-a13dcd22a10e','classificacoes','serviços de terceiros','{"nome":"Serviços de terceiros"}'::jsonb),
('c884c445-0516-4000-8000-26bd19c0a027','classificacoes','frete e transporte','{"nome":"Frete e transporte"}'::jsonb),
('58ae55a2-df84-4000-8000-fc34d7deb63e','classificacoes','ferramentas e consumíveis','{"nome":"Ferramentas e consumíveis"}'::jsonb),
('a5b0e74d-2d9b-4000-8000-50189498974d','classificacoes','outros','{"nome":"Outros"}'::jsonb)
on conflict do nothing;
-- FIM_CATALOGOS
-- Adapta somente rotinas do novo contrato; snapshots e cadastros legados não são reescritos.
do $$ declare assinatura text;definicao text;begin
 foreach assinatura in array array['public.frota_gestao_validar_simplificado(jsonb,uuid,bigint)','public.frota_gestao_finalizar_simplificado(uuid,bigint,uuid,boolean)','public.frota_gestao_aplicar_simplificado(uuid,jsonb,boolean)','public.frota_gestao_estoque_simplificado()'] loop
  definicao:=pg_get_functiondef(to_regprocedure(assinatura));
  if definicao is null then raise exception 'Predecessor ausente: %',assinatura;end if;
  definicao:=replace(definicao,'from public.veiculos v','from public.frota_gestao_veiculos v');
  definicao:=replace(definicao,'from public.veiculos where','from public.frota_gestao_veiculos veiculos where');
  if position('public.frota_gestao_veiculos' in definicao)=0 then raise exception 'Contrato de veículos divergente: %',assinatura;end if;
  if assinatura like '%validar_simplificado%' then
   definicao:=replace(definicao,$troca$coalesce(l->>'conta_codigo','') not in ('4120512','4120503','4120508','4120501','4120506','4120504','4120509','4120510','4120511','4120301','4120302','4110502','4120505','4120701','4120702')$troca$,$troca$not exists(select 1 from public.frota_gestao_cadastros cad where cad.tipo='contas' and cad.dados->>'codigo'=l->>'conta_codigo')$troca$);
   if position('cad.tipo=''contas''' in definicao)=0 then raise exception 'Contrato de contas divergente; revisar 95 antes de aplicar 98.';end if;
  end if;
  execute definicao;
 end loop;
end $$;
notify pgrst,'reload schema';

-- ===== 20261103001400_agendar_expiracao_rascunhos.sql =====
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

-- ===== 20261103001500_endurecer_permissoes.sql =====
-- Rede de segurança: nenhuma tabela do schema public aceita escrita direta
-- pela API (anon/authenticated). Toda gravação passa pelas funções
-- frota_gestao_* (security definer), que aplicam as regras fiscais e de estoque.
do $$
declare tabela record;
begin
  for tabela in select c.relname from pg_class c join pg_namespace n on n.oid = c.relnamespace
      where n.nspname = 'public' and c.relkind in ('r', 'v', 'm', 'p') loop
    execute format('revoke insert, update, delete, truncate, references, trigger on public.%I from public, anon, authenticated', tabela.relname);
    execute format('revoke all on public.%I from anon', tabela.relname);
  end loop;
end $$;

do $$
declare sequencia record;
begin
  for sequencia in select c.relname from pg_class c join pg_namespace n on n.oid = c.relnamespace
      where n.nspname = 'public' and c.relkind = 'S' loop
    execute format('revoke all on sequence public.%I from public, anon, authenticated', sequencia.relname);
  end loop;
end $$;

notify pgrst, 'reload schema';

-- ===== 20261103001600_dados_iniciais.sql =====
-- Dados iniciais da operação: unidades, centros de custo, veículos da planilha
-- fornecida e cadastros mínimos do fluxo de NF. Pode ser reaplicado sem duplicar.

insert into public.operacoes (nome) values ('Patos'), ('Sumé')
on conflict (nome) do nothing;

-- Unidades de Negócio (centros de custo) usadas pelas telas de alocação.
insert into public.frota_centros_custo (codigo, nome) values
  ('101', 'Puxada'),
  ('201', 'Entrega'),
  ('301', 'Armazém'),
  ('401', 'Vendas'),
  ('501', 'Administrativo')
on conflict (codigo) do nothing;

insert into public.veiculos (placa, operacao_id, centro_custo)
select p.placa, o.id, p.centro_custo
from (values
  ('TOT4F49', 'Patos', '201'),
  ('TOT4F19', 'Patos', '201'),
  ('TOT4F59', 'Patos', '201'),
  ('TOU7F79', 'Patos', '201'),
  ('RLS8A29', 'Sumé', '201'),
  ('RLR8F59', 'Patos', '201'),
  ('RLR8F99', 'Patos', '201'),
  ('RLR8D79', 'Patos', '201'),
  ('RLU6A66', 'Patos', '201'),
  ('RLX6B97', 'Patos', '201'),
  ('RLU6B06', 'Patos', '201'),
  ('RLU6A96', 'Patos', '201'),
  ('RLX7E88', 'Patos', '201'),
  ('RLU6A86', 'Patos', '201'),
  ('SKZ7H28', 'Patos', '201'),
  ('SKZ7H38', 'Sumé', '201'),
  ('SKZ8I17', 'Sumé', '201'),
  ('SKZ8I57', 'Sumé', '201'),
  ('SLB3G16', 'Patos', '201'),
  ('SLB3J86', 'Patos', '201'),
  ('OGE4260', 'Patos', '101'),
  ('OFG6240', 'Patos', '101'),
  ('QSA7H32', 'Patos', '101'),
  ('QFS4H61', 'Patos', '101'),
  ('QFS4H71', 'Sumé', '101'),
  ('QFS3I31', 'Patos', '101'),
  ('QFS3H81', 'Sumé', '101'),
  ('RLR0B95', 'Patos', '101'),
  ('QFT5743', 'Patos', '101'),
  ('SKY5B20', 'Patos', '101'),
  ('EMP0002', 'Sumé', '301'),
  ('EMP0003', 'Patos', '301'),
  ('EMP0004', 'Patos', '301'),
  ('EMP0005', 'Sumé', '301'),
  ('EMP0006', 'Patos', '301')
) as p(placa, unidade, centro_custo)
join public.operacoes o on o.nome = p.unidade
on conflict (placa) do nothing;

insert into public.frota_gestao_locais (operacao_id, nome)
select id, 'Almoxarifado' from public.operacoes
on conflict (operacao_id, nome) do nothing;

-- Uma categoria por coluna do relatório HBF.
insert into public.frota_gestao_categorias (codigo, nome, coluna_hbf) values
  ('SER', 'Serviços', 'servicos'),
  ('PEC', 'Peças', 'pecas'),
  ('LAV', 'Lavagem', 'lavagem'),
  ('PNE', 'Pneus', 'pneus'),
  ('OLE', 'Óleo e lubrificantes', 'oleo_lubrificante')
on conflict (codigo) do nothing;

-- Plano de contas do fluxo de NF: mesmas contas cadastradas pelo SQL 98.
insert into public.frota_gestao_contas (codigo, nome)
select dados->>'codigo', dados->>'nome' from public.frota_gestao_cadastros where tipo = 'contas'
on conflict (codigo) do nothing;

commit;
