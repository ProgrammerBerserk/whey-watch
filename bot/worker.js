/**
 * whey-watch bot - Cloudflare Worker
 *
 * Recebe o webhook do Telegram e responde a comandos. Le o estado directamente
 * do repositorio (config e docs/status.json) e, para /update, dispara o
 * workflow_dispatch do GitHub Actions.
 *
 * Duas camadas de autorizacao, e ambas fazem falta: o repositorio e publico e o
 * username do bot e descobrivel, portanto sem elas qualquer pessoa poderia
 * disparar rondas na conta do dono.
 *
 *   1. header X-Telegram-Bot-Api-Secret-Token, definido no setWebhook
 *   2. ALLOWED_CHAT_IDS - so estes chats sao servidos
 *
 * Segredos (wrangler secret put):
 *   TELEGRAM_BOT_TOKEN        token do @BotFather
 *   TELEGRAM_WEBHOOK_SECRET   string aleatoria, a mesma passada ao setWebhook
 *   GH_TOKEN                  PAT fine-grained: Actions read+write, Contents read
 *
 * Vars (wrangler.toml):
 *   GH_OWNER, GH_REPO, GH_WORKFLOW, GH_BRANCH, ALLOWED_CHAT_IDS
 */

const UA = 'whey-watch-bot';

// ---------------------------------------------------------------- entrada

export default {
  async fetch(request, env) {
    // um GET serve so para confirmares no browser que o Worker esta de pe
    if (request.method !== 'POST') {
      return new Response('whey-watch bot online', {
        status: 200,
        headers: { 'content-type': 'text/plain; charset=utf-8' },
      });
    }

    const given = request.headers.get('X-Telegram-Bot-Api-Secret-Token');
    if (!env.TELEGRAM_WEBHOOK_SECRET || given !== env.TELEGRAM_WEBHOOK_SECRET) {
      return new Response('forbidden', { status: 403 });
    }

    let update;
    try {
      update = await request.json();
    } catch {
      return new Response('bad json', { status: 400 });
    }

    try {
      await handleUpdate(update, env);
    } catch (err) {
      // devolver sempre 200: um erro nosso nao deve fazer o Telegram reentregar
      // a mesma mensagem em loop
      console.error('erro a tratar update:', err && err.stack ? err.stack : err);
      const chatId = update?.message?.chat?.id;
      if (chatId) {
        await tg(env, 'sendMessage', {
          chat_id: chatId,
          text: 'Falhou aqui do meu lado: ' + String(err && err.message ? err.message : err),
        }).catch(() => {});
      }
    }
    return new Response('ok');
  },
};

// ---------------------------------------------------------------- despacho

async function handleUpdate(update, env) {
  const msg = update.message || update.edited_message;
  if (!msg || typeof msg.text !== 'string') return;

  const chatId = String(msg.chat.id);
  const allowed = String(env.ALLOWED_CHAT_IDS || '')
    .split(',')
    .map((s) => s.trim())
    .filter(Boolean);

  // silencio para desconhecidos: responder revelaria que o bot esta activo
  if (allowed.length > 0 && !allowed.includes(chatId)) {
    console.log('chat nao autorizado:', chatId);
    return;
  }

  // aceita "/cmd" e "/cmd@nome_do_bot", com argumentos opcionais
  const m = msg.text.trim().match(/^\/([a-zA-Z_]+)(?:@\w+)?(?:\s+([\s\S]*))?$/);
  if (!m) return;

  const cmd = m[1].toLowerCase();
  let text;

  switch (cmd) {
    case 'shop':
    case 'shops':
    case 'lojas':
      text = await cmdShop(env);
      break;
    case 'best':
    case 'melhor':
      text = await cmdBest(env);
      break;
    case 'status':
      text = await cmdStatus(env);
      break;
    case 'update':
    case 'ronda':
      text = await cmdUpdate(env);
      break;
    case 'start':
    case 'help':
    case 'ajuda':
      text = help();
      break;
    default:
      return; // comando desconhecido: nao poluir o grupo
  }

  await tg(env, 'sendMessage', {
    chat_id: chatId,
    text,
    disable_web_page_preview: true,
  });
}

function help() {
  return [
    'whey-watch',
    '',
    '/best    melhor valor em stock agora',
    '/shop    lojas e produtos vigiados',
    '/status  ultima ronda e saude do sistema',
    '/update  forcar uma consulta de precos agora',
  ].join('\n');
}

// ---------------------------------------------------------------- comandos

