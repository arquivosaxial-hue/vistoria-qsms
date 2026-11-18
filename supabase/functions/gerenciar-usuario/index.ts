// ============================================================
// Edge Function: gerenciar-usuario — Vistoria QSMS (Construtora Axial)
// ------------------------------------------------------------
// Só o ADMIN usa. Faz o que o navegador não pode fazer com a chave
// pública: criar login, trocar senha, bloquear/reativar e mandar o
// e-mail de boas-vindas.
//
// Dois jeitos de cadastrar:
//  1. Login simples ("joao.silva", sem @): vira "joao.silva@vistoria-qsms.app".
//     A admin define a senha inicial e passa para o técnico. Sem e-mail.
//  2. E-mail de verdade ("joao@construtoraaxial.com.br") + "enviar e-mail":
//     a pessoa recebe o botão "Criar minha senha" (link de uso único) e
//     escolhe a própria senha. Ninguém além dela fica sabendo qual é.
//
// E-mail (Resend) — igual à Dinâmica Natural:
//   Secrets da função (Edge Functions → Secrets):
//     RESEND_API_KEY   obrigatório para enviar (re_...)
//     EMAIL_REMETENTE  opcional  (padrão abaixo)
//     EMAIL_RESPOSTA   opcional  (padrão abaixo)
//   O domínio do remetente precisa estar verificado no Resend.
//
// Bloquear = perfil.ativo=false E "ban" no Auth (o ban impede o
// login; o ativo=false fecha os dados no banco).
//
// Publicar: painel → Edge Functions → gerenciar-usuario → Code → colar → Deploy
// Em Settings da função: "Verify JWT with legacy secret" DESLIGADO
// (a própria função confere quem chama).
// ============================================================
import { createClient } from 'npm:@supabase/supabase-js@2';

const CORS = {
  'Access-Control-Allow-Origin': '*',
  'Access-Control-Allow-Headers': 'authorization, x-client-info, apikey, content-type',
  'Access-Control-Allow-Methods': 'POST, OPTIONS',
};
const BAN_LONGO = '876000h'; // ~100 anos
const DOMINIO_USUARIO = 'vistoria-qsms.app';
const REMETENTE_PADRAO = 'Vistoria QSMS · Construtora Axial <nao-responda@qsms-axial.frentedigital.app.br>';
const RESPOSTA_PADRAO = 'qsms.axial@frentedigital.app.br';

function resposta(corpo: unknown, status = 200) {
  return new Response(JSON.stringify(corpo), {
    status,
    headers: { ...CORS, 'Content-Type': 'application/json' },
  });
}
const erro = (msg: string) => resposta({ ok: false, erro: msg });

