"use strict";
/* Deterministic frame renderer for the MacPilot promo video.
   Usage:
     node render.js sample 1.5,3.0,8.0        -> /tmp/sample-*.png
     node render.js full [fromFrame]          -> frames/f00000.png ...
     DSF=2 node render.js ...                 -> supersampling factor (default 2)
*/
const path = require("path");
const fs = require("fs");
const { chromium } = require(path.join(__dirname, "node_modules", "playwright-core"));

const CHROME = "/Applications/Google Chrome.app/Contents/MacOS/Google Chrome";
const FPS = 30;
const OUT = path.join(__dirname, "..", "frames");

(async () => {
  const mode = process.argv[2] || "sample";
  const dsf = parseFloat(process.env.DSF || "2");
  const browser = await chromium.launch({
    executablePath: CHROME,
    headless: true,
    args: ["--hide-scrollbars", "--force-color-profile=srgb", "--disable-lcd-text", "--font-render-hinting=none"],
  });
  const page = await browser.newPage({ viewport: { width: 1920, height: 1080 }, deviceScaleFactor: dsf });
  page.on("console", (m) => { if (m.type() === "error") console.error("[console]", m.text()); });
  page.on("pageerror", (e) => console.error("[pageerror]", e.message));
  await page.goto("file://" + path.join(__dirname, "..", "index.html"));
  await page.waitForFunction(() => window.__READY === true, null, { timeout: 15000 });
  await page.evaluate(() => document.fonts.ready);
  const TOTAL = await page.evaluate((fps) => Math.round(window.__DUR * fps), FPS);

  if (mode === "sample") {
    const ts = process.argv[3].split(",").map(Number);
    for (const t of ts) {
      await page.evaluate((x) => window.renderFrame(x), t);
      const p = `/tmp/sample-${t.toFixed(2).replace(".", "_")}.png`;
      await page.screenshot({ path: p });
      console.log("wrote", p);
    }
  } else {
    fs.mkdirSync(OUT, { recursive: true });
    const from = parseInt(process.argv[3] || "0", 10);
    const t0 = Date.now();
    for (let i = from; i < TOTAL; i++) {
      await page.evaluate((x) => window.renderFrame(x), i / FPS);
      await page.screenshot({ path: path.join(OUT, `f${String(i).padStart(5, "0")}.png`) });
      if (i % 90 === 0) {
        const rate = (i - from + 1) / ((Date.now() - t0) / 1000);
        console.log(`frame ${i}/${TOTAL}  (${rate.toFixed(1)} fps)`);
      }
    }
    console.log("done", TOTAL, "frames in", ((Date.now() - t0) / 1000).toFixed(0), "s");
  }
  await browser.close();
})().catch((e) => { console.error(e); process.exit(1); });
