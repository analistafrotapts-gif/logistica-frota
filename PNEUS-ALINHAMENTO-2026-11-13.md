# Política e Gestão de Pneus — alinhamento e balanceamento

Atualização: elegibilidade, ordenação e tema escuro estão descritos em `PNEUS-ELEGIBILIDADE-2026-11-13.md`. O aviso de 30 dias foi confirmado pelo responsável.

Implementação local para avaliação. Não houve instalação do SQL106 no Supabase, push ou deploy desta etapa. As funções 101–105 instaladas anteriormente não são reaplicadas.

## Navegação

O cabeçalho possui um seletor de módulos: **Gerenciamento de custos** e **Política e Gestão de Pneus**. Cada módulo mantém sua página inicial com cards e sua própria lista de telas na lateral. Os endereços atuais de NF, estoque, custos e cadastros permanecem válidos. O primeiro e único card de Pneus nesta etapa é **Alinhamento e balanceamento**.

Rotas preparadas no Next e nos adaptadores de laboratório/publicação:

- `/portal/gestao-frota/pneus`
- `/portal/gestao-frota/pneus/alinhamento`
- No HTML/portal estático: `#/pneus` e `#/pneus/alinhamento`.

## Telas

- **Lançamentos**: placa, data realizada, centro de custo, número da NF, fornecedor e valor. Possui filtros pesquisáveis por placa/centro, período, paginação, Novo lançamento e Editar.
- **Farol e prazos**: total de veículos, em dia, vencendo, atrasados e sem registro. Mostra último serviço, próximo serviço, dias restantes e acesso ao histórico por veículo.
- **Histórico**: origem automática, lançamentos manuais e cada correção, com responsável, data, motivo e situação da NF de origem. O original permanece disponível.

O período filtra os lançamentos e o histórico pela data do serviço. O farol considera sempre o último serviço válido até hoje, mesmo fora do período filtrado, para não inventar atrasos pela seleção de um período.

## Regras implementadas

1. Próximo serviço em **seis meses de calendário**, preservando o dia quando existir e usando o último dia do mês de destino quando necessário. Exemplo: 31/08/2026 → 28/02/2027. Não são 180 dias fixos.
2. Alerta de proximidade aprovado: **30 dias**. Em dia acima de 30; vencendo de 0 a 30; atrasado com dias negativos. Antecedência confirmada pelo responsável; a regra de seis meses é independente desse aviso.
3. Veículo sem serviço conhecido é **Sem registro**. Não presumir serviço realizado ou prazo vencido. Datas futuras recebidas da NF são exibidas para conferência e não definem o último serviço realizado.
4. Participam do farol os veículos disponíveis no cadastro efetivo do módulo e marcados como elegíveis. A aba Veículos e o SQL107 permitem essa escolha; o padrão permanece elegível até alteração explícita. Não há exclusão presumida pelo tipo da placa.

## Integração automática com NF

O SQL106 lê as NFs confirmadas do contrato atual e suas versões, sem converter o Gestran. Reconhece palavras completas **alinhamento** ou **balanceamento** na classificação do item, sem distinguir maiúsculas/acentos. A descrição isolada não basta: isso evita tratar materiais ou peças com nomes semelhantes como serviço concluído.

Somente destinações a uma placa geram acompanhamento. Estoque e destinos sem placa não geram serviço para um veículo presumido. Agrupamento por **NF + versão + veículo + centro de custo**; duas linhas de alinhamento/balanceamento nessa mesma combinação formam um registro com a soma dos valores líquidos pertinentes, sem duplicar a visita por item. Outros itens da NF não integram esse valor.

A data sugerida vem da emissão da NF e fica identificada na tela. O usuário pode corrigir data, placa, centro, número da NF, fornecedor, valor e observação. Essa correção afeta somente o acompanhamento de pneus; não reescreve a NF nem os custos financeiros. Correções financeiras continuam na Central de Notas.

As fontes são calculadas na consulta, não copiadas em triggers. Assim, nova finalização aparece na próxima abertura/atualização; edição financeira substitui a fonte vigente; exclusão da NF retira o serviço do cálculo atual e o preserva no histórico como excluído. Correções de pneus ficam ligadas à versão original: após nova versão financeira, a nova fonte deve ser conferida, sem transferir silenciosamente correções antigas para outro veículo/serviço.

Novo lançamento registra serviço manual sem criar NF, OS, estoque ou custo financeiro. Registros manuais e automáticos são origens distintas; não há reconciliação presumida de um lançamento manual com uma NF futura.

## Banco e segurança

**Novo arquivo: `supabase/106_frota_gestao_alinhamento_balanceamento.sql`, após 105 e seus predecessores.** Preparado e testado apenas em PostgreSQL incorporado isolado. Solicitar autorização própria antes de instalar/publicar esta etapa.

- Tabela `frota_gestao_pneus_alinhamentos`: versões append-only, chave idempotente, fonte, dados, pedido original, motivo, autor/data. UPDATE/DELETE bloqueados e auditoria após INSERT.
- View `frota_gestao_pneus_fontes`: fontes fiscais e situação vigente, com `security_invoker=true`.
- RPCs `frota_gestao_alinhamentos()` e `frota_gestao_salvar_alinhamento(uuid,text,jsonb,text,boolean)`.
- RLS: todos os usuários autenticados e ativos do módulo consultam; nenhuma gravação direta por authenticated/anon. Escrita via RPC requer chave de servidor e conta ativa. A chave não é enviada ao cliente.
- Reenvio com mesma chave/dados retorna o recibo original. Reenvio com dados diferentes é recusado. Edições são serializadas por fonte e preservam cada versão; última gravação confirmada é a atual.
- Correção de fonte fiscal trava/reconfere a NF; uma fonte excluída ou substituída não pode ser atualizada por solicitação atrasada.
- Sem SQL106, a tela informa configuração pendente e não presume dados nem sucesso.

O script cria somente objetos novos desse módulo; não altera tabelas/ACLs de NF, custos, estoque ou módulos legados. É transacional e reaplicável sobre seu próprio resultado. Avaliar o estado real antes de qualquer instalação; não usar o instalador completo sobre a base existente.

## Verificação local

- Teste SQL106: alimentação automática após NF, agrupamento de duas linhas, outras classificações ignoradas, correção auditada, NF/custos preservados, versão/exclusão financeira refletidas, registro manual, reenvio, RLS/chave, reaplicação e cálculo com meses curtos/ano bissexto.
- HTML completo: alternância de módulos, lateral contextual, cadastro/correção manual, farol, histórico e uma NF lançada no fluxo de custos aparecendo automaticamente em Pneus.
- Interface conferida em 320, 768 e 1440 pixels, inclusive tema escuro. Os dados sintéticos foram criados somente durante testes e não estão pré-carregados no HTML distribuído.
- Testes existentes de estoque/retorno e cadastros mantidos. Não equivale a homologação com banco remoto e conexões independentes.

Arquivos principais: `src/components/frota/MenuGestao.tsx`, `src/lib/frota/gestao/alinhamentos.ts`, `src/app/portal/gestao-frota/pneus/alinhamento/Alinhamentos.tsx`, `actions.ts`, páginas Next e adaptadores de laboratório/publicação.
