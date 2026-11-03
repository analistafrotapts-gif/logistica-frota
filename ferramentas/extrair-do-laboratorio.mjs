// Gera o painel de produção a partir do HTML do laboratório.
//
//   node ferramentas/extrair-do-laboratorio.mjs [laboratorio/Pau-Brasil-laboratorio-frota.html]
//
// O laboratório traz as telas do módulo Gestão da Frota ligadas a um PostgreSQL
// que roda no navegador. Este script separa as partes e troca só a camada de
// dados: as telas passam a usar window.__frota (public/js/sessao.js), que fala
// com o Supabase. Cada troca precisa casar exatamente uma vez; se o laboratório
// mudar, o script para e aponta qual trecho não foi encontrado.
import { readFileSync, writeFileSync, mkdirSync } from 'node:fs';

const origem = process.argv[2] ?? 'laboratorio/Pau-Brasil-laboratorio-frota.html';
const html = readFileSync(origem, 'utf8');

function entre(texto, inicio, fim, aPartirDe = 0) {
  const i = texto.indexOf(inicio, aPartirDe);
  const j = texto.indexOf(fim, i + inicio.length);
  if (i < 0 || j < 0) throw new Error(`Trecho não encontrado: ${inicio.slice(0, 60)}`);
  return { i, j, conteudo: texto.slice(i + inicio.length, j) };
}

// 1. Estilos: o primeiro <style> (fontes, Tailwind e tema). O segundo é só do laboratório.
const estilo = entre(html, '<style>', '</style>').conteudo;

// 2. Leitor de PDF/OCR embutido (pdf.js + Tesseract). Descarta o PostgreSQL do navegador.
const scriptRecursos = entre(html, '<script>', '</script>');
const recursos = scriptRecursos.conteudo;
const corteRecursos = recursos.indexOf("document.getElementById('reiniciar')");
if (!recursos.startsWith('const incorporados=') || corteRecursos < 0) throw new Error('Script de recursos com formato inesperado.');
const recursosPdf = recursos.slice(0, corteRecursos);

// 3. Telas (React).
let painel = entre(html, '<script>', '</script>', scriptRecursos.j).conteudo;

function trocar(descricao, antes, depois) {
  const partes = painel.split(antes);
  if (partes.length !== 2) throw new Error(`${descricao}: esperado 1 trecho, encontrado ${partes.length - 1}.`);
  painel = partes.join(depois);
}

function trocarIntervalo(descricao, inicio, fim, depois) {
  const i = painel.indexOf(inicio);
  const j = painel.indexOf(fim, i);
  if (i < 0 || j < 0 || painel.indexOf(inicio, i + 1) >= 0) throw new Error(`${descricao}: trecho não encontrado ou repetido.`);
  painel = painel.slice(0, i) + depois + painel.slice(j);
}

trocar('perfil do usuário',
  'function Yr(){return{id:Dx,nome:Dx===Vt.usuario?"Operador A \\xB7 TESTE":"Operador B \\xB7 TESTE",ativo:Lx,senha_provisoria:!1}}',
  'function Yr(){return window.__frota.perfil()}');

trocarIntervalo('cliente RPC', 'var sE={async chamar(e,t={}){', 'async function n_(',
  'var sE={chamar:(e,t={})=>window.__frota.chamar(e,t)};');

trocar('mensagem de conta inativa',
  'async function Nc(){return Yr().ativo?null:"Perfil de teste inativo."}',
  'async function Nc(){return Yr().ativo?null:"Conta inativa. Procure o administrador."}');

trocarIntervalo('central de notas', 'async function A9(e,t){', 'var en=Ce(Da());',
  'async function A9(e,t){if(!t.ativo)return{dados:null,erro:"Conta inativa. Consulta negada."};' +
  'let r=await E9((o,n)=>window.__frota.selecionar(o,b9[o],n)),{data:o,error:n}=await window.__frota.chamar("frota_gestao_listar_simplificado");' +
  'return n?{dados:null,erro:n.message}:S9(r,{dados:o,erro:null})}');

