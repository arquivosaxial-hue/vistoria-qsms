-- ============================================================
-- VISTORIA QSMS — Construtora Axial
-- 01 — ESTRUTURA COMPLETA DO BANCO (projeto novo)
-- ============================================================
-- Onde rodar: Supabase → SQL Editor → New query → cole TUDO → Run.
--
-- Pode rodar de novo sem estragar nada ("if not exists" / "or replace").
--
-- Regras principais deste app:
--   • DATA E HORA SÃO DO SERVIDOR. O técnico não digita, não vê e não
--     consegue alterar. O registro entra pela função registrar(), que
--     grava criado_em = now() no banco. O técnico NÃO tem leitura da
--     tabela registros: só o admin (engenheira) vê os registros e as horas.
--   • Quem é admin é decidido pelo BANCO (tabela perfis), não pela tela.
--   • Nada é apagado de verdade: o admin manda para a lixeira (excluido_em).
--   • Toda edição do admin fica na auditoria, com o conteúdo de ANTES.
--   • Fotos ficam num bucket PRIVADO (sem link público), com limite de
--     tamanho e de tipo. O admin vê por link temporário.
--   • Anônimo (sem login) não lê nada. Só existe o ping() do keepalive.
-- ============================================================


-- ============================================================
-- 1. TABELAS
-- ============================================================

-- Perfis: 1 linha por pessoa do Auth. O id É o id do Auth.
create table if not exists public.perfis (
  id             uuid primary key references auth.users(id) on delete cascade,
  nome           text not null default '',
  email          text not null default '',   -- login (e-mail ou usuario@vistoria-qsms.app)
  funcao         text not null default '',   -- ex.: Técnico de Segurança do Trabalho
  registro       text not null default '',   -- ex.: registro profissional / MTE
  papel          text not null default 'tecnico'
                 check (papel in ('admin','tecnico')),
  ativo          boolean not null default true,
  removido_em    timestamptz,
  criado_em      timestamptz not null default now(),
  atualizado_em  timestamptz not null default now()
);

-- Opções das listas (o admin edita pelo app).
--   tema_dds  → assuntos comuns de DDS
--   servico   → serviços executados nas obras
--   obra      → obras / locais em andamento (sugestão no campo "Obra")
create table if not exists public.opcoes (
  id         uuid primary key default gen_random_uuid(),
  tipo       text not null check (tipo in ('tema_dds','servico','obra')),
  nome       text not null,
  ordem      int  not null default 0,
  ativo      boolean not null default true,
  criado_em  timestamptz not null default now(),
  unique (tipo, nome)
);

-- Itens do checklist de EPI/EPC da Visita na Obra (ficha da engenheira).
-- A descrição é COPIADA para dentro de cada visita no momento do envio,
-- então editar um item depois não muda as visitas antigas.
create table if not exists public.checklist_itens (
  id         uuid primary key default gen_random_uuid(),
  descricao  text not null unique,
  tipo       text not null default 'Geral' check (tipo in ('EPI','EPC','Geral')),
  ordem      int  not null default 0,
  ativo      boolean not null default true,
  criado_em  timestamptz not null default now()
);

-- Registros: DDS, Visita na Obra e Incidente/Acidente.
-- Campos comuns em colunas; o conteúdo próprio de cada tipo em "dados".
create table if not exists public.registros (
  id             uuid primary key default gen_random_uuid(),
  numero         bigint generated always as identity unique,   -- nº para conversa: "Visita 12"
  tipo           text not null check (tipo in ('dds','visita','ocorrencia')),
  autor_id       uuid references public.perfis(id) on delete set null,
  autor_nome     text not null default '',      -- cópia do nome no envio
  obra           text not null default '',
  endereco       text not null default '',
  latitude       double precision,
  longitude      double precision,
  precisao_m     double precision,              -- precisão do GPS em metros
  dados          jsonb not null default '{}'::jsonb,
  fotos          jsonb not null default '[]'::jsonb,   -- [{path, legenda}]
  -- só do admin:
  status         text not null default 'novo'
                 check (status in ('novo','em_analise','concluido')),
  parecer        text not null default '',      -- comentário da engenheira
  excluido_em    timestamptz,
  -- carimbos do SERVIDOR:
  criado_em      timestamptz not null default now(),
  atualizado_em  timestamptz not null default now()
);

