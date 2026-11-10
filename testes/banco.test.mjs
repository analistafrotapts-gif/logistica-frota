// Aplica todas as migrations num PostgreSQL local (PGlite) que imita o Supabase
// (papéis, auth.uid(), permissões padrão, cabeçalhos do PostgREST, pg_cron) e
// percorre o fluxo real: login, ativação, rascunho, finalização e tentativas
// de contornar as regras.
import { test, before } from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync, readdirSync } from 'node:fs';
import { randomUUID, randomBytes } from 'node:crypto';
import { PGlite } from '@electric-sql/pglite';

const PASTA = new URL('../supabase/migrations/', import.meta.url);
const CHAVE = randomBytes(32).toString('hex');
const ADMIN = randomUUID();
const OPERADOR = randomUUID();
let db;

const AMBIENTE_SUPABASE = `
  create role anon nologin; create role authenticated nologin; create role service_role nologin bypassrls;
  grant usage on schema public to anon, authenticated, service_role;
  alter default privileges for role postgres in schema public grant all on tables to anon, authenticated, service_role;
  alter default privileges for role postgres in schema public grant all on sequences to anon, authenticated, service_role;
  alter default privileges for role postgres in schema public grant all on functions to anon, authenticated, service_role;
  create schema auth; grant usage on schema auth to anon, authenticated, service_role;
  create table auth.users (id uuid primary key, email text, raw_user_meta_data jsonb default '{}');
  create function auth.uid() returns uuid language sql stable as $$
    select nullif(nullif(current_setting('request.jwt.claims', true), '')::jsonb ->> 'sub', '')::uuid $$;
  create schema cron;
  create table cron.job (jobid serial primary key, jobname text, schedule text, command text,
    database text, username text, active boolean default true);
  create function cron.schedule(n text, s text, c text) returns bigint language sql as $$
    insert into cron.job (jobname, schedule, command, database, username)
    values (n, s, c, current_database(), current_user) returning jobid $$;
  create function cron.unschedule(n text) returns boolean language sql as $$
    delete from cron.job where jobname = n returning true $$;
`;

async function comoUsuario(usuario, corpo, { chave = CHAVE } = {}) {
  return db.transaction(async (tx) => {
    await tx.exec('set local role authenticated');
    await tx.query("select set_config('request.jwt.claims', $1, true), set_config('request.headers', $2, true)", [
      JSON.stringify({ sub: usuario, role: 'authenticated' }),
      JSON.stringify(chave ? { 'x-frota-gestao-chave': chave } : {}),
    ]);
    return corpo(tx);
  });
}

async function rpc(usuario, nome, params = {}, opcoes) {
  return comoUsuario(usuario, async (tx) => {
    const nomes = Object.keys(params);
    const sql = `select public.${nome}(${nomes.map((n, i) => `${n}=>$${i + 1}`).join(',')}) as valor`;
    return (await tx.query(sql, Object.values(params))).rows[0].valor;
  }, opcoes);
}

before(async () => {
  db = new PGlite();
  await db.exec(AMBIENTE_SUPABASE);
  for (const arquivo of readdirSync(PASTA).filter((a) => a.endsWith('.sql') && a < '20261110').sort()) {
    // pg_cron não existe no PGlite; o schema cron acima faz o papel dele.
    const sql = readFileSync(new URL(arquivo, PASTA), 'utf8').replace('create extension if not exists pg_cron;', '');
    try {
      await db.transaction((tx) => tx.exec(sql));
    } catch (erro) {
      throw new Error(`Falha em ${arquivo}: ${erro.message}`);
    }
  }
  await db.query("insert into auth.users (id, email, raw_user_meta_data) values ($1, 'admin@empresa.com', '{\"nome\":\"Admin\"}'), ($2, 'operador@empresa.com', '{}')", [ADMIN, OPERADOR]);
});

