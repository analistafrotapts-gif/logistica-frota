// Teste exclusivamente loopback, com o servidor local e dados sintéticos.
import assert from 'node:assert/strict';
import {createRequire} from 'node:module';
import {resolve} from 'node:path';
const {chromium}=createRequire(resolve(process.argv[2]??'../logpaubrasil-novo','package.json'))('playwright-core');
const base=process.argv[3]??'http://localhost:3087';
assert.ok(['localhost','127.0.0.1'].includes(new URL(base).hostname),'Nunca executar este teste em produção');
const navegador=await chromium.launch({channel:'msedge',headless:true});
try{
 const p=await navegador.newPage(),erros=[],externas=[];p.on('pageerror',e=>erros.push(e.message));
 await p.route(/^https?:/,r=>{if(!['localhost','127.0.0.1'].includes(new URL(r.request().url()).hostname)){externas.push(r.request().url());return r.abort();}return r.continue();});
 await p.goto(base);await p.getByLabel('E-mail',{exact:true}).fill('admin@local.test');await p.getByLabel('Senha',{exact:true}).fill('senha-local-123');await p.getByRole('button',{name:'Entrar',exact:true}).click();
 await p.getByRole('heading',{name:'Gerenciamento de custos da frota',exact:true}).waitFor();
 await p.locator('a[href="/portal/gestao-frota/notas/nova"]').first().click();
 await p.getByRole('button',{name:/^Importar XML ou PDF de NF/}).waitFor().catch(async e=>{console.log(JSON.stringify({erros,tela:await p.locator('body').innerText()}));throw e;});
 await p.getByRole('button',{name:/^Importar XML ou PDF de NF/}).click();
 const numero=String(Date.now()).slice(-8);
 const xml=`<nfeProc xmlns="http://www.portalfiscal.inf.br/nfe"><NFe><infNFe><ide><nNF>${numero}</nNF><serie>1</serie><dhEmi>2026-11-10T12:00:00-03:00</dhEmi></ide><emit><CNPJ>00000000000191</CNPJ><xNome>FORNECEDOR SINTETICO NAVEGADOR</xNome></emit><dest><CNPJ>20983885000101</CNPJ></dest><det nItem="1"><prod><xProd>PECA SINTETICA PUBLICACAO</xProd><uCom>UN</uCom><qCom>2</qCom><vUnCom>50.00</vUnCom><vProd>100.00</vProd></prod></det><total><ICMSTot><vNF>100.00</vNF></ICMSTot></total></infNFe></NFe></nfeProc>`;
 await p.locator('input[type=file]').first().setInputFiles({name:'NF-SINTETICA.xml',mimeType:'application/xml',buffer:Buffer.from(xml)});
 await p.locator('#nf-numero').waitFor();assert.equal(await p.locator('#nf-numero').inputValue(),numero);
 await p.getByRole('button',{name:'Continuar',exact:true}).click();await p.getByRole('button',{name:'Continuar',exact:true}).click();
 await p.getByLabel('Destino, item 1, parcela 1',{exact:true}).selectOption('veiculo');
 await p.getByRole('combobox',{name:'Placa, item 1, parcela 1',exact:true}).fill('EMP0002');await p.getByRole('button',{name:'EMP0002',exact:true}).click();
 await p.getByRole('button',{name:'Dividir item entre destinos',exact:true}).first().click();
 await p.getByLabel('Quantidade, item 1, parcela 1',{exact:true}).fill('1');await p.getByLabel('Destino, item 1, parcela 2',{exact:true}).selectOption('estoque');await p.getByLabel('Quantidade, item 1, parcela 2',{exact:true}).fill('1');
 await p.getByRole('button',{name:'Preventivo, item 1, parcela 1',exact:true}).click();
 for(const parcela of [1,2]){await p.getByRole('combobox',{name:`Classificação, item 1, parcela ${parcela}`,exact:true}).fill('eletr');await p.getByRole('button',{name:'Elétrico',exact:true}).click();}
 await p.getByRole('button',{name:'Concluir alocação',exact:true}).click();
 for(const linha of [1,2]){await p.getByRole('combobox',{name:`Conta, linha ${linha}`,exact:true}).fill('0503');await p.getByRole('button',{name:'4120503 · Peças preventiva',exact:true}).click();}
 await p.getByRole('button',{name:'Finalizar Lançamento',exact:true}).click();await p.getByRole('checkbox').check();await p.getByRole('button',{name:'Confirmar lançamento',exact:true}).click();
 await p.getByRole('status').filter({hasText:'NF lançada, informações enviadas'}).waitFor();await p.getByRole('link',{name:'Ir para Central de Notas',exact:true}).click();
 const grupo=p.locator('tbody[data-nota]').filter({hasText:numero});await grupo.getByRole('link',{name:'Histórico do lançamento',exact:true}).click();
 const sem99=async r=>{const dados=r.request().postDataJSON();return dados.nome==='frota_gestao_carregar_edicao_simplificada'?r.fulfill({status:200,contentType:'application/json',body:JSON.stringify({data:null,error:{code:'PGRST202',message:'Função ausente no teste isolado'}})}):r.continue();};
 await p.route('**/api/rpc',sem99);await p.getByRole('button',{name:'Editar',exact:true}).click();await p.getByRole('alert').filter({hasText:'SQL 99'}).waitFor();assert.equal(await p.locator('#nf-numero').count(),0);await p.unroute('**/api/rpc',sem99);
 await p.getByRole('button',{name:'Editar',exact:true}).click();await p.locator('#unidade-fiscal').selectOption({label:'Sumé'});
 await p.getByRole('button',{name:'Continuar',exact:true}).click();await p.getByRole('button',{name:'Continuar',exact:true}).click();await p.getByRole('button',{name:'Concluir alocação',exact:true}).click();
 await p.getByLabel('Motivo da edição',{exact:true}).fill('Corrigir unidade fiscal no teste isolado');await p.getByRole('checkbox').check();await p.getByRole('button',{name:'Salvar alterações',exact:true}).click();
 await p.getByRole('status').filter({hasText:'Versão 2 confirmada'}).waitFor();await p.getByRole('button',{name:'Histórico de versões',exact:true}).click();await p.getByRole('columnheader',{name:'Antes',exact:true}).waitFor();
 const baixar=p.waitForEvent('download');await p.getByRole('button',{name:'Baixar HBF',exact:true}).click();assert.match((await baixar).suggestedFilename(),/v2\.pdf$/);
 await p.getByRole('button',{name:'Apagar lançamento',exact:true}).click();await p.getByLabel('Motivo da exclusão',{exact:true}).fill('Apagar nota sintética de teste');await p.getByRole('checkbox').check();
 const sem100=async r=>{const dados=r.request().postDataJSON();return dados.nome==='frota_gestao_apagar_simplificado'?r.fulfill({status:200,contentType:'application/json',body:JSON.stringify({data:null,error:{code:'PGRST202',message:'Função ausente no teste isolado'}})}):r.continue();};
 await p.route('**/api/rpc',sem100);await p.getByRole('button',{name:'Confirmar exclusão',exact:true}).click();await p.getByRole('alert').filter({hasText:'SQL 100'}).waitFor();assert.equal(await p.getByRole('status').filter({hasText:'Lançamento apagado'}).count(),0);await p.unroute('**/api/rpc',sem100);
 await p.getByRole('button',{name:'Confirmar exclusão',exact:true}).click();await p.getByRole('status').filter({hasText:'Lançamento apagado'}).waitFor();
 await p.getByRole('link',{name:'Voltar à Central de Notas',exact:true}).click();await p.getByRole('heading',{name:'Central de Notas',exact:true}).waitFor();assert.equal(await p.locator('tbody[data-nota]').filter({hasText:numero}).count(),0);
 assert.deepEqual(erros,[]);assert.deepEqual(externas,[]);
 console.log('OK navegador com API local: login, XML, alocação placa/estoque, HBF, lançamento, edição de unidade, histórico, PDF e exclusão. Nenhum acesso à produção.');
}finally{await navegador.close();}