-- Registro de alterações (só o admin lê; quem grava são os gatilhos).
create table if not exists public.auditoria (
  id            bigint generated always as identity primary key,
  quando        timestamptz not null default now(),
  usuario_id    uuid,
  usuario_nome  text,
  acao          text not null,
  tabela        text not null,
  registro_id   text,
  resumo        text,
  antes         jsonb       -- conteúdo antes da edição (registros)
);

create index if not exists idx_registros_criado on public.registros (criado_em desc) where excluido_em is null;
create index if not exists idx_registros_tipo   on public.registros (tipo, criado_em desc);
create index if not exists idx_registros_autor  on public.registros (autor_id, criado_em desc);
create index if not exists idx_auditoria_quando on public.auditoria (quando desc);


-- ============================================================
-- 2. FUNÇÕES DE APOIO ÀS REGRAS DE ACESSO
-- (SECURITY DEFINER + search_path fixo: evita recursão no RLS)
-- ============================================================
create or replace function public.vq_ativo()
returns boolean language sql stable security definer set search_path = public as $$
  select coalesce((select ativo and removido_em is null
                   from public.perfis where id = auth.uid()), false);
$$;

create or replace function public.vq_eh_admin()
returns boolean language sql stable security definer set search_path = public as $$
  select coalesce((select papel = 'admin' and ativo and removido_em is null
                   from public.perfis where id = auth.uid()), false);
$$;

-- Keepalive: o GitHub chama 3x por dia para o Supabase gratuito não pausar.
-- Lição da Dinâmica Natural: só LER não bastou (o projeto foi avisado de
-- pausa mesmo com o ping verde). Aqui o ping GRAVA uma marca no banco.
create table if not exists public.batimento (
  id     int primary key default 1 check (id = 1),
  quando timestamptz not null default now()
);
alter table public.batimento enable row level security;   -- sem policy: ninguém lê pelo app

create or replace function public.ping()
returns text language plpgsql security definer set search_path = public as $$
begin
  insert into public.batimento (id, quando) values (1, now())
  on conflict (id) do update set quando = excluded.quando;
  return 'ok ' || to_char(now(), 'YYYY-MM-DD HH24:MI:SS');
end $$;


-- ============================================================
-- 3. ENVIO DE REGISTRO (a ÚNICA porta de entrada do técnico)
-- ------------------------------------------------------------
-- O app manda só o conteúdo. Quem envia, data e hora são definidos
-- AQUI, no servidor. Devolve apenas o número do registro.
-- ============================================================
create or replace function public.registrar(p jsonb)
returns jsonb language plpgsql security definer set search_path = public as $$
declare
  v_tipo   text  := coalesce(p->>'tipo', '');
  v_fotos  jsonb := coalesce(p->'fotos', '[]'::jsonb);
  v_dados  jsonb := coalesce(p->'dados', '{}'::jsonb);
  v_nome   text;
  v_num    bigint;
begin
  if auth.uid() is null or not public.vq_ativo() then
    raise exception 'Acesso não autorizado.';
  end if;
  if v_tipo not in ('dds','visita','ocorrencia') then
    raise exception 'Tipo de registro inválido.';
  end if;
  if jsonb_typeof(v_fotos) <> 'array' or jsonb_typeof(v_dados) <> 'object' then
    raise exception 'Formato inválido.';
  end if;
  if jsonb_array_length(v_fotos) > 12 then
    raise exception 'Máximo de 12 fotos por registro.';
  end if;
  -- cada foto precisa estar na pasta da própria pessoa
  if exists (select 1 from jsonb_array_elements(v_fotos) f
             where coalesce(f->>'path','') not like auth.uid()::text || '/%') then
    raise exception 'Foto fora da pasta do usuário.';
  end if;
  -- ninguém "manda" data/hora/autor dentro dos dados
  v_dados := v_dados - 'criado_em' - 'data' - 'hora' - 'autor_id';

  select nome into v_nome from public.perfis where id = auth.uid();

  insert into public.registros (tipo, autor_id, autor_nome, obra, endereco,
                                latitude, longitude, precisao_m, dados, fotos)
  values (v_tipo, auth.uid(), coalesce(v_nome,''),
          left(coalesce(p->>'obra',''), 200),
          left(coalesce(p->>'endereco',''), 400),
          nullif(p->>'latitude','')::double precision,
          nullif(p->>'longitude','')::double precision,
          nullif(p->>'precisao_m','')::double precision,
          v_dados, v_fotos)
  returning numero into v_num;

  return jsonb_build_object('numero', v_num);   -- sem data/hora de propósito