test('migrations instalam o contrato completo e os dados iniciais', async () => {
  assert.equal((await db.query('select public.frota_gestao_contrato_completo() ok')).rows[0].ok, true);
  assert.equal((await db.query('select count(*)::int n from public.veiculos')).rows[0].n, 35);
  assert.equal((await db.query('select count(*)::int n from public.operacoes')).rows[0].n, 2);
  assert.equal((await db.query("select count(*)::int n from public.frota_gestao_cadastros where tipo = 'contas'")).rows[0].n > 0, true);
  const job = (await db.query("select * from cron.job where jobname = 'frota_gestao_expirar_rascunhos'")).rows;
  assert.equal(job.length, 1);
});

test('usuário novo nasce desativado, com senha provisória, e só entra após liberação e troca de senha', async () => {
  const perfil = (await db.query('select nome, ativo, senha_provisoria from public.perfis where id = $1', [ADMIN])).rows[0];
  assert.deepEqual(perfil, { nome: 'Admin', ativo: false, senha_provisoria: true });
  assert.equal((await db.query('select nome from public.perfis where id = $1', [OPERADOR])).rows[0].nome, 'operador');
  for (const u of [ADMIN, OPERADOR]) await comoUsuario(u, (tx) => tx.query('select public.perfil_confirmar_senha_definitiva()'));
  await assert.rejects(rpc(OPERADOR, 'frota_gestao_listar_cadastros'), /Conta ativa/, 'troca de senha sozinha não libera');
  await db.query('update public.perfis set ativo = true where id = any($1)', [[ADMIN, OPERADOR]]);
  const consulta = await rpc(OPERADOR, 'frota_gestao_listar_cadastros');
  assert.equal(consulta.contrato, 'cadastros-01');
  assert.equal(consulta.veiculos.length, 35);
});

test('anônimo não lê nada e logado não grava direto nas tabelas', async () => {
  await assert.rejects(db.transaction(async (tx) => {
    await tx.exec('set local role anon');
    await tx.query('select * from public.veiculos');
  }), /permission denied/);
  const tabelas = (await db.query(`select c.relname from pg_class c join pg_namespace n on n.oid = c.relnamespace
    where n.nspname = 'public' and c.relkind in ('r','v','m','p')`)).rows.map((r) => r.relname);
  assert.ok(tabelas.length > 30);
  const graváveis = (await db.query(`select table_name, privilege_type from information_schema.role_table_grants
    where table_schema = 'public' and grantee in ('anon', 'authenticated', 'PUBLIC') and privilege_type <> 'SELECT'`)).rows;
  assert.deepEqual(graváveis, []);
  await assert.rejects(comoUsuario(OPERADOR, (tx) => tx.query("insert into public.frota_gestao_notas (id) values (gen_random_uuid())")), /permission denied/);
  await assert.rejects(comoUsuario(OPERADOR, (tx) => tx.query("update public.veiculos set placa = 'XXX0000'")), /permission denied/);
});

test('antes da ativação o módulo fica somente leitura', async () => {
  await assert.rejects(rpc(OPERADOR, 'frota_gestao_salvar_rascunho', { p_id: randomUUID(), p_dados: { formato: 1 } }), /somente leitura/);
});

test('ativação exige a chave de servidor correta', async () => {
  const ativar = readFileSync(new URL('../scripts/ativar-escritas.sql', import.meta.url), 'utf8')
    .replace('COLE_AQUI_A_CHAVE', CHAVE).replace('COLE_AQUI_A_EVIDENCIA', 'teste automatizado');
  await db.exec(ativar);
  assert.equal((await rpc(OPERADOR, 'frota_gestao_estado_ativacao')).liberado, true);
  await assert.rejects(rpc(OPERADOR, 'frota_gestao_salvar_rascunho', { p_id: randomUUID(), p_dados: { formato: 1 } }, { chave: null }), /Chave de servidor/);
  await assert.rejects(rpc(OPERADOR, 'frota_gestao_salvar_rascunho', { p_id: randomUUID(), p_dados: { formato: 1 } }, { chave: 'f'.repeat(64) }), /Chave de servidor/);
});

