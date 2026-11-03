// Build da Vercel: copia o cliente do Supabase e grava public/config.js com a
// URL e a chave pública (anon) do projeto. A chave anon é pública por desenho;
// a proteção dos dados fica no RLS e na chave de servidor da função /api/rpc.
import { copyFileSync, mkdirSync, writeFileSync } from 'node:fs';

const url = process.env.SUPABASE_URL || process.env.NEXT_PUBLIC_SUPABASE_URL || '';
const chave = process.env.SUPABASE_ANON_KEY || process.env.NEXT_PUBLIC_SUPABASE_ANON_KEY || '';
if (!url || !chave) console.warn('Aviso: SUPABASE_URL/SUPABASE_ANON_KEY ausentes; o painel vai pedir a configuração.');
if (!process.env.FROTA_GESTAO_CHAVE) console.warn('Aviso: FROTA_GESTAO_CHAVE ausente; o painel ficará somente leitura.');

mkdirSync('public/vendor', { recursive: true });
copyFileSync('node_modules/@supabase/supabase-js/dist/umd/supabase.js', 'public/vendor/supabase.js');
writeFileSync('public/config.js', `window.__config=${JSON.stringify({ url, chave })};\n`);
console.log('Build concluído.');
