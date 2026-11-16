# Elegibilidade, ordenação do farol e listas no tema escuro

Preparação local para avaliação. Nenhum SQL106/107 executado no Supabase nesta etapa; nenhum push ou deploy.

## Farol

- **Dias restantes**: primeiro clique mostra do maior prazo restante aos serviços atrasados; novo clique inverte. A ordenação considera todos os resultados filtrados antes de paginar.
- **Status**: primeiro clique segue Em dia → Vencendo em breve → Atrasado; novo clique inverte esses grupos. Dentro de cada grupo, o maior prazo vem primeiro.
- **Sem registro** permanece no fim em ambos os sentidos, sem presumir uma data ou atraso. Placa desempata os resultados.
- Os cabeçalhos são botões acessíveis por teclado e informam o sentido por `aria-sort` e indicação visual.
- Mantidos os seis meses de calendário e o aviso de **30 dias**, confirmado pelo responsável.

## Aba Veículos

Dentro de Alinhamento e Balanceamento, a aba **Veículos** lista o cadastro efetivo atual, com placa, centro de custo, botão Elegível/Não elegível e última alteração/responsável. Tem os filtros por placa/centro e a paginação existentes, sem rolagem vertical interna da lista.

Para preservar o comportamento anterior, **o padrão é elegível** até ser salva uma escolha. Esse padrão é calculado na leitura, sem inserir dados nem alterar cadastros antigos. O usuário desativa os veículos que não realizam esse serviço. Não foi presumida elegibilidade pelo nome/tipo da placa.

Não elegíveis saem do farol e de seus indicadores, mas permanecem em Veículos. Lançamentos, datas realizadas, NF, custos e histórico não são apagados. Ao reativar, o prazo usa o último serviço conhecido, sem reiniciar a contagem na data da reativação. A elegibilidade vale apenas para alinhamento/balanceamento; não altera milimetragem ou outras atividades.

Cada alteração é confirmada pelo banco antes de atualizar a tela. Em falha de comunicação, é possível reenviar a mesma chave para recuperar o recibo sem duplicar a operação. A interface evita cliques concorrentes e não simula sucesso.

## Banco: novo SQL107

Ordem futura de instalação, a partir do SQL105 já existente: **106_frota_gestao_alinhamento_balanceamento.sql → 107_frota_gestao_elegibilidade_alinhamento.sql**. Não reaplicar instaladores gerais nem 84–105 para instalar esta mudança. Se algum sucessor já existir, conferir o estado antes de reaplicar seu predecessor, que pode substituir funções.

O 107 acrescenta:

- `frota_gestao_pneus_elegibilidade`: eventos imutáveis por veículo, chave idempotente, escolha, sequência, autor/data. Sem UPDATE/DELETE; auditoria após INSERT.
- Índice veículo/sequência para consultar a última escolha, ordenada por uma sequência atribuída sob lock por veículo. Datas/UUIDs não decidem empates de gravações.
- RPC `frota_gestao_salvar_elegibilidade_alinhamento(uuid,uuid,boolean)`: conta ativa e chave exclusivamente no servidor; recibo idempotente; valida veículo disponível no cadastro efetivo.
- A consulta do 106 ganha `elegibilidade_editavel=true` e os campos de elegibilidade/autor/data nos veículos. Não é alterado o registro mestre de veículos, as NFs ou os serviços.
- RLS de leitura para contas ativas; anon sem acesso; authenticated sem INSERT/UPDATE/DELETE/TRUNCATE direto.

Sem o 107, a consulta do 106 permanece utilizável e os botões de elegibilidade ficam desabilitados com orientação explícita. Não há salvamento apenas no navegador apresentado como persistência real.

## Tema escuro

Os selects e suas opções/agrupamentos agora usam as cores semânticas de superfície e texto do tema, com `color-scheme` herdado. A regra fica restrita à estrutura de Gestão da Frota, sem mudar controles dos módulos legados. Mantidos os selects nativos e seu comportamento de teclado.

A lista de unidades foi conferida aberta no navegador: fundo escuro/texto claro no escuro, fundo claro/texto escuro no claro. Contraste medido nas opções: 14,71:1 e 14,33:1, respectivamente.

## Validação

- SQL107 em banco isolado: padrão elegível, desativar/reativar, preservação de serviço/histórico/custos, recibo idempotente, chave reutilizada com outros dados recusada, RLS, bloqueio sem chave de servidor, erro de comunicação e reaplicação.
- Ordenação por dias/status nos dois sentidos, com Sem registro ao fim.
- HTML completo: cliques nos cabeçalhos; escolha persistente de elegibilidade, exclusão do farol, manutenção do histórico e reativação com a mesma data do serviço.
- Regressão dos atalhos Alt + setas/F2, repetição de unidade e integração automática de NF do 106.
- Build/TypeScript e lint dos arquivos alterados. Testes locais não equivalem à homologação em PostgreSQL remoto com conexões independentes.
