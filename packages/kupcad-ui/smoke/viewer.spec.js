import { expect, test } from '@playwright/test';
import { BACKGROUND_RGB } from './colors.js';

/** @param {number[]} rgb @param {number} channel which of red, green, blue leads */
const leads = (rgb, channel) => rgb.every((value, i) => i === channel || rgb[channel] > value + 60);

test('draws what the core made: its colour, the background, a section and its cap', async ({
  page,
}) => {
  const errors = /** @type {string[]} */ ([]);
  page.on('pageerror', (error) => errors.push(error.message));
  await page.goto('/');
  await page.waitForFunction(() => window.ready);
  await page.evaluate(() =>
    window.smoke.show('cube(20, center: true).named("block").material(color: "#d02020")'),
  );

  // The iso view's centre is where three edges meet: a face is beside it
  expect(leads(await page.evaluate(() => window.smoke.pixel(0.4, 0.6)), 0)).toBe(true);
  expect(await page.evaluate(() => window.smoke.pixel(0.02, 0.02))).toEqual(BACKGROUND_RGB);

  // From the top, a section below the cube cuts all of it away
  await page.evaluate(() => {
    window.smoke.setCamera({ view: 'top' });
    window.smoke.setSection({ axis: 'z', offset: -15 });
  });
  expect(await page.evaluate(() => window.smoke.pixel(0.5, 0.5))).toEqual(BACKGROUND_RGB);

  // Through its middle, the cut is capped in the cap's colour
  await page.evaluate(() => window.smoke.setSection({ axis: 'z', offset: 0 }));
  expect(leads(await page.evaluate(() => window.smoke.pixel(0.5, 0.5)), 1)).toBe(true);
  expect(errors).toEqual([]);
});

test('draws the view cube, which turns the camera to the part clicked', async ({ page }) => {
  const errors = /** @type {string[]} */ ([]);
  page.on('pageerror', (error) => errors.push(error.message));
  await page.goto('/');
  await page.waitForFunction(() => window.ready);
  await page.evaluate(() => window.smoke.show('cube(20, center: true)'));
  const cube = page.locator('#cube');
  await page.evaluate(() => window.smoke.setCamera({ view: 'top' }));
  // From the top, the front edge is the cube's lower one
  await cube.click({ position: { x: 48, y: 68 } });
  expect(await page.evaluate(() => window.smoke.view())).toBeNull();
  await cube.click({ position: { x: 48, y: 48 } });
  expect(await page.evaluate(() => window.smoke.view())).toBeNull();
  expect(errors).toEqual([]);
});