function esc(s: string): string {
  return String(s ?? '').replace(/[&<>"']/g, (c) => ({ '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;' }[c]!));
}

function paraLogin(u: string): string {
  const s = String(u || '').trim().toLowerCase();
  return s.includes('@') ? s : `${s}@${DOMINIO_USUARIO}`;
}
const emailDeVerdade = (e: string) => !!e && !e.endsWith('@' + DOMINIO_USUARIO);

function senhaAleatoria(): string {
  const b = new Uint8Array(24);
  crypto.getRandomValues(b);
  return btoa(String.fromCharCode(...b)).replace(/[^A-Za-z0-9]/g, '').slice(0, 24) + 'aA1!';
}

function traduzir(msg: string): string {
  const m = String(msg || '');
  if (/already been registered|already registered|exists/i.test(m)) return 'Já existe um usuário com este login.';
  if (/password.*(short|least|characters)/i.test(m)) return 'A senha precisa ter pelo menos 8 caracteres.';
  if (/weak|pwned|leaked/i.test(m)) return 'Senha muito fraca ou conhecida. Escolha outra.';
  if (/invalid.*email|email.*invalid/i.test(m)) return 'Login inválido.';
  return m;
}

Deno.serve(async (req) => {
  if (req.method === 'OPTIONS') return new Response('ok', { headers: CORS });
  if (req.method !== 'POST') return erro('Método não permitido.');

  const url = Deno.env.get('SUPABASE_URL')!;
  let service = Deno.env.get('SUPABASE_SERVICE_ROLE_KEY') || '';
  if (!service) {
    try { service = Object.values(JSON.parse(Deno.env.get('SUPABASE_SECRET_KEYS') || '{}'))[0] as string || ''; } catch { /* segue */ }
  }
  if (!service) return erro('Chave de serviço indisponível na função.');
  const adm = createClient(url, service, { auth: { persistSession: false, autoRefreshToken: false } });

  // 1. Quem está chamando? Precisa ser admin ativo.
  const token = (req.headers.get('Authorization') || '').replace(/^Bearer\s+/i, '');
  if (!token) return erro('Sessão ausente. Entre novamente.');
  const { data: quem, error: eQuem } = await adm.auth.getUser(token);
  if (eQuem || !quem?.user) return erro('Sessão inválida. Entre novamente.');
  const { data: perfilAdm } = await adm.from('perfis')
    .select('id,nome,papel,ativo,removido_em').eq('id', quem.user.id).maybeSingle();
  if (!perfilAdm || perfilAdm.papel !== 'admin' || !perfilAdm.ativo || perfilAdm.removido_em) {
    return erro('Apenas administradores podem fazer isto.');
  }

  let corpo: Record<string, unknown> = {};
  try { corpo = await req.json(); } catch { return erro('Pedido inválido.'); }
  const acao = String(corpo.acao || '');
  const id = String(corpo.id || '');
  // endereço do app (vem do navegador da admin); o Supabase só aceita se
  // estiver em Authentication → URL Configuration → Redirect URLs
  const site = /^https:\/\/[^\s"'<>]+$/.test(String(corpo.site || '')) ? String(corpo.site) : undefined;

  async function auditar(acaoTxt: string, alvoId: string, resumo: string) {
    await adm.from('auditoria').insert({
      usuario_id: perfilAdm!.id, usuario_nome: perfilAdm!.nome,
      acao: acaoTxt, tabela: 'perfis', registro_id: alvoId, resumo: resumo.slice(0, 200),
    });
  }

  async function enviarBoasVindas(email: string, nome: string): Promise<string | null> {
    if (!emailDeVerdade(email)) return 'Este usuário entra com login simples, sem e-mail. Defina a senha e passe para ele.';
    const chave = Deno.env.get('RESEND_API_KEY');
    if (!chave) return 'E-mail ainda não configurado (falta o secret RESEND_API_KEY na função).';
    const { data: link, error: eL } = await adm.auth.admin.generateLink({
      type: 'recovery', email, options: site ? { redirectTo: site } : undefined,
    });
    const acesso = link?.properties?.action_link;
    if (eL || !acesso) return 'Não consegui gerar o link: ' + (eL?.message || 'sem link');
    const primeiro = esc(nome.split(/\s+/)[0] || nome);
    const appUrl = esc(site || '');
    const html = `<div style="font-family:Arial,Helvetica,sans-serif;background:#eef4f9;padding:24px">
  <div style="max-width:520px;margin:0 auto;background:#fff;border-radius:14px;overflow:hidden">
    <div style="background:#155F8F;padding:18px 22px;color:#fff;font-weight:bold;font-size:18px">Vistoria QSMS · Construtora Axial</div>
    <div style="padding:22px;color:#1f2a33;font-size:15px;line-height:1.55">
      <p style="margin:0 0 12px">Olá, ${primeiro}!</p>
      <p style="margin:0 0 12px">Seu acesso ao app <b>Vistoria QSMS</b> da Construtora Axial foi liberado.</p>
      <p style="margin:0 0 18px">Para começar, crie a sua senha:</p>
      <p style="margin:0 0 20px;text-align:center"><a href="${esc(acesso)}" style="background:#1B7BB8;color:#fff;text-decoration:none;font-weight:bold;padding:13px 26px;border-radius:26px;display:inline-block">Criar minha senha</a></p>
      <p style="margin:0 0 6px"><b>Seu login:</b> ${esc(email)}</p>
      ${appUrl ? `<p style="margin:0 0 12px"><b>Endereço do app:</b> <a href="${appUrl}" style="color:#155F8F">${appUrl}</a></p>` : ''}
      <p style="margin:0 0 12px;font-size:13px;color:#5c6873">O botão vale por tempo limitado e funciona uma vez só. Se expirar, peça à engenharia de segurança para reenviar.</p>
      <p style="margin:0;font-size:13px;color:#5c6873">Dica: no celular, abra o app e use “Adicionar à tela inicial” para ter o ícone.</p>
    </div>
  </div>
</div>`;
    const r = await fetch('https://api.resend.com/emails', {
      method: 'POST',
      headers: { Authorization: `Bearer ${chave}`, 'Content-Type': 'application/json' },
      body: JSON.stringify({
        from: Deno.env.get('EMAIL_REMETENTE') || REMETENTE_PADRAO,
        to: [email],
        reply_to: Deno.env.get('EMAIL_RESPOSTA') || RESPOSTA_PADRAO,
        subject: 'Seu acesso ao Vistoria QSMS — Construtora Axial',
        html,
      }),
    });
    if (!r.ok) return 'O serviço de e-mail recusou: ' + (await r.text()).slice(0, 160);
    return null;
  }

  try {
    // ---------------------------------------------------------- criar
    if (acao === 'criar') {
      const login = paraLogin(String(corpo.login || ''));
      const nome = String(corpo.nome || '').trim();
      const comEmail = !!corpo.enviar_email && emailDeVerdade(login);
      // com e-mail de boas-vindas, a pessoa cria a própria senha
      const senha = comEmail && !corpo.senha ? senhaAleatoria() : String(corpo.senha || '');
      const papel = corpo.papel === 'admin' ? 'admin' : 'tecnico';
      const funcao = String(corpo.funcao || '').trim();
      const registro = String(corpo.registro || '').trim();
      if (!nome) return erro('Informe o nome.');
      if (!/^[^\s@]+@[^\s@]+\.[^\s@]+$/.test(login)) return erro('Login inválido (use letras, números, ponto).');
      if (senha.length < 8) return erro('A senha precisa ter pelo menos 8 caracteres.');

      const { data, error } = await adm.auth.admin.createUser({
        email: login, password: senha, email_confirm: true, user_metadata: { nome },
      });
      if (error || !data?.user) {
        if (/already|exists/i.test(error?.message || '')) {
          const { data: ja } = await adm.from('perfis').select('nome,ativo').ilike('email', login).maybeSingle();
          if (ja && !ja.ativo) return erro(`${ja.nome} já usa este login, mas está bloqueado. Toque no nome na lista e use “Reativar”.`);
          if (ja) return erro(`${ja.nome} já usa este login.`);
        }
        return erro(traduzir(error?.message || 'Falha ao criar.'));
      }
      const { error: eP } = await adm.from('perfis').upsert({
        id: data.user.id, email: login, nome, papel, funcao, registro, ativo: true, removido_em: null,
      });
      if (eP) return erro('Login criado, mas o perfil falhou: ' + eP.message);
      await auditar('cadastrou usuário', data.user.id, `${nome} <${login}> (${papel})`);
      let emailErro: string | null = null;
      if (comEmail) {
        emailErro = await enviarBoasVindas(login, nome);
        if (!emailErro) await auditar('enviou e-mail de boas-vindas', data.user.id, `${nome} <${login}>`);
      }
      return resposta({ ok: true, id: data.user.id, login, email_enviado: comEmail && !emailErro, email_erro: emailErro });
    }

    if (!id) return erro('Usuário não informado.');
    const { data: p } = await adm.from('perfis').select('id,nome,email,papel').eq('id', id).maybeSingle();
    if (!p) return erro('Usuário não encontrado.');
    const eu = id === perfilAdm.id;

    // ---------------------------------------------------------- editar
    if (acao === 'editar') {
      const nome = String(corpo.nome ?? p.nome).trim();
      const papel = corpo.papel === 'admin' ? 'admin' : (corpo.papel === 'tecnico' ? 'tecnico' : p.papel);
      const funcao = String(corpo.funcao ?? '').trim();
      const registro = String(corpo.registro ?? '').trim();
      if (!nome) return erro('Informe o nome.');
      if (eu && papel !== 'admin') return erro('Você não pode tirar o seu próprio acesso de administrador.');
      await adm.auth.admin.updateUserById(id, { user_metadata: { nome } });
      const { error: eP } = await adm.from('perfis').update({ nome, papel, funcao, registro }).eq('id', id);
      if (eP) return erro(eP.message);
      await auditar('editou usuário', id, `${nome} <${p.email}> (${papel})`);
      return resposta({ ok: true });
    }

    // ---------------------------------------------------------- reenviar boas-vindas
    if (acao === 'boas_vindas') {
      const falha = await enviarBoasVindas(p.email, p.nome);
      if (falha) return erro(falha);
      await auditar('enviou e-mail de boas-vindas', id, `${p.nome} <${p.email}>`);
      return resposta({ ok: true });
    }

    // ---------------------------------------------------------- senha
    if (acao === 'senha') {
      const senha = String(corpo.senha || '');
      if (senha.length < 8) return erro('A senha precisa ter pelo menos 8 caracteres.');
      const { error } = await adm.auth.admin.updateUserById(id, { password: senha });
      if (error) return erro(traduzir(error.message));
      await auditar('redefiniu senha', id, `${p.nome} <${p.email}>`);
      return resposta({ ok: true });
    }

    // ---------------------------------------------------------- bloquear
    if (acao === 'bloquear') {
      if (eu) return erro('Você não pode bloquear a si mesma.');
      const { error } = await adm.auth.admin.updateUserById(id, { ban_duration: BAN_LONGO });
      if (error) return erro(traduzir(error.message));
      await adm.from('perfis').update({ ativo: false }).eq('id', id);
      await auditar('bloqueou', id, `${p.nome} <${p.email}>`);
      return resposta({ ok: true });
    }

    // ---------------------------------------------------------- reativar
    if (acao === 'reativar') {
      const { error } = await adm.auth.admin.updateUserById(id, { ban_duration: 'none' });
      if (error) return erro(traduzir(error.message));
      await adm.from('perfis').update({ ativo: true, removido_em: null }).eq('id', id);
      await auditar('reativou', id, `${p.nome} <${p.email}>`);
      return resposta({ ok: true });
    }

    return erro('Ação desconhecida: ' + acao);
  } catch (e) {
    return erro('Erro inesperado: ' + (e instanceof Error ? e.message : String(e)));
  }
});
