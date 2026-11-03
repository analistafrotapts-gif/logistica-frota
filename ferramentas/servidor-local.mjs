// Ambiente local de desenvolvimento: npm run local  →  http://localhost:3000
//
// Imita o Supabase em cima de um PostgreSQL local (PGlite) com as mesmas
// migrations, papéis e RLS, e serve o painel com a função api/rpc.js real.
// Dados persistidos em .dados/banco. Usuários locais (senha: senha-local-123):
//   admin@local.test  (senha definitiva)   operador@local.test (senha provisória)
// Cobre apenas o que o painel usa do Supabase; não é um substituto completo.
import { createServer } from 'node:http';
import { readFileSync, readdirSync, existsSync, mkdirSync } from 'node:fs';
import { fileURLToPath } from 'node:url';
import { extname, join, normalize } from 'node:path';
import { randomUUID, randomBytes } from 'node:crypto';
import { PGlite } from '@electric-sql/pglite';

const PORTA = Number(process.env.PORT ?? 3000);
const BASE = `http://localhost:${PORTA}`;
const SENHA = 'senha-local-123';
const CHAVE = randomBytes(32).toString('hex');
const PUBLICO = fileURLToPath(new URL('../public/', import.meta.url));
const MIGRATIONS = new URL('../supabase/migrations/', import.meta.url);

process.env.SUPABASE_URL = BASE;
process.env.SUPABASE_ANON_KEY = 'chave-anon-local';
process.env.FROTA_GESTAO_CHAVE = CHAVE;
const { default: rpcHandler } = await import('../api/rpc.js');

const DADOS = fileURLToPath(new URL('../.dados/banco/', import.meta.url));
mkdirSync(DADOS, { recursive: true });
const db = new PGlite(DADOS);
process.on('SIGINT', async () => { await db.close(); process.exit(0); });
process.on('SIGTERM', async () => { await db.close(); process.exit(0); });
const instalado = (await db.query("select to_regclass('public.perfis') is not null as pronto")).rows[0].pronto;
if (!instalado) {
await db.exec(`
  create role anon nologin; create role authenticated nologin; create role service_role nologin bypassrls;
  grant usage on schema public to anon, authenticated, service_role;
  alter default privileges for role postgres in schema public grant all on tables to anon, authenticated, service_role;
  alter default privileges for role postgres in schema public grant all on sequences to anon, authenticated, service_role;
  alter default privileges for role postgres in schema public grant all on functions to anon, authenticated, service_role;
  create schema auth; grant usage on schema auth to anon, authenticated, service_role;
  create table auth.users (id uuid primary key, email text unique, senha text, raw_user_meta_data jsonb default '{}');
  create function auth.uid() returns uuid language sql stable as $$
    select nullif(nullif(current_setting('request.jwt.claims', true), '')::jsonb ->> 'sub', '')::uuid $$;
  create schema cron;
  create table cron.job (jobid serial primary key, jobname text, schedule text, command text, database text, username text, active boolean default true);
  create function cron.schedule(n text, s text, c text) returns bigint language sql as $$
    insert into cron.job (jobname, schedule, command, database, username) values (n, s, c, current_database(), current_user) returning jobid $$;
  create function cron.unschedule(n text) returns boolean language sql as $$ delete from cron.job where jobname = n returning true $$;
`);
for (const arquivo of readdirSync(MIGRATIONS).filter((a) => a.endsWith('.sql')).sort()) {
  await db.transaction((tx) => tx.exec(readFileSync(new URL(arquivo, MIGRATIONS), 'utf8').replace('create extension if not exists pg_cron;', '')));
}
}
const ADMIN = instalado
  ? (await db.query("select id from auth.users where email = 'admin@local.test'")).rows[0].id
  : randomUUID();
