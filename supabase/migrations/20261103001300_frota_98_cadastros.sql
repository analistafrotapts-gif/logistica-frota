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