trocar('consulta da central', 'function nq(){return A9(En(),Yr())}', 'function nq(){return A9(null,Yr())}');

trocarIntervalo('veículos e unidades', 'async function PT(){', 'async function lce(e){',
  'async function PT(){let[e,t]=await Promise.all([window.__frota.selecionar("veiculos","id,placa,operacao_id,centro_custo",null,{ordem:"placa"}),' +
  'window.__frota.selecionar("operacoes","id,nome,ativa",null,{ordem:"nome"})]);' +
  'return{veiculos:e,unidades:t.filter(a=>a.ativa).map(({id:a,nome:r})=>({id:a,nome:r}))}}');

trocar('roteador sem banco local', 'a=t.pathname,r=En();', 'a=t.pathname,r=null;');

trocar('lista de OS',
  'n=(await r.query("select o.id,o.numero::text,o.estado,v.placa,o.contexto_id as contexto,o.periodo_inicio as inicio,o.periodo_fim as fim from frota_gestao_os o join veiculos v on v.id=o.veiculo_id order by o.numero desc")).rows;',
  'n=await window.__frota.listarOS();');
trocar('título das OS', '"Ordens de Servi\\xE7o locais"', '"Ordens de Servi\\xE7o"');

trocar('auditoria',
  'let o=(await r.query("select * from frota_gestao_auditoria order by id desc limit 200")).rows;',
  'let o=await window.__frota.selecionar("frota_gestao_auditoria","*",null,{ordem:"id",decrescente:!0,limite:200});');
trocar('título da auditoria', '"Auditoria das opera\\xE7\\xF5es no banco local"', '"Auditoria das opera\\xE7\\xF5es"');

trocar('telas exclusivas do laboratório',
  'if(a==="/gestran")return(0,Ue.jsx)(dce,{});if(a==="/seguranca")return(0,Ue.jsx)(uce,{});if(a==="/melhorias")return(0,Ue.jsx)(fce,{});throw new Error("Tela n\\xE3o dispon\\xEDvel no laborat\\xF3rio.")',
  'throw new Error("Tela n\\xE3o encontrada.")');

trocar('tabela vazia', '"Nenhum registro neste banco local."', '"Nenhum registro encontrado."');

trocar('marca d\'água de laboratório nos PDFs',
  'async function sp(e,t={}){let a=await cne(e,t),r=await Mo.load(a);for(let o of r.getPages())o.drawText("LABORATORIO LOCAL - SEM VALIDADE FISCAL",{x:24,y:5,size:8,color:At(.65,0,0)});return r.save()}',
  'async function sp(e,t={}){return cne(e,t)}');

trocarIntervalo('menu da conta',
  'usuario:"Operador local de teste",ferramentas:(0,Ue.jsxs)(Ue.Fragment,{children:[',
  '(0,Ue.jsx)("button",{className:Kf,onClick:()=>t(f=>f+1),children:"Atualizar tela"})',
  'usuario:Yr().nome,ferramentas:(0,Ue.jsxs)(Ue.Fragment,{children:[');
trocar('botão sair', 'children:"Alternar tema"})', 'children:"Alternar tema"}),(0,Ue.jsx)("button",{className:Kf,onClick:()=>{window.__frota.sair()},children:"Sair"})');
trocar('carregando', '"Consultando banco local\\u2026"', '"Carregando\\u2026"');

trocarIntervalo('inicialização', 'async function pce(){', 'pce();})();',
  'async function pce(){try{await window.__frota.iniciar(),(0,iq.createRoot)(document.getElementById("formulario")).render((0,Ue.jsx)(E8,{children:(0,Ue.jsx)(hce,{})}))}' +
  'catch(e){document.getElementById("formulario").textContent=`Falha ao iniciar o painel: ${Zf(e)}`}}');

mkdirSync('public/css', { recursive: true });
mkdirSync('public/js', { recursive: true });
writeFileSync('public/css/painel.css', estilo);
writeFileSync('public/js/recursos-pdf.js', recursosPdf);
writeFileSync('public/js/painel.js', painel);
console.log('Gerados: public/css/painel.css, public/js/recursos-pdf.js, public/js/painel.js');
