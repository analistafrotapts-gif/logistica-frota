# Campos obrigatórios e milimetragem por centro

Preparação local de 12/11/2026. Sem SQL no Supabase, alteração de registros reais, commit, push ou deploy.

## Obrigatoriedade

A alocação exige tipo de manutenção/despesa (Preventivo, Corretivo ou Contas de OBZ) em cada item e classificação não vazia em cada parcela. Texto com apenas espaços é recusado. Os campos são identificados como obrigatórios e os erros indicam o item pendente. Digitar no campo de busca sem selecionar uma classificação não confirma a escolha.

A validação é repetida no encerramento e nos serviços de conferência/finalização/edição. O novo SQL 104 repete a regra nos dois validadores transacionais, cobrindo chamadas diretas. Os itens de estoque também precisam de classificação e tipo; sua unidade continua Estoque até aplicação. A repetição explícita pelo primeiro item continua válida; não foi inventado um preenchimento padrão para satisfazer a regra.

## HBF por centro

A milimetragem é apresentada por item fiscal e centro de custo. O HBF soma as parcelas de veículos desse centro; não divide o valor novamente entre os centros. As dez parcelas de R$ 10,00 do exemplo geram:

| Centro | Veículos | Linha do HBF |
| --- | ---: | ---: |
| Armazém 301 | 2 | R$ 20,00 |
| Puxada 101 | 3 | R$ 30,00 |
| Entrega 201 | 5 | R$ 50,00 |

O Dashboard conserva R$ 10,00 por veículo. A soma das linhas do HBF continua R$ 100,00. Os centavos residuais são distribuídos primeiro entre veículos; cada centro recebe a soma exata dessas parcelas. Quantidades, descontos e as 13 colunas são preservados.

Conta/descrição/valores editados em uma linha consolidada afetam apenas as parcelas daquele item e centro, sem alterar os outros grupos. As OS de cada grupo aparecem na célula da linha correspondente. Centro sem participante não gera linha vazia.

## Dependências e limites

Preparado `supabase/104_frota_gestao_classificacao_obrigatoria.sql`, após 103 e seus predecessores. Para atualizar o banco existente, confirmar 99 revisado/100 e instalar/verificar os pendentes **101 → 102 → 103 → 104**, mediante autorização. Não reaplicar instalação completa nem scripts anteriores sobre produção existente.

104 cria um helper privado e adapta os validadores, sem atualizar dados ou liberar escritas. Mantém RLS/grants/guardas operacionais. É transacional, reaplicável e interrompe em dependências divergentes. Lançamentos antigos sem classificação permanecem preservados; para salvar uma nova edição, será necessário completar os campos exigidos.

A consolidação por centro é do renderizador/consulta; não regrava o histórico financeiro. O HTML local incorpora o SQL no PostgreSQL isolado. Backups de versões anteriores do laboratório não recebem o novo SQL automaticamente.

## Testes

- `scripts/gestao-frota/laboratorio/testar-classificacao-centros.mts`: bloqueios no formulário/serviços sem enviar RPC, rejeição em chamadas diretas de finalização e edição, espaços em branco, instalação/reaplicação 104 preservando NF; dez custos de 10 e HBF 20/30/50; edição de um grupo sem mudar os demais.
- `scripts/gestao-frota/testar-destinos-interface.mts`: avanço bloqueado sem ambos os campos e com apenas tipo preenchido; preenchimento válido libera a próxima etapa; larguras 320/768/1366/1920 sem rolagem horizontal.
- Regressões de destinos nominais, edição e exclusão; layout PDF de 5/20/40 linhas e texto extenso, com 13 colunas e paginação.
- TypeScript, build e lint verificados localmente.
- HTML completo recompilado: avanço recusado sem os campos, classificação preenchida pelo usuário, HBF com três linhas 20/30/50, seleção de conta por centro, finalização pela interface e dez custos de 10 confirmados no banco local.
- Onze testes do projeto de publicação aprovados. As cópias do HTML em Downloads e `laboratorio/` foram atualizadas.

Testes locais não equivalem à instalação/verificação no Supabase de produção.
