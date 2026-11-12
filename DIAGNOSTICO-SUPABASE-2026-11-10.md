# Preflight do Supabase de produção — 10/11/2026

## Confirmado por conexão administrativa, somente leitura

- Projeto `logistica-frota`, ref `fixvhizwcztmvmpykovr`, região `sa-east-1`, ativo.
- A referência coincide com a configuração pública do portal publicado.
- PostgreSQL 17.11. Organização `Frota`, assinatura `free` retornada pela API.
- 12 NFs no contrato simplificado, 13 OS, um lote, nenhuma aplicação de peças.
- Contrato completo 92 verificado por consulta; nenhuma identidade fiscal duplicada.
- Os hashes dos corpos das 13 funções críticas de 95–98 correspondem às
  definições reconstruídas do repositório em PostgreSQL isolado, normalizando CRLF.
- PKs, FKs, unicidades e triggers de preservação/auditoria conferidos no catálogo.
- RLS ativo e sem leitura anônima nas quatro tabelas de lançamentos/OS/lotes/aplicações.
  `authenticated` não tem INSERT, UPDATE ou DELETE direto nessas tabelas.
- Tabelas e RPCs de edição/exclusão 99/100 ainda ausentes.
- Histórico de migrations da plataforma vazio: a presença dos objetos foi
  comprovada por catálogo/definições, sem presumir instalações pelo histórico.

Foram registrados hashes dos lançamentos, OS, lotes e aplicações para comparação
antes/depois, sem exportar o conteúdo fiscal dos registros para o repositório.
Esses hashes são baseline de integridade; **não são backup recuperável**.

## Segurança

O advisor sinalizou a view preexistente `frota_gestao_veiculos` como view com
privilégios do proprietário e avisos sobre RPCs SECURITY DEFINER autenticadas.
São estruturas do contrato atual; não foram alteradas em produção. As RPCs
operacionais são intencionalmente privilegiadas, com checagem de conta ativa e
guarda de escrita. Alterações no legado exigem análise separada.

Nas versões locais preparadas dos SQLs 99/100, as duas novas views usam
`security_invoker=true` e `security_barrier=true`, preservando RLS/grants do
usuário. Onze testes isolados passaram após esse ajuste, inclusive instalação
em base sintética com registros anteriores, edição/exclusão e acesso negado.

## Bloqueador de instalação

**Backup recuperável e procedimento de recuperação ainda não comprovados.**

O plano Free não deve ser tratado como evidência de backups diários ou PITR.
A documentação orienta exportação manual para esse plano. A conexão MCP atual
permite diagnóstico e SQL, mas não expõe uma ferramenta de exportação pg_dump,
listagem de backups da plataforma ou validação de restauração de backup.

Não substituir um backup completo por CSV, hashes, cópia de tabelas no mesmo
banco ou testes sintéticos. Não testar restauração sobre produção.

É necessário localizar backup existente ou gerar exportação por conexão segura
e verificar sua restauração isolada antes da instalação. Não pedir senhas ou
tokens pelo chat. Até resolver, preservar o banco atual e não aplicar 99/100.

## Alterações executadas

Nenhum DDL, migration, INSERT, UPDATE ou DELETE foi executado no Supabase.
Não foram criadas NFs fictícias nem alteradas credenciais, permissões ou ativação.

Referência: https://supabase.com/docs/guides/platform/backups
