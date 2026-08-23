// Testa o worker.js sem o publicar: mocka o fetch para servir os ficheiros
// reais do repo e captura o que seria enviado ao Telegram.
import fs from 'node:fs';
import path from 'node:path';

import { fileURLToPath } from 'node:url';
const REPO = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '..');
const worker = (await import(new URL('./worker.js', import.meta.url).href)).default;

const env = {
  TELEGRAM_BOT_TOKEN: '123456789:FAKE_TOKEN_FOR_TEST_ONLY_xxxxxxxxxx',
  TELEGRAM_WEBHOOK_SECRET: 'segredo-de-teste',
  GH_TOKEN: 'ghp_fake',
  GH_OWNER: 'ProgrammerBerserk',
  GH_REPO: 'whey-watch',
  GH_WORKFLOW: 'whey-watch.yml',
  GH_BRANCH: 'main',
  ALLOWED_CHAT_IDS: '-1001234567890',
};

let sent = [];
let dispatched = 0;

// estado do workflow que o mock devolve; alterado pelos testes
let fakeRun = {
  status: 'completed',
  conclusion: 'success',
  created_at: new Date(Date.now() - 3600e3).toISOString(),
};

globalThis.fetch = async (url, init = {}) => {
  const u = String(url);

  // ---- GitHub: ficheiros
  if (u.includes('/contents/')) {
    const m = u.match(/\/contents\/([^?]+)/);
    const file = decodeURIComponent(m[1]);
    const full = path.join(REPO, file);
    if (!fs.existsSync(full)) {
      return new Response('not found', { status: 404 });
    }
    return new Response(fs.readFileSync(full, 'utf8'), {
      status: 200,
      headers: { 'content-type': 'application/json' },
    });
  }

  // ---- GitHub: execucoes do workflow
  if (u.includes('/runs?')) {
    return new Response(JSON.stringify({ workflow_runs: fakeRun ? [fakeRun] : [] }), {
      status: 200,
      headers: { 'content-type': 'application/json' },
    });
  }

  // ---- GitHub: dispatch
  if (u.includes('/dispatches')) {
    dispatched++;
    if (init.method !== 'POST') throw new Error('dispatch deveria ser POST');
    const body = JSON.parse(init.body);
    if (body.ref !== 'main') throw new Error('ref errada: ' + body.ref);
    if (body.inputs.digest !== 'true') throw new Error('input digest errado');
    return new Response(null, { status: 204 });
  }

  // ---- Telegram
  if (u.includes('api.telegram.org')) {
    const body = JSON.parse(init.body);
    sent.push(body);
    return new Response(JSON.stringify({ ok: true, result: {} }), {
      status: 200,
      headers: { 'content-type': 'application/json' },
    });
  }

  throw new Error('fetch inesperado: ' + u);
};

function makeReq(text, { chatId = '-1001234567890', secret = 'segredo-de-teste' } = {}) {
  return new Request('https://worker.dev/', {
    method: 'POST',
    headers: {
      'content-type': 'application/json',
      'X-Telegram-Bot-Api-Secret-Token': secret,
    },
    body: JSON.stringify({
      update_id: 1,
      message: { message_id: 1, chat: { id: Number(chatId), type: 'supergroup' }, text },
    }),
  });
}

async function run(text, opts) {
  sent = [];
  const res = await worker.fetch(makeReq(text, opts), env);
  return { status: res.status, body: await res.text(), sent: [...sent] };
}

let fails = 0;
function check(name, cond, detail) {
  if (cond) {
    console.log(`  PASS  ${name}`);
  } else {
    fails++;
    console.log(`  FAIL  ${name}${detail ? ' -> ' + detail : ''}`);
  }
}

// ================================================================ seguranca

console.log('\n=== seguranca');

let r = await run('/best', { secret: 'errado' });
check('segredo errado devolve 403', r.status === 403, 'status=' + r.status);
check('segredo errado nao responde no Telegram', r.sent.length === 0);

r = await run('/best', { chatId: '999999' });
check('chat nao autorizado fica em silencio', r.sent.length === 0 && r.status === 200);

r = await run('/naoexiste');
check('comando desconhecido nao polui o grupo', r.sent.length === 0);

