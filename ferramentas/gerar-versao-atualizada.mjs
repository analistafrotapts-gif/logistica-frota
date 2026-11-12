// Compila os componentes antes da minificação: evita substituições por nomes gerados.
// node ferramentas/gerar-versao-atualizada.mjs <pasta-logpaubrasil-novo> <HTML-atualizado>
import {readFileSync,writeFileSync,mkdirSync} from 'node:fs';
import {resolve,dirname} from 'node:path';
import {createRequire} from 'node:module';
import {createHash} from 'node:crypto';
const origem=resolve(process.argv[2]??'../logpaubrasil-novo'),arquivo=resolve(process.argv[3]??'');
if(!process.argv[3])throw new Error('Informe o HTML atualizado para obter estilos e recursos PDF/OCR.');
const {build}=createRequire(resolve(origem,'package.json'))('esbuild');
const html=readFileSync(arquivo,'utf8');
function extrair(inicio,fim){const i=html.indexOf(inicio),j=html.indexOf(fim,i+inicio.length);if(i<0||j<0)throw new Error('HTML incompatível.');return html.slice(i+inicio.length,j);}
const css=extrair('<style>','</style>'),recursos=extrair('<script>','</script>');
const corte=recursos.indexOf("document.getElementById('reiniciar')");
if(!recursos.startsWith('const incorporados=')||corte<0)throw new Error('Recursos incompatíveis.');
const pdf=recursos.slice(0,corte);
if(/__laboratorioRecursos|frota_gestao_|pglite\.wasm/.test(pdf))throw new Error('Recursos contêm banco ou SQL local.');
const entrada=readFileSync(new URL('./interface-portal.tsx',import.meta.url),'utf8');
const pacote=await build({stdin:{contents:entrada,resolveDir:origem,loader:'tsx'},alias:{'@':resolve(origem,'src')},tsconfig:resolve(origem,'tsconfig.json'),bundle:true,write:false,minify:true,metafile:true,jsx:'automatic',format:'iife',platform:'browser',target:'es2022',legalComments:'none',define:{'process.env.NODE_ENV':'"production"'},plugins:[{name:'transporte-portal-publicado',setup(b){
 b.onResolve({filter:/^next\/link$/},()=>({path:'link',namespace:'ponte-portal'}));
 b.onResolve({filter:/^@\/lib\/(sessao|frota\/gestao\/ativacao-servidor)$/},a=>({path:a.path,namespace:'ponte-portal'}));
 b.onLoad({filter:/.*/,namespace:'ponte-portal'},a=>({loader:'js',resolveDir:origem,contents:a.path==='link'?`import {createElement} from 'react';export default function Link({href,children,prefetch,...props}){return createElement('a',{href,...props},children)}`:a.path.endsWith('sessao')?`export async function perfilAtual(){return window.__frota.perfil()}`:`
 export async function transporteGestao(){return {chamar:(nome,args)=>window.__frota.chamar(nome,args)}}
 export async function estadoAcessoGestao(){const p=window.__frota.perfil();return {acesso:!!p?.ativo&&!p.senha_provisoria,escrita:false}}
 export async function motivoBloqueioEscrita(){const p=window.__frota.perfil();if(!p?.ativo||p.senha_provisoria)return 'Sessão ativa necessária.';const r=await window.__frota.chamar('frota_gestao_estado_ativacao');return !r.error&&r.data?.contrato===92&&r.data?.liberado===true&&r.data?.completo===true?null:'Somente leitura: a liberação de escrita do servidor/banco não foi confirmada.';}` }));
 b.onLoad({filter:/[\\/]notas[\\/]central-actions\.ts$/},()=>({loader:'ts',resolveDir:origem,contents:`
 import {carregarCentralNotas,incluirSimplificados,fontesCentral} from '@/lib/frota/gestao/central-notas';
 import {listarLancamentosSimplificados} from '@/app/portal/gestao-frota/notas/nova/simplificado-actions';
 export async function consultarCentralNotas(){try{const p=window.__frota.perfil();if(!p?.ativo||p.senha_provisoria)throw new Error();const [anteriores,novos]=await Promise.all([carregarCentralNotas((fonte,filtro)=>window.__frota.selecionar(fonte,fontesCentral[fonte],filtro)),listarLancamentosSimplificados()]);return incluirSimplificados(anteriores,novos);}catch{return {dados:null,erro:'Não foi possível consultar a Central. Verifique a sessão e tente novamente.'}}}` }));
 b.onLoad({filter:/[\\/]pdf-leitura\.ts$/},a=>{let s=readFileSync(a.path,'utf8');for(const [antes,depois] of [
  ['"/gestao-frota-ocr/pdf.worker.min.mjs"','window.__pdfLocal.pdf'],
  ['const origem = new URL("/gestao-frota-ocr/", window.location.origin).href;','const origem = "";'],
  ['workerPath: `${origem}worker.min.js`, corePath: origem, langPath: origem,','workerPath: window.__pdfLocal.trabalhador, corePath: window.__pdfLocal.nucleo, langPath: "local:",']
 ]){if(!s.includes(antes))throw new Error('Leitor PDF incompatível.');s=s.replace(antes,depois);}return {contents:s,loader:'ts',resolveDir:dirname(a.path)};});
} }]});
const proibidos=Object.keys(pacote.metafile.inputs).filter(p=>/laboratorio[\\/]|@electric-sql|supabase[\\/]server|ativacao-servidor\.ts|next[\\/]headers|\.env$/.test(p));
if(proibidos.length)throw new Error(`Módulos exclusivos de servidor/laboratório no cliente: ${proibidos.join(', ')}`);
const js=pacote.outputFiles[0].text;
if(/__laboratorio|LABORATORIO LOCAL - SEM VALIDADE FISCAL|Operador local de teste/.test(js))throw new Error('Código local no painel publicado.');
mkdirSync('public/css',{recursive:true});mkdirSync('public/js',{recursive:true});
writeFileSync('public/css/painel.css',css);writeFileSync('public/js/recursos-pdf.js',pdf);writeFileSync('public/js/painel.js',js);
const hash=s=>createHash('sha256').update(s).digest('hex');
writeFileSync('public/versao.json',JSON.stringify({versao:'2026-11-12-estoque-cadastros-atalhos',gerado_em:new Date().toISOString(),painel_sha256:hash(js),estilos_sha256:hash(css),recursos_sha256:hash(pdf),banco_requerido:'99 revisado, 100, 101 OBZ, 102 milimetragem, 103 destinos, 104 classificacao obrigatoria e 105 retornos/cadastros, instalação manual separada'},null,2)+'\n');
const lista=readFileSync(resolve(origem,'src/lib/frota/gestao/ativacao.ts'),'utf8');
const rotinas=[...new Set([...lista.matchAll(/"(frota_gestao_[a-z_]+)"/g)].map(m=>m[1]).concat(['frota_gestao_estado_ativacao','frota_gestao_contrato_completo']))].sort();
writeFileSync('api/rotinas.js',`// Lista fechada; nenhuma chave ou dado do banco é incluído.\nexport const ROTINAS_PERMITIDAS=new Set(${JSON.stringify(rotinas,null,2)});\n`);
console.log('Painel atualizado: componentes reais, transporte autenticado, sem banco local, seed ou credenciais.');
