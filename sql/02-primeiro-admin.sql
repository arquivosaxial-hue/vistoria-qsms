-- ============================================================
-- VISTORIA QSMS — 02 — TRANSFORMA A ENGENHEIRA EM ADMINISTRADORA
-- ============================================================
-- Use UMA vez. Os próximos usuários a própria admin cadastra pelo app
-- (Administrador → Usuários → Novo usuário).
--
-- Antes: Supabase → Authentication → Users → Add user → Create new user
--        (e-mail + senha, marque "Auto Confirm User").
--
-- Troque o e-mail e o nome abaixo e rode.
-- ============================================================
update public.perfis
set papel = 'admin', ativo = true, removido_em = null,
    nome = 'Engenheira de Segurança',
    funcao = 'Engenheira de Segurança do Trabalho'
where lower(email) = lower('engenheira@construtoraaxial.com.br');

-- Confira: deve aparecer 1 linha com papel = admin.
select nome, email, papel, ativo from public.perfis order by criado_em;
