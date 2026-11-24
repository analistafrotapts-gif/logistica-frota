# Milimetragem — adaptação do HTML fornecido

Preparação local para avaliação. Não publica, não instala SQL nem modifica dados de produção.

## Navegação e identidade visual

- Novo card **Milimetragem**, ao lado de Alinhamento e balanceamento em Política e Gestão de Pneus. A lateral desse módulo também inclui a nova tela.
- Rota `/portal/gestao-frota/pneus/milimetragem`, registrada no Next.js, no laboratório HTML e no adaptador do pacote de publicação.
- Cabeçalho próprio azul do documento removido da apresentação. Usa o cabeçalho e a navegação do portal, cores semânticas, vinho, fontes, bordas e temas claro/escuro do sistema.
- Placas geradas pelo componente `PlacaVeiculo`, preservando a identificação e o visual usado nas demais telas.
- Abas Medições, Veículos, Pneus Cadastrados, Análise e Histórico Milimetragem. Histórico de Pneus permanece acessível dentro de Pneus Cadastrados. Mantidos os mapas de eixos/estepes, quatro sulcos por posição, seleção de pneus e movimentações do exemplar.
- Altura se ajusta ao conteúdo para usar a rolagem principal. Tema é atualizado sem recarregar formulários abertos.

## Preservação e limites

O documento fornecido permanece intacto. Sua cópia está em `src/lib/frota/gestao/milimetragem-referencia.ts`; a adaptação fica em `src/components/frota/Milimetragem.tsx`. Os fluxos originais são apresentados em um documento incorporado, com estilos e placas do portal, para preservar as regras antes de uma migração funcional mais ampla.

Esse documento não acessa APIs. A política de conteúdo impede conexões de rede; o código estático fornecido é incluído no pacote, sem carregar scripts externos. A integração de tema/altura aceita mensagens somente da janela correspondente. O documento não representa uma fronteira de segurança contra código arbitrário: é código local revisado e incluído no projeto, não um mecanismo para executar futuros HTMLs enviados por usuários.

O cadastro base agora é recebido do contexto autenticado de Cadastros de Custos. Configurações técnicas, pneus e medições continuam em **localStorage** (`paubrasil_milimetragem_v3` e fallback v2). Esses registros técnicos não são enviados ao Supabase, não geram custos no dashboard nem modificam os cadastros financeiros. Não há importação automática dos dados salvos no outro arquivo/origem do navegador. A importação de planilhas foi retirada da Milimetragem; a tela de Cadastros de Custos permanece inalterada.

A tela informa explicitamente o armazenamento local. Não foram incluídos veículos, pneus ou medições fictícios como registros reais. Os testes usam apenas navegador isolado e dados sintéticos.

Antes do uso compartilhado em produção, ainda é necessário persistir centralmente pneus/posições/medições/movimentações, configurações técnicas, auditoria, concorrência e migração do armazenamento local. O vínculo lógico ao cadastro base já usa o identificador do veículo existente; nenhuma estrutura nova foi instalada no banco nesta etapa.

Os critérios de análise do exemplar (sulco crítico de 4 mm e diferença de 2,5 mm para avaliar rodízio) foram preservados. Não são novas regras aprovadas por esta adaptação.

## Cadastro único e configuração pendente

- Placa, centro de custo, unidade e participação no rateio são definidos exclusivamente em Cadastros de Custos. Não existe criação paralela de veículos nesta área.
- Apenas veículos com participação marcada entram na lista operacional da Milimetragem. Entradas novas exibem triângulo/aviso de informações pendentes, sem escolher eixos ou estepes por suposição.
- Para retirar o aviso, o usuário confirma configuração dos eixos e quantidade de estepes (0, 1 ou 2). Modelo e fabricante são opcionais. A medição fica bloqueada até essa confirmação.
- O cadastro do Alinhamento continua recebendo todos os veículos da consulta existente, independentemente da participação na milimetragem; a elegibilidade específica do Alinhamento continua independente.
- Ao desmarcar a participação ou excluir o cadastro base das seleções, o veículo sai da lista operacional e do farol, mas configurações, pneus, medições e histórico local permanecem. Ao voltar a participar, a configuração confirmada é reutilizada.
- Vínculo mantido por identificador estável; cadastros locais antigos com a mesma placa normalizada podem receber o vínculo sem apagar seus dados. Alterações posteriores de placa preservam as identificações anteriores para consulta histórica.

