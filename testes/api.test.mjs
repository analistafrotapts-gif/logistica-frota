import {test} from 'node:test';
import assert from 'node:assert/strict';
process.env.SUPABASE_URL='https://banco-isolado.invalid';
process.env.SUPABASE_ANON_KEY='publica-sintetica';
process.env.FROTA_GESTAO_CHAVE='chave-sintetica-de-servidor';
const {default:handler}=await import('../api/rpc.js');
test('API aceita somente rotinas explícitas e não expõe chave ao cliente',async()=>{
 const original=globalThis.fetch;let chamadas=0;
 globalThis.fetch=async(url,opcoes)=>{chamadas++;assert.equal(url,'https://banco-isolado.invalid/rest/v1/rpc/frota_gestao_estado_ativacao');assert.equal(opcoes.headers['x-frota-gestao-chave'],process.env.FROTA_GESTAO_CHAVE);return new Response(JSON.stringify({contrato:92,liberado:false,completo:false}),{status:200});};
 async function requisicao(req){let codigo,corpo;const res={setHeader(){},status(n){codigo=n;return this;},json(d){corpo=d;return this;}};await handler({headers:{authorization:'Bearer token-sintetico'},...req},res);return {codigo,corpo};}
 try{
  assert.equal((await requisicao({method:'GET'})).codigo,405);
  assert.equal((await requisicao({method:'POST',headers:{},body:{nome:'frota_gestao_estado_ativacao'}})).codigo,401);
  for(const body of [{nome:'frota_gestao_lancamento_ativo'},{nome:'frota_gestao_nao_autorizada'},{nome:'frota_gestao_estado_ativacao',params:null}])assert.equal((await requisicao({method:'POST',body})).codigo,400);
  assert.equal(chamadas,0);
  const r=await requisicao({method:'POST',body:{nome:'frota_gestao_estado_ativacao'}});assert.equal(r.codigo,200);assert.equal(r.corpo.data.liberado,false);assert.ok(!JSON.stringify(r).includes(process.env.FROTA_GESTAO_CHAVE));assert.equal(chamadas,1);
 }finally{globalThis.fetch=original;}
});
