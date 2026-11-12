// PostgreSQL 17 local, conexoes independentes, fixtures sinteticas; sem Supabase remoto.
import assert from 'node:assert/strict';
import {spawn,execFileSync} from 'node:child_process';
import {readFileSync,readdirSync,mkdtempSync,mkdirSync,writeFileSync} from 'node:fs';
import {homedir} from 'node:os';
import {join,resolve} from 'node:path';
import {fileURLToPath} from 'node:url';
import {randomUUID} from 'node:crypto';
import {createServer} from 'node:net';

const raiz=fileURLToPath(new URL('../',import.meta.url));
const binarios=join(homedir(),'.codex/tools/postgresql-17/pgsql/bin');
const temporarios=join(homedir(),'.codex/tmp');mkdirSync(temporarios,{recursive:true});
const pasta=mkdtempSync(join(temporarios,'frota-concorrencia-pg17-'));
const dados=join(pasta,'dados'),log=join(pasta,'postgres.log');
const reserva=createServer();await new Promise(r=>reserva.listen(0,'127.0.0.1',r));const porta=reserva.address().port;await new Promise(r=>reserva.close(r));
const ambiente={...process.env,PGHOST:'127.0.0.1',PGPORT:String(porta),PGUSER:'postgres',PGDATABASE:'postgres',PGCONNECT_TIMEOUT:'5',PGSSLMODE:'disable',PGCLIENTENCODING:'UTF8',LANG:'C'};
for(const k of ['PGPASSWORD','PGSERVICE','PGSERVICEFILE','PGOPTIONS'])delete ambiente[k];
const usuario=randomUUID(),chave='e'.repeat(64),resultados=[];
const literal=s=>"'"+String(s).replaceAll("'","''")+"'";
const json=d=>literal(JSON.stringify(d))+'::jsonb';
const prefixo=`begin;set local role authenticated;set local request.jwt.claims=${literal(JSON.stringify({sub:usuario,role:'authenticated'}))};set local request.headers=${literal(JSON.stringify({'x-frota-gestao-chave':chave}))};`;
const pausa=ms=>new Promise(r=>setTimeout(r,ms));
const conexoes=new Set();
function conectar(nome){
 const processo=spawn(join(binarios,'psql.exe'),['--no-psqlrc','--quiet','--tuples-only','--no-align','--set','ON_ERROR_STOP=1','--file','-'],{env:{...ambiente,PGAPPNAME:nome},stdio:['pipe','pipe','pipe'],windowsHide:true});
 const c={processo,saida:'',erro:'',codigo:null,encerrada:false};conexoes.add(c);
 processo.stdout.setEncoding('utf8');processo.stderr.setEncoding('utf8');
 processo.stdout.on('data',s=>{c.saida+=s;});processo.stderr.on('data',s=>{c.erro+=s;});
 c.fim=new Promise((ok,rejeitar)=>{processo.on('error',rejeitar);processo.on('close',codigo=>{c.codigo=codigo;c.encerrada=true;conexoes.delete(c);ok(c);});});
 return c;
}
async function executar(sql,nome='frota-observador'){
 const c=conectar(nome);c.processo.stdin.end(sql+'\n');
 const timer=setTimeout(()=>c.processo.kill(),25000);try{return await c.fim;}finally{clearTimeout(timer);}
}
async function consultar(sql){const r=await executar(sql);assert.equal(r.codigo,0,r.erro);return JSON.parse(r.saida.trim());}
async function rpc(sql){return consultar(prefixo+sql+'commit;');}
async function marcador(c,texto){const limite=Date.now()+15000;while(!c.saida.includes(texto)){if(c.encerrada||Date.now()>limite)throw new Error('Conexao A nao chegou ao marcador: '+c.erro);await pausa(30);}}
async function disputar(nome,sqlA,sqlB,{rejeitar}={}){
 const a=conectar('frota-A-'+randomUUID()),nomeB='frota-B-'+randomUUID();
 a.processo.stdin.write(prefixo+sqlA+'\n\\echo A_PRONTO\n');await marcador(a,'A_PRONTO');
 const b=conectar(nomeB);b.processo.stdin.end(prefixo+sqlB+'commit;\n');
 let bloqueou=false;const limite=Date.now()+8000;
 while(Date.now()<limite&&!b.encerrada){
  const espera=await consultar(`select json_build_object('bloqueado',coalesce((select wait_event_type='Lock' from pg_stat_activity where application_name=${literal(nomeB)} limit 1),false))::text;`);
  if(espera.bloqueado){bloqueou=true;break;}await pausa(30);
 }
 assert.ok(bloqueou,'Conexao B deveria aguardar a transacao A: '+b.erro);
 a.processo.stdin.end('commit;\n');const [ra,rb]=await Promise.all([a.fim,b.fim]);assert.equal(ra.codigo,0,ra.erro);
 if(rejeitar){assert.notEqual(rb.codigo,0);assert.match(rb.erro,rejeitar);}else assert.equal(rb.codigo,0,rb.erro);
 resultados.push({cenario:nome,aprovado:true,bloqueioPostgresConfirmado:true});console.log('OK concorrencia: '+nome);
 return {a:ra,b:rb};
}
function payload(numero,veiculo,unidade,valor=50){
 const nota={numero,serie:'1',chave:'',emissao:'2026-11-11',fornecedor:'FORNECEDOR SINTETICO CONCORRENCIA',documento_fornecedor:'00000000000191',documento_destinatario:'',total:(valor*2).toFixed(2),informacoes:'',avisos:[],itens:[{numero:'1',codigo:'TESTE',descricao:'PECA SINTETICA CONCORRENCIA',unidade:'UN',quantidade:'2',unitario:valor.toFixed(2),bruto:(valor*2).toFixed(2),desconto:'0.00',acrescimo:'0.00'}]};
 const rateio={destino:'veiculo',veiculo_id:veiculo.id,placa:veiculo.placa,unidade_id:veiculo.operacao_id,centro_custo:'301',conta_id:'',categoria_id:'',quantidade:'1',valor:valor.toFixed(2),os_item_id:'',executado_em:'',classificacao:'Eletrico'};
 const linhas=[veiculo.placa,'Estoque'].map((v,i)=>({id:`1:${i}`,veiculo:v,numero_os:i?'—':'A gerar',numero_nf:numero,centro_custo:i?'Estoque':'Armazém 301',conta_codigo:'4120503',conta:'4120503 · Peças preventiva',categoria_hbf:'pecas',pecas_servicos:nota.itens[0].descricao,servicos:'0.00',pecas:valor.toFixed(2),lavagem:'0.00',pneus:'0.00',oleo_lubrificante:'0.00',desconto:'0.00',valor_total:valor.toFixed(2),valor_alocado:valor.toFixed(2),quantidade:'1',unidade:'UN',manutencao:'preventiva',classificacao:'Eletrico'}));
 nota.dados_fiscais={conferencia_hbf:{formato:1,assinatura:'fixture sintetica',linhas}};
 return {formato:1,nota,etapa:4,unidadeFiscal:unidade,referencia:'',destinos:{},conferido:true,finalizacao:{fornecedor_id:'',emissao:'',veiculos:{},itens:{'1':{catalogo_id:'',fator:'1',local_id:'',manutencao:'preventiva',rateios:[rateio,{...rateio,destino:'estoque',veiculo_id:'',placa:'',centro_custo:'estoque'}]}}}};
}
const finalizar=(d,pedido=randomUUID())=>`select public.frota_gestao_finalizar_envio(${json(d)},${literal(pedido)}::uuid,true);`;
const editar=(id,base,d,pedido=randomUUID())=>`select public.frota_gestao_confirmar_edicao_simplificada(${literal(id)}::uuid,${literal(base)}::uuid,${literal(pedido)}::uuid,${json(d)},'Correcao sintetica concorrente',true);`;
const apagar=(id,base,pedido=randomUUID())=>`select public.frota_gestao_apagar_simplificado(${literal(id)}::uuid,${literal(base)}::uuid,${literal(pedido)}::uuid,'Exclusao sintetica concorrente',true);`;
const aplicar=(lote,veiculo,pedido=randomUUID())=>`select public.frota_gestao_aplicar_simplificado(${literal(pedido)}::uuid,${json({lote_id:lote,veiculo_id:veiculo,centro_custo:'301',quantidade:'1',manutencao:'corretiva'})},true);`;
async function registro(id){return rpc(`select public.frota_gestao_carregar_edicao_simplificada(${literal(id)}::uuid);`);}
async function estoque(id){const r=await rpc('select public.frota_gestao_estoque_simplificado();');return r.lotes.filter(l=>l.lancamento_id===id);}