async function cmdShop(env) {
  const cfg = await ghJson(env, 'whey-watch.config.json');
  const targets = cfg.targets || [];

  const byStore = new Map();
  for (const t of targets) {
    if (!byStore.has(t.store)) byStore.set(t.store, []);
    byStore.get(t.store).push(t);
  }

  const cloud = targets.filter((t) => !t.residentialOnly).length;
  const resid = targets.length - cloud;

  const out = [];
  out.push(`${byStore.size} lojas, ${targets.length} paginas`);
  out.push(`${cloud} vigiadas na nuvem` + (resid > 0 ? `, ${resid} so em IP residencial` : ''));
  out.push('');

  for (const [store, list] of byStore) {
    out.push(store);
    for (const t of list) {
      const p = t.proteinPer100g != null ? `${pct(t.proteinPer100g)}% proteina` : 'proteina n/d';
      const flag = t.residentialOnly ? '  [so IP residencial]' : '';
      out.push(`  ${t.name} - ${p}${flag}`);
    }
    out.push('');
  }

  if (resid > 0) {
    out.push(
      `${resid} pagina(s) marcada(s) [so IP residencial]: bloqueiam IPs de ` +
        'datacenter, logo na nuvem nao sao consultadas.'
    );
  }
  return out.join('\n').trim();
}

async function cmdBest(env) {
  const st = await ghJson(env, 'docs/status.json');
  const rows = (st.rows || []).filter(
    (r) => r.EurPor100gProt != null && inStock(r.Stock)
  );
  if (rows.length === 0) return 'Nada em stock com preco por proteina calculado.';

  rows.sort((a, b) => a.EurPor100gProt - b.EurPor100gProt);
  const b = rows[0];

  const out = [];
  out.push('Melhor valor em stock');
  out.push('');
  out.push(`${fmt(b.EurPor100gProt)} EUR / 100 g de proteina`);
  out.push(b.Produto);
  out.push(`${b.Loja} - ${fmt(b.Preco)} EUR a embalagem`);
  if (b.MinVisto != null && b.MinVisto < b.Preco - 0.005) {
    out.push(`(minimo ja visto: ${fmt(b.MinVisto)} EUR)`);
  }

  const next = rows.slice(1, 4);
  if (next.length > 0) {
    out.push('');
    out.push('A seguir');
    for (const r of next) {
      out.push(`  ${fmt(r.EurPor100gProt)} - ${r.Produto} - ${fmt(r.Preco)} EUR`);
    }
  }
  out.push('');
  out.push(`Dados de ${when(st.generatedAt)}`);
  return out.join('\n');
}

async function cmdStatus(env) {
  const st = await ghJson(env, 'docs/status.json');
  const health = st.health || [];
  const ok = health.filter((h) => h.Estado === 'ok');
  const bad = health.filter((h) => h.Estado !== 'ok');

  const out = [];
  out.push('whey-watch - estado');
  out.push('');
  out.push(`Ultima ronda: ${when(st.generatedAt)}`);
  out.push(`Lojas: ${ok.length}/${health.length} responderam`);
  out.push(`Precos verificados: ${(st.rows || []).length}`);
  out.push(`Alertas nessa ronda: ${(st.alerts || []).length}`);

  if (bad.length > 0) {
    out.push('');
    out.push('Nao responderam');
    for (const h of bad) out.push(`  ${h.Loja} (${h.Estado})`);
  }

  // conclusao da execucao mais recente do workflow
  try {
    const runs = await ghApi(
      env,
      `/actions/workflows/${env.GH_WORKFLOW}/runs?per_page=1`
    );
    const r = (runs.workflow_runs || [])[0];
    if (r) {
      out.push('');
      out.push(`Workflow: ${r.status}${r.conclusion ? ' / ' + r.conclusion : ''} (${when(r.created_at)})`);
    }
  } catch (e) {
    out.push('');
    out.push('Nao consegui ler o estado do workflow.');
  }

  return out.join('\n');
}

async function cmdUpdate(env) {
  // nao empilhar rondas: uma consulta demora cerca de um minuto e disparar
  // varias em paralelo so gera commits em conflito
  try {
    const runs = await ghApi(
      env,
      `/actions/workflows/${env.GH_WORKFLOW}/runs?per_page=1`
    );
    const r = (runs.workflow_runs || [])[0];
    if (r) {
      if (r.status === 'queued' || r.status === 'in_progress') {
        return 'Ja ha uma ronda a correr. O resumo chega daqui a pouco.';
      }
      const ageSec = (Date.now() - new Date(r.created_at).getTime()) / 1000;
      if (ageSec < 180) {
        return `A ultima ronda foi ha ${Math.round(ageSec)}s. Espera um pouco antes de forcar outra.`;
      }
    }
  } catch (e) {
    // se nao conseguires ler, segue: e melhor disparar do que travar por isto
    console.error('nao li as execucoes:', e);
  }

  await ghApi(
    env,
    `/actions/workflows/${env.GH_WORKFLOW}/dispatches`,
    'POST',
    { ref: env.GH_BRANCH || 'main', inputs: { digest: 'true' } }
  );

  return 'Ronda disparada. O resumo com os precos chega aqui dentro de um minuto ou dois.';
}

