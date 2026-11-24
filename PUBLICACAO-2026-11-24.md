# Atualização de destinos e Milimetragem — 24/11/2026

Pacote autorizado para publicação no portal existente, incluindo instalação dos SQLs **109 → 110**. Não utilizar o instalador completo nem dados iniciais no banco existente.

## Entregas

- Destino **Inspeção Preventiva** com seleção independente no cadastro, participantes por Patos/Sumé, rateio em centavos, OS por veículo, HBF agrupado por centro e custos por placa.
- Destino **Serviços Elétricos** para Entrega de Patos. QSA5A52/QSA5A62 ficam fora da seleção inicial; a participação explícita pode ser editada. Checkbox independente das outras marcações.
- Filtros dos destinos no dashboard e preservação das versões financeiras após edição.
- Card **Milimetragem** em Política e Gestão de Pneus, cadastro técnico vinculado aos participantes do cadastro de Custos, pneus em tela própria, histórico e farol mensal. OK exige todas as posições, incluindo estepes. Correções de abertura do mapa do veículo e de carregamento do tema.

**Limitação da Milimetragem:** configuração técnica, pneus e medições dessa adaptação continuam no armazenamento local do navegador. O cadastro base é consultado do portal. Publicar a tela não transforma esses dados em registros compartilhados no Supabase. Conservar os backups locais; não confundir esse controle com o rateio financeiro de milimetragem já existente.

## Instalação confirmada no banco

Projeto `logistica-frota`, referência `fixvhizwcztmvmpykovr`.
Migration aplicada: **20261124165840_frota_109_110_inspecao_servicos_eletricos**.

- Dez hashes de funções predecessoras e a definição da view coincidiram com o PostgreSQL isolado.
- 109 e 110 executados em uma transação, com limites de espera/execução, verificação de estado inicial e de hashes finais.
- As **40 tabelas públicas** tiveram suas linhas protegidas durante a comparação de contagens/hashes antes e depois. Nenhuma linha fiscal, de estoque, cadastro ou custo foi modificada pela instalação.
- Preservados **45 lançamentos e 3 edições**. Não criamos NF ou movimentação de teste em produção.
- ACL/RLS, políticas e configurações de execução das funções existentes preservadas. Somente cinco corpos de funções e a definição da view de veículos foram atualizados. Nenhuma credencial, variável da Vercel ou configuração de ativação foi alterada.
- Consulta real com papel `authenticated` e contexto de perfil ativo: contrato `cadastros-01`, capacidades dos dois destinos habilitadas, **46 veículos** disponíveis.
- Participantes confirmados: **Inspeção: 17 Patos e 4 Sumé; Serviços Elétricos: 17 Patos e 0 Sumé**.
- Os validadores internos continuam sem EXECUTE para anon/authenticated. Consultar/listar e salvar cadastros mantêm as permissões anteriores; gravações continuam exigindo o servidor autorizado.

Contagens/hashes demonstram preservação durante esta instalação; não são backup e não comprovam restauração integral.

## Validação

- Build e TypeScript do projeto de origem e lint dos arquivos modificados aprovados na preparação.
- SQLs reais em PGlite isolado: lista, exceções, unidade/centro, parcelas, reaplicação, reenvio idempotente, edição, OS, HBF, dashboard, adulteração e ACL.
- Instalador transacional completo validado primeiro no banco isolado.
- Navegador isolado: destinos em celular/desktop, placas automáticas, classificação/tipo obrigatórios, edição das marcações e retirada ao mudar o centro. HTML completo com rede bloqueada.
- `npm test` do pacote de publicação: **11 testes aprovados**. `npm run build` aprovado. As verificações locais não equivalem a lançar uma NF real no portal.

## Segurança existente

O advisor continua indicando a view `frota_gestao_veiculos` como [security definer](https://supabase.com/docs/guides/database/database-linter?lint=0010_security_definer_view), conforme o comportamento anterior e seu filtro de usuário ativo. Continua também o aviso de [senhas vazadas desabilitado](https://supabase.com/docs/guides/auth/password-security#password-strength-and-leaked-password-protection). Não foram alterados Auth nem o modelo de acesso legado nesta atualização. O total de funções SECURITY DEFINER executáveis por autenticados permanece em 60; nenhum novo EXECUTE foi concedido.

## Conferência após deploy

Versão esperada em `/versao.json`: `2026-11-24-destinos-milimetragem`. Conferir hashes dos arquivos JS/CSS/PDF, tela de login e recusa de `/api/rpc` sem autenticação. Após entrar, atualizar o navegador e verificar Cadastros → Veículos, Lançar NF → Alocação e os filtros do Dashboard.

Para recuperação da interface, é possível retornar o deploy anterior na Vercel; isso não desfaz operações realizadas posteriormente. Não remover históricos nem reaplicar SQLs antigos para tentar desfazer esta atualização. Se houver regressão financeira, interromper novos lançamentos e diagnosticar antes de modificar dados.