test('fluxo completo: cadastro de fornecedor, rascunho e finalização de NF de serviço', async () => {
  const hoje = (await db.query('select current_date::text d')).rows[0].d;
  const veiculo = (await db.query("select v.id, v.placa, v.operacao_id from public.veiculos v where placa = 'TOT4F49'")).rows[0];
  const ids = { fornecedor: randomUUID(), servico: randomUUID() };
  // Cadastros mestres que o admin mantém pelo SQL Editor (ver scripts/cadastros-mestres.sql).
  await db.transaction(async (tx) => {
    await tx.query("select set_config('request.jwt.claims', $1, true)", [JSON.stringify({ sub: ADMIN })]);
    await tx.query('insert into public.frota_fornecedores (id) values ($1)', [ids.fornecedor]);
    await tx.query("insert into public.frota_gestao_fornecedores (fornecedor_id, documento, razao_social) values ($1, '00000000000191', 'Oficina Exemplo')", [ids.fornecedor]);
    await tx.query("insert into public.frota_gestao_catalogo (id, codigo, descricao, natureza, unidade_padrao) values ($1, 'S-001', 'Mão de obra mecânica', 'servico', 'SRV')", [ids.servico]);
  });
  const conta = (await db.query("select id from public.frota_gestao_contas where codigo = '4120506'")).rows[0].id;
  const categoria = (await db.query("select id from public.frota_gestao_categorias where coluna_hbf = 'servicos'")).rows[0].id;

  const rascunho = randomUUID();
  const dados = {
    formato: 1, etapa: 3, unidadeFiscal: veiculo.operacao_id, referencia: '', destinos: {}, conferido: true,
    nota: {
      numero: '1001', serie: '1', chave: '', emissao: hoje, documento_fornecedor: '00000000000191', fornecedor: 'Oficina Exemplo',
      documento_destinatario: '', total: '100.00', informacoes: '', dados_fiscais: null, avisos: [],
      itens: [{ numero: '1', codigo: 'S-001', descricao: 'Mão de obra mecânica', unidade: 'SRV', quantidade: '1', unitario: '100.00', bruto: '100.00', desconto: '0.00', acrescimo: '0.00' }],
    },
    finalizacao: {
      fornecedor_id: ids.fornecedor, emissao: hoje,
      veiculos: { [veiculo.id]: { contexto: 'teste-1001', inicio: hoje, fim: hoje, medidor: 'km' } },
      itens: { 1: { catalogo_id: ids.servico, fator: '1', local_id: '', manutencao: 'corretiva', rateios: [{
        destino: 'veiculo', veiculo_id: veiculo.id, placa: veiculo.placa, unidade_id: veiculo.operacao_id, centro_custo: '201',
        conta_id: conta, categoria_id: categoria, quantidade: '1', valor: '100.00', os_item_id: '', executado_em: hoje,
      }] } },
    },
  };
  await rpc(OPERADOR, 'frota_gestao_salvar_rascunho', { p_id: rascunho, p_dados: dados });
  const recibo = await rpc(OPERADOR, 'frota_gestao_finalizar_nf', { p_id: rascunho, p_revisao: 1, p_chave: randomUUID(), p_confirmado: true });
  assert.ok(recibo, 'finalização devolveu recibo');
  const custos = (await db.query("select origem, valor::text from public.frota_gestao_custos")).rows;
  assert.deepEqual(custos, [{ origem: 'servico', valor: '100.00' }]);
  const auditoria = (await db.query("select count(*)::int n from public.frota_gestao_auditoria where autor_id = $1", [OPERADOR])).rows[0].n;
  assert.ok(auditoria > 0, 'operações ficam auditadas com o autor');
  // A leitura pela API (como faz a tela) enxerga a nota finalizada.
  const notas = await comoUsuario(OPERADOR, (tx) => tx.query('select numero from public.frota_gestao_notas'));
  assert.deepEqual(notas.rows, [{ numero: '1001' }]);
});

