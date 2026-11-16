# NF e HBF em um único PDF

Implementação local na tela de conferência do HBF. Não executa SQL, não armazena arquivos no banco e não finaliza lançamentos.

- **NF/HBF anexado:** prepara um arquivo com todas as páginas do PDF da NF, seguidas de todas as páginas do HBF atual. Preserva os tamanhos e orientações originais, sem transformar as páginas em imagens.
- Nome padrão: `NFC_NUMERO_DDMMAA_FORNECEDOR_VALOR.pdf` para peças e `NFS_NUMERO_DDMMAA_FORNECEDOR_VALOR.pdf` para serviços. Exemplo: `NFC_101881_101126_GOTEMBURGO_2.052,60.pdf`. Usa a data de emissão e o valor total atual do lançamento, com milhar e centavos brasileiros. O fornecedor é o nome completo informado na tela, em maiúsculas, sem acentos e com espaços removidos (sem sublinhados entre as palavras do fornecedor); não presume apelidos comerciais. NFS-e reconhecida e lançamentos inteiramente em unidades/colunas de serviço recebem NFS; os demais recebem NFC.
- O PDF utilizado para importar a NF é reaproveitado automaticamente. Arquivos XML não são convertidos em uma representação fiscal inventada: nesse caso, é necessário anexar o PDF correspondente.
- **Importar NF:** abre o seletor e valida o PDF (até 20 MB e 30 páginas, sem senha). Após a validação, aparece a confirmação com o nome do arquivo. Não executa nova interpretação nem substitui dados conferidos.
- O PDF anexado manualmente permanece disponível ao voltar entre as etapas do lançamento. Uma nova importação de nota limpa esse anexo. Fechar/recarregar a página encerra a sessão do arquivo; não há armazenamento permanente.
- A junção usa o mesmo HBF gerado pelos botões atuais, com as mesmas 13 colunas, contas, descontos, totalizações e marcações de conferência. A conciliação financeira continua obrigatória para baixar.
- Sem PDF, o botão combinado fica desabilitado. Arquivos inválidos não substituem um anexo válido anterior.
- Todas as páginas do PDF selecionado são preservadas. Se ele já contiver um HBF antigo, esse HBF também estará presente; selecionar o PDF somente da NF evita duplicação. Não se removem páginas do original por inferência.

## Verificação

`scripts/gestao-frota/testar-pdf-anexo.mts`: duas páginas de NF e três de HBF, ordem do texto, retrato/paisagem, arquivo original intacto, conteúdo corrompido, tamanho e limite de páginas. Somente PDFs sintéticos em memória.

Teste de navegador isolado: botão bloqueado para XML sem PDF; importação inválida recusada; confirmação após PDF válido; anexo preservado ao voltar; download do conjunto com NF antes do HBF; baixar não finaliza o lançamento. Nenhuma chamada ao Supabase.
