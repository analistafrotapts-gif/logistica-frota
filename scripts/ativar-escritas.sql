-- Libera as gravações do módulo Gestão da Frota.
-- Rode UMA vez no SQL Editor do Supabase, depois de conferir a instalação.
--
-- 1. Gere a chave:  node scripts/gerar-chave.mjs
-- 2. Cole a MESMA chave aqui e na variável FROTA_GESTAO_CHAVE da Vercel.
-- 3. Descreva em "evidencia" quem conferiu a instalação e quando.
--
-- O banco guarda só o hash SHA-256 da chave. Sem a chave correta no servidor,
-- o módulo continua somente leitura.
update frota_gestao_privado.ativacao set
  escritas_liberadas = true,
  contrato_verificado = 91,
  verificado_em = now(),
  evidencia = 'COLE_AQUI_A_EVIDENCIA',
  chave_sha256 = encode(sha256(convert_to('COLE_AQUI_A_CHAVE', 'UTF8')), 'hex'),
  expiracao_liberada = true
where id;
