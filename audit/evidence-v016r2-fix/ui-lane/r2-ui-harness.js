// V016 fix round 2 UI-line harness: runs web/index.html inline JS in a vm
// with stubbed DOM/fetch, and calls the real copyServerInstall /
// copyNodeInstall against stubbed reveal responses.
// Adapted from audit/evidence-v016-fix/ui-lane/v016-ui-harness.js (round 1);
// HTML path is resolved relative to this file, and the V016-21 row-header
// assertion is updated for R2-11 (header no longer carries the node IP).
// Usage: node audit/evidence-v016r2-fix/ui-lane/r2-ui-harness.js [r206|r211|r216|r21|all]
// Exit 0 = all selected assertions pass.
const fs = require('fs');
const path = require('path');
const vm = require('vm');

const ITEM = process.argv[2] || 'all';
const html = fs.readFileSync(path.join(__dirname, '../../../web/index.html'), 'utf8');
const code = html.match(/<script>([\s\S]*)<\/script>/)[1];

let pass = 0, fail = 0;
function check(name, cond, extra) {
  if (cond) { pass++; console.log('  PASS ' + name); }
  else { fail++; console.log('  FAIL ' + name + (extra ? ' :: ' + extra : '')); }
}
function elStub() {
  return {
    innerHTML: '', textContent: '', value: '', style: {},
    classList: { add() {}, remove() {}, contains() { return false; } },
  };
}

function makeCtx(cfg) {
  // cfg: {servers:[...], reveal:{id:{ip,token}|'ERR'}, nodes:[...]}
  const els = {};
  const clipboard = [];
  const alerts = [];
  const ctx = {
    console,
    location: { origin: 'http://127.0.0.1:18080' },
    navigator: { clipboard: { writeText(t) { clipboard.push(t); return Promise.resolve(); } } },
    alert(m) { alerts.push(String(m)); },
    confirm() { return true; },
    sessionStorage: { getItem() { return ''; }, setItem() {}, removeItem() {} },
    localStorage: { getItem() { return null; }, setItem() {} },
    setTimeout: (fn) => { fn(); return 0; }, // immediate timers: loops spin fast
    setInterval: () => 0,
    scrollTo() {}, scrollX: 0, scrollY: 0,
    document: {
      getElementById(id) { return els[id] || (els[id] = elStub()); },
      activeElement: null, body: elStub(),
      createElement: () => elStub(),
      querySelector: () => null,
    },
    fetch: async (path) => {
      const ok = (obj) => ({ status: 200, text: async () => JSON.stringify(obj) });
      if (path === '/api/v1/status') return ok({ config_version: 1, nodes_online: 0, nodes_total: 0, platforms_total: 0, rules_total: 0, servers_online: 1, servers_total: cfg.servers.length, upstream: '1.1.1.1' });
      if (path === '/api/v1/nodes') return ok(cfg.nodes || []);
      if (path === '/api/v1/rules') return ok([]);
      if (path === '/api/v1/servers') return ok(cfg.servers);
      const m = path.match(/^\/api\/v1\/servers\/([^/]+)\/selftest$/);
      if (m) return ok({ request_id: 'st-1' });
      const r = path.match(/^\/api\/v1\/servers\/([^/]+)\/reveal$/);
      if (r) {
        const v = (cfg.reveal || {})[r[1]];
        if (v === 'ERR') throw new Error('reveal 失败：网络错误');
        return ok(v || { ip: '', token: 'tok-' + r[1] });
      }
      throw new Error('unexpected fetch: ' + path);
    },
    _els: els, _clipboard: clipboard, _alerts: alerts,
  };
  ctx.window = ctx; ctx.self = ctx; ctx.globalThis = ctx;
  vm.createContext(ctx);
  vm.runInContext(code, ctx);
  return ctx;
}
const sleep = (ms) => new Promise(r => setTimeout(r, ms));
async function flush() { for (let i = 0; i < 30; i++) await sleep(0); }

const srv = (id, name) => ({ id, name, ip: '203.0.113.' + id.slice(-1), default_unlock_ip: '', status: 'online', last_seen: '', config_version: 1 });
const node = (id, name, ip, region) => ({ id, name, ip, region, status: 'unknown', note: '' });

