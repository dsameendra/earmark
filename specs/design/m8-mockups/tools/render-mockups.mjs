// Regenerates static HTML snapshots and PNG previews from the Claude Design sources.
// Usage (see ../README.md): put source/*.dc.html, canvas.json and dc-runtime.js in a folder, serve it on :8765,
// run this script from that folder with playwright-core installed. Output goes to ./out/static and ./out/png.
// Set CHROMIUM to a Chromium/Chrome binary if the default Playwright cache path below is not present.
import { chromium } from 'playwright-core';
import fs from 'fs';
import path from 'path';
const canvas = JSON.parse(fs.readFileSync('canvas.json','utf8'));
const exe = process.env.CHROMIUM || (process.env.HOME + '/Library/Caches/ms-playwright/chromium-1248/chrome-mac-arm64/Google Chrome for Testing.app/Contents/MacOS/Google Chrome for Testing');
const browser = await chromium.launch({ executablePath: exe });
fs.rmSync('out', { recursive: true, force: true });
fs.mkdirSync('out/static', { recursive: true }); fs.mkdirSync('out/png', { recursive: true });
for (const [name, b] of Object.entries(canvas.boards)) {
  const stem = name.replace('.dc.html','');
  const page = await browser.newPage({ viewport: { width: b.w, height: b.h }, deviceScaleFactor: 1 });
  await page.goto('http://localhost:8765/' + name, { waitUntil: 'load' });
  await page.waitForTimeout(1800);
  await page.screenshot({ path: `out/png/${stem}.png`, fullPage: false, clip: { x:0, y:0, width:b.w, height:b.h } });
  let html = await page.evaluate(() => {
    document.querySelectorAll('script').forEach(s => s.remove());
    document.querySelectorAll('x-dc, helmet').forEach(e => { if (e.tagName==='HELMET') e.remove(); });
    return '<!doctype html>\n' + document.documentElement.outerHTML;
  });
  html = html.replace('<head>', `<head>\n<meta name="viewport" content="width=${b.w}">\n<!-- Static snapshot of ${name}. Generated from the Claude Design canvas source; edit the .dc.html in ../source and regenerate. -->`);
  fs.writeFileSync(`out/static/${stem}.html`, html);
  console.log(stem.padEnd(16), b.w+'x'+b.h, (html.length/1024).toFixed(0)+'KB html', (fs.statSync(`out/png/${stem}.png`).size/1024).toFixed(0)+'KB png');
  await page.close();
}
await browser.close();
