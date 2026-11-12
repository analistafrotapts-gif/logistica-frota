# Atualização do portal — 12/11/2026

**Atualização posterior confirmada:** os SQLs 101–105 foram autorizados e instalados na migration `20261112172313_frota_101_105_obz_destinos_retornos_cadastros`. Consulte `INSTALACAO-101-105-2026-11-12.md` para as verificações e preservação das 36 tabelas. O diagnóstico abaixo registra o estado anterior à instalação. A revisão posterior também corrigiu placas e números de contas no tema escuro.

Publicação solicitada pelo responsável. Projeto existente: `logistica-frota`, domínio `logistica-frota-frota13.vercel.app`. Não criar projeto nem substituir banco/credenciais.

## Código incluído

- Contas de OBZ; milimetragem e destinos cadastrados; HBF por centro de custo e classificação/tipo obrigatórios.
- Replicação de campos do primeiro item e navegação Alt + setas em todas as etapas de lançamento.
- Histórico do estoque, retorno integral de aplicações e exclusão lógica de cadastros, com confirmação e auditoria.
- Cadastros compactos, sem rolagem vertical interna na listagem; cabeçalho do histórico em vinho.

## Preservação e dependências

O build apenas prepara arquivos estáticos e configuração pública. Não executa SQL, não semeia dados e não modifica lançamentos. O cliente publicado utiliza autenticação e banco existentes; não inclui o PostgreSQL incorporado nem os dados de teste do laboratório. A pasta `laboratorio` está excluída do deploy pela `.vercelignore`.

O diagnóstico de leitura desta preparação confirmou as funções de cadastro/aplicação anteriores, mas não encontrou as funções introduzidas pelos SQLs 102–105. Portanto, não considerar as novas operações de banco disponíveis apenas por terem sido publicadas as telas.

Depois dos SQLs 99 revisado e 100 já confirmados, a ordem da atualização é **101 → 102 → 103 → 104 → 105**. Não executar `instalacao-completa.sql` sobre o banco existente. A instalação dessas dependências exige autorização específica, conferência dos predecessores e evidência de preservação dos registros. Esta publicação não substitui backup e não comprova restauração.

Sem o SQL105, a exclusão de cadastros fica desabilitada e o histórico de estoque informa configuração pendente. Sem 102/103, os cadastros de milimetragem/destinos informam a dependência e não simulam gravação. Os recursos que dependem do banco não são instalados pelo cliente.

Instruções detalhadas: `RETORNOS-CADASTROS-2026-11-12.md`, `HBF-CENTROS-CLASSIFICACAO-2026-11-12.md`, `DESTINOS-HBF-2026-11-12.md`. Consultas de leitura em `supabase/verificacoes/`.

## Validação

- 11 testes do pacote de publicação aprovados; build estático aprovado. Esses testes usam banco isolado e não alteram produção.
- TypeScript, lint dos componentes alterados e build Next aprovados na origem dos componentes.
- Testes isolados de SQL105 e de classificação/milimetragem, com saldo/custo, recibo idempotente, RLS e preservação de registros.
- Navegador no HTML completo: lançamento, aplicação, retorno, histórico, exclusão de cadastro; cabeçalho vinho e rolagem principal da lista de veículos verificados.

Após o deploy, conferir `/versao.json`, arquivos JS/CSS, tela de login, ausência de credenciais privadas no cliente e rejeição de operações sem sessão. Não criar/editar/apagar NF real para testar a publicação.

## Recuperação do código

Versão publicada anterior de referência: `564fa5fd4a857a8b8c754ea181faa17af85a8e24`. Promover novamente o deploy anterior na Vercel permite recuar o código caso necessário. Isso não reverte alterações do banco nem movimentações operacionais e não deve ser apresentado como backup do banco.