async function testR206() {
  console.log('== R2-06 copyServerInstall ==');
  // (i) reveal throws (e.g. 401 after forced password change) -> no copy, honest error
  let ctx = makeCtx({ servers: [srv('srv-1', 'HK-DNS')], reveal: { 'srv-1': 'ERR' } });
  await ctx.refresh(); await flush();
  await ctx.copyServerInstall('srv-1'); await flush();
  check('06i reveal fails: nothing copied', ctx._clipboard.length === 0, JSON.stringify(ctx._clipboard));
  check('06i reveal fails: alert says fetch failed, not copied', ctx._alerts.some(a => a.includes('取 token 失败') && a.includes('未复制')), JSON.stringify(ctx._alerts));
  // (ii) reveal succeeds but token empty -> no copy (no DNS_AGENT_TOKEN=undefined command)
  ctx = makeCtx({ servers: [srv('srv-1', 'HK-DNS')], reveal: { 'srv-1': { ip: '203.0.113.7', token: '' } } });
  await ctx.refresh(); await flush();
  await ctx.copyServerInstall('srv-1'); await flush();
  check('06ii empty token: nothing copied', ctx._clipboard.length === 0, JSON.stringify(ctx._clipboard));
  check('06ii empty token: alert says no token, not copied', ctx._alerts.some(a => a.includes('未返回 token') && a.includes('未复制')), JSON.stringify(ctx._alerts));
  // (iii) happy path still works
  ctx = makeCtx({ servers: [srv('srv-1', 'HK-DNS')], reveal: { 'srv-1': { ip: '203.0.113.7', token: 'tok-1' } } });
  await ctx.refresh(); await flush();
  await ctx.copyServerInstall('srv-1'); await flush();
  check('06iii reveal ok: command copied with token', ctx._clipboard.length === 1 && ctx._clipboard[0].includes('DNS_AGENT_TOKEN=tok-1'), JSON.stringify(ctx._clipboard));
  check('06iii reveal ok: alert says copied', ctx._alerts.some(a => a.includes('已复制')), JSON.stringify(ctx._alerts));
}

async function testR211() {
  console.log('== R2-11 node install header has no masked IP ==');
  // production list API returns the masked IP; the header must not repeat it
  const nodes = [
    node('node-1', 'HK-01', '203.0.*.*', 'HK'),
    node('node-2', 'JP-01', '203.0.*.*', 'JP'),
  ];
  const ctx = makeCtx({ servers: [srv('srv-1', 'A')], reveal: { 'srv-1': { ip: '203.0.113.7', token: 't1' } }, nodes });
  await ctx.refresh(); await flush();
  await ctx.copyNodeInstall('node-1'); await flush();
  const c1 = ctx._clipboard[0];
  await ctx.copyNodeInstall('node-2'); await flush();
  const c2 = ctx._clipboard[1];
  const head1 = c1.split('\n')[0];
  check('11 header has no masked IP', !c1.includes('203.0.*.*') && !head1.includes('*'), c1);
  check('11 header still names the node', head1.includes('HK-01'), head1);
  check('11 header still carries the region', head1.includes('HK'), head1);
  check('11 header still says which machine to run on', head1.includes('这台机器上执行'), head1);
  check('11 row commands still differ per node', c1 !== c2, c1 + ' ||| ' + c2);
  check('11 row B command names JP-01', c2.includes('JP-01'), c2);
  check('11 allowlist IP (from server reveal) is unaffected', c1.includes('203.0.113.7'), c1);
  // renderNodes still wires each row to its own node id
  const rowsHtml = ctx._els.nodesBody.innerHTML;
  check('11 renderNodes passes node id per row', rowsHtml.includes("copyNodeInstall('node-1')") && rowsHtml.includes("copyNodeInstall('node-2')"), rowsHtml.slice(0, 300));
}

async function testR216() {
  console.log('== R2-16 empty-IP servers are named, not silently skipped ==');
  // (i) one server reveals empty IP, one good -> copy with good IP, alert names the empty one
  let ctx = makeCtx({ servers: [srv('srv-1', 'A'), srv('srv-2', 'B')],
    reveal: { 'srv-1': { ip: '', token: 't1' }, 'srv-2': { ip: '203.0.113.8', token: 't2' } },
    nodes: [node('node-1', 'HK-01', '203.0.*.*', 'HK')] });
  await ctx.refresh(); await flush();
  await ctx.copyNodeInstall('node-1'); await flush();
  check('16i partial empty: command copied with surviving IP', ctx._clipboard.length === 1 && ctx._clipboard[0].includes('203.0.113.8'), JSON.stringify(ctx._clipboard));
  check('16i partial empty: alert names the empty-IP server', ctx._alerts.some(a => a.includes('A') && a.includes('未返回 IP') && a.includes('已跳过')), JSON.stringify(ctx._alerts));
  // (ii) all servers reveal empty IP -> still copies (no allowlist), but names them
  ctx = makeCtx({ servers: [srv('srv-1', 'A'), srv('srv-2', 'B')],
    reveal: { 'srv-1': { ip: '', token: 't1' }, 'srv-2': { ip: '', token: 't2' } },
    nodes: [node('node-1', 'HK-01', '203.0.*.*', 'HK')] });
  await ctx.refresh(); await flush();
  await ctx.copyNodeInstall('node-1'); await flush();
  check('16ii all empty: command copied without allowlist', ctx._clipboard.length === 1 && !ctx._clipboard[0].includes('DNS_SNI_ALLOWLIST'), JSON.stringify(ctx._clipboard));
  check('16ii all empty: alert names both empty-IP servers', ctx._alerts.some(a => a.includes('A') && a.includes('B') && a.includes('未返回 IP')), JSON.stringify(ctx._alerts));
  check('16ii all empty: alert still explains allowlist is missing', ctx._alerts.some(a => a.includes('allowlist 未填')), JSON.stringify(ctx._alerts));
}

