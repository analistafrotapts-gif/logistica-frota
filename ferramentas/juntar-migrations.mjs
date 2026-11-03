// Junta as migrations num único arquivo para colar no SQL Editor do Supabase
// (alternativa ao Supabase CLI):  node ferramentas/juntar-migrations.mjs
import { readFileSync, readdirSync, writeFileSync } from 'node:fs';

export function juntar() {
  const pasta = new URL('../supabase/migrations/', import.meta.url);
  const partes = readdirSync(pasta).filter((a) => a.endsWith('.sql')).sort()
    .map((a) => `-- ===== ${a} =====\n${readFileSync(new URL(a, pasta), 'utf8').trim()}\n`);
  return `-- GERADO por ferramentas/juntar-migrations.mjs. Não edite à mão.\n-- Instalação completa do banco, para rodar UMA vez num projeto Supabase novo.\nbegin;\n\n${partes.join('\n')}\ncommit;\n`;
}

if (import.meta.url === `file://${process.argv[1]}`) {
  writeFileSync(new URL('../supabase/instalacao-completa.sql', import.meta.url), juntar());
  console.log('Gerado: supabase/instalacao-completa.sql');
}
