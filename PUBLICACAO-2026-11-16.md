# Atualização do site — 16/11/2026

**Atualização posterior confirmada:** os SQLs 106–108 foram autorizados e instalados na migration `20261116184047_frota_106_108_alinhamento_elegibilidade_hodometro`. Consulte `INSTALACAO-106-108-2026-11-16.md`. O diagnóstico de ausência abaixo registra o estado anterior à instalação.

Publicação no projeto existente `logistica-frota`, domínio `logistica-frota-frota13.vercel.app`, solicitada pelo responsável. Versão de código anterior: `34b66c6fc9c741287e8d007f8ec60bcb0aea75c3`. Não mudar projeto, banco, usuários nem credenciais.

## Incluído

- Navegação entre Gestão de Custos e Política e Gestão de Pneus; lançamentos, farol de seis meses com aviso de 30 dias, histórico e elegibilidade de alinhamento/balanceamento.
- Hodômetro obrigatório por veículo para serviços de alinhamento/balanceamento, com sugestão a partir do XML/PDF/OCR quando reconhecida e edição manual preservada.
- Identificações visuais de placas inspiradas no padrão Mercosul nos cadastros e nas listas de pneus, mantendo os códigos originais.
- Enter confirma a conta do HBF e avança à próxima linha; a conta da primeira linha preenche as seguintes. Alterações nas demais continuam individuais.
- Importar PDF da NF sem reler/substituir campos e baixar NF/HBF no mesmo arquivo, NF completa primeiro, HBF depois. Somente na sessão do navegador, sem upload ao banco.
- Nome `NFC_NUMERO_DDMMAA_FORNECEDOR_VALOR.pdf` ou `NFS_NUMERO_DDMMAA_FORNECEDOR_VALOR.pdf`, usando a emissão e o total do lançamento. Fornecedor em maiúsculas, sem espaços/sublinhados entre suas palavras. Exemplo: `NFS_381_201026_CARLOSWAGNERDELUCENA_1.090,00.pdf`.
- Ajustes locais anteriores de elegibilidade, ordenação do farol e seletores no tema escuro.

## Banco e limitações verificadas

Consulta exclusivamente de leitura ao projeto `fixvhizwcztmvmpykovr`, em 16/11/2026: ainda ausentes `frota_gestao_alinhamentos()`, `frota_gestao_salvar_alinhamento(uuid,text,jsonb,text,boolean)`, `frota_gestao_salvar_elegibilidade_alinhamento(uuid,uuid,boolean)` e `frota_gestao_validar_hodometro_alinhamento(jsonb)`.

Esta publicação de código **não instala SQL**. Os arquivos manuais preparados são **106 → 107 → 108**, após os 101–105 anteriormente instalados. Não executar o instalador completo sobre o banco existente. Instalação dessas funções depende de autorização própria, revisão dos predecessores, validação de ACL/RLS e plano de recuperação.

Até a instalação/verificação, o módulo de pneus informa configuração pendente. Notas classificadas como alinhamento/balanceamento não são finalizadas por esta versão sem o contrato de hodômetro do SQL108. Não são simulados registros nem sucesso. As consultas antigas e operações que não dependem das funções novas conservam o transporte autenticado existente.

As novas rotinas da ponte seguem uma lista fechada; a chave de servidor continua fora do cliente. Não alterar `public/config.js` de produção: é gerado pelas variáveis já existentes na Vercel. O laboratório e o PGlite não integram o deploy.

## Verificações

- TypeScript e lint dos componentes alterados aprovados na origem.
- Build Next e geração do HTML/pacote concluídos nas alterações locais; pacote estático recompilado para esta publicação.
- 11 testes de publicação aprovados, em banco isolado. Esses testes cobrem o instalador base até 100; não comprovam instalação de 106–108 em produção.
- Testes isolados de junção NF/HBF e reconhecimento de hodômetro aprovados; ordem, todas as páginas, orientação, limites, conteúdo inválido e preservação dos originais.
- Testes anteriores no navegador: navegação por Enter, propagação da primeira conta, placas em ambos os temas, hodômetro, anexação manual/automática e nome do download.
- Pacote compilado sem banco local, operador sintético e referências a credenciais privadas verificadas.

Após publicar, verificar `/versao.json`, hashes de JS/CSS/recursos, configuração pública preservada, login e rejeição da API sem autenticação. Não criar/editar/excluir NF real para testar o deploy. Os testes locais não substituem a validação autenticada no portal.

## Recuperação do código

Se houver regressão, promover o deploy anterior `34b66c6` na Vercel. Isso reverte o código; não reverte lançamentos realizados por usuários e não é backup do banco.
