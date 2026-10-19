// LuCI UI test: card on Status -> Overview and the settings page.
// Usage: node ui.mjs <screenshot prefix>
import { chromium } from 'playwright';

const BASE = process.env.LUCI_URL || 'http://127.0.0.1:8080/cgi-bin/luci';
const shot = process.argv[2] || 'shot';
const failures = [];

function check(cond, msg) {
	console.log((cond ? 'ok   - ' : 'FAIL - ') + msg);
	if (!cond)
		failures.push(msg);
}

async function overview(page) {
	await page.goto(BASE + '/admin/status/overview');
	const card = page.locator('.ys-card');
	await card.waitFor({ timeout: 30000 });

	// OpenWrt 25.12 asks once whether to check online for firmware upgrades;
	// answer with the button that does not enable it
	await page.waitForTimeout(1000);
	const modal = page.locator('#modal_overlay .modal');
	if (await modal.isVisible()) {
		const buttons = modal.locator('button');
		const n = await buttons.count();
		let pick = n - 1;
		for (let i = 0; i < n; i++) {
			const cls = await buttons.nth(i).getAttribute('class') || '';
			if (!/positive|apply|save|action/.test(cls)) {
				pick = i;
				break;
			}
		}
		console.log('closing modal: ' + (await modal.locator('h4').innerText().catch(() => '?')) +
			' -> ' + (await buttons.nth(pick).innerText()));
		await buttons.nth(pick).click();
		await modal.waitFor({ state: 'hidden', timeout: 5000 }).catch(() => {});
	}

	return card;
}

const browser = await chromium.launch();
const ctx = await browser.newContext({ viewport: { width: 1280, height: 1000 }, locale: 'ru-RU' });
const page = await ctx.newPage();
const errors = [];
page.on('pageerror', e => errors.push(e.message));

try {
	await page.goto(BASE + '/');
	await page.fill('input[name=luci_username]', 'root');
	await page.fill('input[name=luci_password]', '');
	// LuCI keeps the /cgi-bin/luci/ address after login, wait for the page instead
	await Promise.all([
		page.waitForNavigation({ timeout: 30000 }),
		page.press('input[name=luci_password]', 'Enter')
	]);
	check(await page.locator('input[name=luci_password]').count() == 0, 'logged in');
	errors.length = 0; /* the login page itself is not ours */

	const card = await overview(page);
	const title = await page.locator('.cbi-section h3', { has: page.locator('text=Тест скорости') }).count();
	check(title > 0, 'card section titled "Тест скорости" (translation loaded)');

	// result of the previous ubus test is shown, IP masked
	const ip = page.locator('.ys-ip');
	if (await ip.isVisible()) {
		check(await ip.evaluate(e => e.classList.contains('ys-masked')), 'IP is blurred after page load');
		try {
			await ip.click({ timeout: 5000 });
		}
		catch (e) {
			/* Playwright waits for a "stable" element; report why it is not and click anyway */
			const why = await ip.evaluate(e => {
				const r = e.getBoundingClientRect(), cs = getComputedStyle(e);
				const top = document.elementFromPoint(r.x + r.width / 2, r.y + r.height / 2);
				const chain = [];
				for (let n = e; n && n != document.body; n = n.parentElement) {
					const c = getComputedStyle(n);
					chain.push(`${n.tagName}.${n.className}[pe=${c.pointerEvents},op=${c.opacity},z=${c.zIndex}]`);
				}
				const t = top ? getComputedStyle(top) : null;
				return `box ${r.x|0},${r.y|0} ${r.width|0}x${r.height|0}, visibility ${cs.visibility}, ` +
					`animation ${cs.animationName}, transition ${cs.transitionProperty}; ` +
					`on top: ${top ? top.outerHTML.slice(0, 300) : 'none'} ` +
					(t ? `[pos=${t.position},z=${t.zIndex},contains card=${top.contains(e)}]` : '') +
					`; ancestors: ${chain.join(' < ')}`;
			});
			check(false, 'IP element is not stable for Playwright: ' + why);
			await ip.click({ force: true });
		}
		check(!(await ip.evaluate(e => e.classList.contains('ys-masked'))), 'click on IP shows it');
		await page.waitForTimeout(1500);
		check(!(await card.evaluate(e => e.classList.contains('ys-running'))), 'click on IP does not start a test');
	}
	else {
		check(false, 'IP row visible after a finished test');
	}
	await page.screenshot({ path: shot + '-overview.png', fullPage: true });

	// start, pick it up in a second tab, stop
	const speedRow = page.locator('.ys-speed');
	await speedRow.click();
	await page.waitForSelector('.ys-card.ys-running', { timeout: 5000 });
	check(true, 'click starts the test');

	const page2 = await ctx.newPage();
	page2.on('pageerror', e => errors.push(e.message));
	await overview(page2);
	await page2.waitForSelector('.ys-card.ys-running', { timeout: 5000 });
	check(true, 'second tab picks up the running test');

	await page.waitForSelector('.ys-card .ys-bar > div[style*="width"]', { timeout: 10000 });
	await page.screenshot({ path: shot + '-running.png', fullPage: true });

	await speedRow.click();
	await page.waitForSelector('.ys-card:not(.ys-running)', { timeout: 10000 });
	check(true, 'second click stops the test');
	const speed = await page.locator('.ys-speed').innerText();
	check(/–.*–/.test(speed), `card back to the initial look ("${speed}")`);
	await page2.waitForSelector('.ys-card:not(.ys-running)', { timeout: 10000 });
	check(true, 'second tab sees the stop');
	await page2.close();

	// full run from the UI
	await speedRow.click();
	await page.waitForSelector('.ys-card.ys-running', { timeout: 5000 });
	await page.waitForSelector('.ys-card:not(.ys-running)', { timeout: 90000 });
	await page.waitForTimeout(1500); /* number animation */
	const done = await page.locator('.ys-speed').innerText();
	check(/^\d+\.\d ↓\s*\|\s*\d+\.\d ↑/.test(done), 'full run shows both numbers: ' + done.replace(/\s+/g, ' '));
	await page.screenshot({ path: shot + '-done.png', fullPage: true });

	// settings page
	await page.goto(BASE + '/admin/services/yandex-speedtest');
	const streams = page.locator('input[id$=".streams"]');
	await streams.waitFor({ timeout: 30000 });
	check(true, 'settings page renders');
	await page.screenshot({ path: shot + '-settings.png', fullPage: true });
	await streams.fill('2');
	await page.click('.cbi-page-actions .cbi-button-apply');
	await page.waitForTimeout(8000);
}
catch (e) {
	check(false, 'exception: ' + e.message.split('\n').filter(l => l.trim()).slice(0, 6).join(' / '));
	await page.screenshot({ path: shot + '-error.png', fullPage: true }).catch(() => {});
}

check(errors.length == 0, 'no JavaScript errors' + (errors.length ? ': ' + errors.join('; ') : ''));

await browser.close();
console.log(failures.length ? 'UI failed' : 'UI passed');
process.exit(failures.length ? 1 : 0);
