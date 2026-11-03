// Login no Supabase e acesso aos dados para as telas do painel (window.__frota).
(() => {
  const config = window.__config ?? {};
  const raiz = () => document.getElementById('formulario');
  let cliente;
  let perfilAtual = null;

  function tela(html) {
    raiz().innerHTML = `<div class="acesso">${html}</div>`;
    return raiz().querySelector('form');
  }

  function escapar(texto) {
    return String(texto).replace(/[&<>"']/g, (c) => `&#${c.charCodeAt(0)};`);
  }

  function aviso(form, mensagem, tipo = 'erro') {
    form.querySelector('[role=status]').innerHTML = mensagem ? `<p class="acesso-${tipo}">${escapar(mensagem)}</p>` : '';
  }

  function aguardarEnvio(form, acao) {
    return new Promise((resolver) => {
      form.addEventListener('submit', async (evento) => {
        evento.preventDefault();
        const botao = form.querySelector('button[type=submit]');
        botao.disabled = true;
        aviso(form, '');
        try {
          const resultado = await acao(new FormData(form));
          if (resultado !== false) resolver(resultado);
        } catch (erro) {
          aviso(form, erro?.message ?? String(erro));
        } finally {
          botao.disabled = false;
        }
      });
    });
  }

  async function entrar() {
    const form = tela(`
      <h1>Gestão da Frota</h1>
      <form>
        <label>E-mail<input name="email" type="email" autocomplete="username" required></label>
        <label>Senha<input name="senha" type="password" autocomplete="current-password" required></label>
        <button type="submit">Entrar</button>
        <button type="button" class="acesso-link" data-esqueci>Esqueci minha senha</button>
        <div role="status"></div>
      </form>`);
    form.querySelector('[data-esqueci]').onclick = async () => {
      const email = form.elements.email.value.trim();
      if (!email) return aviso(form, 'Informe o e-mail para receber o link de nova senha.');
      const { error } = await cliente.auth.resetPasswordForEmail(email, { redirectTo: location.origin });
      aviso(form, error ? error.message : 'Se o e-mail estiver cadastrado, você receberá um link para criar nova senha.', error ? 'erro' : 'ok');
    };
    await aguardarEnvio(form, async (dados) => {
      const { error } = await cliente.auth.signInWithPassword({ email: dados.get('email'), password: dados.get('senha') });
      if (error) throw new Error(error.message === 'Invalid login credentials' ? 'E-mail ou senha incorretos.' : error.message);
    });
  }

  async function definirSenha(titulo) {
    const form = tela(`
      <h1>${escapar(titulo)}</h1>
      <form>
        <p>Crie sua senha definitiva (mínimo de 8 caracteres).</p>
        <label>Nova senha<input name="senha" type="password" autocomplete="new-password" minlength="8" required></label>
        <label>Repita a senha<input name="confirmacao" type="password" autocomplete="new-password" minlength="8" required></label>
        <button type="submit">Salvar senha</button>
        <div role="status"></div>
      </form>`);
    await aguardarEnvio(form, async (dados) => {
      if (dados.get('senha') !== dados.get('confirmacao')) throw new Error('As senhas não conferem.');
      const { error } = await cliente.auth.updateUser({ password: dados.get('senha') });
      if (error) throw new Error(error.message);
      const confirmacao = await cliente.rpc('perfil_confirmar_senha_definitiva');
      if (confirmacao.error) throw new Error(confirmacao.error.message);
    });
  }

  async function carregarPerfil() {
    const { data: { user } } = await cliente.auth.getUser();
    if (!user) return null;
    const { data, error } = await cliente.from('perfis').select('id,nome,ativo,senha_provisoria').eq('id', user.id).maybeSingle();
    if (error) throw new Error(error.message);
    if (!data) throw new Error('Seu usuário não tem perfil no painel. Procure o administrador.');
    return data;
  }

  async function token() {
    const { data } = await cliente.auth.getSession();
    return data.session?.access_token;
  }

  async function iniciar() {
    if (!config.url || !config.chave) throw new Error('Painel sem SUPABASE_URL/SUPABASE_ANON_KEY. Configure as variáveis na Vercel e refaça o deploy.');
    cliente = window.supabase.createClient(config.url, config.chave, { auth: { flowType: 'pkce' } });
    let recuperacao = false;
    cliente.auth.onAuthStateChange((evento) => {
      if (evento === 'PASSWORD_RECOVERY') recuperacao = true;
      if (evento === 'SIGNED_OUT' && perfilAtual) location.reload();
    });
    // Aguarda a troca do código do link de e-mail (?code=...) antes de decidir a tela.
    await cliente.auth.getSession();
    if (location.search.includes('code=')) history.replaceState(null, '', location.pathname + location.hash);
    for (;;) {
      perfilAtual = await carregarPerfil();
      if (!perfilAtual) { await entrar(); continue; }
      if (recuperacao) { await definirSenha('Nova senha'); recuperacao = false; continue; }
      if (perfilAtual.senha_provisoria) { await definirSenha('Primeiro acesso'); continue; }
      if (!perfilAtual.ativo) {
        tela('<h1>Acesso não liberado</h1><form><p>Sua conta ainda não foi liberada ou foi desativada. Peça ao administrador para ativar seu acesso.</p><button type="submit">Sair</button><div role="status"></div></form>')
          .addEventListener('submit', (e) => { e.preventDefault(); sair(); });
        return new Promise(() => {});
      }
      raiz().textContent = '';
      return perfilAtual;
    }
  }

  async function chamar(nome, params = {}) {
    try {
      const resposta = await fetch('/api/rpc', {
        method: 'POST',
        headers: { 'Content-Type': 'application/json', Authorization: `Bearer ${await token()}` },
        body: JSON.stringify({ nome, params }),
      });
      if (resposta.status === 401) return { data: null, error: { code: '42501', message: 'Sessão expirada. Recarregue a página e entre novamente.' } };
      return await resposta.json();
    } catch {
      return { data: null, error: { message: 'Falha de comunicação com o servidor.' } };
    }
  }

  // Lê uma tabela inteira (respeitando o RLS), em páginas, na ordem da primeira coluna.
  async function selecionar(tabela, colunas, filtro, { ordem, decrescente = false, limite } = {}) {
    const coluna = ordem ?? colunas.split(',')[0];
    async function lerPaginas(valores) {
      const linhas = [];
      const pagina = 1000;
      for (let inicio = 0; ; inicio += pagina) {
        const fim = limite ? Math.min(inicio + pagina, limite) - 1 : inicio + pagina - 1;
        let consulta = cliente.from(tabela).select(colunas).order(coluna, { ascending: !decrescente }).range(inicio, fim);
        if (valores) consulta = consulta.in(filtro.coluna, valores);
        const { data, error } = await consulta;
        if (error) throw new Error(error.message);
        linhas.push(...data);
        if (data.length < fim - inicio + 1 || (limite && linhas.length >= limite)) return linhas;
      }
    }
    if (!filtro) return lerPaginas(null);
    if (!filtro.valores.length) return [];
    // Lotes pequenos para a lista de ids não estourar o tamanho da URL.
    const lotes = [];
    for (let i = 0; i < filtro.valores.length; i += 100) lotes.push(filtro.valores.slice(i, i + 100));
    const linhas = (await Promise.all(lotes.map(lerPaginas))).flat();
    const sinal = decrescente ? -1 : 1;
    return linhas.sort((a, b) => (a[coluna] > b[coluna] ? sinal : a[coluna] < b[coluna] ? -sinal : 0));
  }

  async function listarOS() {
    const [ordens, veiculos] = await Promise.all([
      selecionar('frota_gestao_os', 'id,numero,estado,veiculo_id,contexto_id,periodo_inicio,periodo_fim', null, { ordem: 'numero', decrescente: true }),
      selecionar('veiculos', 'id,placa', null),
    ]);
    const placas = new Map(veiculos.map((v) => [v.id, v.placa]));
    return ordens.map((o) => ({
      id: o.id, numero: String(o.numero), estado: o.estado, placa: placas.get(o.veiculo_id) ?? null,
      contexto: o.contexto_id, inicio: o.periodo_inicio, fim: o.periodo_fim,
    }));
  }

  async function sair() {
    await cliente.auth.signOut();
    location.replace(location.pathname);
  }

  window.__frota = {
    iniciar,
    chamar,
    selecionar,
    listarOS,
    sair,
    perfil: () => perfilAtual ?? { id: '', nome: '', ativo: false, senha_provisoria: true },
  };
})();
