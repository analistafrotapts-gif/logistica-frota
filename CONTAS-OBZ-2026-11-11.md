# Contas de OBZ e alocação responsiva — preparação local

## Comportamento

- Três opções por item fiscal: Corretivo, Preventivo e Contas de OBZ (`obz`). O tipo continua pertencendo ao item e vale para seus destinos, como ocorria com MP/MC.
- Cada item tem um cartão com descrição, quantidade total e tipo no cabeçalho. Os destinos têm campos com rótulos alinhados: Destino, Placa/Estoque, Quantidade, Unidade de Negócio, Classificação e Valor alocado.
- Sem tabela de largura mínima ou rolagem horizontal. Em telas menores, os campos passam para novas linhas; a página continua rolando verticalmente conforme a quantidade de itens.
- Busca de placas e classificações, centro sugerido pela placa e divisão de quantidades permanecem disponíveis. O valor mantém o rateio em centavos.
- HBF conserva as 13 colunas e identifica Contas de OBZ no detalhamento. Central, Estoque e histórico do Dashboard mostram `OBZ`, sem converter em MP ou MC.
- OBZ participa dos custos totais e dos filtros, mas fica fora da base do percentual preventiva/corretiva. Não é apresentado como tipo ausente.
- Uma entrada OBZ em estoque mantém o tipo e permite confirmá-lo ou alterá-lo na aplicação. Saldo não aplicado continua fora dos custos de veículo.
- Nenhuma conta financeira é escolhida automaticamente apenas por selecionar OBZ; a conferência da conta continua independente.

## Banco e publicação

**Não aplicado em produção nesta etapa. Sem push, commit ou deploy.** Os SQLs 99/100 já instalados em 11/11 não aceitam OBZ por si sós.

Próxima atualização manual, após autorização específica: `supabase/101_frota_gestao_contas_obz.sql`, depois dos SQLs 99 revisado e 100. Esse arquivo fica separado em `supabase/`, sem inventar uma entrada no histórico de migrations. No projeto fonte, usa o mesmo nome e conteúdo.

O SQL 101 adapta somente a validação dos tipos nas duas funções simplificadas de validação e na aplicação de estoque; amplia o CHECK de manutenção das aplicações para aceitar `obz`, mantendo NULL histórico. Não atualiza linhas existentes, não altera enum do legado, não muda dados Gestran e não libera a chave de servidor.

O script usa transação, limites de espera/execução e aborta se as dependências 99/100 ou os trechos esperados divergirem. Preserva as versões e os bloqueios de identidade, edição/exclusão e lotes antigos. As funções privadas permanecem sem execução direta por autenticados; a aplicação segue exigindo servidor e conta ativa. É reaplicável, conforme teste isolado.

Para instalação nova, o instalador completo atual vai até o SQL 100: executar o 101 separadamente depois dele. Para instalação existente, não executar o instalador completo nem reaplicar 95–100: conferir a base e executar somente o 101 autorizado. Não reaplicar predecessores depois do 101 sem revisão.

Instalar e verificar 101 antes de disponibilizar o frontend OBZ em produção. Os artefatos de frontend foram recompilados localmente; a configuração de produção não foi modificada. O build local sem variáveis avisa que precisa da configuração Vercel já existente, sem criar credenciais.

## Validação

- TypeScript e build Next.js aprovados.
- ESLint dos arquivos alterados e lint do módulo completo aprovados.
- Teste isolado `scripts/gestao-frota/laboratorio/testar-obz.mts`: recusa antes de 101, aplicação/reaplicação sem modificar NF anterior, finalização, HBF/Central, edição MC↔OBZ, estoque/aplicação, custo OBZ, filtros, exclusão e recusa de tipo inválido.
- `scripts/gestao-frota/testar-alocacao-responsiva.mts`: navegador Edge, larguras 320, 768, 1024, 1366 e 1920; seleção OBZ, divisão 10+10, conciliação e ausência de rolagem horizontal. Usa catálogos isolados e bloqueia rede externa.
- Regressões de Dashboard, edição SQL 99 e exclusão SQL 100 aprovadas.
- Navegador com HTML completo: consulta, edição 100→120, rejeição SQL com rollback, recuperação de resposta após commit, recibo sem duplicação e atualização da Central/custos/estoque aprovados, com rede externa bloqueada.
- Projeto de publicação: 11 testes de banco/API aprovados e build aprovado.
- HTML de laboratório recompilado com fontes/CSS atuais e SQL 101 somente no PostgreSQL incorporado; nenhuma chamada ao Supabase.

Os testes usam dados sintéticos em bases locais. Não constituem comprovação da instalação do SQL 101 no banco de produção.
