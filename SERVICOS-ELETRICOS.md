# Destino Serviços Elétricos

Preparação original local. Atualização em 24/11/2026: SQLs 109 → 110 instalados no Supabase existente com preservação dos registros, conforme [PUBLICACAO-2026-11-24.md](PUBLICACAO-2026-11-24.md).

O cadastro de veículos contém uma marcação própria **Participa do rateio de Serviços Elétricos (Entrega de Patos)**. A seleção inicial considera os veículos cadastrados no centro **Entrega 201**, na unidade ativa **Patos**, exceto **QSA5A52** e **QSA5A62**. Nenhuma placa é criada automaticamente.

A marcação explícita prevalece sobre o padrão, inclusive uma desmarcação. As duas exceções começam desmarcadas; podem ser incluídas posteriormente pelo checkbox, se houver uma mudança operacional deliberada. Veículos de outra unidade ou centro não podem participar. Mover um cadastro para fora de Entrega de Patos o retira do grupo; isso não reescreve notas já finalizadas. Milimetragem e Inspeção Preventiva mantêm seus controles independentes.

Na alocação de custos, o destino **Serviços Elétricos** carrega os participantes de Entrega de Patos, independentemente da unidade fiscal da NF. Esta não é modificada. Se a unidade Patos estiver ausente/ambígua, ou não houver participantes, a tela apresenta erro e não presume placas. O botão de atualizar elegíveis refaz o grupo com o cadastro atual. Classificação e tipo de manutenção continuam obrigatórios e selecionáveis, sem inferir preventiva ou corretiva pelo destino.

O valor líquido e a quantidade fiscal são divididos igualmente entre os participantes; resíduos seguem a ordem das placas, com diferença máxima de um centavo entre os valores. O HBF usa a apresentação coletiva existente por item/centro de custo, mantendo o total. Custos, dashboard e OS mantêm parcelas por veículo. O dashboard tem filtro específico de Serviços Elétricos. Edições recalculam os custos vigentes e preservam versões anteriores.

## Instalação posterior

Em instalação existente, confirmar **109** e seus predecessores e então instalar manualmente **110_frota_gestao_servicos_eletricos.sql**. Não reaplicar scripts antigos indiscriminadamente, pois podem substituir validadores mais recentes. As consultas de preflight, os cuidados de backup e os controles de ativação existentes continuam necessários.

Instalação nova: **92 → 84 → 85 → 86 → 87 → 88 → 89 → 90 → 91 → 95 → 96 → 97 → 98 → 99 revisado → 100 → 101 → 102 → 103 revisado → 104 → 105 → 106 → 107 revisado → 108 → 109 → 110**. SQLs 93/94 são de outro fluxo.

O SQL 110 é transacional e reaplicável. Acrescenta uma coluna à view do módulo preservando a definição anterior, inclusive exclusões. Ajusta a normalização do cadastro, anuncia a capacidade `servicos_eletricos` e amplia o validador interno. Não atualiza tabelas legadas, notas, estoque ou custos. Os validadores permanecem sem EXECUTE para anon/authenticated; escritas continuam passando pelas funções autorizadas e pela chave do servidor. Nenhuma permissão antiga é ampliada.

Sem a capacidade confirmada pelo banco, a interface desabilita destino e checkbox, informa configuração pendente e recusa seu salvamento. A instalação não ativa a chave de escrita.

Consultas de leitura após instalação, usando sessão autenticada ativa para as consultas do módulo:

```sql
select column_name,data_type from information_schema.columns
where table_schema='public' and table_name='frota_gestao_veiculos'
and column_name='servicos_eletricos';
select public.frota_gestao_listar_cadastros()->>'servicos_eletricos' as capacidade;
select v.placa,v.centro_custo,o.nome,v.servicos_eletricos
from public.frota_gestao_veiculos v join public.operacoes o on o.id=v.operacao_id
where v.servicos_eletricos order by v.placa;
select r,has_function_privilege(r,
 'public.frota_gestao_validar_destinos_coletivos(jsonb)','execute') as executa
from (values ('anon'),('authenticated')) x(r);
-- Esperado: false para ambos os papéis. Conferir a lista real antes de usar.
```

## Testes isolados

- `scripts/gestao-frota/laboratorio/testar-servicos-eletricos.mts`: scripts reais em PGlite, dados sintéticos, instalação/reaplicação, defaults/exceções, unidade e centro, marcações, parcelas, OS/HBF/dashboard, edição, reenvio e recusa de adulteração.
- `scripts/gestao-frota/testar-servicos-eletricos-interface.mts`: componente real no navegador, telas estreita/larga, carregamento de Patos mesmo com NF de Sumé, placas, tipo e classificação obrigatórios.

Os testes locais não confirmam a situação do banco de produção nem substituem sua homologação.