end $$;


-- ============================================================
-- 4. GATILHOS
-- ============================================================

-- Pessoa criada no Auth → nasce o perfil (técnico, ativo).
create or replace function public.vq_novo_usuario()
returns trigger language plpgsql security definer set search_path = public as $$
begin
  insert into public.perfis (id, email, nome)
  values (new.id, coalesce(new.email,''),
          coalesce(nullif(new.raw_user_meta_data->>'nome',''), split_part(coalesce(new.email,''),'@',1)))
  on conflict (id) do nothing;
  return new;
end $$;

drop trigger if exists vq_ao_criar_usuario on auth.users;
create trigger vq_ao_criar_usuario
  after insert on auth.users
  for each row execute function public.vq_novo_usuario();

-- atualizado_em automático. Em registros, criado_em e autor NUNCA mudam.
create or replace function public.vq_carimbar()
returns trigger language plpgsql as $$
begin
  new.atualizado_em := now();
  if tg_op = 'UPDATE' and tg_table_name = 'registros' then
    new.criado_em  := old.criado_em;
    new.autor_id   := old.autor_id;
    new.autor_nome := old.autor_nome;
  end if;
  return new;
end $$;

drop trigger if exists vq_carimbo on public.perfis;
create trigger vq_carimbo before insert or update on public.perfis
  for each row execute function public.vq_carimbar();
drop trigger if exists vq_carimbo on public.registros;
create trigger vq_carimbo before insert or update on public.registros
  for each row execute function public.vq_carimbar();

-- Técnico não muda o próprio papel nem se desbloqueia (segunda tranca).
create or replace function public.vq_proteger_perfil()
returns trigger language plpgsql security definer set search_path = public as $$
begin
  if auth.uid() is not null and not public.vq_eh_admin() then
    if new.papel is distinct from old.papel
       or new.ativo is distinct from old.ativo
       or new.removido_em is distinct from old.removido_em then
      raise exception 'Somente o administrador altera permissões.';
    end if;
  end if;
  return new;
end $$;

drop trigger if exists vq_protecao on public.perfis;
create trigger vq_protecao before update on public.perfis
  for each row execute function public.vq_proteger_perfil();

-- Auditoria das alterações feitas pelo admin.
create or replace function public.vq_auditar()
returns trigger language plpgsql security definer set search_path = public as $$
declare
  v_nome   text;
  v_acao   text := lower(tg_op);
  v_linha  jsonb := to_jsonb(coalesce(new, old));
  v_antes  jsonb := null;
  v_resumo text;
begin
  if not public.vq_eh_admin() then
    return coalesce(new, old);
  end if;
  select nome into v_nome from public.perfis where id = auth.uid();
  if tg_table_name = 'registros' then
    v_resumo := upper(v_linha->>'tipo') || ' nº ' || (v_linha->>'numero') || ' — ' || coalesce(v_linha->>'obra','');
  else
    v_resumo := coalesce(v_linha->>'descricao', v_linha->>'nome', '');
  end if;
  if tg_op = 'UPDATE' then
    if (to_jsonb(old)->>'excluido_em') is null and (v_linha->>'excluido_em') is not null then
      v_acao := 'enviou para a lixeira';
    elsif (to_jsonb(old)->>'excluido_em') is not null and (v_linha->>'excluido_em') is null then
      v_acao := 'restaurou';
    elsif tg_table_name = 'registros'
          and (to_jsonb(old) - 'status' - 'atualizado_em') = (v_linha - 'status' - 'atualizado_em') then
      v_acao := 'status: ' || coalesce(to_jsonb(old)->>'status','') || ' → ' || coalesce(v_linha->>'status','');
    else
      v_acao := 'editou';
      if tg_table_name = 'registros' then v_antes := to_jsonb(old); end if;
    end if;
  elsif tg_op = 'INSERT' then
    v_acao := 'criou';
  end if;
  insert into public.auditoria (usuario_id, usuario_nome, acao, tabela, registro_id, resumo, antes)
  values (auth.uid(), v_nome, v_acao, tg_table_name, v_linha->>'id', left(v_resumo, 200), v_antes);
  return coalesce(new, old);
end $$;

drop trigger if exists vq_auditoria on public.registros;
create trigger vq_auditoria after update on public.registros
  for each row execute function public.vq_auditar();
