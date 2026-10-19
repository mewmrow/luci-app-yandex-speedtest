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
		await ip.click();
		check(!(await ip.evaluate(e => e.classList.contains('ys-masked'))), 'click on IP shows it');
		await page.waitForTimeout(1500);
		check(!(await card.evaluate(e => e.classList.contains('ys-running'))), 'click on IP does not start a test');
	}
	else {
		check(false, 'IP row visible after a finished test');
	}
	await page.screenshot({ path: shot + '-overview.png', fullPage: true });

	// start, pick it up in a second tab, stop
	await card.click();
	await page.waitForSelector('.ys-card.ys-running', { timeout: 5000 });
	check(true, 'click starts the test');

	const page2 = await ctx.newPage();
	page2.on('pageerror', e => errors.push(e.message));
	await overview(page2);
	await page2.waitForSelector('.ys-card.ys-running', { timeout: 5000 });
	check(true, 'second tab picks up the running test');

	await page.waitForSelector('.ys-card .ys-bar > div[style*="width"]', { timeout: 10000 });
	await page.screenshot({ path: shot + '-running.png', fullPage: true });

	await card.click();
	await page.waitForSelector('.ys-card:not(.ys-running)', { timeout: 10000 });
	check(true, 'second click stops the test');
	const speed = await page.locator('.ys-speed').innerText();
	check(/–.*–/.test(speed), `card back to the initial look ("${speed}")`);
	await page2.waitForSelector('.ys-card:not(.ys-running)', { timeout: 10000 });
	check(true, 'second tab sees the stop');
	await page2.close();

	// full run from the UI
	await card.click();
	await page.waitForSelector('.ys-card:not(.ys-running)', { timeout: 90000 });
	const done = await page.locator('.ys-card').innerText();
	check(/\d+\.\d.*\d+\.\d/s.test(done), 'full run shows both numbers: ' + done.replace(/\s+/g, ' '));
	await page.waitForTimeout(1500);
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
	check(false, 'exception: ' + e.message.split('\n')[0]);
	await page.screenshot({ path: shot + '-error.png', fullPage: true }).catch(() => {});
}

check(errors.length == 0, 'no JavaScript errors' + (errors.length ? ': ' + errors.join('; ') : ''));

await browser.close();
console.log(failures.length ? 'UI failed' : 'UI passed');
process.exit(failures.length ? 1 : 0);
