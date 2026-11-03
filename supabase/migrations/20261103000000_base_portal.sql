-- Base do portal: tabelas que o módulo Gestão da Frota pressupõe existirem
-- (no sistema original vinham dos "módulos antigos"). Instalação nova do zero.

-- O Supabase concede, por padrão, ALL em tabelas/funções novas do schema public
-- para anon e authenticated. O módulo foi escrito e testado num Postgres sem
-- esse padrão, com GRANTs explícitos. Removemos o padrão para que valham
-- apenas as permissões declaradas nas migrations.
alter default privileges for role postgres in schema public revoke all on tables from anon, authenticated;
alter default privileges for role postgres in schema public revoke all on sequences from anon, authenticated;
alter default privileges for role postgres in schema public revoke all on functions from anon, authenticated, public;

-- Perfis: um por usuário do Supabase Auth. Nasce DESATIVADO: mesmo que o cadastro
-- público do Supabase fique ligado por engano, ninguém entra sem o administrador
-- liberar (perfis.ativo = true).
create table public.perfis (
  id uuid primary key references auth.users(id) on delete cascade,
  nome text not null check (btrim(nome) <> ''),
  email text,
  ativo boolean not null default false,
  senha_provisoria boolean not null default true,
  criado_em timestamptz not null default now()
);

-- Todo usuário criado no Supabase Auth ganha um perfil desativado com senha provisória.
create function public.perfis_criar_do_usuario()
returns trigger language plpgsql security definer set search_path = pg_catalog, public as $$
begin
  insert into public.perfis (id, nome, email)
  values (new.id, coalesce(nullif(btrim(new.raw_user_meta_data->>'nome'), ''), split_part(new.email, '@', 1), 'Usuário'), new.email)
  on conflict (id) do nothing;
  return new;
end $$;
revoke all on function public.perfis_criar_do_usuario() from public, anon, authenticated;
create trigger perfis_criar_do_usuario after insert on auth.users
  for each row execute function public.perfis_criar_do_usuario();

-- Chamado pela tela de login depois que o usuário troca a senha provisória.
create function public.perfil_confirmar_senha_definitiva()
returns void language sql security definer set search_path = pg_catalog, public as $$
  update public.perfis set senha_provisoria = false where id = auth.uid();
$$;
revoke all on function public.perfil_confirmar_senha_definitiva() from public, anon;
grant execute on function public.perfil_confirmar_senha_definitiva() to authenticated;

create function public.perfil_ativo()
returns boolean language sql stable security definer set search_path = pg_catalog, public as $$
  select exists (select 1 from public.perfis where id = auth.uid() and ativo and not senha_provisoria);
$$;
revoke all on function public.perfil_ativo() from public, anon;
grant execute on function public.perfil_ativo() to authenticated;

alter table public.perfis enable row level security;
grant select on public.perfis to authenticated;
create policy proprio_perfil on public.perfis for select to authenticated using (id = auth.uid());

-- Unidades operacionais (filiais).
create table public.operacoes (
  id uuid primary key default gen_random_uuid(),
  nome text not null unique check (btrim(nome) <> ''),
  ativa boolean not null default true
);

create table public.frota_centros_custo (
  codigo text primary key check (btrim(codigo) <> ''),
  nome text not null check (btrim(nome) <> '')
);

create table public.veiculos (
  id uuid primary key default gen_random_uuid(),
  placa text not null unique check (btrim(placa) <> ''),
  operacao_id uuid not null references public.operacoes(id),
  centro_custo text references public.frota_centros_custo(codigo)
);

-- Identidade dos fornecedores; os dados ficam em frota_gestao_fornecedores.
create table public.frota_fornecedores (
  id uuid primary key default gen_random_uuid()
);

do $$
declare tabela text;
begin
  foreach tabela in array array['operacoes', 'frota_centros_custo', 'veiculos', 'frota_fornecedores'] loop
    execute format('alter table public.%I enable row level security', tabela);
    execute format('grant select on public.%I to authenticated', tabela);
    execute format('create policy usuario_ativo_le on public.%I for select to authenticated using (public.perfil_ativo())', tabela);
  end loop;
end $$;
