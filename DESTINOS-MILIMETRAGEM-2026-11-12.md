# Milimetragem, destinos e repetição de classificações

**Correção posterior:** a regra de novos destinos e a apresentação do HBF foram substituídas por `DESTINOS-HBF-2026-11-12.md`. Novos destinos são opções por nome, sem placas; apenas Milimetragem tem rateio pelos veículos elegíveis. Este arquivo conserva o registro da proposta anterior.

Implementação local de 12/11/2026. Nenhum SQL executado no Supabase, sem push/deploy e sem alteração de dados reais.

## Operação

1. Cadastros → Veículos → Editar: marcar **Participa do rateio de milimetragem** nos participantes. Nenhum veículo é marcado automaticamente. Só participam os explicitamente marcados com centro 101 (Puxada), 201 (Entrega) ou 301 (Armazém).
2. No item da NF, escolher **Milimetragem** em Destino. O item passa a ter uma parcela por participante, em ordem estável de placa e ID. Cada placa recebe seu centro cadastrado como sugestão, editável na conferência.
3. O custo líquido é repartido em partes iguais em centavos: R$ 100,00 / 3 resulta em 33,34 + 33,33 + 33,33. A quantidade fiscal é distribuída em até seis casas, mantendo a soma original. Quantidade insuficiente para parcelas positivas é recusada com explicação.
4. Não há baixa/entrada de estoque para esse destino: são parcelas por veículo. O HBF mantém as 13 colunas e gera uma linha por placa; a finalização cria/reutiliza uma OS por veículo dentro do lançamento e reconhece seus custos no Dashboard.
5. **Atualizar veículos elegíveis e recalcular** recompõe um grupo antes da confirmação. Cadastros posteriores não reescrevem notas finalizadas ou custos históricos.
6. Cadastros → **Destinos**: informar nome e escolher veículos. Esses novos destinos são grupos de rateio igualitário; não se presume uma nova regra de estoque, departamento sem veículo ou outra estratégia ainda não definida. Placa e Estoque continuam destinos próprios; Milimetragem continua usando a caixa dos veículos.

## Repetição a partir do primeiro item

- Tipo de manutenção/despesa escolhido no primeiro item é aplicado aos itens abaixo.
- Unidade de Negócio e Classificação escolhidas na primeira parcela do primeiro item são aplicadas às parcelas abaixo. Alterações nas demais parcelas/itens são individuais.
- A Unidade de Negócio de uma parcela destinada ao Estoque permanece **Estoque**, até sua aplicação. Não copia o centro operacional de outro item.
- Sugestões automáticas ao escolher uma placa ou grupo não disparam essa repetição: ela exige a escolha explícita do usuário no campo.

## Banco: SQL 102 após 101

Arquivo: `supabase/102_frota_gestao_destinos_milimetragem.sql` (mesmo conteúdo no projeto fonte).

Preflight de metadados, exclusivamente leitura: `supabase/verificacoes/destinos_milimetragem.sql`. O resultado não autoriza instalação; ausência da coluna/função antes de 102 é esperada. Depois da instalação, conferir a coluna booleana, CHECK ampliado e helper privado sem EXECUTE para anon/authenticated.

Sequência de atualização do banco existente, mediante autorização: confirmar 99 revisado e 100 já instalados → instalar/verificar 101 (OBZ) → instalar/verificar 102. Não executar `instalacao-completa.sql` em produção existente. Para base nova, o instalador completo atual vai até 100: complementar com 101 e 102 separados.

102 amplia o CHECK de tipo dos cadastros para `destinos`, acrescenta a projeção de elegibilidade à view existente de veículos e adapta as RPCs de cadastro/validação, sem editar linhas fiscais ou marcar veículos existentes. A view conserva o modelo de permissões existente; não se apresenta como resolvido o aviso anterior de privilégios de proprietário nessa view. Não cria usuários, seeds ou agendamentos. Não modifica as permissões dos módulos antigos, o histórico Gestran nem a ativação 92.

A nova validação de grupos é privada, não executável diretamente por `anon` ou `authenticated`. As RPCs de gravação mantêm conta ativa e chave de servidor. O backend confere os participantes atuais, ordem, placas, quantidades e divisão financeira exata; não aceita apenas o rateio enviado pelo navegador. Um cadastro que mude entre conferência e confirmação pode exigir recalcular o grupo; isso preserva o lançamento em preenchimento e evita gravar sobre um grupo divergente.

O cadastro detecta `destinos_coletivos` na consulta do banco e recusa a gravação dos novos campos antes do SQL 102, impedindo que um backend 98 descarte silenciosamente a marcação e indique sucesso. O script 102 é transacional, reaplicável e interrompe se os trechos de dependências divergirem. O CHECK de tipo substituído continua cobrindo todos os tipos anteriores. Não reaplicar 98–101 depois dele sem revisar a sequência.

O novo campo opcional do plano é `destino_grupo`. As parcelas financeiras persistidas continuam usando destinos físicos `veiculo`/`estoque`; portanto consultas por placa, versionamento, exclusão, OS, HBF e Dashboard conservam o fluxo transacional existente. Nas notas de grupo, editar uma placa individualmente requer voltar à alocação e escolher Placa, saindo do grupo; não alterar o conjunto na prévia HBF e manter o marcador coletivo divergente.

O limite anterior de 100 parcelas por item e de 1 MiB por lançamento permanece. Uma NF muito grande com grupos em muitos itens pode exigir ajuste técnico futuro; não foi removida a proteção de tamanho para fazê-la passar.

## Testes locais

- `scripts/gestao-frota/laboratorio/testar-destinos.mts`: instalação/reaplicação 102, preservação da base, elegibilidade inicial desmarcada, registro dos participantes, recusa de centro não elegível, cadastro de grupo, rateio de 100/3, soma fiscal e financeira, três OS, Dashboard por placa, imutabilidade histórica após cadastro posterior, recusa de grupo divergente e repetição de campos com estoque protegido.
- `scripts/gestao-frota/testar-destinos-interface.mts`: interface real no Edge, rede externa bloqueada, Milimetragem e destino cadastrado, propagação e alteração individual em 320, 768, 1366 e 1920 pixels, sem rolagem horizontal.
- HTML completo recompilado no Edge, sem rede externa: marcação de três veículos e cadastro de um destino pela tela, lançamento manual sintético, seleção Milimetragem, três parcelas e abertura da conferência HBF aprovados.
- TypeScript sem emissão, build Next.js, ESLint dos arquivos envolvidos, regressões de OBZ/unidades/F2/alocação e 11 testes do projeto de publicação aprovados.
- TypeScript, build, lint e regressões das funcionalidades anteriores são verificados localmente. Nenhum teste grava notas fictícias em produção.

O HTML de laboratório é recompilado com 102 no PostgreSQL incorporado. Backups antigos do laboratório não são migrados automaticamente ao restaurar; a tela deve informar a dependência ausente em vez de simular salvamento.
