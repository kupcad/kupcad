import { expect, test } from '@playwright/test';

test('runs the example in the browser: its model, its parts and parameters; an edit runs again', async ({
  page,
}) => {
  // The first visit compiles the core's module, a few seconds on a slow machine
  test.setTimeout(120_000);
  const errors = /** @type {string[]} */ ([]);
  page.on('pageerror', (error) => errors.push(error.message));
  await page.goto('/');
  // The core's worker loaded its module and ran the script
  await expect(page.getByRole('status')).toHaveText(/Ready · \d+ ms/, { timeout: 60_000 });
  await expect(page.getByRole('list', { name: 'Parts' })).toBeVisible();
  // A parameter by its title, with its description; one without, by its name
  await expect(
    page.getByRole('spinbutton', { name: 'Standoff spacing' }),
  ).toHaveAccessibleDescription('Centre to centre of the two frame standoffs it clips onto');
  await expect(page.getByRole('spinbutton', { name: 'platform_w' })).toBeVisible();
  // Highlighted as KupCAD: `param`, a function of the core's, in a colour of its own
  const colours = await page.evaluate(() => {
    const param = [...document.querySelectorAll('.cm-line span')].find(
      (span) => span.textContent === 'param',
    );
    const line = param?.closest('.cm-line');
    return param && line && [getComputedStyle(param).color, getComputedStyle(line).color];
  });
  expect(colours?.[0]).not.toBe(colours?.[1]);

  // A script that fails says so, and where
  await page.locator('.cm-content').click();
  await page.keyboard.press('ControlOrMeta+a');
  await page.keyboard.type('raise "boom"\n');
  await expect(page.getByRole('status')).toHaveText(/Failed · \d+ ms/, { timeout: 30_000 });
  await expect(page.getByRole('list', { name: 'Problems' })).toContainText('boom');
  expect(errors).toEqual([]);
});