test('atualiza banco existente sem perder NF; edição, exclusão com aplicação e relançamento', async () => {
  const veiculos=(await db.query('select id,placa,operacao_id from veiculos order by placa limit 2')).rows;
  const unidade=(await db.query("select id from operacoes where nome='Sumé'")).rows[0].id;
  const nota={numero:'99110',serie:'1',chave:'',emissao:'2026-11-10',fornecedor:'FORNECEDOR SINTETICO ATUALIZACAO',documento_fornecedor:'00000000000191',documento_destinatario:'',total:'100.00',informacoes:'',avisos:[],itens:[{numero:'1',codigo:'TESTE',descricao:'PECA SINTETICA ATUALIZACAO',unidade:'UN',quantidade:'2',unitario:'50.00',bruto:'100.00',desconto:'0.00',acrescimo:'0.00'}]};
  const rateio={destino:'veiculo',veiculo_id:veiculos[0].id,placa:veiculos[0].placa,unidade_id:veiculos[0].operacao_id,centro_custo:'201',conta_id:'',categoria_id:'',quantidade:'1',valor:'50.00',os_item_id:'',executado_em:'',classificacao:'Elétrico'};
  const linhas=[veiculos[0].placa,'Estoque'].map((veiculo,i)=>({id:`1:${i}`,veiculo,numero_os:i?'—':'A gerar',numero_nf:nota.numero,centro_custo:i?'Estoque':'Entrega 201',conta_codigo:'4120503',conta:'4120503 · Peças preventiva',categoria_hbf:'pecas',pecas_servicos:nota.itens[0].descricao,servicos:'0.00',pecas:'50.00',lavagem:'0.00',pneus:'0.00',oleo_lubrificante:'0.00',desconto:'0.00',valor_total:'50.00',valor_alocado:'50.00',quantidade:'1',unidade:'UN',manutencao:'preventiva',classificacao:'Elétrico'}));
  nota.dados_fiscais={conferencia_hbf:{formato:1,assinatura:'fixture isolada',linhas}};
  const dados={formato:1,nota,etapa:4,unidadeFiscal:veiculos[0].operacao_id,referencia:'',destinos:{},conferido:true,finalizacao:{fornecedor_id:'',emissao:'',veiculos:{},itens:{'1':{catalogo_id:'',fator:'1',local_id:'',manutencao:'preventiva',rateios:[rateio,{...rateio,destino:'estoque',veiculo_id:'',placa:'',centro_custo:'estoque'}]}}}};
  const recibo=await rpc(OPERADOR,'frota_gestao_finalizar_envio',{p_dados:dados,p_chave:randomUUID(),p_confirmado:true});
  const original=(await db.query('select * from frota_gestao_lancamentos where id=$1',[recibo.nota_id])).rows;
  const legadas=(await db.query('select * from frota_gestao_notas order by id')).rows;
  const cadastro=(await db.query('select * from veiculos order by id')).rows;
  for(const nome of readdirSync(PASTA).filter(n=>n.startsWith('20261110')).sort())await db.transaction(tx=>tx.exec(readFileSync(new URL(nome,PASTA),'utf8')));
  await db.exec('begin read only');
  await db.exec(readFileSync(new URL('../supabase/verificacoes/atualizacao-20261110.sql',import.meta.url),'utf8'));
  await db.exec('rollback');
  assert.deepEqual((await db.query('select * from frota_gestao_lancamentos where id=$1',[recibo.nota_id])).rows,original);
  assert.deepEqual((await db.query('select * from frota_gestao_notas order by id')).rows,legadas);
  assert.deepEqual((await db.query('select * from veiculos order by id')).rows,cadastro);
  const editada=structuredClone(dados);editada.unidadeFiscal=unidade;editada.nota.dados_fiscais.conferencia_hbf.linhas[0].veiculo=veiculos[1].placa;
  Object.assign(editada.finalizacao.itens['1'].rateios[0],{veiculo_id:veiculos[1].id,placa:veiculos[1].placa,unidade_id:veiculos[1].operacao_id});
  const chave=randomUUID(),params={p_id:recibo.nota_id,p_base:recibo.versao_id,p_chave:chave,p_dados:editada,p_motivo:'Corrigir placa e unidade fiscal',p_confirmado:true};
  const revisao=await rpc(OPERADOR,'frota_gestao_confirmar_edicao_simplificada',params);assert.equal(revisao.numero_versao,2);assert.deepEqual(await rpc(OPERADOR,'frota_gestao_confirmar_edicao_simplificada',params),revisao);
  const consulta=await rpc(OPERADOR,'frota_gestao_carregar_edicao_simplificada',{p_id:recibo.nota_id});assert.equal(consulta.historico.length,2);assert.equal(consulta.registro.unidade_fiscal_id,unidade);
  const central=await rpc(OPERADOR,'frota_gestao_listar_simplificado');assert.equal(central.filter(n=>n.id===recibo.nota_id).length,1);
  const painel=await rpc(OPERADOR,'frota_gestao_dashboard_simplificado');assert.deepEqual(painel.custos.filter(n=>n.lancamento_id===recibo.nota_id).map(n=>[n.placa,n.valor]),[[veiculos[1].placa,'50.00']]);
  const lote=(await rpc(OPERADOR,'frota_gestao_estoque_simplificado')).lotes.find(l=>l.lancamento_id===recibo.nota_id);
  await rpc(OPERADOR,'frota_gestao_aplicar_simplificado',{p_chave:randomUUID(),p_confirmado:true,p_dados:{lote_id:lote.id,veiculo_id:veiculos[1].id,centro_custo:'301',quantidade:'1',manutencao:'corretiva'}});
  await assert.rejects(rpc(OPERADOR,'frota_gestao_apagar_simplificado',{p_id:recibo.nota_id,p_base:revisao.versao_id,p_chave:randomUUID(),p_motivo:'Teste sem chave de servidor',p_confirmado:true},{chave:null}),/Chave de servidor/);
  await rpc(OPERADOR,'frota_gestao_apagar_simplificado',{p_id:recibo.nota_id,p_base:revisao.versao_id,p_chave:randomUUID(),p_motivo:'Aplicação incorreta; relançar corrigida',p_confirmado:true});
  const apagada=await rpc(OPERADOR,'frota_gestao_dashboard_simplificado');for(const campo of ['custos','compras','estoque'])assert.ok(!apagada[campo].some(n=>n.lancamento_id===recibo.nota_id));
  assert.deepEqual((await db.query('select * from frota_gestao_lancamentos where id=$1',[recibo.nota_id])).rows,original);
  const nova=await rpc(OPERADOR,'frota_gestao_finalizar_envio',{p_dados:dados,p_chave:randomUUID(),p_confirmado:true});assert.notEqual(nova.nota_id,recibo.nota_id);
  await db.exec(readFileSync(new URL('20261110001800_frota_100_exclusao_simplificada.sql',PASTA),'utf8'));
});