## Pneus, histórico por veículo e farol

- Pneus Cadastrados separa catálogo, pesquisa, edição e cadastro manual de pneus. Importadores e modelos de planilhas não aparecem no módulo.
- Histórico Milimetragem lista placas com participação atual ou eventos registrados. Ao abrir uma placa, mostra medições e movimentações, datas, número de fogo, posição e sulcos/hodômetro quando existentes. Veículos fora da lista atual permanecem consultáveis quando têm histórico.
- Novos salvamentos registram uma fotografia das posições/pneus e da configuração usada. Isso preserva qual pneu estava em cada posição no momento; movimentações posteriores não reescrevem as fotografias.
- Regra aprovada pelo responsável: **OK somente após medir todas as posições, incluindo estepes**. As quatro leituras de cada posição devem ser válidas, da mesma competência, do pneu/posição/veículo correspondentes. Configuração pendente, medição parcial ou ausência de prova completa permanece NOK.
- Uma simples alocação não conta como medição. Leituras de outro veículo ou de outro mês não completam o farol. Alterar a configuração atual exige cobrir suas novas posições. O histórico de uma medição completa não é perdido pela substituição posterior de um pneu.
- Fotografias completas dependem da existência e validade das leituras referenciadas. Registros antigos sem fotografia só são reconhecidos como completos na competência atual quando cada posição atual tem sua própria leitura comprovada; não são criados serviços retroativos.
- O farol permite selecionar a competência e pesquisar placa, com resumo OK/NOK, última completa e data realizada no mês. Usa a lista de participação **atual** do cadastro de Custos; não afirma reconstruir a composição histórica da frota. Não foi presumido vencimento em um dia fixo ou em 30 dias: o critério aprovado é realização no mês.

## Testes de fluxo

`node scripts/gestao-frota/testar-fluxo-milimetragem.mjs`: cadastro de veículos marcado/não marcado em Custos; todas as placas no Alinhamento; aviso e confirmação técnica; pneus separados; remoção de importadores; seis de sete posições geram NOK e medição do estepe completa OK; histórico por veículo; competência anterior não recebe medições atuais; retirada/retorno à participação preservam histórico e configuração. Execução em navegador isolado e com rede bloqueada, sem alterar produção.

## Correção da abertura e fechamento da medição

A regra original `.modalback.modal-stack` tinha prioridade sobre o posicionamento da adaptação. Ao abrir, a lista desaparecia e o diálogo permanecia fixo, fora do fluxo; a altura do documento era calculada como zero e a área incorporada encolhia para 4 pixels. O mapa estava no DOM, mas cortado na tela.

A adaptação agora prioriza `#modalroot .modalback` no fluxo normal, recusa alturas transitórias abaixo de 64 pixels e sincroniza a rolagem no próximo quadro, após o redimensionamento. O documento só fica visível depois de receber o tema do portal, com envio do tema também no evento load, para evitar o primeiro desenho com o visual antigo. Não limpa cadastros nem medições existentes.

Teste de regressão: `scripts/gestao-frota/testar-abertura-milimetragem.mts`. Exercita as seis configurações de eixos, abre/fecha três vezes em cada tema, verifica a altura real do mapa e da área incorporada, preenche campos e confirma que o cabeçalho antigo não reaparece. Usa somente cadastros sintéticos em navegador isolado, com rede bloqueada.

Na entrada do módulo, ocultar apenas o conteúdo interno ainda deixava o navegador pintar o fundo padrão branco da área incorporada. Agora o próprio iframe começa invisível, com fundo e esquema de cores do portal, e só é exibido após a mensagem `milimetragem-tema-aplicado`, enviada no quadro seguinte à aplicação do CSS. Durante a preparação aparece uma indicação de carregamento sobre o fundo do portal. Trocar o tema não recarrega o documento nem apaga campos.
