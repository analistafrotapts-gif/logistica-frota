# PostgreSQL 17: instalação e concorrência — 11/11/2026

Resultado: **APROVADO no ambiente local isolado**.

Executado `node testes/concorrencia-postgres.mjs`, usando PostgreSQL 17.11 nativo
do Windows, conexões `psql` independentes, autenticação/cron simulados e dados
sintéticos. O servidor escuta exclusivamente `127.0.0.1`, usa uma pasta temporária
própria e é encerrado ao concluir. Não houve conexão ao Supabase de produção.
Nenhum segundo projeto Supabase foi criado.

## Instalação e preservação

Uma NF sintética foi finalizada antes de instalar 99/100. Uma divisão por zero
foi injetada depois dos dois scripts, ainda na mesma transação. O PostgreSQL
abortou a transação: as tabelas novas não permaneceram instaladas e o hash do
registro original ficou inalterado. A instalação foi então repetida sem a falha,
confirmada e verificada; a NF anterior continuou intacta até o fim dos testes.

Isso comprova rollback **antes do commit** neste cenário. Não comprova recuperação
de dados de produção depois de operações reais ou dispensa backup.

## Operações simultâneas

Em cada cenário a conexão A gravou e manteve a transação aberta. A conexão B
iniciou a operação conflitante; seu bloqueio foi confirmado em `pg_stat_activity`.
Somente depois A confirmou, permitindo verificar o resultado de B.

| Cenário | Resultado verificado |
| --- | --- |
| Duas finalizações da mesma identidade fiscal | A confirma; B aguarda e é recusada como duplicidade. |
| Duas edições da mesma versão base | A confirma; B aguarda e é recusada por versão desatualizada. |
| Edição antes de aplicação do lote substituído | Aplicação aguarda e é recusada porque o lote deixou de ser vigente. |
| Aplicação antes de edição da NF | Edição aguarda e é bloqueada pela aplicação confirmada. |
| Exclusão antes de aplicação de estoque | Aplicação aguarda e é recusada; NF excluída não compõe custos, compras ou estoque. |
| Duas exclusões com a mesma chave | B aguarda e recebe o mesmo recibo, sem segunda exclusão. |

Também foi confirmado o relançamento da identidade fiscal excluída, os totais
vigentes após edição/aplicação e a preservação da NF anterior. Contagem final
esperada: cinco registros físicos de NF, duas edições, duas exclusões e uma
aplicação. Os registros físicos anteriores não foram apagados.

Relatório local da execução aprovada:
`C:\Users\apft.patos\.codex\tmp\frota-concorrencia-pg17-Bmn6kr\resultado.json`.

## Limites e próximo passo

Estes testes ampliam a evidência anterior em PGlite. O host de produção usa outra
plataforma/arquitetura e autenticação real; ainda é necessária a validação controlada
no Supabase. Após instalação autorizada e com recuperação preparada, verificar
catálogo, RLS/ACL, guarda de escrita, leituras das versões vigentes e integridade
dos registros preexistentes. Não editar ou apagar notas reais para simplesmente
testar botões, nem apresentar uma escrita não confirmada como sucesso.

O backup recuperável continua pendente. Nenhum SQL 99/100 foi instalado em produção
nesta execução. Não foi feito commit, push ou deploy desta suíte.