if (!instalado) {
await db.query(`insert into auth.users (id, email, senha, raw_user_meta_data) values
  ($1, 'admin@local.test', $3, '{"nome":"Administrador local"}'), ($2, 'operador@local.test', $3, '{"nome":"Operador local"}')`, [ADMIN, randomUUID(), SENHA]);
await db.query('update public.perfis set ativo = true, senha_provisoria = (id <> $1)', [ADMIN]);
await db.transaction(async (tx) => {
  await tx.query("select set_config('request.jwt.claims', $1, true)", [JSON.stringify({ sub: ADMIN })]);
  const fornecedor = randomUUID();
  await tx.query('insert into public.frota_fornecedores (id) values ($1)', [fornecedor]);
  await tx.query("insert into public.frota_gestao_fornecedores (fornecedor_id, documento, razao_social) values ($1, '00000000000191', 'Oficina Exemplo (local)')", [fornecedor]);
  await tx.query(`insert into public.frota_gestao_catalogo (codigo, descricao, natureza, unidade_padrao) values
    ('S-001', 'Mão de obra mecânica', 'servico', 'SRV'), ('P-001', 'Filtro de óleo', 'peca', 'UN')`);
});
}
await db.exec(readFileSync(new URL('../scripts/ativar-escritas.sql', import.meta.url), 'utf8')
  .replace('COLE_AQUI_A_CHAVE', CHAVE).replace('COLE_AQUI_A_EVIDENCIA', 'ambiente local'));

// --- Auth (subconjunto do GoTrue) -------------------------------------------
const b64 = (o) => Buffer.from(JSON.stringify(o)).toString('base64url');
function token(usuario) {
  const exp = Math.floor(Date.now() / 1000) + 3600;
  return `${b64({ alg: 'none', typ: 'JWT' })}.${b64({ sub: usuario.id, email: usuario.email, role: 'authenticated', exp })}.local`;
}
function claims(req) {
  const t = req.headers.authorization?.replace(/^Bearer /, '');
  try { return JSON.parse(Buffer.from(t.split('.')[1], 'base64url')); } catch { return null; }
}
const usuarioPublico = (u) => ({ id: u.id, aud: 'authenticated', role: 'authenticated', email: u.email, user_metadata: u.raw_user_meta_data, app_metadata: {}, created_at: new Date().toISOString() });
function sessao(u) {
  return { access_token: token(u), token_type: 'bearer', expires_in: 3600, expires_at: Math.floor(Date.now() / 1000) + 3600, refresh_token: `r-${u.id}`, user: usuarioPublico(u) };
}
const buscarUsuario = async (id) => (await db.query('select * from auth.users where id = $1', [id])).rows[0];

// --- Execução como o PostgREST faz: papel authenticated + claims + headers ---
async function comoUsuario(req, corpo) {
  const c = claims(req);
  return db.transaction(async (tx) => {
    await tx.exec(`set local role ${c ? 'authenticated' : 'anon'}`);
    await tx.query("select set_config('request.jwt.claims', $1, true), set_config('request.headers', $2, true)", [JSON.stringify(c ?? {}), JSON.stringify(req.headers)]);
    return corpo(tx);
  });
}
const IDENT = /^[a-z_][a-z0-9_]*$/;
function lista(sel) {
  if (sel === '*') return '*';
  const colunas = sel.split(',');
  if (!colunas.every((c) => IDENT.test(c))) throw new Error('select inválido');
  return colunas.map((c) => `"${c}"`).join(',');
}
async function restTabela(req, tabela, url) {
  if (!IDENT.test(tabela)) throw new Error('tabela inválida');
  const p = url.searchParams;
  const filtros = [];
  const valores = [];
  for (const [chave, valor] of p) {
    if (['select', 'order', 'limit', 'offset'].includes(chave)) continue;
    if (!IDENT.test(chave)) throw new Error('filtro inválido');
    if (valor.startsWith('eq.')) { valores.push(valor.slice(3)); filtros.push(`"${chave}"::text = $${valores.length}`); }
    else if (valor.startsWith('in.(')) { valores.push(valor.slice(4, -1).split(',').map((v) => v.replace(/^"|"$/g, ''))); filtros.push(`"${chave}"::text = any($${valores.length}::text[])`); }
    else throw new Error(`filtro não suportado: ${valor}`);
  }
  let sql = `select ${lista(p.get('select') ?? '*')} from public."${tabela}"`;
  if (filtros.length) sql += ` where ${filtros.join(' and ')}`;
  if (p.get('order')) {
    const [col, dir] = p.get('order').split('.');
    if (!IDENT.test(col)) throw new Error('ordem inválida');
    sql += ` order by "${col}" ${dir === 'desc' ? 'desc' : 'asc'}`;
  }
  if (p.get('limit')) sql += ` limit ${Number(p.get('limit'))}`;
  if (p.get('offset')) sql += ` offset ${Number(p.get('offset'))}`;
  return comoUsuario(req, async (tx) => (await tx.query(sql, valores)).rows);
}
async function restRpc(req, nome, params) {
  if (!IDENT.test(nome)) throw new Error('rotina inválida');
  const nomes = Object.keys(params);
  if (!nomes.every((n) => IDENT.test(n))) throw new Error('parâmetro inválido');
  return comoUsuario(req, async (tx) => {
    const r = await tx.query(`select public."${nome}"(${nomes.map((n, i) => `${n}=>$${i + 1}`).join(',')}) as valor`, Object.values(params));
    return r.rows[0]?.valor ?? null;
  });
}

