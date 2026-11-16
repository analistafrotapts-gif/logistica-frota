# Hodômetro obrigatório — alinhamento e balanceamento

Preparação local para avaliação. Nenhuma instalação do SQL108 no Supabase, commit, push ou deploy nesta etapa.

## Lançamento de NF

- A importação XML (NF-e e NFS-e), PDF e OCR aproveita leituras rotuladas como Hodômetro, Odômetro, Quilometragem ou KM. No XML, são consultadas as informações complementares e descrições, incluindo `infAdProd` da NF-e. No PDF, somente páginas fiscais reconhecidas, ignorando linhas com baixa confiança de OCR e anexos HBF/OS.
- Ao selecionar a classificação e a placa, o campo vazio ainda não editado recebe a leitura encontrada para a placa. Uma leitura sem placa explícita só é sugerida quando há uma única placa alocada e nenhuma placa divergente na nota. Múltiplos valores para a mesma placa ficam para preenchimento manual. Não são usados preços, número da NF ou valores identificados como prazo/próxima troca.
- O valor automático permanece editável; correções e limpeza manual não são sobrescritas. Toda leitura importada deve ser conferida com o original. Layouts não reconhecidos ou texto OCR incerto podem exigir digitação manual.
- Esse complemento de importação não exige SQL adicional ao 108 e não instala funções em produção.
- Ao classificar um item como alinhamento/balanceamento, a alocação mostra **Hodômetro (km) — obrigatório** para cada placa envolvida.
- Uma leitura por veículo nesta NF, guardada em `finalizacao.hodometros[veiculo_id]`. Itens da mesma placa compartilham a leitura fornecida pelo usuário; placas diferentes não recebem cópias.
- Trocar uma placa exige a leitura da placa de destino; não transfere a leitura da anterior. Se a placa de destino já possui uma leitura explicitamente informada nesta NF, essa leitura é reutilizada.
- Destino Estoque/nominal não identifica o veículo de um serviço de alinhamento. Para essa classificação, selecionar uma placa ou corrigir a classificação antes de continuar.
- A conferência bloqueia Concluir alocação e a finalização/edição quando faltar leitura válida. Os dois validadores financeiros do contrato atual repetem essa verificação no banco, inclusive em chamadas diretas.
- A leitura é parte dos dados estruturados preservados pela versão da NF. Não altera quantidade, desconto, rateio, OS ou cálculo financeiro. O HBF mantém suas **13 colunas**, sem acrescentar coluna de hodômetro ao PDF financeiro.

## Módulo de pneus

- Campo obrigatório no lançamento manual e na correção do registro, para a leitura realizada na data do serviço.
- A troca da placa no formulário manual limpa a leitura para evitar atribuí-la automaticamente ao veículo errado.
- Leitura exibida em Lançamentos, no último serviço do Farol e em cada evento do Histórico. Uma correção guarda a leitura anterior e o motivo/responsável, sem alterar a NF nem os custos financeiros.
- As fontes automáticas leem o hodômetro da versão da NF correspondente, mantendo a identidade do registro e seus vínculos de correção.
- **Registros antigos sem leitura mostram “Não informado”.** Não são retroativamente preenchidos com zero, leitura atual ou outro valor presumido. Ao fazer nova correção, informar a leitura real.

## Validação da leitura

Quilômetros inteiros não negativos, até 12 dígitos. Zero é uma leitura explicitamente informada válida; vazio é ausente. Dígitos e separador de milhar brasileiro são aceitos na entrada (`125.000` → `125000`). Frações, letras e negativos são recusados, sem converter silenciosamente `-100` em `100`. A interface mostra `125.000 km`.

Não foi criada regra de comparação com o hodômetro atual do cadastro, nem bloqueio por sequência de leituras de datas diferentes: registros históricos podem ser anteriores à leitura atual, e regras para troca de painel dependeriam de aprovação específica.

## Banco e habilitação

Novo script manual: **`supabase/108_frota_gestao_hodometro_alinhamento.sql`**, após 107 e seus predecessores. Para o módulo de pneus ainda não instalado, a sequência a partir de 105 é **106 → 107 → 108**. Não executar o instalador completo para atualizar a base existente.

- Novo validador privado `frota_gestao_validar_hodometro_alinhamento(jsonb)`, invocado pelos validadores de finalização e edição de NF simplificada. Sem EXECUTE direto para authenticated/anon.
- View de fontes atualizada para expor a leitura por veículo a partir dos dados da NF, com `security_invoker=true`, sem alterar as identidades das fontes históricas.
- Salvamento manual exige e preserva `dados.hodometro`. Registros originais e recibos anteriormente confirmados permanecem preservados.
- Consulta de pneus informa `hodometro_obrigatorio=true` somente depois da instalação completa do 108. A interface e os serviços verificam essa capacidade antes de solicitar novas gravações com alinhamento; não permitem que o backend anterior descarte a informação silenciosamente.
- Não altera linhas antigas nem preenche dados em tabelas preexistentes. Mantém autenticação ativa, chave no servidor, RLS, auditoria e recibos idempotentes dos predecessores.

## Validação local

- SQL108 aplicado sobre base isolada contendo NF e manual anteriores sem leitura: dados físicos preservados, leitura desconhecida mantida.
- Recusa de finalização/edição de NF e manual sem leitura; vazios, negativos, frações e letras recusados.
- NF com duas placas preserva leituras distintas e as apresenta automaticamente no módulo de pneus.
- Correção manual mantém os valores anterior/atual no histórico e não altera custos.
- Leitura zero, normalização de milhar, recibo idempotente, outras classificações sem exigência e reaplicação do script.
- Testes de navegador verificam bloqueios na alocação/manual, dados da NF no módulo de pneus e histórico. Build/TypeScript e lint dos arquivos alterados.

Testes isolados não equivalem à homologação no Supabase real. Os SQLs 106, 107 e 108 continuam preparados para instalação futura autorizada.
