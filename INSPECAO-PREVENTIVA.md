# Destino Inspeção Preventiva

Preparação original local. Atualização em 24/11/2026: SQLs 109 → 110 instalados no Supabase existente com preservação dos registros, conforme [PUBLICACAO-2026-11-24.md](PUBLICACAO-2026-11-24.md).

No cadastro de veículos, a participação na Inspeção Preventiva é independente da milimetragem. A lista inicial aprovada contém 17 placas de Patos e 4 de Sumé, declaradas em `src/lib/frota/gestao/inspecao-preventiva.ts` e no SQL 109. A lista apenas marca veículos já cadastrados na unidade correspondente; não cria placas nem muda sua unidade ou centro de custo. Uma marcação explícita, inclusive desmarcar, prevalece sobre essa lista inicial e sobre a reaplicação do SQL. Novas placas podem participar pelo checkbox.

Na alocação, selecione o destino **Inspeção Preventiva**. A unidade inicial é a unidade fiscal informada no lançamento, podendo ser alterada para Patos/Sumé no seletor específico do item. As placas elegíveis da unidade escolhida aparecem automaticamente nas parcelas. A unidade fiscal da NF não é alterada por esse seletor. Não confundir Patos/Sumé com os centros de custo 101/201/301/401/501.

O valor líquido e a quantidade fiscal são distribuídos igualmente, respeitando duas casas para dinheiro e seis para quantidade. Diferenças residuais vão às primeiras placas em ordem alfabética, com diferença máxima de R$ 0,01. Nenhum veículo elegível, unidade ausente, cadastro alterado, grupo adulterado ou rateio divergente impede a finalização. Atualize os participantes e confira novamente se o cadastro mudar.

O tipo de manutenção continua sendo escolhido pelo usuário: o nome do destino não força preventiva. Classificação e tipo continuam obrigatórios. O dashboard recebe cada parcela por veículo, com filtro próprio de destino. O HBF segue a apresentação coletiva existente: uma linha por item/centro de custo, sem multiplicar o total; os registros financeiros conservam as parcelas por placa e uma OS por veículo. Uma edição substitui os custos vigentes e preserva a versão anterior no histórico. Alterar a elegibilidade do cadastro não reescreve notas finalizadas.

Não há agendamento quinzenal automático; a frequência informada descreve a operação, e cada serviço é registrado pelo lançamento da sua NF.

## Banco e instalação posterior

**Instalação existente com 108 verificado:** revisar e executar manualmente apenas `supabase/109_frota_gestao_inspecao_preventiva.sql`, após backup e os controles de implantação já documentados. Não reaplicar SQLs anteriores indiscriminadamente: eles podem substituir funções mais recentes.

**Instalação nova:** sequência `92 → 84 → 85 → 86 → 87 → 88 → 89 → 90 → 91 → 95 → 96 → 97 → 98 → 99 revisado → 100 → 101 → 102 → 103 revisado → 104 → 105 → 106 → 107 revisado → 108 → 109`. SQLs 93/94 são de outro fluxo e não integram esta instalação. Confirmar dependências físicas do portal pelo preflight existente. A instalação não libera a chave de escrita do módulo.

O SQL 109 é transacional, verifica o predecessor 108, acrescenta uma coluna à view do módulo preservando seu filtro vigente de exclusões, modifica a normalização de cadastro para conservar a nova flag e amplia o validador interno do rateio. Não altera tabelas legadas nem registros fiscais. Não acrescenta grants operacionais ou libera EXECUTE dos validadores internos. A view mantém o modelo de acesso anterior, sem alegar que seu comportamento de segurança foi redesenhado nesta alteração.

A interface consulta a capacidade `inspecao_preventiva` no contrato de cadastros. Sem essa capacidade, mostra configuração pendente, desabilita o destino/checkbox e recusa seu salvamento. As chamadas diretas de finalização/edição continuam sujeitas à autenticação, chave de ativação e validação financeira existentes. O SQL também verifica o grupo, a unidade, as placas e os valores, sem depender dos botões.

Consultas de leitura para conferência após instalação:

```sql
select column_name, data_type from information_schema.columns
where table_schema='public' and table_name='frota_gestao_veiculos'
and column_name in ('milimetragem','inspecao_preventiva');

-- Executar com sessão autenticada ativa: owner sem auth.uid() não representa o usuário.
select public.frota_gestao_listar_cadastros()->>'inspecao_preventiva' as capacidade;
select o.nome, v.placa, v.centro_custo, v.inspecao_preventiva
from public.frota_gestao_veiculos v join public.operacoes o on o.id=v.operacao_id
where v.inspecao_preventiva order by o.nome,v.placa;

select r, has_function_privilege(r,
 'public.frota_gestao_validar_destinos_coletivos(jsonb)','execute') as executa
from (values ('anon'),('authenticated')) x(r);
-- Esperado: false para ambos. O validador é chamado pelas funções autorizadas.
```

Não concluir que existem 21 participantes em produção sem consultar os cadastros reais: placas ausentes, unidade divergente, exclusões e marcações explícitas podem mudar a contagem. A homologação deve conferir a lista antes de lançar a primeira nota.

## Validação local

`scripts/gestao-frota/laboratorio/testar-inspecao-preventiva.mts` executa os scripts reais em PostgreSQL PGlite isolado, com dados sintéticos. Verifica 17/4 participantes, preservação de veículos legados, reaplicação, checkbox independente, centavos, finalização/OS, reenvio idempotente, HBF, dashboard, edição de unidade, adulteração e ACL do validador. Isso não equivale à homologação no Supabase de produção.
