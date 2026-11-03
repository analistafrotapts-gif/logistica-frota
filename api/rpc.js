// Ponte entre o navegador e as funções frota_gestao_* do Supabase.
// Repassa o login do usuário (JWT) e acrescenta a chave de servidor, que
// nunca chega ao navegador. Sem ela, o banco recusa qualquer gravação.

const URL_SUPABASE = process.env.SUPABASE_URL || process.env.NEXT_PUBLIC_SUPABASE_URL;
const CHAVE_PUBLICA = process.env.SUPABASE_ANON_KEY || process.env.NEXT_PUBLIC_SUPABASE_ANON_KEY;
const CHAVE_FROTA = process.env.FROTA_GESTAO_CHAVE;

const ROTINA = /^frota_gestao_[a-z_]+$/;
const PARAMETRO = /^p_[a-z_]+$/;

export default async function handler(req, res) {
  if (req.method !== 'POST') {
    res.setHeader('Allow', 'POST');
    return res.status(405).json({ data: null, error: { message: 'Use POST.' } });
  }
  if (!URL_SUPABASE || !CHAVE_PUBLICA) {
    return res.status(500).json({ data: null, error: { message: 'Servidor sem SUPABASE_URL/SUPABASE_ANON_KEY configurados.' } });
  }
  const autorizacao = req.headers.authorization;
  if (!autorizacao?.startsWith('Bearer ')) {
    return res.status(401).json({ data: null, error: { code: '42501', message: 'Sessão expirada. Entre novamente.' } });
  }
  const { nome, params = {} } = req.body ?? {};
  if (typeof nome !== 'string' || !ROTINA.test(nome) || typeof params !== 'object' || Array.isArray(params) ||
      Object.keys(params).some((p) => !PARAMETRO.test(p))) {
    return res.status(400).json({ data: null, error: { code: '42501', message: 'Rotina não permitida.' } });
  }

  const cabecalhos = { apikey: CHAVE_PUBLICA, Authorization: autorizacao, 'Content-Type': 'application/json' };
  // Sem a variável, as leituras seguem funcionando e as gravações ficam bloqueadas pelo banco.
  if (CHAVE_FROTA) cabecalhos['x-frota-gestao-chave'] = CHAVE_FROTA;

  let resposta;
  try {
    resposta = await fetch(`${URL_SUPABASE}/rest/v1/rpc/${nome}`, { method: 'POST', headers: cabecalhos, body: JSON.stringify(params) });
  } catch {
    return res.status(502).json({ data: null, error: { message: 'Banco de dados indisponível. Tente novamente.' } });
  }
  const texto = await resposta.text();
  let corpo = null;
  try { corpo = texto ? JSON.parse(texto) : null; } catch { corpo = null; }
  if (!resposta.ok) {
    return res.status(200).json({ data: null, error: { code: corpo?.code, message: corpo?.message ?? `Falha ${resposta.status} no banco.` } });
  }
  return res.status(200).json({ data: corpo, error: null });
}