// ---------------------------------------------------------------- github

function ghBase(env) {
  return `https://api.github.com/repos/${env.GH_OWNER}/${env.GH_REPO}`;
}

async function ghApi(env, path, method = 'GET', body) {
  const res = await fetch(ghBase(env) + path, {
    method,
    headers: {
      accept: 'application/vnd.github+json',
      authorization: `Bearer ${env.GH_TOKEN}`,
      'x-github-api-version': '2022-11-28',
      'user-agent': UA,
      ...(body ? { 'content-type': 'application/json' } : {}),
    },
    body: body ? JSON.stringify(body) : undefined,
  });

  if (res.status === 204) return {};
  const txt = await res.text();
  if (!res.ok) {
    throw new Error(ghError(res.status, path, txt));
  }
  return txt ? JSON.parse(txt) : {};
}

// um "GitHub 401" cru no grupo nao diz a ninguem o que fazer
function ghError(status, path, txt) {
  if (status === 401) {
    return (
      'O GH_TOKEN do Worker nao e uma credencial valida (401). Esta errado, ' +
      'expirado, ou foi gravado o valor de outro segredo. Corre ' +
      'bot/set-gh-token.ps1 para validar e regravar.'
    );
  }
  if (status === 403) {
    return (
      'O GH_TOKEN e valido mas nao tem permissao para isto (403). O bot precisa ' +
      'de Actions: read and write e Contents: read neste repositorio.'
    );
  }
  if (status === 404) {
    return (
      `Nao encontrei ${path} (404). Ou o token nao tem este repositorio no ` +
      'scope, ou o caminho/nome do workflow mudou.'
    );
  }
  return `GitHub ${status} em ${path}: ${String(txt).slice(0, 200)}`;
}

async function ghJson(env, filePath) {
  // a API de contents devolve conteudo mais fresco que o raw.githubusercontent,
  // que fica em cache na CDN durante minutos
  const res = await fetch(`${ghBase(env)}/contents/${filePath}?ref=${env.GH_BRANCH || 'main'}`, {
    headers: {
      accept: 'application/vnd.github.raw+json',
      authorization: `Bearer ${env.GH_TOKEN}`,
      'x-github-api-version': '2022-11-28',
      'user-agent': UA,
    },
  });
  if (!res.ok) {
    throw new Error(ghError(res.status, filePath, await res.text().catch(() => '')));
  }
  return res.json();
}

// ---------------------------------------------------------------- telegram

async function tg(env, method, payload) {
  const res = await fetch(
    `https://api.telegram.org/bot${env.TELEGRAM_BOT_TOKEN}/${method}`,
    {
      method: 'POST',
      headers: { 'content-type': 'application/json' },
      body: JSON.stringify(payload),
    }
  );
  const data = await res.json().catch(() => ({}));
  if (!res.ok || data.ok === false) {
    throw new Error(`Telegram ${method}: ${data.description || res.status}`);
  }
  return data;
}

// ---------------------------------------------------------------- auxiliares

function inStock(availability) {
  if (!availability || availability === '?') return true;
  return /InStock|LimitedAvailability|PreOrder|BackOrder/i.test(availability);
}

function fmt(n) {
  if (n == null) return '-';
  return Number(n).toFixed(2).replace('.', ',');
}

// percentagens de proteina: 78 -> "78", 71.3 -> "71,3". o toFixed(2) fixo dava
// "78,00%", que le mal
function pct(n) {
  if (n == null) return '-';
  const s = Number(n).toFixed(1).replace(/\.0$/, '');
  return s.replace('.', ',');
}

function when(iso) {
  if (!iso) return 'desconhecido';
  const d = new Date(iso);
  if (isNaN(d)) return String(iso);
  // Lisboa; o Worker corre em UTC
  const p = {};
  for (const part of new Intl.DateTimeFormat('pt-PT', {
    timeZone: 'Europe/Lisbon',
    day: '2-digit',
    month: '2-digit',
    hour: '2-digit',
    minute: '2-digit',
    hour12: false,
  }).formatToParts(d)) {
    p[part.type] = part.value;
  }
  return `${p.day}/${p.month} as ${p.hour}:${p.minute}`;
}
