import {createRoot} from "react-dom/client";
import {useEffect,useState,type ReactNode} from "react";
import {CatalogosGestao} from "@/components/frota/CatalogosGestao";
import {EstruturaGestao,InicioGestao} from "@/components/frota/MenuGestao";
import {Aviso} from "@/components/ui/base";
import {Lancamento} from "@/app/portal/gestao-frota/notas/nova/Lancamento";
import {CentralNotas} from "@/app/portal/gestao-frota/notas/CentralNotas";
import {consultarCentralNotas} from "@/app/portal/gestao-frota/notas/central-actions";
import {listarLancamentosSimplificados} from "@/app/portal/gestao-frota/notas/nova/simplificado-actions";
import {NotaSimplificada} from "@/app/portal/gestao-frota/notas/NotaSimplificada";
import {EstoqueSimplificado} from "@/app/portal/gestao-frota/estoque/EstoqueSimplificado";
import {consultarEstoqueSimplificado} from "@/app/portal/gestao-frota/estoque/simplificado-actions";
import {DashboardFrota} from "@/app/portal/gestao-frota/custos/DashboardFrota";
import {consultarDashboard} from "@/app/portal/gestao-frota/custos/dashboard-actions";
import {Cadastros} from "@/app/portal/gestao-frota/cadastros/Cadastros";
import {consultarCadastros} from "@/app/portal/gestao-frota/cadastros/actions";
import {historicoRevisoes} from "@/app/portal/gestao-frota/notas/[id]/actions";
import {RevisaoNota} from "@/app/portal/gestao-frota/notas/[id]/RevisaoNota";
import {prepararFinalizacao} from "@/app/portal/gestao-frota/notas/nova/finalizacao-actions";
import {AberturaOs} from "@/app/portal/gestao-frota/os/AberturaOs";
import {CentralHbf} from "@/app/portal/gestao-frota/custos/CentralHbf";
import {listarHbf} from "@/app/portal/gestao-frota/custos/actions";

const ponte=()=>window.__frota;
const mensagem=(e:unknown)=>e instanceof Error?e.message:"Não foi possível carregar a tela.";
async function cadastrosBase(){const [veiculos,operacoes]=await Promise.all([
 ponte().selecionar("veiculos","id,placa,operacao_id,centro_custo",null,{ordem:"placa"}),
 ponte().selecionar("operacoes","id,nome,ativa",null,{ordem:"nome"})
]);return {veiculos,unidades:operacoes.filter(o=>o.ativa).map(({id,nome})=>({id,nome}))};}
async function tela(rota:string):Promise<ReactNode>{
 const url=new URL(rota,location.origin),caminho=url.pathname;
 if(caminho==="/")return <InicioGestao/>;
 if(caminho==="/notas/nova"){const base=await cadastrosBase();return <Lancamento veiculos={base.veiculos} operacoes={base.unidades} erroCadastro={null}/>;}
 if(caminho==="/notas")return <CentralNotas inicial={await consultarCentralNotas()} consultar={consultarCentralNotas}/>;
 if(/^\/notas\/[0-9a-f-]+$/.test(caminho)){
  const id=caminho.split("/").at(-1)!,novos=await listarLancamentosSimplificados();if(novos.erro)throw new Error(novos.erro);
  const registro=novos.dados?.find(n=>n.id===id);if(registro)return <NotaSimplificada registro={registro}/>;
  const [r,cad,base]=await Promise.all([historicoRevisoes(id,0,url.searchParams.get("versao")),prepararFinalizacao(),cadastrosBase()]);
  if(!r.dados)throw new Error(r.erro??"Lançamento não encontrado ou indisponível.");
  return <RevisaoNota inicial={r.dados} pagina={0} cadastros={cad.cadastros} veiculos={base.veiculos} unidades={base.unidades} erroCadastros={cad.disponivel?null:cad.motivo}/>;
 }
 if(caminho==="/estoque")return <EstoqueSimplificado inicial={await consultarEstoqueSimplificado()}/>;
 if(caminho==="/custos")return <DashboardFrota inicial={await consultarDashboard()}/>;
 if(caminho==="/cadastros")return <Cadastros inicial={await consultarCadastros()}/>;
 // Mantém links anteriores de OS/HBF; nenhum banco local é inicializado.
 if(caminho==="/os"){const base=await cadastrosBase(),ordens=await ponte().listarOS();return <div className="space-y-5"><h2 className="text-xl font-bold">Ordens de Serviço</h2><div className="overflow-auto"><table className="w-full text-left text-sm"><thead><tr><th className="p-3">OS</th><th className="p-3">Placa</th><th className="p-3">Estado</th></tr></thead><tbody>{ordens.map(o=><tr key={o.id}><td className="p-3">{o.numero}</td><td className="p-3">{o.placa}</td><td className="p-3">{o.estado}</td></tr>)}</tbody></table></div><AberturaOs veiculos={base.veiculos}/></div>;}
 if(caminho==="/hbf"){const r=await listarHbf("",0);if(!r.dados)throw new Error(r.erro??"Consulta indisponível.");return <CentralHbf inicial={r.dados}/>;}
 throw new Error("Tela não encontrada.");
}
function Aplicacao(){
 const [versao,setVersao]=useState(0),[conteudo,setConteudo]=useState<ReactNode>(null),[falha,setFalha]=useState(""),[ocupado,setOcupado]=useState(true);
 const rota=location.hash.slice(1)||"/";
 useEffect(()=>{const mudar=()=>setVersao(v=>v+1);const links=(e:MouseEvent)=>{const link=(e.target as Element).closest?.("a"),href=link?.getAttribute("href");if(href?.startsWith("/portal/gestao-frota")){e.preventDefault();const destino=href.replace("/portal/gestao-frota","")||"/";if(location.hash.slice(1)===destino)mudar();else location.hash=destino;}};window.addEventListener("hashchange",mudar);document.addEventListener("click",links);return()=>{window.removeEventListener("hashchange",mudar);document.removeEventListener("click",links);};},[]);
 useEffect(()=>{let atual=true;void Promise.resolve().then(()=>{if(atual){setOcupado(true);setFalha("");}return tela(rota);}).then(r=>{if(atual)setConteudo(r);}).catch(e=>{if(atual)setFalha(mensagem(e));}).finally(()=>{if(atual)setOcupado(false);});return()=>{atual=false;};},[rota,versao]);
 const botao="min-h-11 rounded border border-[var(--color-linha)] px-4 text-sm font-semibold";
 return <EstruturaGestao rota={rota==="/"?"":rota.split("?")[0]} usuario={ponte().perfil().nome} ferramentas={<><button type="button" className={botao} onClick={()=>setVersao(v=>v+1)}>Atualizar tela</button><button type="button" className={botao} onClick={()=>{document.documentElement.dataset.tema=document.documentElement.dataset.tema==="escuro"?"claro":"escuro";}}>Alternar tema</button><button type="button" className={botao} onClick={()=>ponte().sair()}>Sair</button></>}>{ocupado?<p role="status">Carregando…</p>:falha?<Aviso tipo="erro">{falha}</Aviso>:<div key={`${rota}-${versao}`}>{conteudo}</div>}</EstruturaGestao>;
}
async function iniciar(){try{await ponte().iniciar();createRoot(document.getElementById("formulario")!).render(<CatalogosGestao><Aplicacao/></CatalogosGestao>);}catch(e){document.getElementById("formulario")!.textContent=`Falha ao iniciar o painel: ${mensagem(e)}`;}}
void iniciar();