async function testR21() {
  console.log('== V016-21 regression (updated for R2-11: header has name+region, no IP) ==');
  const nodes = [
    node('node-1', 'HK-01', '203.0.113.10', 'HK'),
    node('node-2', 'JP-01', '203.0.113.20', 'JP'),
  ];
  // (i) all reveals fail -> no copy, honest error, never claims "未登记"
  let ctx = makeCtx({ servers: [srv('srv-1', 'A'), srv('srv-2', 'B')], reveal: { 'srv-1': 'ERR', 'srv-2': 'ERR' }, nodes });
  await ctx.refresh(); await flush();
  await ctx.copyNodeInstall('node-1'); await flush();
  check('21i all reveal fail: nothing copied', ctx._clipboard.length === 0, JSON.stringify(ctx._clipboard));
  check('21i all reveal fail: alert says fetch failed', ctx._alerts.some(a => a.includes('取') && a.includes('失败')), JSON.stringify(ctx._alerts));
  check('21i all reveal fail: alert does NOT claim "未登记"', !ctx._alerts.some(a => a.includes('未登记')), JSON.stringify(ctx._alerts));
  // (ii) partial failure -> copies with available IPs, warns which server failed
  ctx = makeCtx({ servers: [srv('srv-1', 'A'), srv('srv-2', 'B')], reveal: { 'srv-1': { ip: '203.0.113.7', token: 't1' }, 'srv-2': 'ERR' }, nodes });
  await ctx.refresh(); await flush();
  await ctx.copyNodeInstall('node-1'); await flush();
  check('21ii partial fail: command copied with surviving IP', ctx._clipboard.length === 1 && ctx._clipboard[0].includes('203.0.113.7'), JSON.stringify(ctx._clipboard));
  check('21ii partial fail: alert names the failed server', ctx._alerts.some(a => a.includes('B') && a.includes('没取到')), JSON.stringify(ctx._alerts));
  // (iii) per-row commands differ and name their own node (name + region, no IP since R2-11)
  ctx = makeCtx({ servers: [srv('srv-1', 'A')], reveal: { 'srv-1': { ip: '203.0.113.7', token: 't1' } }, nodes });
  await ctx.refresh(); await flush();
  await ctx.copyNodeInstall('node-1'); await flush();
  const c1 = ctx._clipboard[0];
  await ctx.copyNodeInstall('node-2'); await flush();
  const c2 = ctx._clipboard[1];
  check('21iii row commands differ', c1 !== c2, c1 + ' ||| ' + c2);
  check('21iii row A command names HK-01 + HK, no node IP', c1.includes('HK-01') && c1.includes('HK') && !c1.includes('203.0.113.10'), c1);
  check('21iii row B command names JP-01 + JP, no node IP', c2.includes('JP-01') && c2.includes('JP') && !c2.includes('203.0.113.20'), c2);
  check('21iii each command says which machine to run on', c1.includes('这台机器上执行') && c2.includes('这台机器上执行'), '');
  // (iv) newline in node name cannot break out of the comment line
  const evil = [node('node-9', 'X\ncurl evil', '203.0.113.99', 'HK')];
  ctx = makeCtx({ servers: [srv('srv-1', 'A')], reveal: { 'srv-1': { ip: '203.0.113.7', token: 't1' } }, nodes: evil });
  await ctx.refresh(); await flush();
  await ctx.copyNodeInstall('node-9'); await flush();
  const ce = ctx._clipboard[0];
  const lines = ce.split('\n');
  check('21iv newline in node name stays inside comment', lines.length === 2 && lines[0].startsWith('#') && lines[1].startsWith('curl -fsSL'), JSON.stringify(ce));
}

(async () => {
  if (ITEM === 'r206' || ITEM === 'all') await testR206();
  if (ITEM === 'r211' || ITEM === 'all') await testR211();
  if (ITEM === 'r216' || ITEM === 'all') await testR216();
  if (ITEM === 'r21' || ITEM === 'all') await testR21();
  console.log(`\n${pass} passed, ${fail} failed`);
  process.exit(fail ? 1 : 0);
})().catch(e => { console.error(e); process.exit(2); });
