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
