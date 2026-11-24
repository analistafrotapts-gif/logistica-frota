-- MANUAL após 109 e seus predecessores. Preparação local, sem liberação de escrita.
-- Mantém cadastros e lançamentos originais; a sugestão só vale na ausência de marcação explícita.
begin;
set local lock_timeout='5s';
set local statement_timeout='60s';
do $instalar$ declare fonte text;antes text;depois text;begin
 if not exists(select 1 from pg_attribute where attrelid='public.frota_gestao_veiculos'::regclass and attname='inspecao_preventiva' and not attisdropped) then raise exception 'Instale e verifique SQL 109 antes de 110.';end if;
 if not exists(select 1 from pg_attribute where attrelid='public.frota_gestao_veiculos'::regclass and attname='servicos_eletricos' and not attisdropped) then
  fonte:=rtrim(pg_get_viewdef('public.frota_gestao_veiculos'::regclass,true),E';\n ');
  execute 'create or replace view public.frota_gestao_veiculos with (security_barrier=true) as select base.*,
   base.centro_custo=''201'' and exists(select 1 from public.operacoes o where o.id=base.operacao_id and o.ativa and lower(o.nome) ~ ''^patos($|[^a-z])'')
   and coalesce((select c.dados->>''servicos_eletricos'' from public.frota_gestao_cadastros c where c.id=base.id and c.tipo=''veiculos''),
     (base.placa not in (''QSA5A52'',''QSA5A62''))::text)=''true'' servicos_eletricos
   from ('||fonte||') base';
 end if;
 fonte:=replace(pg_get_functiondef('public.frota_gestao_salvar_cadastro(uuid,text,uuid,jsonb)'::regprocedure),chr(13),'');
 if position('servicos-eletricos-01' in fonte)=0 then
  antes:=$a$p_dados:=p_dados||jsonb_build_object('inspecao_preventiva',$a$;
  depois:=$b$-- servicos-eletricos-01: desmarcação explícita não volta ao padrão após reaplicação.
  if p_dados ? 'servicos_eletricos' and (p_dados->>'servicos_eletricos' is null or p_dados->>'servicos_eletricos' not in ('true','false')) then raise exception 'Confira a participacao nos Servicos Eletricos.';end if;
  if p_dados->>'centro_custo'='201' and exists(select 1 from public.operacoes o where o.id=(p_dados->>'unidade_id')::uuid and o.ativa and lower(o.nome) ~ '^patos($|[^a-z])') then
   p_dados:=p_dados||jsonb_build_object('servicos_eletricos',coalesce(p_dados->>'servicos_eletricos',(select dados->>'servicos_eletricos' from public.frota_gestao_cadastros where id=p_id),(chave_cadastro not in ('QSA5A52','QSA5A62'))::text));
  else
   if p_dados->>'servicos_eletricos'='true' then raise exception 'Servicos Eletricos: selecione Entrega 201 e a unidade Patos.';end if;
   p_dados:=p_dados||jsonb_build_object('servicos_eletricos','false');
  end if;
  p_dados:=p_dados||jsonb_build_object('inspecao_preventiva',$b$;
  if position(antes in fonte)=0 then raise exception 'Normalizacao 109 divergente.';end if;
  fonte:=replace(fonte,antes,depois);
  antes:=$a$p_dados:=jsonb_build_object('inspecao_preventiva',p_dados->>'inspecao_preventiva',$a$;
  depois:=$b$p_dados:=jsonb_build_object('servicos_eletricos',p_dados->>'servicos_eletricos','inspecao_preventiva',p_dados->>'inspecao_preventiva',$b$;
  if position(antes in fonte)=0 then raise exception 'Persistencia 109 divergente.';end if;
  fonte:=replace(fonte,antes,depois);
  fonte:=replace(fonte,'''inspecao preventiva'')','''inspecao preventiva'',''serviços elétricos'',''servicos eletricos'')');
  execute fonte;
 end if;
 fonte:=pg_get_functiondef('public.frota_gestao_listar_cadastros()'::regprocedure);
 if position('''servicos_eletricos''' in fonte)=0 then
  antes:='''contrato'',''cadastros-01''';
  if position(antes in fonte)=0 then raise exception 'Contrato de cadastros divergente.';end if;
  execute replace(fonte,antes,antes||',''servicos_eletricos'',true');
 end if;
 fonte:=pg_get_functiondef('public.frota_gestao_validar_destinos_coletivos(jsonb)'::regprocedure);
 if position('''servicos_eletricos''' in fonte)=0 then
  antes:=$a$x->>'destino_id'='inspecao_preventiva'$a$;
  if position(antes in fonte)=0 then raise exception 'Guarda de grupo 109 divergente.';end if;
  fonte:=replace(fonte,antes,$b$x->>'destino_id' in ('inspecao_preventiva','servicos_eletricos')$b$);
  antes:=$a$if grupo not in ('milimetragem','inspecao_preventiva') then$a$;
  depois:=$b$if grupo='servicos_eletricos' and not exists(select 1 from public.operacoes where id=(cfg->>'destino_unidade')::uuid and ativa and lower(nome) ~ '^patos($|[^a-z])') then raise exception 'Servicos Eletricos exige a unidade Patos.';end if;
  if grupo not in ('milimetragem','inspecao_preventiva','servicos_eletricos') then$b$;
  if position(antes in fonte)=0 then raise exception 'Validador de destinos 109 divergente.';end if;
  fonte:=replace(fonte,antes,depois);
  antes:=$a$else (cad->>'veiculos')::jsonb ? x.id::text end$a$;
  depois:=$b$when grupo='servicos_eletricos' then x.servicos_eletricos and x.centro_custo='201' and x.operacao_id=(cfg->>'destino_unidade')::uuid else (cad->>'veiculos')::jsonb ? x.id::text end$b$;
  if position(antes in fonte)=0 then raise exception 'Participantes 109 divergentes.';end if;
  fonte:=replace(fonte,antes,depois);
  antes:=$a$if grupo='inspecao_preventiva' and (r->>'unidade_id'$a$;
  if position(antes in fonte)=0 then raise exception 'Guarda de unidade 109 divergente.';end if;
  fonte:=replace(fonte,antes,$b$if grupo in ('inspecao_preventiva','servicos_eletricos') and (r->>'unidade_id'$b$);
  fonte:=replace(fonte,$a$l->>'destino_nome' is distinct from 'Inspeção Preventiva'$a$,$b$l->>'destino_nome' is distinct from (case when grupo='servicos_eletricos' then 'Serviços Elétricos' else 'Inspeção Preventiva' end)$b$);
  execute fonte;
 end if;
end $instalar$;
do $$ declare assinatura text;fonte text;antes text;begin
 foreach assinatura in array array['public.frota_gestao_validar_simplificado(jsonb,uuid,bigint)','public.frota_gestao_validar_edicao_simplificada(jsonb,uuid,bigint)'] loop
  fonte:=pg_get_functiondef(to_regprocedure(assinatura));
  if position('''servicos_eletricos''' in fonte)=0 then
   antes:='''veiculo'',''milimetragem'',''inspecao_preventiva''';
   if position(antes in fonte)=0 then raise exception 'Validador 109 divergente: %',assinatura;end if;
   execute replace(fonte,antes,antes||',''servicos_eletricos''');
  end if;
 end loop;
end $$;
revoke all on function public.frota_gestao_validar_destinos_coletivos(jsonb),public.frota_gestao_validar_simplificado(jsonb,uuid,bigint),public.frota_gestao_validar_edicao_simplificada(jsonb,uuid,bigint) from public,anon,authenticated;
notify pgrst,'reload schema';
commit;
