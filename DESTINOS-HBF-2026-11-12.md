# Correção de destinos, HBF e filtro do Dashboard

**Ajuste posterior:** o HBF de milimetragem agora consolida por centro de custo, e classificação/tipo são obrigatórios. Consulte `HBF-CENTROS-CLASSIFICACAO-2026-11-12.md`; a referência anterior a uma única linha do serviço foi substituída.

Esta orientação substitui a proposta anterior de grupos de veículos para destinos novos. Implementação local; nenhum SQL executado em produção e sem push/deploy.

## Regra aprovada

- **Cadastrar destino** pede somente nome. A opção aparece no seletor da alocação, ao lado de Placa, Estoque e Milimetragem. Não exige escolher veículos.
- Um destino cadastrado recebe custo pelo próprio nome, com centro de custo escolhido na conferência; não cria placa fictícia, OS de veículo ou lote de estoque. Seu valor entra no custo total, nos centros e fornecedores; não entra na média/contagem/ranking de veículos.
- Milimetragem mantém as parcelas internas por veículo elegível, com centavos conciliados e uma OS por veículo. Essas parcelas geram os custos do Dashboard.
- Na conferência, consulta, Central e PDF HBF, cada item de milimetragem aparece **uma vez**, como Milimetragem, com o valor integral. As 13 colunas continuam preservadas. Havendo várias OS/centros, seus identificadores/nomes são reunidos na célula correspondente, sem somar o serviço novamente.
- A apresentação consolidada não é somada às parcelas: é outra representação dos mesmos valores. Alterações na conta/descrição/categorias são repartidas de volta nas parcelas internas, conservando centavos e totais, inclusive desconto.

## Filtro de destino

Dashboard inclui seletor pesquisável de Destino: Todos, Placa, Estoque, Milimetragem e os nomes cadastrados. Atua nos indicadores, gráficos, compras e histórico. Custos de peças aplicadas continuam identificados pelo destino original Estoque. O saldo de estoque é filtrado pela unidade fiscal e pelo destino, com aviso de que é posição atual.

## Preparação de banco

Novo corretivo manual `supabase/103_frota_gestao_destinos_nominais.sql`, após 102 e seus predecessores. Sequência pendente do banco existente: **101 → 102 → 103**, depois de confirmar 99 revisado e 100. Não reinstalar a base completa sobre produção existente. Não reaplicar os predecessores por cima destes corretivos sem revisão.

103 adapta as funções transacionais existentes: normaliza destino cadastrado apenas por nome; valida identidade do destino e ausência de placa/OS; finalização/edição de destino nominal não criam OS nem lote; o Dashboard passa a projetar o identificador/nome do destino. Helpers ficam privados e as guardas de escrita/conta ativa permanecem. Nenhum cadastro ou lançamento antigo é regravado pelo script. Instalação e reaplicação foram testadas localmente.

As linhas fiscais internas preservam o rateio e recebem metadados de apresentação (`destino_id`, `destino_nome`, `grupo_hbf`). Não há conversão automática de lançamentos antigos ou de grupos anteriores em despesas nominais. Em dados de versões antigas sem esses metadados, não se presume um destino por texto da descrição. Backups locais antigos não recebem SQL novo automaticamente.

O cadastro verifica a capacidade `destinos_nominais` antes de salvar um destino, recusando backend sem 103 em vez de afirmar sucesso. Publicar a interface somente depois de instalar/verificar todas as dependências; o filtro precisa da projeção de 103 para distinguir os destinos corretamente.

## Verificação local

- SQL 102/103 instalados e reaplicados em base sintética, preservando registros anteriores.
- Milimetragem de 100/3: HBF consolidado em uma linha de 100; três custos de 33,34 + 33,33 + 33,33; PDF válido.
- Repartição de desconto/categorias preserva cada líquido e as somas financeiras.
- Destino nominal de 25: finalização sem OS/lote, custo com veículo nulo, filtro próprio, edição versionada e exclusão com retirada do custo.
- Recusa de adulteração e helpers sem EXECUTE para anon/authenticated.
- Regressão de Dashboard e layout HBF com 5/20/40 linhas e texto extenso; 13 colunas, totais e cabeçalhos repetidos.
- Interface de alocação validada em 320, 768, 1366 e 1920 pixels, sem rolagem horizontal.
- HTML completo, sem rede externa: cadastro somente com nome; duas NFs finalizadas pela interface; HBF de milimetragem em uma linha, dois custos de 50 por placa e um custo nominal de 25; filtro alternando o histórico de duas parcelas para um lançamento nominal.
- Campo opcional ausente não é serializado como `undefined`; regressões de edição/exclusão e validação do formulário aprovadas depois dessa correção.
- TypeScript/build Next.js e ESLint aprovados; 11 testes de publicação aprovados. Artefatos/HTML atualizados localmente, sem commit, push, deploy ou alteração do Supabase.

Estas verificações usam bases locais; não comprovam instalação do 103 no Supabase de produção.
