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

// @kupcad/ui's tokens as the page's colour scheme is: the brand's orange accent on white or
// on the brand black, and a slider's track filled to its thumb (WebKit and Blink fill none)
for (const [scheme, background] of /** @type {const} */ ([
  ['light', 'rgb(255, 255, 255)'],
  ['dark', 'rgb(26, 27, 28)'],
])) {
  test(`wears the KupCAD tokens in a ${scheme} colour scheme, its sliders filled to their thumbs`, async ({
    page,
  }) => {
    test.setTimeout(120_000);
    await page.emulateMedia({ colorScheme: scheme });
    await page.goto('/');
    const slider = page.getByRole('slider', { name: 'Standoff spacing slider' });
    await expect(slider).toBeVisible({ timeout: 60_000 });
    const look = await slider.evaluate((element) => {
      const style = getComputedStyle(element);
      return {
        accent: style.getPropertyValue('--kc-accent').trim(),
        fill: style.getPropertyValue('--kc-range-fill').trim(),
      };
    });
    // 20 of 15 to 35: a quarter along
    expect(look).toEqual({ accent: '#ff5f14', fill: '25%' });
    await expect(page.locator('.kc-console')).toHaveCSS('background-color', background);
  });
}

test("keeps the parameters where they are as a value is set and all reset: Reset all's room is kept", async ({
  page,
}) => {
  test.setTimeout(120_000);
  await page.goto('/');
  await expect(page.getByRole('status')).toHaveText(/Ready · \d+ ms/, { timeout: 60_000 });
  const field = page.getByRole('spinbutton', { name: 'Standoff spacing' });
  const top = async () => (await field.boundingBox())?.y;
  const before = await top();
  await expect(page.getByRole('button', { name: 'Reset all' })).toBeHidden();
  await field.fill('30');
  await field.press('Enter');
  await expect(page.getByRole('button', { name: 'Reset all' })).toBeVisible();
  await expect(page.locator('.kc-params .set')).toHaveText('1 changed');
  expect(await top()).toBe(before);
  await page.getByRole('button', { name: 'Reset all' }).click();
  await expect(page.getByRole('button', { name: 'Reset all' })).toBeHidden();
  expect(await top()).toBe(before);
});
