# Pau Brasil · Gestão da Frota

**Atualização de 10/11/2026:** ver [ATUALIZACAO-2026-11-10.md](ATUALIZACAO-2026-11-10.md).
Em banco existente, não executar a instalação completa nem os dados iniciais.
A publicação das telas não instala os SQLs 99/100 e não altera lançamentos.

Painel de custos da frota (NF-e/NFS-e, estoque, OS, HBF e dashboard) com banco **Supabase** compartilhado pela equipe e hospedagem na **Vercel**.

```
navegador ──login──▶ Supabase Auth
    │
    ├─ leituras ─────▶ Supabase (RLS: só usuários ativos)
    └─ /api/rpc ─────▶ função na Vercel ──(+ chave de servidor)──▶ funções frota_gestao_* no Supabase
```

Toda gravação passa pelas funções `frota_gestao_*` do banco, que aplicam as regras fiscais, de estoque e de auditoria. A **chave de servidor** fica só na Vercel. Sem ela, o banco recusa qualquer gravação.

## Estrutura

| Pasta | Conteúdo |
|---|---|
| `supabase/migrations/` | Banco completo: base (perfis, unidades, veículos), SQLs 84–100 do módulo, agendamento, permissões e dados iniciais |
| `supabase/instalacao-completa.sql` | Todas as migrations num arquivo só, para colar no SQL Editor |
| `api/rpc.js` | Função da Vercel que repassa as chamadas com a chave de servidor |
| `public/` | Painel (telas, login, leitor de PDF/OCR das notas) |
| `scripts/` | Ativação das gravações, geração da chave e build |
| `ferramentas/` | Servidor local de desenvolvimento e extração das telas a partir do laboratório |
| `laboratorio/` | HTML original do laboratório offline (referência, não é publicado) |
| `testes/` | Testes do banco (`npm test`) |

## Implantação (uma vez)

### 1. Supabase

1. Crie um projeto em [supabase.com](https://supabase.com) (região São Paulo).
2. Instale o banco, por **uma** das opções abaixo:
   - **SQL Editor:** abra `supabase/instalacao-completa.sql`, cole todo o conteúdo e clique em **Run**.
   - **CLI:** `npx supabase login`, depois `npx supabase link --project-ref <ref-do-projeto>` e por fim `npx supabase db push`.
3. Em **Authentication → Sign In / Providers → Email**, **desligue "Allow new users to sign up"**. Só o administrador cria contas.
4. Em **Authentication → URL Configuration**, coloque o endereço da Vercel em *Site URL* (é usado pelo link de "Esqueci minha senha").
5. Em **Project Settings → API**, anote a *Project URL* e a chave *anon public*.

### 2. Vercel

1. **Add New → Project** e importe este repositório do GitHub.
2. Em **Environment Variables**, cadastre:
   - `SUPABASE_URL`: a Project URL.
   - `SUPABASE_ANON_KEY`: a chave anon public.
   - `FROTA_GESTAO_CHAVE`: gere com `node scripts/gerar-chave.mjs`. **É segredo. Não coloque no GitHub.**
3. Clique em **Deploy**. O build e as configurações já estão em `vercel.json`.

### 3. Liberar gravações

Até este passo o painel funciona **somente leitura**. Abra `scripts/ativar-escritas.sql`, troque `COLE_AQUI_A_CHAVE` pela **mesma** chave da Vercel e `COLE_AQUI_A_EVIDENCIA` por quem conferiu a instalação e a data. Depois rode o arquivo no SQL Editor. O banco guarda só o hash da chave.

### 4. Usuários

1. **Authentication → Users → Add user**: informe o e-mail e uma senha provisória e marque *Auto Confirm User*.
2. **Table Editor → perfis**: na linha do usuário, mude `ativo` para `true` e ajuste o `nome`.
3. Passe a senha provisória para a pessoa. No primeiro acesso, o painel obriga a criar a senha definitiva.

Para tirar o acesso de alguém, mude `ativo` para `false`. Contas novas sempre nascem desativadas.

## Dados iniciais

As migrations já cadastram:
- as unidades Patos e Sumé;
- as Unidades de Negócio 101 a 501;
- os 35 veículos da planilha;
- o almoxarifado de cada unidade;
- as categorias do HBF;
- o plano de contas e as classificações.

Os fornecedores e os novos veículos são cadastrados pela tela **Cadastros**.

## Banco local sem Supabase

No Windows, execute `iniciar-local.cmd` (requer Node.js 20+ e `npm ci`).
Abra http://localhost:3000 e entre com `admin@local.test` / `senha-local-123`.
O banco é criado automaticamente com as migrations e os cadastros iniciais.
Os dados ficam em `.dados/banco/` e são preservados ao reiniciar. Para fazer
backup, pare o servidor e copie a pasta `.dados` inteira. Essa pasta não vai
para o GitHub. O servidor aceita conexões apenas deste computador; a autenticação
local é de desenvolvimento. Para acesso compartilhado online, siga a implantação
Supabase/Vercel acima. A configuração local não cria um banco na nuvem.

## Desenvolvimento

```bash
npm install
npm test        # migrations + regras de acesso + fluxo de NF num Postgres local (PGlite)
npm run local   # painel em http://localhost:3000 com banco persistente em .dados/banco
```

Usuários do ambiente local: `admin@local.test` e `operador@local.test` (este último cai no fluxo de primeiro acesso), ambos com a senha `senha-local-123`.

As telas atuais (`public/js/painel.js`) são compiladas por `ferramentas/gerar-versao-atualizada.mjs`, com os componentes do projeto fonte e os estilos/recursos do HTML aprovado. O banco local não é incluído. O extrator antigo fica apenas como referência histórica; não usá-lo para regenerar esta versão.
