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

