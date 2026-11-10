# Atualização de telas, edição e exclusão — 10/11/2026

Destino: https://logistica-frota-frota13.vercel.app/

## Publicação da aplicação

Mantém `public/js/sessao.js`, o login, a mesma configuração de Supabase nas
variáveis existentes da Vercel e o transporte `/api/rpc`. Não executa SQL, seed,
importação de cadastros ou alteração de registros no build/deploy.

Atualiza os componentes de lançamento, conferência HBF, Central, Estoque,
Dashboard e Cadastros para a versão aprovada. O compilador usa as fontes React
antes de minificar; o cliente publicado não inclui PGlite, usuários de laboratório,
chaves de servidor, inicialização de banco ou fixtures.

A API passa a aceitar uma lista explícita de rotinas. Mantém as rotinas usadas
pelo painel e acrescenta edição/exclusão/recibos. Repassa o JWT ao Supabase, onde
a sessão e o perfil são conferidos pelas funções e RLS; a chave de escrita continua
exclusivamente no servidor. A verificação da ativação usa uma RPC de leitura.

## Banco existente: execução manual separada, ainda não realizada

**Não executar `instalacao-completa.sql` neste banco existente. Não reaplicar
as migrations iniciais nem os dados iniciais para atualizar as telas.**

1. Confirmar projeto Supabase de destino, backup e recuperação antes de qualquer DDL.
2. Executar somente as consultas de `supabase/verificacoes/atualizacao-20261110.sql`
   e comparar as definições com os scripts versionados. Nenhum estado real do banco
   foi presumido ou confirmado por testes locais.
3. Com os predecessores 95–98 compatíveis e autorização para alterar o banco,
   executar manualmente, nesta ordem e dentro de transação:
   - `supabase/migrations/20261110001700_frota_99_edicao_simplificada.sql`;
   - `supabase/migrations/20261110001800_frota_100_exclusao_simplificada.sql`.
4. Conferir as funções, políticas, grants, views e o trigger de identidade.
   Só então homologar as novas operações com dados e procedimento controlados.

Os scripts não apagam NFs, lotes, aplicações ou usuários. O 99 cria versões
imutáveis e leituras vigentes. O 100 cria exclusão lógica e substitui **duas
constraints UNIQUE do contrato simplificado** por validação de identidades ativas
sob advisory locks, permitindo relançar uma NF excluída. PKs/FKs permanecem.
Essa alteração exige revisão de integridade/concorrência antes de instalação.
Não desabilitar o trigger de identidade nem reaplicar 95–99 depois do 100 sem
revisar e reaplicar 100 por último. O corretivo 99 normaliza somente CRLF antes
de comparar o corpo do validador; continua abortando quando a regra esperada diverge.

Sem 99, o detalhe/HBF atual continua disponível e Editar informa configuração
pendente. Sem 100, Apagar não confirma sucesso. Nenhum SQL roda pelo navegador.
Enquanto os scripts não forem instalados/verificados, a edição e a exclusão
reais permanecem pendentes, mesmo depois da publicação das telas.

## Comportamento dos registros

- Central exibe somente a versão vigente, sem duplicar as linhas antigas.
- Histórico mostra versões e comparações Antes/Depois, autor, motivo e data.
- Edição confirmada altera os custos/saldos vigentes por placa, centro e unidade.
- NF com peças aplicadas exige exclusão integral e relançamento corrigido.
- Apagar retira da Central os lançamentos e remove seus custos diretos, custos
  das aplicações e saldos das consultas. O histórico físico/auditoria é preservado.
- Não é cancelamento fiscal no órgão emissor nem devolução física de material.

## Verificações realizadas sem produção

- `npm ci`, `npm run build`, `npm test`.
- Onze testes de banco/API, incluindo instalação sobre dados sintéticos existentes,
  preservação das notas e veículos, edição, mudança de placa/unidade, estoque,
  exclusão com aplicação, relançamento, RLS, chave de servidor e instalação limpa.
- `node testes/navegador.mjs ../logpaubrasil-novo http://localhost:3087`: login,
  XML, alocação placa/estoque, HBF, finalização, edição Patos/Sumé, histórico,
  download PDF e exclusão contra a API e PostgreSQL locais. Bloqueia rede externa.
- O schema e os lançamentos de produção não foram consultados nem modificados.

## Recompilar e recuperar

Para atualizar os artefatos usando o projeto fonte e o HTML aprovado:

```sh
node ferramentas/gerar-versao-atualizada.mjs ../logpaubrasil-novo /caminho/Pau-Brasil-laboratorio-frota.html
```

Não executar o extrator antigo baseado em nomes minificados sobre esta versão.
O manifesto público `versao.json` identifica os hashes da aplicação, CSS e OCR.

Rollback de frontend: promover o deployment anterior na Vercel. Como o build não
altera o banco, essa reversão da aplicação não exclui nem recria registros.
Se os SQLs já tiverem sido instalados, um rollback de frontend não desfaz o schema;
não tentar removê-lo automaticamente. Recuperação do banco exige procedimento
próprio aprovado e backup verificado.