test('perfil desativado perde o acesso', async () => {
  await db.query('update public.perfis set ativo = false where id = $1', [OPERADOR]);
  await assert.rejects(rpc(OPERADOR, 'frota_gestao_listar_cadastros'), /Conta ativa/);
  const notas = await comoUsuario(OPERADOR, (tx) => tx.query('select * from public.frota_gestao_notas'));
  assert.equal(notas.rows.length, 0);
  await db.query('update public.perfis set ativo = true where id = $1', [OPERADOR]);
});

test('instalacao-completa.sql está em dia com as migrations', async () => {
  const { juntar } = await import('../ferramentas/juntar-migrations.mjs');
  const arquivo = readFileSync(new URL('../supabase/instalacao-completa.sql', import.meta.url), 'utf8');
  assert.equal(arquivo, juntar(), 'rode: node ferramentas/juntar-migrations.mjs');
});

test('instalacao-completa.sql instala sozinho num banco vazio', async () => {
  const limpo = new PGlite();
  await limpo.exec(AMBIENTE_SUPABASE);
  const sql = readFileSync(new URL('../supabase/instalacao-completa.sql', import.meta.url), 'utf8').replace('create extension if not exists pg_cron;', '');
  await limpo.exec(sql);
  assert.equal((await limpo.query('select public.frota_gestao_contrato_completo() ok')).rows[0].ok, true);
  assert.equal((await limpo.query('select count(*)::int n from public.veiculos')).rows[0].n, 35);
  await limpo.close();
});
