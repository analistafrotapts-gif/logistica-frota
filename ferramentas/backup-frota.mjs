// Backup somente leitura. A senha e solicitada pelo cliente PostgreSQL, fora do chat.
import {spawnSync} from 'node:child_process';
import {mkdirSync,mkdtempSync,readFileSync,renameSync,writeFileSync,statSync} from 'node:fs';
import {join,resolve} from 'node:path';
import {homedir} from 'node:os';
import {createHash} from 'node:crypto';
import {createInterface} from 'node:readline/promises';
import {fileURLToPath} from 'node:url';

const projeto='fixvhizwcztmvmpykovr';
export function validarConexao(texto){
 const uri=new URL(texto.trim());
 if(!['postgres:','postgresql:'].includes(uri.protocol))throw new Error('Use a URI PostgreSQL do Connect.');
 const usuario=decodeURIComponent(uri.username),senha=decodeURIComponent(uri.password);
 if(senha&&!/^\[YOUR[-_](DATABASE[-_])?PASSWORD\]$/i.test(senha))throw new Error('Mantenha [YOUR-PASSWORD] na URI. A senha sera solicitada separadamente.');
 const direta=uri.hostname===`db.${projeto}.supabase.co`&&usuario==='postgres';
 const pooler=/^aws-\d+-sa-east-1\.pooler\.supabase\.com$/.test(uri.hostname)&&usuario===`postgres.${projeto}`;
 if(!direta&&!pooler)throw new Error('A conexao nao corresponde ao projeto logistica-frota esperado.');
 if((uri.port&&uri.port!=='5432')||uri.pathname!=='/postgres')throw new Error('Use Session pooler ou Direct connection, porta 5432 e banco postgres.');
 return {host:uri.hostname,usuario,porta:'5432',banco:'postgres'};
}
async function executar(){
 const terminal=createInterface({input:process.stdin,output:process.stdout});
 try{
  if(process.argv[2]==='--validar-conexao'){console.log(JSON.stringify(validarConexao(process.argv[3]??'')));return;}
  console.log('BACKUP PAU BRASIL - SOMENTE LEITURA DO BANCO');
  console.log('Supabase > logistica-frota > Connect > Session pooler > URI.');
  console.log('Cole a URI mantendo [YOUR-PASSWORD]. NAO cole a senha na URI.');
  const conexao=validarConexao(await terminal.question('\nURI sem senha: '));
  terminal.close();
  const binarios=join(homedir(),'.codex/tools/postgresql-17/pgsql/bin');
  const ambiente={...process.env,PGSSLMODE:'require',PGCONNECT_TIMEOUT:'15',PGOPTIONS:'-c default_transaction_read_only=on -c statement_timeout=0'};
  delete ambiente.PGPASSWORD;delete ambiente.PGSERVICE;delete ambiente.PGSERVICEFILE;
  function cliente(nome,args,capturar=false){
   const r=spawnSync(join(binarios,nome+'.exe'),args,{env:ambiente,stdio:capturar?['inherit','pipe','pipe']:'inherit',encoding:'utf8'});
   if(r.error||r.status!==0)throw new Error(`${nome} nao concluiu. Backup ainda nao confirmado. Avise ao assistente sem redefinir senhas ou executar SQLs.`);
   return r.stdout??'';
  }
  const versao=cliente('pg_dump',['--version'],true).trim();
  if(!/PostgreSQL\) 17\./.test(versao))throw new Error('Cliente PostgreSQL 17 necessario.');
  const raiz=resolve(process.env.LOCALAPPDATA??join(homedir(),'AppData/Local'),'PauBrasil/Backups/logistica-frota');
  mkdirSync(raiz,{recursive:true});
  const pasta=mkdtempSync(join(raiz,new Date().toISOString().replace(/[:.]/g,'-')+'-'));
  const sistema=process.env.SystemRoot??'C:/Windows';
  const identidade=spawnSync(join(sistema,'System32/whoami.exe'),['/user','/fo','csv','/nh'],{encoding:'utf8'});
  const sid=identidade.stdout?.match(/S-1-\d+(?:-\d+)+/)?.[0];
  if(identidade.status!==0||!sid)throw new Error('Nao foi possivel proteger a pasta do backup.');
  const permissao=spawnSync(join(sistema,'System32/icacls.exe'),[pasta,'/inheritance:r','/grant:r',`*${sid}:(OI)(CI)F`,'*S-1-5-18:(OI)(CI)F'],{encoding:'utf8'});
  if(permissao.status!==0)throw new Error('Nao foi possivel restringir o acesso ao backup.');
  const args=['--host',conexao.host,'--port','5432','--username',conexao.usuario];
  const parcial=join(pasta,'banco.parcial'),arquivo=join(pasta,'banco.dump'),roles=join(pasta,'roles-sem-senhas.sql');
  console.log('\n1/2 - Digite a senha do BANCO quando aparecer Password. Os caracteres nao aparecem.');
  console.log('Nao e a senha de login do portal. Esta exportacao nao altera os registros.');
  cliente('pg_dump',[...args,'--dbname','postgres','--password','--format=custom','--lock-wait-timeout=10s','--file',parcial]);
  if(statSync(parcial).size<100)throw new Error('Arquivo de backup incompleto.');
  renameSync(parcial,arquivo);
  console.log('\n2/2 - Digite novamente a mesma senha do banco para exportar as permissoes de roles, sem senhas.');
  cliente('pg_dumpall',[...args,'--database=postgres','--password','--roles-only','--no-role-passwords','--file',roles]);
  const indice=cliente('pg_restore',['--list',arquivo],true);
  if(!indice.includes('TABLE'))throw new Error('Indice do backup sem tabelas; verificacao pendente.');
  writeFileSync(join(pasta,'indice-arquivo.txt'),indice);
  const hash=caminho=>createHash('sha256').update(readFileSync(caminho)).digest('hex');
  writeFileSync(join(pasta,'manifesto.json'),JSON.stringify({projeto,gerado_em_utc:new Date().toISOString(),cliente:versao,arquivo:'banco.dump',sha256:hash(arquivo),roles_arquivo:'roles-sem-senhas.sql',roles_sha256:hash(roles),indice_lido:true,restauracao_testada:false,observacoes:'Backup do banco. Nao inclui arquivos fisicos do Storage ou configuracao Vercel. Ler indice nao comprova restauracao. Nao restaurar sobre producao para testar.'},null,2));
  console.log('\nARQUIVO DE BACKUP GERADO E INDICE LIDO.');
  console.log('Pasta do backup: '+pasta);
  console.log('A recuperacao ainda precisa ser verificada. Nao execute os SQLs agora.');
 }finally{terminal.close();}
}
if(process.argv[1]&&resolve(process.argv[1])===fileURLToPath(import.meta.url))executar().catch(e=>{console.error('\nNAO CONCLUIDO: '+e.message);process.exitCode=1;});
