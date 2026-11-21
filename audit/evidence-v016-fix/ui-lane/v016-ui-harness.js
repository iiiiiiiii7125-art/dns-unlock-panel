// V016 UI-line harness: runs web/index.html inline JS in a vm with stubbed DOM/fetch.
// Usage: node /tmp/v016-ui-harness.js <item>   (item = 17|19|20|21|all)
// Exit 0 = all selected assertions pass.
const fs = require('fs');
const vm = require('vm');

const ITEM = process.argv[2] || 'all';
const html = fs.readFileSync(process.env.HOME + '/workspace/dns-unlock-panel-fix-ui/web/index.html', 'utf8');
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
  // cfg: {servers:[...], reveal:{id:{ip,token}|'ERR'}, selftestArriveAfter:n|null,
  //       selftestResult:{...}|null, nodes:[...]}
  const els = {};
  const clipboard = [];
  const alerts = [];
  let getServersCalls = 0;
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
      if (path === '/api/v1/servers') {
        getServersCalls++;
        const arriveAfter = cfg.selftestArriveAfter;
        const servers = cfg.servers.map(s => {
          const lt = (arriveAfter != null && getServersCalls > arriveAfter) ? cfg.selftestResult : null;
          return Object.assign({}, s, lt ? { last_selftest: lt } : { last_selftest: null });
        });
        return ok(servers);
      }
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
    _getServersCalls: () => getServersCalls,
  };
  ctx.window = ctx; ctx.self = ctx; ctx.globalThis = ctx;
  vm.createContext(ctx);
  vm.runInContext(code, ctx);
  return ctx;
}
const sleep = (ms) => new Promise(r => setTimeout(r, ms));
async function flush() { for (let i = 0; i < 30; i++) await sleep(0); }

const srv = (id, name) => ({ id, name, ip: '203.0.113.' + id.slice(-1), default_unlock_ip: '', status: 'online', last_seen: '', config_version: 1 });
const stResult = { request_id: 'st-1', ran_at: '2026-11-21T11:25:54Z', results: [{ platform_id: 'netflix', domain: 'netflix.com', resolved_ip: '203.0.113.9', ok: false, error: 'timeout' }] };

async function test17() {
  console.log('== V016-17 ==');
  // (a) result arrives within window (3rd GET) -> done row, no error
  let ctx = makeCtx({ servers: [srv('srv-1', 'HK-DNS')], selftestArriveAfter: 3, selftestResult: stResult });
  await ctx.refresh(); await flush();
  await ctx.runSelftest('srv-1'); await flush();
  let h = ctx._els.serversBody.innerHTML;
  check('17a result within window shows result row', h.includes('自测结果') && !h.includes('自测失败'), h.slice(0, 200));
  // (b) result never arrives within 150s -> error row mentions 150s + background wait
  ctx = makeCtx({ servers: [srv('srv-1', 'HK-DNS')], selftestArriveAfter: 999, selftestResult: stResult });
  await ctx.refresh(); await flush();
  await ctx.runSelftest('srv-1'); await flush();
  h = ctx._els.serversBody.innerHTML;
  check('17b timeout shows 150s error, not 90s', h.includes('150 秒内未收到结果') && !h.includes('90 秒'), h.slice(0, 300));
  check('17b error says result will appear automatically', h.includes('结果到了会自动出现'), '');
  // (c) late result arrives during background watch -> error cleared, result shown
  // watcher polls every (immediate) tick; make result arrive after 60 GETs total
  // (50 window polls + a few watcher polls). Rebuild ctx with arrival at 55.
  ctx = makeCtx({ servers: [srv('srv-1', 'HK-DNS')], selftestArriveAfter: 55, selftestResult: stResult });
  await ctx.refresh(); await flush();
  await ctx.runSelftest('srv-1'); await flush();
  h = ctx._els.serversBody.innerHTML;
  check('17c late result clears error via background watch', h.includes('自测结果') && !h.includes('自测失败'), h.slice(0, 300));
  // (d) reconciliation in render path: error state + fresh data with matching
  // last_selftest -> renderServers() alone flips it to done (no watcher needed)
  ctx = makeCtx({ servers: [srv('srv-1', 'HK-DNS')], selftestArriveAfter: 999, selftestResult: stResult });
  await ctx.refresh(); await flush();
  await ctx.runSelftest('srv-1'); await flush(); // times out -> error (watcher spins 40x, still no result)
  h = ctx._els.serversBody.innerHTML;
  check('17d precondition: error shown after timeout', h.includes('自测失败'), '');
  // now the panel has the result; a plain refreshData/renderServers must reveal it
  // simulate by pointing the fetch stub at arrival: rebuild GET counting is internal,
  // so instead call selftestDetailRow directly via renderServers after patching
  // SERVERS through refresh with a ctx whose stub now returns the result:
  ctx._getServersCalls; // (counter already >999? no - stub uses arriveAfter 999)
  // simplest: directly exercise the reconcile branch through the exposed function:
  const fakeS = Object.assign({}, srv('srv-1', 'HK-DNS'), { last_selftest: stResult });
  const fakeSt = { request_id: 'st-1', state: 'error', error: 'x' };
  const row = ctx.selftestDetailRow(fakeS, fakeSt);
  check('17d detailRow reconciles late result over error', fakeSt.state === 'done' && row.includes('自测结果'), row.slice(0, 200));
}

