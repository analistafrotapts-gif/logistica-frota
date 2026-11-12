# Histórico, retorno ao estoque, exclusão de cadastros e atalhos

Preparação local em 12/11/2026. Nenhum SQL enviado ao Supabase, push ou deploy.

## Comportamento

- Alt + setas em Dados da NF, Itens, Alocação e HBF, inclusive ao editar. Nas tabelas, cima/baixo mantém a coluna; nos formulários segue a posição visual. Tab e digitação normais permanecem; AltGr não é interceptado. F2 continua disponível na tabela de itens.
- Estoque → **Histórico do estoque** consulta entradas, aplicações e retornos, com NF, item, quantidade, valor, destino, centro, data, responsável e motivo. Há pesquisa e filtro por movimento. NFs excluídas/versões substituídas são identificadas e não retornam ao saldo.
- **Retornar ao Estoque** desfaz uma aplicação inteira, mediante confirmação e motivo (5–1000 caracteres). Quantidade e valor exatos voltam ao lote. O custo dessa aplicação deixa de compor o Dashboard; outras aplicações e custos diretos permanecem. Não é devolução fiscal ao fornecedor, nem retorno parcial.
- Aplicação e retorno ficam imutáveis no histórico/auditoria. A mesma chave e os mesmos dados recuperam o recibo; outra chave não permite retornar novamente a aplicação. Falha de comunicação mantém o pedido para reenvio, sem sucesso presumido.
- Os cinco cadastros (veículos, fornecedores, contas, classificações e destinos) têm **Excluir**, confirmação e motivo. Exclusão lógica apenas neste módulo: remove das novas seleções, preserva vínculos, notas, custos e registros do portal antigo. Não existe exclusão física de veículo/fornecedor legado.
- Cadastros excluídos não podem ser editados/recriados silenciosamente com a mesma identidade. Recuperação/reativação não faz parte desta entrega; novas identidades continuam permitidas. As chaves históricas permanecem reservadas.
- Cadastros: cartões menores, até três colunas, cabeçalho de destaque, contagem real de registros, ícones compactos e ações nas cores semânticas do portal.

## Instalação manual futura

1. Identificar projeto/banco e guardar evidência de backup recuperável. Esta entrega não comprova backup nem compatibilidade de produção.
2. Confirmar os predecessores já instalados. A base do novo contrato exige SQL92, 84–91 e 95–98, com suas dependências legadas previamente verificadas; SQL99 revisado e 100, nessa ordem. Não reaplicar instaladores antigos indiscriminadamente.
3. Para a atualização a partir de 99/100 confirmados: **101 → 102 → 103 → 104 → 105_frota_gestao_retornos_cadastros.sql**. Verificar cada etapa antes de seguir. O 105 é transacional e reaplicável sobre seu próprio resultado; aborta ao encontrar funções predecessoras divergentes.
4. Consultar `supabase/verificacoes/retornos_cadastros.sql`, exclusivamente leitura. Confirmar RLS e somente SELECT para authenticated nas duas tabelas novas; nenhum acesso anon. Conferir funções e permissões.
5. Testar com usuário autenticado ativo e chave de escrita fornecida exclusivamente pelo servidor. Chamadas diretas sem chave são negadas, inclusive exclusão/retorno. Não ampliar ACL dos módulos antigos.
6. Publicar a interface e liberar somente após autorização. O HTML isolado inclui o SQL105 somente no PostgreSQL local incorporado. No portal, sem SQL105, o histórico informa configuração pendente e a exclusão fica desabilitada. Nenhum SQL é executado pelo build/cliente.

Reaplicar scripts predecessores pode substituir funções/views atualizadas: revisar e reaplicar sucessores em ordem; não tratar isso como rollback. Em falha de instalação, a transação do 105 reverte suas alterações. Isso não substitui backup, nem desfaz movimentações futuras.

## Estruturas do 105

- `frota_gestao_retornos_estoque`: registro append-only, aplicação e chave únicas, motivo/autor/data. RLS de leitura ativa, sem DML direto.
- `frota_gestao_cadastros_excluidos`: marcadores append-only por tipo/ID, chave única, motivo/autor/data. Mesmo controle de acesso.
- Views `frota_gestao_aplicacoes_efetivas` e `frota_gestao_cadastros_ativos`, com `security_invoker=true`.
- RPCs `frota_gestao_historico_estoque`, `frota_gestao_retornar_estoque`, `frota_gestao_excluir_cadastro`; filtros de leitura e validadores adaptados somente no novo módulo.
- Retorno usa locks NF → lote → aplicação, mesma ordem dos fluxos existentes. Revalida NF/lote vigentes dentro da transação.
- Aplicações posteriores usam o valor/saldo restantes, com arredondamento financeiro e ajuste integral na última baixa, evitando valores negativos por centavos após retornos fora de ordem.
- A view de veículos conserva o mecanismo preexistente e seus controles; a dívida anterior de view com privilégios de proprietário não é apresentada como corrigida nesta entrega.

## Limitações e validação

- NF que já recebeu aplicação continua com a restrição de edição do SQL99, mesmo se a aplicação tiver retornado. Não foi removido esse bloqueio de segurança. Exclusão integral da NF continua sendo o fluxo de correção aprovado para esse caso.
- Sem homologação em PostgreSQL remoto com conexões independentes nesta entrega. Testes PGlite isolados não provam concorrência entre servidores nem políticas reais de produção.
- Testes isolados cobrem centavos, aplicações/retornos fora de ordem, reenvio, recusa duplicada, NF excluída, saldo/custo, cinco exclusões, preservação do legado, RLS, ausência de chave e reaplicação.
- Testes de navegador usam componentes reais e serviços simulados apenas nos testes: exclusões, modal, reenvio idêntico, layout 320–1920px e navegação. O laboratório completo executa operações reais exclusivamente no banco incorporado em memória.
- Backup de laboratório antigo não recebe SQL105 automaticamente. Usar banco local novo para avaliar estes recursos; não supor que restaurar um backup antigo instala novas funções.
