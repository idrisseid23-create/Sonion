// Screenshots the cars in cars.json from several angles into out/.
// Usage (from tests/preview):  node render.mjs [car] [views...]
//   node render.mjs            every car, every view
//   node render.mjs Bolt hero rear
import { chromium } from 'playwright';
import http from 'node:http';
import fs from 'node:fs';
import path from 'node:path';

// Use a preinstalled headless Chromium if there is one; otherwise Playwright's own browser
// (install it once with: npx playwright install chromium).
function findHeadlessShell() {
  try {
    const dir = fs.readdirSync('/opt/pw-browsers').find(d => d.startsWith('chromium_headless_shell'));
    return dir ? `/opt/pw-browsers/${dir}/chrome-linux/headless_shell` : undefined;
  } catch {
    return undefined;
  }
}
const here = path.dirname(new URL(import.meta.url).pathname);
const outDir = path.join(here, 'out');
fs.mkdirSync(outDir, { recursive: true });

const types = { '.html': 'text/html', '.js': 'text/javascript', '.json': 'application/json' };
const server = http.createServer((req, res) => {
  const file = path.join(here, decodeURIComponent(new URL(req.url, 'http://x').pathname));
  if (!file.startsWith(here) || !fs.existsSync(file) || fs.statSync(file).isDirectory()) {
    res.writeHead(404).end();
    return;
  }
  res.writeHead(200, { 'Content-Type': types[path.extname(file)] || 'application/octet-stream' });
  fs.createReadStream(file).pipe(res);
});
await new Promise(r => server.listen(0, r));
const port = server.address().port;

const args = process.argv.slice(2);
const cars = args[0] ? [args[0]] : ['Bolt', 'Mule', 'Kite'];
const views = args.length > 1 ? args.slice(1) : ['hero', 'rear', 'side', 'front', 'back', 'top', 'chase'];

const browser = await chromium.launch({
  executablePath: process.env.CHROMIUM || findHeadlessShell(),
  args: ['--use-angle=swiftshader', '--enable-unsafe-swiftshader', '--ignore-gpu-blocklist'],
});
const page = await browser.newPage({ viewport: { width: 1200, height: 800 } });
page.on('console', m => { if (m.type() === 'error') console.log('page error:', m.text()); });
page.on('pageerror', e => console.log('page exception:', e.message));

for (const car of cars) {
  for (const view of views) {
    const pose = view === 'hero' ? 'steer' : 'rest';
    const extra = view === 'lineup' ? '' : `&car=${car}`;
    await page.goto(`http://localhost:${port}/viewer.html?view=${view}&pose=${pose}${extra}`);
    await page.waitForFunction(() => window.__ready === true, null, { timeout: 60000 });
    const name = view === 'lineup' ? 'lineup.png' : `${car}-${view}.png`;
    await page.locator('canvas').screenshot({ path: path.join(outDir, name) });
    console.log('wrote out/' + name);
    if (view === 'lineup') break;
  }
}
await browser.close();
server.close();
