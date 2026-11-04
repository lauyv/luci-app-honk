// Exercise the actual LuCI view in an offline browser with simulated RPCs.
// python3 tests/preview/build.py
// BROWSER_BIN=/path/to/chromium node tests/browser.mjs
import { spawn } from 'node:child_process';
import { mkdtemp, mkdir, readFile, writeFile, rm } from 'node:fs/promises';
import { fileURLToPath, pathToFileURL } from 'node:url';
import { dirname, resolve } from 'node:path';
import { tmpdir } from 'node:os';
import assert from 'node:assert/strict';

const root = resolve(dirname(fileURLToPath(import.meta.url)), '..');
const profile = await mkdtemp(resolve(tmpdir(), 'honk-preview-browser.'));
const browser = spawn(process.env.BROWSER_BIN || '/Applications/Brave Browser.app/Contents/MacOS/Brave Browser', [
  '--headless=new', '--disable-gpu', '--no-first-run', '--no-default-browser-check',
  '--disable-background-networking', '--remote-debugging-pipe', `--user-data-dir=${profile}`,
], { stdio: ['ignore', 'ignore', 'pipe', 'pipe', 'pipe'] });
let buffer = '', next = 0, stderr = '';
const pending = new Map(), errors = [];
browser.stderr.on('data', chunk => stderr += chunk);
browser.on('error', error => { for (const item of pending.values()) item.reject(error); });
browser.stdio[4].on('data', chunk => {
  buffer += chunk;
  while (buffer.includes('\0')) {
    const end = buffer.indexOf('\0');
    const item = JSON.parse(buffer.slice(0, end));
    buffer = buffer.slice(end + 1);
    if (item.id) {
      const task = pending.get(item.id);
      pending.delete(item.id);
      if (item.error) task?.reject(Error(JSON.stringify(item.error)));
      else task?.resolve(item.result);
    } else if (item.method === 'Runtime.exceptionThrown') errors.push(item.params.exceptionDetails);
  }
});
function cdp(method, params = {}, sessionId) {
  return new Promise((resolve, reject) => {
    const id = ++next;
    const timer = setTimeout(() => { pending.delete(id); reject(Error('Timeout ' + method + ' ' + stderr.slice(-1000))); }, 15000);
    pending.set(id, {
      resolve: value => { clearTimeout(timer); resolve(value); },
      reject: error => { clearTimeout(timer); reject(error); },
    });
    browser.stdio[3].write(JSON.stringify({ id, method, params, sessionId }) + '\0');
  });
}
try {
  const { targetId } = await cdp('Target.createTarget', { url: 'about:blank' });
  const { sessionId } = await cdp('Target.attachToTarget', { targetId, flatten: true });
  const cmd = (method, params = {}) => cdp(method, params, sessionId);
  await cmd('Runtime.enable'); await cmd('Page.enable');
  const releaseFixture = JSON.parse(await readFile(resolve(root, 'tests/fixtures/releases.json'), 'utf8'));
  await cmd('Page.addScriptToEvaluateOnNewDocument', { source: `
    window.previewRequests=[];
    window.previewFetchMode='ok';
    window.fetch=async(url)=>{
      window.previewRequests.push(String(url));
      if(window.previewFetchMode==='network')throw new TypeError('Failed to fetch');
      if(window.previewFetchMode==='invalid')return new Response('{}');
      if(window.previewFetchMode==='limited')return new Response('{}',{status:403});
      if(window.previewFetchMode==='empty')return new Response('[]');
      return new Response(JSON.stringify(${JSON.stringify(releaseFixture)}));
    };
  ` });
  const evaluate = async expression => {
    const result = await cmd('Runtime.evaluate', { expression, returnByValue: true, awaitPromise: true, userGesture: true });
    if (result.exceptionDetails) throw Error(JSON.stringify(result.exceptionDetails));
    return result.result.value;
  };
  const until = async expression => {
    for (let i = 0; i < 100; i++) {
      if (await evaluate(expression)) return;
      await new Promise(done => setTimeout(done, 100));
    }
    throw Error('Not ready: ' + expression + '\n' + await evaluate('document.body.innerText'));
  };
  const idle = () => until('!previewPanel.status.busy && !previewPanel.localBusy');
  await cmd('Emulation.setDeviceMetricsOverride', { width: 1200, height: 1000, deviceScaleFactor: 1, mobile: false });
  await cmd('Page.navigate', { url: pathToFileURL(resolve(root, 'build/preview.html')).href });
  await until('!!window.previewPanel?.running');
  await evaluate('window.confirm = () => true');
  assert.equal(await evaluate('document.getElementById("preview-errors").textContent'), '');
  assert.deepEqual(await evaluate('[...document.querySelectorAll(".tab-button")].map(n => n.textContent)'), ['服务', '配置', '核心管理', 'Geo 数据', '系统日志']);
  assert.equal(await evaluate('previewPanel.running.disabled'), true);
  assert.equal(await evaluate('document.querySelectorAll("input[type=file]").length'), 0);
  assert.equal(await evaluate('[...document.querySelectorAll(".cbi-value-title")].some(n=>["运行面板","doona 地址"].includes(n.textContent))'), false);
  assert.ok(!(await evaluate('[...document.querySelectorAll("button")].some(n => ["启动","停止","重启","保存并应用","格式化 JSON","清理缓存","拉取","上传配置","独立打开"].includes(n.textContent))')));
  assert.deepEqual(await evaluate('[...document.querySelector("[data-tab=overview]").querySelectorAll(".cbi-value-title")].slice(0,3).map(n=>n.textContent)'), ['运行状态','开机启动','运行服务']);
  await evaluate('document.querySelectorAll(".tab-button")[2].click(); [...document.querySelectorAll("button")].find(n=>n.textContent==="检查版本").click()');
  await idle();
  assert.equal(await evaluate('previewPanel.releaseSelect.options.length'), 2);
  assert.deepEqual(await evaluate('[...previewPanel.releaseSelect.options].map(n=>n.value)'), ['v0.1.0-beta.6', 'v0.1.0-beta.5']);
  assert.deepEqual(await evaluate('window.previewRequests'), ['https://api.github.com/repos/daeuniverse/honk/releases?per_page=10']);
  for(const mode of ['network','invalid','limited']){
    await evaluate(`window.previewFetchMode=${JSON.stringify(mode)}; [...document.querySelectorAll('button')].find(n=>n.textContent==='检查版本').click()`); await idle();
    assert.deepEqual(await evaluate('[...previewPanel.releaseSelect.options].map(n=>n.value)'), ['v0.1.0-beta.6', 'v0.1.0-beta.5']);
    assert.equal(await evaluate('JSON.parse(previewPanel.status.job).state'), 'error');
  }
  await evaluate('window.previewFetchMode="ok"; document.getElementById("preview-target").value="x86_64-unknown-linux-musl"; document.getElementById("preview-target").dispatchEvent(new Event("change"));');
  await until('previewPanel.status.target==="x86_64-unknown-linux-musl"');
  await evaluate('[...document.querySelectorAll("button")].find(n=>n.textContent==="检查版本").click()'); await idle();
  assert.deepEqual(await evaluate('[...previewPanel.releaseSelect.options].map(n=>n.value)'), ['v0.1.0-beta.5']);
  assert.equal(await evaluate('previewPanel.coreTarget.textContent'), 'x86_64-unknown-linux-musl-full');
  await evaluate('window.previewFetchMode="empty"; [...document.querySelectorAll("button")].find(n=>n.textContent==="检查版本").click()'); await idle();
  assert.equal(await evaluate('previewPanel.installButton.disabled'), true);
  await evaluate('window.previewFetchMode="ok"; document.getElementById("preview-target").value="aarch64-unknown-linux-musl"; document.getElementById("preview-target").dispatchEvent(new Event("change"));');
  await until('previewPanel.status.target==="aarch64-unknown-linux-musl"');
  await evaluate('[...document.querySelectorAll("button")].find(n=>n.textContent==="检查版本").click()'); await idle();
  await evaluate('previewPanel.releaseSelect.value="v0.1.0-beta.5"; previewPanel.installButton.click()');
  await idle();
  assert.equal(await evaluate('previewPanel.status.core_installed'), true);
  assert.equal(await evaluate('previewPanel.status.running'), false);
  assert.equal(await evaluate('previewPanel.status.rollback_available'), false);
  assert.equal(await evaluate('[...document.querySelectorAll(".cbi-value-title")].some(n=>n.textContent==="下载方式")'), false);
  await evaluate('previewPanel.proxyPrefix.value=""; [...document.querySelectorAll("button")].find(n=>n.textContent==="保存核心设置").click()'); await idle();
  assert.equal(await evaluate('previewPanel.status.proxy_prefix'), '');
  await evaluate('previewPanel.preferencesLoaded=false; previewPanel.refresh()');
  await until('previewPanel.preferencesLoaded');
  assert.equal(await evaluate('previewPanel.proxyPrefix.value'), '');
  await evaluate('previewPanel.boot.click()'); await idle();
  assert.equal(await evaluate('previewPanel.running.checked'), false);
  await evaluate('previewPanel.running.click()'); await idle();
  assert.equal(await evaluate('previewPanel.running.checked'), true);
  assert.equal(await evaluate('previewPanel.boot.checked'), true);
  await evaluate('previewPanel.proxyPrefix.value="https://gh-proxy.com"; previewPanel.releaseSelect.value="v0.1.0-beta.6"; previewPanel.installButton.click()');
  await idle();
  assert.equal(await evaluate('previewPanel.status.version'), 'honk-core v0.1.0-beta.6');
  assert.equal(await evaluate('previewPanel.running.checked'), true);
  assert.equal(await evaluate('previewPanel.rollbackButton.disabled'), false);
  await evaluate('previewPanel.rollbackButton.click()'); await idle();
  assert.equal(await evaluate('previewPanel.status.version'), 'honk-core v0.1.0-beta.5');
  await evaluate('document.querySelectorAll(".tab-button")[3].click()');
  assert.equal(await evaluate('document.querySelector("[data-tab=core]").contains(previewPanel.geositeUrl)'), false);
  assert.equal(await evaluate('document.querySelector("[data-tab=geo]").contains(previewPanel.geositeUrl)'), true);
  assert.equal(await evaluate('document.querySelectorAll("[data-tab=geo] input[type=checkbox]").length'), 0);
  assert.equal(await evaluate('previewPanel.geositeUrl.value'), 'https://gh-proxy.com/https://github.com/lauyv/rdat/raw/rel/geosite.dat');
  assert.equal(await evaluate('previewPanel.geoipUrl.value'), 'https://gh-proxy.com/https://github.com/lauyv/cnip/raw/rel/chnroutes.dat');
  assert.equal(await evaluate('[...document.querySelectorAll("[data-tab=geo] button")].map(n=>n.textContent).join()'), '更新 Geo 数据');
  await evaluate('previewPanel.proxyPrefix.value="https://unsaved-core-proxy.example"');
  await evaluate('[...document.querySelectorAll("button")].find(n=>n.textContent==="更新 Geo 数据").click()'); await idle();
  assert.equal(await evaluate('previewPanel.status.proxy_prefix'), 'https://gh-proxy.com');
  await evaluate('previewPanel.proxyPrefix.value=previewPanel.status.proxy_prefix');
  assert.equal(await evaluate('previewPanel.status.geo_downloaded'), true);
  assert.equal(await evaluate('previewPanel.status.running'), true);
  assert.equal(await evaluate('[...document.querySelectorAll("[data-tab=geo] .cbi-value-title")].some(n=>n.textContent==="本地文件")'), false);
  await evaluate('previewPanel.geositeUrl.value="https://example.com/custom.dat"; [...document.querySelectorAll("button")].find(n=>n.textContent==="更新 Geo 数据").click()'); await idle();
  assert.equal(await evaluate('previewPanel.status.geosite_url'), 'https://example.com/custom.dat');
  assert.equal(await evaluate('previewPanel.geositeUrl.value'), 'https://example.com/custom.dat');
  assert.equal(await evaluate('previewPanel.status.running'), true);
  await evaluate('previewPanel.geositeUrl.value=previewPanel.status.geosite_url');
  await evaluate('document.getElementById("simulate-failure").checked=true; [...document.querySelectorAll("button")].find(n=>n.textContent==="更新 Geo 数据").click()'); await idle();
  assert.equal(await evaluate('previewPanel.status.geo_downloaded'), true);
  assert.equal(await evaluate('previewPanel.status.running'), true);
  assert.ok((await evaluate('document.getElementById("notifications").innerText')).includes('旧文件'));
  await evaluate('document.querySelectorAll(".tab-button")[2].click()');
  await evaluate('document.getElementById("simulate-failure").checked=true; previewPanel.releaseSelect.value="v0.1.0-beta.6"; previewPanel.installButton.click()'); await idle();
  assert.equal(await evaluate('previewPanel.status.version'), 'honk-core v0.1.0-beta.5');
  assert.equal(await evaluate('previewPanel.running.checked'), true);
  assert.ok((await evaluate('document.getElementById("notifications").innerText')).includes('旧核心'));
  await evaluate('document.querySelectorAll(".tab-button")[1].click(); previewPanel.editor.value="INVALID"; [...document.querySelectorAll("button")].find(n=>n.textContent==="保存").click()'); await idle();
  assert.equal(await evaluate('previewPanel.editor.value'), 'INVALID');
  assert.ok((await evaluate('previewPanel.savedText')).includes('global'));
  await evaluate('previewPanel.editor.value=previewPanel.savedText + "\\n# preview edit\\n"; [...document.querySelectorAll("button")].find(n=>n.textContent==="保存").click()'); await idle();
  assert.equal(await evaluate('previewPanel.editor.value===previewPanel.savedText'), true);
  assert.equal(await evaluate('previewPanel.running.checked'), false);
  assert.ok((await evaluate('document.getElementById("notifications").innerText')).includes('配置已保存'));
  await evaluate('document.getElementById("external-change").click(); [...document.querySelectorAll("button")].find(n=>n.textContent==="保存").click()'); await idle();
  assert.ok((await evaluate('document.getElementById("notifications").innerText')).includes('配置文件已改变'));
  await evaluate('document.querySelectorAll(".tab-button")[2].click()');
  await mkdir(resolve(root, 'build'), { recursive: true });
  const screenshot = await cmd('Page.captureScreenshot', { format: 'png' });
  await writeFile(resolve(root, 'build/preview-core.png'), Buffer.from(screenshot.data, 'base64'));
  await evaluate('previewPanel.writable=false; previewPanel.updateControls()');
  assert.ok(await evaluate('previewPanel.running.disabled && previewPanel.boot.disabled && previewPanel.installButton.disabled && previewPanel.rollbackButton.disabled && previewPanel.editor.readOnly && previewPanel.geositeUrl.disabled && previewPanel.geoipUrl.disabled'));
  await cmd('Emulation.setDeviceMetricsOverride', { width: 390, height: 844, deviceScaleFactor: 1, mobile: true });
  for (const tab of [0, 1, 2, 3, 4]) {
    await evaluate(`document.querySelectorAll('.tab-button')[${tab}].click()`);
    assert.ok(await evaluate('document.documentElement.scrollWidth <= innerWidth+1'), `mobile overflow tab ${tab}`);
  }
  assert.deepEqual(errors, []);
  console.log('PASS: five tabs, first install, independent service/boot controls, live release query/filter/error handling, proxy settings, fixed Geo paths/download/update/recovery, update/rollback/recovery, config preservation, conflicts, read-only controls, mobile layout');
} finally {
  await cdp('Browser.close').catch(() => browser.kill());
  await new Promise(done => setTimeout(done, 300));
  await rm(profile, { recursive: true, force: true, maxRetries: 4, retryDelay: 200 });
}
