-- Dados iniciais da operação: unidades, centros de custo, veículos da planilha
-- fornecida e cadastros mínimos do fluxo de NF. Pode ser reaplicado sem duplicar.

insert into public.operacoes (nome) values ('Patos'), ('Sumé')
on conflict (nome) do nothing;

-- Unidades de Negócio (centros de custo) usadas pelas telas de alocação.
insert into public.frota_centros_custo (codigo, nome) values
  ('101', 'Puxada'),
  ('201', 'Entrega'),
  ('301', 'Armazém'),
  ('401', 'Vendas'),
  ('501', 'Administrativo')
on conflict (codigo) do nothing;

insert into public.veiculos (placa, operacao_id, centro_custo)
select p.placa, o.id, p.centro_custo
from (values
  ('TOT4F49', 'Patos', '201'),
  ('TOT4F19', 'Patos', '201'),
  ('TOT4F59', 'Patos', '201'),
  ('TOU7F79', 'Patos', '201'),
  ('RLS8A29', 'Sumé', '201'),
  ('RLR8F59', 'Patos', '201'),
  ('RLR8F99', 'Patos', '201'),
  ('RLR8D79', 'Patos', '201'),
  ('RLU6A66', 'Patos', '201'),
  ('RLX6B97', 'Patos', '201'),
  ('RLU6B06', 'Patos', '201'),
  ('RLU6A96', 'Patos', '201'),
  ('RLX7E88', 'Patos', '201'),
  ('RLU6A86', 'Patos', '201'),
  ('SKZ7H28', 'Patos', '201'),
  ('SKZ7H38', 'Sumé', '201'),
  ('SKZ8I17', 'Sumé', '201'),
  ('SKZ8I57', 'Sumé', '201'),
  ('SLB3G16', 'Patos', '201'),
  ('SLB3J86', 'Patos', '201'),
  ('OGE4260', 'Patos', '101'),
  ('OFG6240', 'Patos', '101'),
  ('QSA7H32', 'Patos', '101'),
  ('QFS4H61', 'Patos', '101'),
  ('QFS4H71', 'Sumé', '101'),
  ('QFS3I31', 'Patos', '101'),
  ('QFS3H81', 'Sumé', '101'),
  ('RLR0B95', 'Patos', '101'),
  ('QFT5743', 'Patos', '101'),
  ('SKY5B20', 'Patos', '101'),
  ('EMP0002', 'Sumé', '301'),
  ('EMP0003', 'Patos', '301'),
  ('EMP0004', 'Patos', '301'),
  ('EMP0005', 'Sumé', '301'),
  ('EMP0006', 'Patos', '301')
) as p(placa, unidade, centro_custo)
join public.operacoes o on o.nome = p.unidade
on conflict (placa) do nothing;

insert into public.frota_gestao_locais (operacao_id, nome)
select id, 'Almoxarifado' from public.operacoes
on conflict (operacao_id, nome) do nothing;

-- Uma categoria por coluna do relatório HBF.
insert into public.frota_gestao_categorias (codigo, nome, coluna_hbf) values
  ('SER', 'Serviços', 'servicos'),
  ('PEC', 'Peças', 'pecas'),
  ('LAV', 'Lavagem', 'lavagem'),
  ('PNE', 'Pneus', 'pneus'),
  ('OLE', 'Óleo e lubrificantes', 'oleo_lubrificante')
on conflict (codigo) do nothing;

-- Plano de contas do fluxo de NF: mesmas contas cadastradas pelo SQL 98.
insert into public.frota_gestao_contas (codigo, nome)
select dados->>'codigo', dados->>'nome' from public.frota_gestao_cadastros where tipo = 'contas'
on conflict (codigo) do nothing;