// --- Servidor ----------------------------------------------------------------
const TIPOS = { '.html': 'text/html; charset=utf-8', '.js': 'text/javascript; charset=utf-8', '.css': 'text/css; charset=utf-8' };
async function lerCorpo(req) {
  const partes = [];
  for await (const p of req) partes.push(p);
  const texto = Buffer.concat(partes).toString('utf8');
  return texto ? JSON.parse(texto) : {};
}
function json(res, status, corpo) {
  res.writeHead(status, { 'Content-Type': 'application/json' });
  res.end(corpo === undefined ? '' : JSON.stringify(corpo));
}

createServer(async (req, res) => {
  const url = new URL(req.url, BASE);
  try {
    if (url.pathname === '/config.js') {
      res.writeHead(200, { 'Content-Type': TIPOS['.js'] });
      return res.end(`window.__config=${JSON.stringify({ url: BASE, chave: process.env.SUPABASE_ANON_KEY })};`);
    }
    if (url.pathname === '/api/rpc') {
      const corpo = await lerCorpo(req);
      const vres = { statusCode: 200, setHeader: (k, v) => res.setHeader(k, v), status(c) { this.statusCode = c; return this; }, json(c) { json(res, this.statusCode, c); } };
      return rpcHandler({ method: req.method, headers: req.headers, body: corpo }, vres);
    }
    if (url.pathname === '/auth/v1/token') {
      const corpo = await lerCorpo(req);
      if (url.searchParams.get('grant_type') === 'refresh_token') {
        const u = await buscarUsuario(String(corpo.refresh_token).slice(2));
        return u ? json(res, 200, sessao(u)) : json(res, 400, { error: 'invalid_grant', error_description: 'Invalid Refresh Token' });
      }
      const u = (await db.query('select * from auth.users where email = $1 and senha = $2', [corpo.email, corpo.password])).rows[0];
      return u ? json(res, 200, sessao(u)) : json(res, 400, { error: 'invalid_grant', error_description: 'Invalid login credentials', msg: 'Invalid login credentials', code: 'invalid_credentials' });
    }
    if (url.pathname === '/auth/v1/user') {
      const u = claims(req) && await buscarUsuario(claims(req).sub);
      if (!u) return json(res, 401, { msg: 'invalid JWT' });
      if (req.method === 'PUT') {
        const corpo = await lerCorpo(req);
        if (corpo.password) await db.query('update auth.users set senha = $1 where id = $2', [corpo.password, u.id]);
      }
      return json(res, 200, usuarioPublico(u));
    }
    if (url.pathname === '/auth/v1/logout') return json(res, 204);
    if (url.pathname === '/auth/v1/recover') return json(res, 200, {});
    if (url.pathname.startsWith('/rest/v1/rpc/')) {
      try { return json(res, 200, await restRpc(req, url.pathname.slice(13), await lerCorpo(req))); }
      catch (e) { return json(res, 400, { code: e.code, message: e.message }); }
    }
    if (url.pathname.startsWith('/rest/v1/')) {
      try { return json(res, 200, await restTabela(req, url.pathname.slice(9), url)); }
      catch (e) { return json(res, 400, { code: e.code, message: e.message }); }
    }
    const caminho = normalize(join(PUBLICO, url.pathname === '/' ? 'index.html' : decodeURIComponent(url.pathname)));
    if (!caminho.startsWith(PUBLICO) || !existsSync(caminho)) return json(res, 404, { message: 'não encontrado' });
    res.writeHead(200, { 'Content-Type': TIPOS[extname(caminho)] ?? 'application/octet-stream' });
    res.end(readFileSync(caminho));
  } catch (erro) {
    json(res, 500, { message: erro.message });
  }
}).listen(PORTA, '127.0.0.1', () => {
  console.log(`Painel local em ${BASE}`);
  console.log(`Entrar: admin@local.test / ${SENHA}  (ou operador@local.test para testar o primeiro acesso)`);
});