let iniciado=false;
try{
 execFileSync(join(binarios,'initdb.exe'),['-D',dados,'-U','postgres','--auth=trust','--encoding=UTF8','--no-locale'],{stdio:'pipe'});
 // O postmaster do Windows pode herdar pipes do pg_ctl e impedir o retorno ao Node.
 execFileSync(join(binarios,'pg_ctl.exe'),['start','-D',dados,'-l',log,'-o',`-h 127.0.0.1 -p ${porta} -c max_connections=20`,'-w','-t','20'],{stdio:'ignore',windowsHide:true});iniciado=true;
 console.log('PostgreSQL local iniciado; preparando esquema sintetico.');
 const fonteTeste=readFileSync(join(raiz,'testes/banco.test.mjs'),'utf8'),inicio='const AMBIENTE_SUPABASE = `',pos=fonteTeste.indexOf(inicio)+inicio.length,fim=fonteTeste.indexOf('`;',pos);
 assert.ok(pos>=inicio.length&&fim>pos);
 let instalacao=fonteTeste.slice(pos,fim);
 for(const nome of readdirSync(join(raiz,'supabase/migrations')).filter(n=>n.endsWith('.sql')&&n<'20261110').sort())instalacao+='\n'+readFileSync(join(raiz,'supabase/migrations',nome),'utf8').replace('create extension if not exists pg_cron;','');
 instalacao+=`\ninsert into auth.users(id,email,raw_user_meta_data) values(${literal(usuario)},'sintetico@teste.invalid','{}');update perfis set ativo=true,senha_provisoria=false where id=${literal(usuario)};`;
 instalacao+='\n'+readFileSync(join(raiz,'scripts/ativar-escritas.sql'),'utf8').replace('COLE_AQUI_A_CHAVE',chave).replace('COLE_AQUI_A_EVIDENCIA','PostgreSQL local com dados sinteticos');
 const preparada=await executar(instalacao);assert.equal(preparada.codigo,0,preparada.erro);
 const base=await consultar("select json_build_object('veiculos',(select json_agg(v) from (select id,placa,operacao_id from veiculos order by placa limit 2) v),'unidade',(select id from operacoes where nome='Patos'))::text;");
 const [x,y]=base.veiculos,unidade=base.unidade;
 const preexistente=await rpc(finalizar(payload('99200',x,unidade)));
 const hashOriginal=await consultar(`select to_json(md5(to_jsonb(n)::text))::text from frota_gestao_lancamentos n where id=${literal(preexistente.nota_id)};`);
 const atualizacao=readdirSync(join(raiz,'supabase/migrations')).filter(n=>n.startsWith('20261110')&&n.endsWith('.sql')).sort().map(n=>readFileSync(join(raiz,'supabase/migrations',n),'utf8')).join('\n');
 const falhaInstalacao=await executar('begin;\n'+atualizacao+'\nselect 1/0;commit;');assert.notEqual(falhaInstalacao.codigo,0);assert.match(falhaInstalacao.erro,/division by zero|divis[aã]o por zero/i);
 const depoisDaFalha=await consultar(`select json_build_object('edicoes',to_regclass('public.frota_gestao_edicoes_simplificadas'),'exclusoes',to_regclass('public.frota_gestao_exclusoes_simplificadas'),'hash',(select md5(to_jsonb(n)::text) from frota_gestao_lancamentos n where id=${literal(preexistente.nota_id)}))::text;`);
 assert.deepEqual(depoisDaFalha,{edicoes:null,exclusoes:null,hash:hashOriginal});
 console.log('OK transacao: falha forcada reverte SQL99/100 e preserva a NF preexistente.');
 const instalada=await executar('begin;\n'+atualizacao+'\ncommit;');assert.equal(instalada.codigo,0,instalada.erro);
 assert.equal(await consultar(`select to_json(md5(to_jsonb(n)::text))::text from frota_gestao_lancamentos n where id=${literal(preexistente.nota_id)};`),hashOriginal);
 const d=payload('99201',x,unidade);
 await disputar('duas finalizacoes da mesma NF',finalizar(d),finalizar(d),{rejeitar:/NF j[aá]|already|duplic/i});
 const original=await consultar("select recibo::text from frota_gestao_lancamentos where numero='99201';");
 const d60=payload('99201',y,unidade,60),d70=payload('99201',x,unidade,70);
 await disputar('duas edicoes da mesma versao',editar(original.nota_id,original.versao_id,d60),editar(original.nota_id,original.versao_id,d70),{rejeitar:/outra sess[aã]o|vers[aã]o atual/i});
 let atual=await registro(original.nota_id);assert.equal(atual.historico.length,2);assert.equal(atual.registro.total,'120.00');assert.equal(atual.registro.hbf.linhas[0].veiculo,y.placa);
 const loteAnterior=(await estoque(original.nota_id))[0],d80=payload('99201',y,unidade,80);
 await disputar('edicao vence aplicacao de lote substituido',editar(original.nota_id,atual.registro.versao_id,d80),aplicar(loteAnterior.id,x.id),{rejeitar:/vers[aã]o anterior/i});
 atual=await registro(original.nota_id);const lote=(await estoque(original.nota_id))[0];assert.equal(lote.valor,'80.00');
 await disputar('aplicacao vence e bloqueia edicao atrasada',aplicar(lote.id,x.id),editar(original.nota_id,atual.registro.versao_id,d70),{rejeitar:/pe[cç]as j[aá] aplicadas|estorno controlado/i});
 const painel=await rpc('select public.frota_gestao_dashboard_simplificado();');assert.equal(painel.custos.filter(c=>c.lancamento_id===original.nota_id).reduce((s,c)=>s+Number(c.valor),0),160);
 const novo=await rpc(finalizar(payload('99202',x,unidade))),novoLote=(await estoque(novo.nota_id))[0];
 await disputar('exclusao vence aplicacao atrasada',apagar(novo.nota_id,novo.versao_id),aplicar(novoLote.id,x.id),{rejeitar:/vers[aã]o anterior|n[aã]o encontrad|apagado/i});
 const apagado=await rpc('select public.frota_gestao_dashboard_simplificado();');for(const campo of ['custos','compras','estoque'])assert.ok(!apagado[campo].some(c=>c.lancamento_id===novo.nota_id));
 const terceiro=await rpc(finalizar(payload('99203',x,unidade))),pedido=randomUUID(),solicitacao=apagar(terceiro.nota_id,terceiro.versao_id,pedido);
 const replay=await disputar('duas exclusoes com a mesma chave',solicitacao,solicitacao);const recibos=replay.a.saida.split('\n').filter(l=>l.startsWith('{'));assert.deepEqual(JSON.parse(replay.b.saida.trim()),JSON.parse(recibos[0]));
 const relancada=await rpc(finalizar(payload('99202',y,unidade)));assert.notEqual(relancada.nota_id,novo.nota_id);
 const contagem=await consultar("select json_build_object('notas',(select count(*) from frota_gestao_lancamentos),'edicoes',(select count(*) from frota_gestao_edicoes_simplificadas),'exclusoes',(select count(*) from frota_gestao_exclusoes_simplificadas),'aplicacoes',(select count(*) from frota_gestao_lancamento_aplicacoes))::text;");assert.deepEqual(contagem,{notas:5,edicoes:2,exclusoes:2,aplicacoes:1});
 assert.equal(await consultar(`select to_json(md5(to_jsonb(n)::text))::text from frota_gestao_lancamentos n where id=${literal(preexistente.nota_id)};`),hashOriginal);
 writeFileSync(join(pasta,'resultado.json'),JSON.stringify({ambiente:'PostgreSQL 17.11 local, somente dados sinteticos',producaoAcessada:false,rollbackInstalacaoConfirmado:true,notaPreexistentePreservada:true,cenarios:resultados,contagem},null,2));
 console.log('APROVADO: '+resultados.length+' cenarios concorrentes em conexoes PostgreSQL independentes. Relatorio: '+join(pasta,'resultado.json'));
}finally{
 for(const c of conexoes)c.processo.kill();
 if(iniciado)execFileSync(join(binarios,'pg_ctl.exe'),['stop','-D',dados,'-m','fast','-w','-t','20'],{stdio:'pipe'});
}