drop trigger if exists vq_auditoria on public.opcoes;
create trigger vq_auditoria after insert or update on public.opcoes
  for each row execute function public.vq_auditar();
drop trigger if exists vq_auditoria on public.checklist_itens;
create trigger vq_auditoria after insert or update on public.checklist_itens
  for each row execute function public.vq_auditar();


-- ============================================================
-- 5. PERMISSÕES (GRANTS) — explícitas
--   anon          → só o ping()
--   authenticated → o necessário (o RLS filtra as linhas)
--   service_role  → Edge Function e backup
-- ============================================================
grant usage on schema public to anon, authenticated, service_role;

revoke all on all tables    in schema public from anon;
revoke all on all functions in schema public from anon, public;

grant all on all tables    in schema public to service_role;
grant all on all sequences in schema public to service_role;
grant execute on all functions in schema public to service_role;

grant select, update        on public.perfis          to authenticated;
grant select, insert, update on public.opcoes          to authenticated;
grant select, insert, update on public.checklist_itens to authenticated;
grant select, update        on public.registros       to authenticated;  -- insert só via registrar()
grant select                on public.auditoria       to authenticated;

grant execute on function public.ping() to anon, authenticated;
grant execute on function public.vq_ativo(), public.vq_eh_admin(), public.registrar(jsonb)
  to authenticated;


-- ============================================================
-- 6. REGRAS DE ACESSO (RLS)
-- ============================================================
alter table public.perfis          enable row level security;
alter table public.opcoes          enable row level security;
alter table public.checklist_itens enable row level security;
alter table public.registros       enable row level security;
alter table public.auditoria       enable row level security;

-- perfis: cada um vê o seu; admin vê e edita todos.
drop policy if exists perfis_ler on public.perfis;
create policy perfis_ler on public.perfis for select to authenticated
  using (id = auth.uid() or public.vq_eh_admin());
drop policy if exists perfis_admin_edita on public.perfis;
create policy perfis_admin_edita on public.perfis for update to authenticated
  using (public.vq_eh_admin()) with check (public.vq_eh_admin());

-- opcoes e checklist: ativos leem; admin cria e edita.
drop policy if exists opcoes_ler on public.opcoes;
create policy opcoes_ler on public.opcoes for select to authenticated
  using (public.vq_ativo());
drop policy if exists opcoes_admin_cria on public.opcoes;
create policy opcoes_admin_cria on public.opcoes for insert to authenticated
  with check (public.vq_eh_admin());
drop policy if exists opcoes_admin_edita on public.opcoes;
create policy opcoes_admin_edita on public.opcoes for update to authenticated
  using (public.vq_eh_admin()) with check (public.vq_eh_admin());

drop policy if exists checklist_ler on public.checklist_itens;
create policy checklist_ler on public.checklist_itens for select to authenticated
  using (public.vq_ativo());
drop policy if exists checklist_admin_cria on public.checklist_itens;
create policy checklist_admin_cria on public.checklist_itens for insert to authenticated
  with check (public.vq_eh_admin());
drop policy if exists checklist_admin_edita on public.checklist_itens;
create policy checklist_admin_edita on public.checklist_itens for update to authenticated
  using (public.vq_eh_admin()) with check (public.vq_eh_admin());

-- registros: SÓ o admin lê e edita. Técnico só envia (pela registrar()).
drop policy if exists registros_admin_le on public.registros;
create policy registros_admin_le on public.registros for select to authenticated
  using (public.vq_eh_admin());
drop policy if exists registros_admin_edita on public.registros;
create policy registros_admin_edita on public.registros for update to authenticated
  using (public.vq_eh_admin()) with check (public.vq_eh_admin());

-- auditoria: só o admin lê.
drop policy if exists auditoria_admin_le on public.auditoria;
create policy auditoria_admin_le on public.auditoria for select to authenticated
  using (public.vq_eh_admin());


-- ============================================================
-- 7. STORAGE — bucket PRIVADO de fotos
-- ------------------------------------------------------------
-- 3 MB por arquivo, só imagem. O app reduz a foto antes (~150–300 KB).
-- Pasta: <id da pessoa>/<arquivo>.jpg
-- ============================================================
insert into storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
values ('fotos', 'fotos', false, 3145728, array['image/jpeg','image/png','image/webp'])
on conflict (id) do update
  set public = false,
      file_size_limit = excluded.file_size_limit,
      allowed_mime_types = excluded.allowed_mime_types;

