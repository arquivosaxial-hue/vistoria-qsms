# Vistoria QSMS — Construtora Axial

App (PWA) para vistoria simplificada de obras: **DDS**, **Visita na Obra** e
**Incidente / Acidente**. Funciona no celular, que pode instalar o app na tela
inicial, e no computador.

- **Usuário (técnico de segurança)** registra. Ele **não digita e não vê data
  nem hora**: o servidor do Supabase grava esse dado no envio.
- **Administrador (engenharia de segurança)** vê tudo com data e hora, edita
  (com histórico), analisa, gera PDF e planilha, e cadastra usuários.

## Onde fica o quê

| Caminho | O que é |
|---|---|
| `index.html` | O app inteiro, em um arquivo só |
| `sw.js`, `manifest.json`, `icon-*.png`, `logo.png` | Instalação no celular e ícones |
| `sql/01-estrutura.sql` | Banco completo: tabelas, regras de acesso (RLS), bucket de fotos e listas iniciais |
| `sql/02-primeiro-admin.sql` | Transforma a engenheira em administradora |
| `supabase/functions/gerenciar-usuario/` | Função do servidor para criar usuário, trocar senha, bloquear e reativar |
| `.github/workflows/` | Publicar o site, manter o Supabase ativo e conferir a versão |

## Modo demonstração

Enquanto o `index.html` tiver `COLE_AQUI...` no lugar da URL e da chave, o app
roda em **modo demonstração**: os dados ficam só no aparelho. Os logins são
`admin`, `tecnico1` e `tecnico2`, todos com a senha `demo1234`.

## Colocar no ar (uma vez)

### 1. Supabase
1. Crie um projeto novo em supabase.com (região São Paulo).
   Em *Data API*, deixe **desligado** o "Automatically expose new tables".
2. Vá em **SQL Editor**, cole `sql/01-estrutura.sql` e clique em **Run**. Confira
   o resultado no fim: as tabelas devem aparecer com `true` e o bucket com
   `publico: false`.
3. Vá em **Authentication → Sign In / Providers → Email** e **desligue** "Allow new users
   to sign up". Assim só a admin cria acessos.
4. Vá em **Authentication → Users → Add user**, informe o e-mail e a senha da
   engenheira e marque "Auto Confirm".
5. Abra `sql/02-primeiro-admin.sql`, troque o e-mail pelo dela e clique em **Run**.
6. Vá em **Edge Functions → Deploy new function**, dê o nome `gerenciar-usuario`
   e cole o arquivo `supabase/functions/gerenciar-usuario/index.ts`.
7. Vá em **Project Settings → API Keys** e copie a **URL** e a chave
   **Publishable** (`sb_publishable_...`). Cole as duas no topo do `index.html`,
   em `SUPABASE_URL` e `SUPABASE_KEY`.
   ⚠️ Nunca use a chave `sb_secret_...` no `index.html`.

### 2. GitHub
1. Crie um repositório (por exemplo `vistoria-qsms`) e envie esta pasta.
2. Vá em **Settings → Pages → Source** e escolha **GitHub Actions**.
3. Em **Settings → Secrets and variables → Actions**, crie `SUPABASE_URL` e
   `SUPABASE_ANON_KEY` (a mesma chave publishable). Eles servem para o keepalive.
4. Opcional: crie a variável `SITE_URL` com o endereço publicado.
5. Opcional: para usar um domínio próprio, adicione um arquivo `CNAME` e
   inclua esse arquivo no `cp` do workflow *Publicar site*.

### 3. Primeiro acesso
A engenheira entra como **Administrador**, abre **Usuários → Novo usuário** e
cadastra os técnicos. O login pode ser um nome simples, como `joao.silva`, sem
e-mail. Ela anota a senha inicial e passa para cada técnico.

## Regras da casa

- **Ao mudar o app, suba a versão nos DOIS lugares**: `APP_VERSION` no
  `index.html` e `VERSION` no `sw.js`, com o mesmo número.
- **Data e hora são do servidor.** O técnico só envia pela função `registrar()`
  e não tem leitura da tabela `registros`.
- **Nada é apagado de verdade.** Os registros vão para a lixeira e podem ser
  restaurados. Toda edição da admin guarda a versão anterior na auditoria.
- **As fotos são privadas.** Ficam num bucket sem link público, e a admin vê
  por um link temporário de 1 hora.
- **A localização usa o GPS do celular.** O endereço aproximado vem do
  OpenStreetMap (Nominatim), e o técnico pode corrigir.

## Classificação de ocorrências (NBR 14280)

| Opção no app | Gera CAT? |
|---|---|
| Quase-acidente / incidente (sem lesão e sem dano) | Não |
| Acidente sem lesão (só dano material) | Não |
| Acidente com lesão **sem** afastamento | **Sim** |
| Acidente com lesão **com** afastamento | **Sim** |
| Acidente fatal | **Sim, imediata** |

Os tipos de acidente são típico, de trajeto e doença ocupacional. O painel da
admin mostra um alerta vermelho com o **prazo da CAT**: até o 1º dia útil
seguinte, conforme a Lei 8.213/91, art. 22. O cálculo não considera feriados.

## Próximos passos possíveis

- Fila offline: guardar o registro no celular quando não houver sinal e enviar
  depois.
- Aviso por e-mail ou WhatsApp para a engenheira quando chegar uma ocorrência
  com lesão.
- Relatório mensal consolidado em PDF.
- Backup semanal pelo GitHub Actions, como no projeto Dinâmica Natural.
