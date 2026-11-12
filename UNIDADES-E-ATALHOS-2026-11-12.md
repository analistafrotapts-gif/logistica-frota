# Unidades e atalhos na conferência de itens

Preparação local de 12/11/2026, sem SQL, gravações em produção, push ou deploy.

## Unidade de medida

Alterar manualmente o seletor do primeiro item aplica a unidade escolhida a todos os itens existentes. Alterar o segundo ou qualquer outro item modifica somente aquela linha. Uma nova alteração no primeiro volta a aplicar a escolha a todas as linhas. O primeiro é identificado pela posição atual na lista, inclusive depois de uma exclusão.

As unidades importadas de XML/PDF não são uniformizadas ao abrir a tela. A propagação exige a alteração explícita do primeiro seletor pelo usuário. Descrições, quantidades, preços, descontos e acréscimos permanecem intactos.

A atualização ocorre em uma única atualização funcional do estado do lançamento, através de `alterarItensConferidos`, evitando atualizações concorrentes por linha ou perda de dados durante a replicação.

## Teclado

- `Alt + ↑/↓`: sobe/desce mantendo a mesma coluna.
- `Alt + ←/→`: muda de campo dentro da mesma linha.
- `Tab` e `Shift + Tab`: continuam com o comportamento normal.
- `F2` dentro de um campo, ou botão “Ativar navegação por setas (F2)”: alterna um modo em que as setas navegam sem Alt. A indicação na tela informa quando está ativo.
- `Esc`: desativa o modo e devolve o comportamento normal das setas. O botão devolve o foco ao último campo editado.
- Setas sem Alt e digitação de F: continuam disponíveis para texto e seletores.

Foi utilizado Alt, em lugar de manter F pressionado, porque F é uma letra válida na descrição e poderia ser inserida ou repetida durante a navegação. Após relato de Alt sem funcionar no HTML local, o arquivo completo foi testado no Edge automatizado: Alt funcionou nas sete colunas, sem reproduzir o relato. Como alternativa a interferências de teclado/navegador não reproduzidas, foi acrescentado F2 e botão, sem afirmar uma causa comprovada para a falha relatada. O tratamento agora ocorre na captura do evento, antes das ações nativas dos seletores.

As opções são indicadas na própria tela. O tratamento fica restrito à tabela de itens; não altera atalhos de outras páginas. Nas bordas da tabela, mantém o foco sem sair do lançamento. Valor líquido automático e botões de ações não entram nessa navegação de campos editáveis. Pressionar F2 continuamente não alterna o modo repetidamente.

## Validação

`scripts/gestao-frota/testar-unidades-teclado.mts` verifica a alteração atômica das unidades e executa a interface real no Edge, com rede externa bloqueada e dados sintéticos. Cobre importação com unidades diferentes, propagação pelo primeiro, alteração individual do segundo e terceiro, preservação dos totais, navegação nas sete colunas, limites, exclusão de linha intermediária, F, Tab, ativação por F2/botão, restauração do foco e saída por Esc/F2.

TypeScript/build Next.js, ESLint dos arquivos alterados e teste específico aprovados. As fontes compartilhadas são usadas no HTML de laboratório e na preparação dos artefatos do portal. Nenhum novo SQL é necessário para estes dois ajustes; a dependência 101 de Contas de OBZ, da etapa anterior, continua separada e pendente de instalação/publicação.