drop policy if exists vq_fotos_enviar on storage.objects;
create policy vq_fotos_enviar on storage.objects for insert to authenticated
  with check (bucket_id = 'fotos' and public.vq_ativo()
              and (storage.foldername(name))[1] = auth.uid()::text);

-- ler: admin tudo; o técnico só a própria pasta (o upload precisa "ver" o arquivo)
drop policy if exists vq_fotos_ler on storage.objects;
create policy vq_fotos_ler on storage.objects for select to authenticated
  using (bucket_id = 'fotos' and (public.vq_eh_admin()
         or (public.vq_ativo() and (storage.foldername(name))[1] = auth.uid()::text)));

-- apagar: só o admin
drop policy if exists vq_fotos_apagar on storage.objects;
create policy vq_fotos_apagar on storage.objects for delete to authenticated
  using (bucket_id = 'fotos' and public.vq_eh_admin());


-- ============================================================
-- 8. DADOS INICIAIS (o admin edita depois pelo app)
-- ============================================================
insert into public.checklist_itens (descricao, tipo, ordem) values
  ('Uso obrigatório de Capacete, Botina de Segurança e Óculos', 'EPI', 1),
  ('Protetor Auditivo em áreas de ruído intenso (>85 dB)', 'EPI', 2),
  ('Uso de Cinto de Segurança tipo Paraquedista para Trabalho em Altura', 'EPI', 3),
  ('Luvas adequadas para a atividade (Raspa, Nitrílica, Vaqueta)', 'EPI', 4),
  ('Guarda-corpo, Rodapé e Proteção de Periferia em pavimentos', 'EPC', 5),
  ('Telas de Proteção, Tapumes e Sinalização de Segurança', 'EPC', 6),
  ('Aterramento Elétrico, Quadros Protegidos e Fiação Elevada', 'EPC', 7),
  ('Extintores de Incêndio desobstruídos e com validade em dia', 'EPC', 8),
  ('Organização, Limpeza e Desobstrução das Vias de Passagem', 'Geral', 9)
on conflict (descricao) do nothing;

insert into public.opcoes (tipo, nome, ordem) values
  ('tema_dds','Uso correto de EPI',1),
  ('tema_dds','Trabalho em altura (NR-35)',2),
  ('tema_dds','Escavações e valas',3),
  ('tema_dds','Sinalização e isolamento de área',4),
  ('tema_dds','Riscos elétricos (NR-10)',5),
  ('tema_dds','Máquinas e equipamentos (NR-12)',6),
  ('tema_dds','Ordem e limpeza no canteiro',7),
  ('tema_dds','Calor, hidratação e protetor solar',8),
  ('tema_dds','Trânsito e operação próxima a vias',9),
  ('tema_dds','Ergonomia e levantamento de cargas',10),
  ('tema_dds','Prevenção de incêndio',11),
  ('tema_dds','Comunicação de incidentes e quase-acidentes',12),
  ('servico','Escavação',1),
  ('servico','Repavimentação / asfalto',2),
  ('servico','Assentamento de rede (água/esgoto)',3),
  ('servico','Concretagem',4),
  ('servico','Alvenaria',5),
  ('servico','Armação / forma',6),
  ('servico','Instalações elétricas',7),
  ('servico','Demolição',8),
  ('servico','Trabalho em altura',9),
  ('servico','Içamento de cargas',10),
  ('servico','Calçada / meio-fio',11)
on conflict (tipo, nome) do nothing;


-- ============================================================
-- 9. [CONFERIR] — rode no fim e veja se está tudo certo
-- ============================================================
select jsonb_pretty(jsonb_build_object(
  'tabelas_com_rls', (select jsonb_object_agg(tablename, rowsecurity)
                      from pg_tables where schemaname = 'public'),
  'policies_com_delete', (select coalesce(jsonb_agg(tablename||'.'||policyname), '[]'::jsonb)
                          from pg_policies where schemaname = 'public' and cmd in ('DELETE','ALL')),
  'itens_checklist', (select count(*) from public.checklist_itens),
  'opcoes', (select count(*) from public.opcoes),
  'bucket', (select jsonb_build_object('publico', public, 'limite', file_size_limit)
             from storage.buckets where id = 'fotos'),
  'ping', public.ping()
));
-- Esperado: todas as tabelas "true"; policies_com_delete vazio;
-- 9 itens de checklist; 23 opções; bucket publico=false, limite 3145728.