// ================================================================ comandos

console.log('\n=== /shop');
r = await run('/shop');
check('respondeu', r.sent.length === 1);
if (r.sent.length) {
  const t = r.sent[0].text;
  check('lista as lojas', /Fitnis/.test(t) && /Zumub/.test(t) && /MyProtein/.test(t));
  check('marca os residentialOnly', /so IP residencial/.test(t));
  check('mostra a percentagem de proteina', /% proteina/.test(t));
  console.log('\n----- /shop -----\n' + t + '\n-----------------');
}

console.log('\n=== /best');
r = await run('/best');
check('respondeu', r.sent.length === 1);
if (r.sent.length) {
  const t = r.sent[0].text;
  check('nao propoe produto esgotado', !/esgotado/i.test(t));
  check('usa virgula decimal', /\d,\d\d/.test(t));
  console.log('\n----- /best -----\n' + t + '\n-----------------');
}

console.log('\n=== /status');
r = await run('/status');
check('respondeu', r.sent.length === 1);
if (r.sent.length) {
  const t = r.sent[0].text;
  check('mostra as lojas que responderam', /lojas: \d+\/\d+ responderam/i.test(t));
  check('mostra o estado do workflow', /Workflow:/.test(t));
  console.log('\n----- /status -----\n' + t + '\n-------------------');
}

console.log('\n=== /update');

fakeRun = { status: 'in_progress', conclusion: null, created_at: new Date().toISOString() };
dispatched = 0;
r = await run('/update');
check('recusa se ja ha ronda a correr', dispatched === 0 && /a correr/i.test(r.sent[0].text));

fakeRun = { status: 'completed', conclusion: 'success', created_at: new Date(Date.now() - 30e3).toISOString() };
dispatched = 0;
r = await run('/update');
check('recusa se a ultima foi ha 30s', dispatched === 0 && /Espera/i.test(r.sent[0].text));

fakeRun = { status: 'completed', conclusion: 'success', created_at: new Date(Date.now() - 3600e3).toISOString() };
dispatched = 0;
r = await run('/update');
check('dispara quando pode', dispatched === 1, 'dispatched=' + dispatched);
if (r.sent.length) console.log('\n----- /update -----\n' + r.sent[0].text + '\n-------------------');

console.log('\n=== /help');
r = await run('/start');
check('/start responde com a ajuda', r.sent.length === 1 && /\/best/.test(r.sent[0].text));

console.log('\n=== mensagens de erro do GitHub');

// forcar respostas de erro nas leituras de ficheiros
const realFetch = globalThis.fetch;
function withGhStatus(code) {
  globalThis.fetch = async (url, init = {}) => {
    const u = String(url);
    if (u.includes('api.github.com')) {
      return new Response('{"message":"Bad credentials"}', { status: code });
    }
    return realFetch(url, init);
  };
}

withGhStatus(401);
r = await run('/best');
check(
  '401 explica que o GH_TOKEN e invalido',
  r.sent.length === 1 && /GH_TOKEN.*nao e uma credencial valida/s.test(r.sent[0].text),
  r.sent[0]?.text?.slice(0, 90)
);
check('401 diz o que correr para corrigir', /set-gh-token\.ps1/.test(r.sent[0].text));

withGhStatus(403);
r = await run('/shop');
check(
  '403 explica que faltam permissoes',
  r.sent.length === 1 && /nao tem permissao/.test(r.sent[0].text),
  r.sent[0]?.text?.slice(0, 90)
);

withGhStatus(404);
r = await run('/status');
check('404 fala do scope do token', r.sent.length === 1 && /scope/.test(r.sent[0].text));

globalThis.fetch = realFetch;

console.log('\n=== alias e sufixo do bot');
r = await run('/best@whey_watch_bot');
check('aceita /cmd@nomedobot', r.sent.length === 1);
r = await run('/lojas');
check('aceita o alias /lojas', r.sent.length === 1);

console.log(fails === 0 ? '\nTODOS OS TESTES PASSARAM\n' : `\n${fails} TESTE(S) A FALHAR\n`);
process.exit(fails === 0 ? 0 : 1);