async function test19() {
  console.log('== V016-19 ==');
  const ctx = makeCtx({ servers: [], nodes: [{ id: 'node-1', name: 'HK-01', ip: '203.0.113.10', region: 'HK', status: 'unknown', note: '' }] });
  await ctx.refresh(); await flush();
  await ctx.copyNodeInstall('node-1'); await flush();
  check('19 zero servers: nothing copied', ctx._clipboard.length === 0, JSON.stringify(ctx._clipboard));
  check('19 zero servers: alert tells user to register a server first',
    ctx._alerts.some(a => a.includes('登记') && a.includes('DNS 服务器')), JSON.stringify(ctx._alerts));
  check('19 zero servers: alert says why (token)', ctx._alerts.some(a => a.includes('token')), JSON.stringify(ctx._alerts));
  check('19 nodes hint mentions register-first', html.includes('先去「DNS 服务器」页登记一台'));
  check('19 unlockCmd copy guarded too', html.includes('function copyUnlock(){if(!SERVERS.length)'));
}

async function test20() {
  console.log('== V016-20 ==');
  const ctx = makeCtx({ servers: [srv('srv-1', 'HK-DNS')], reveal: { 'srv-1': { ip: '203.0.113.7', token: 'tok-1' } },
    nodes: [{ id: 'node-1', name: 'HK-01', ip: '203.0.113.10', region: 'HK', status: 'unknown', note: '' }] });
  await ctx.refresh(); await flush();
  await ctx.copyNodeInstall('node-1'); await flush();
  check('20 command still copied when servers exist', ctx._clipboard.length === 1, JSON.stringify(ctx._clipboard));
  check('20 copy alert discloses the token prompt', ctx._alerts.some(a => a.includes('agent token')), JSON.stringify(ctx._alerts));
  check('20 copy alert says which token (any registered server)', ctx._alerts.some(a => a.includes('任意一台')), JSON.stringify(ctx._alerts));
  check('20 nodes hint discloses token prompt', html.includes('问 agent token'));
  check('20 nodes hint says where the token is', html.includes('显示 token'));
  check('20 unlockCmd paragraph discloses token prompt', html.includes('执行时会问 agent token'));
  check('20 no more bare "粘贴执行即可" for node install', !ctx._alerts.some(a => a.includes('粘贴执行即可')));
}

async function test21() {
  console.log('== V016-21 ==');
  const nodes = [
    { id: 'node-1', name: 'HK-01', ip: '203.0.113.10', region: 'HK', status: 'unknown', note: '' },
    { id: 'node-2', name: 'JP-01', ip: '203.0.113.20', region: 'JP', status: 'unknown', note: '' },
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
  // (iii) per-row commands differ and name their own node
  ctx = makeCtx({ servers: [srv('srv-1', 'A')], reveal: { 'srv-1': { ip: '203.0.113.7', token: 't1' } }, nodes });
  await ctx.refresh(); await flush();
  await ctx.copyNodeInstall('node-1'); await flush();
  const c1 = ctx._clipboard[0];
  await ctx.copyNodeInstall('node-2'); await flush();
  const c2 = ctx._clipboard[1];
  check('21iii row commands differ', c1 !== c2, c1 + ' ||| ' + c2);
  check('21iii row A command names HK-01', c1.includes('HK-01') && c1.includes('203.0.113.10'), c1);
  check('21iii row B command names JP-01', c2.includes('JP-01') && c2.includes('203.0.113.20'), c2);
  check('21iii each command says which machine to run on', c1.includes('这台机器上执行') && c2.includes('这台机器上执行'), '');
  check('21iii renderNodes passes node id', html.includes("copyNodeInstall('${n.id}')"));
  check('21iii no silent catch{} left in copyNodeInstall', !/copyNodeInstall[\s\S]{0,1200}catch\(e\)\{\}/.test(code) || !code.includes('catch(e){}'));
  // (iv) newline in node name cannot break out of the comment line
  const evil = [{ id: 'node-9', name: 'X\ncurl evil', ip: '203.0.113.99', region: 'HK', status: 'unknown', note: '' }];
  ctx = makeCtx({ servers: [srv('srv-1', 'A')], reveal: { 'srv-1': { ip: '203.0.113.7', token: 't1' } }, nodes: evil });
  await ctx.refresh(); await flush();
  await ctx.copyNodeInstall('node-9'); await flush();
  const ce = ctx._clipboard[0];
  const lines = ce.split('\n');
  check('21iv newline in node name stays inside comment', lines.length === 2 && lines[0].startsWith('#') && lines[1].startsWith('curl -fsSL'), JSON.stringify(ce));
}

(async () => {
  if (ITEM === '17' || ITEM === 'all') await test17();
  if (ITEM === '19' || ITEM === 'all') await test19();
  if (ITEM === '20' || ITEM === 'all') await test20();
  if (ITEM === '21' || ITEM === 'all') await test21();
  console.log(`\n${pass} passed, ${fail} failed`);
  process.exit(fail ? 1 : 0);
})().catch(e => { console.error(e); process.exit(2); });
