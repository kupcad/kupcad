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

/** @param {number[]} rgb */
const dark = (rgb) => rgb.every((value) => value < 60);

test('draws a drawing in its order, over the floor', async ({ page }) => {
  // All at z = 0, by depth the red square was lost under the black one, and the grid over both
  const errors = /** @type {string[]} */ ([]);
  page.on('pageerror', (error) => errors.push(error.message));
  await page.goto('/');
  await page.waitForFunction(() => window.ready);
  await page.evaluate(() => window.smoke.setEnvironment('grid'));
  await page.evaluate(() =>
    window.smoke.show(
      '[square(40, center: true).material(color: "#000000"), square(10, center: true).material(color: "#d02020")]',
    ),
  );
  // The red square's middle, through which the grid's lines at x = 0 and y = 0 run
  const red = await page.evaluate(() => window.smoke.pixels(0.46, 0.46, 0.54, 0.54));
  expect(red.filter((rgb) => !leads(rgb, 0))).toEqual([]);
  // The black square's, past the red one, across several of the grid's lines
  const black = await page.evaluate(() => window.smoke.pixels(0.3, 0.3, 0.4, 0.4));
  expect(black.filter((rgb) => !dark(rgb))).toEqual([]);
  expect(errors).toEqual([]);
});

test('a section on a face cuts it cleanly: the cap at the bottom, the face at the top', async ({
  page,
}) => {
  // Whether a face on the plane was clipped came down to each pixel's rounding: the cap in streaks
  const errors = /** @type {string[]} */ ([]);
  page.on('pageerror', (error) => errors.push(error.message));
  await page.goto('/');
  await page.waitForFunction(() => window.ready);
  await page.evaluate(() =>
    window.smoke.show(
      'cube(20, center: true).translate(z: 10).named("block").material(color: "#d02020")',
    ),
  );
  const middle = () => page.evaluate(() => window.smoke.pixels(0.4, 0.4, 0.6, 0.6));
  // At its bottom face, the section is all of its footprint: from above, and from the side,
  // where the footprint is low in the view of the whole cube
  await page.evaluate(() => {
    window.smoke.setCamera({ view: 'top' });
    window.smoke.setSection({ axis: 'z', offset: 0 });
  });
  expect((await middle()).filter((rgb) => !leads(rgb, 1))).toEqual([]);
  await page.evaluate(() => window.smoke.setCamera({ view: 'iso' }));
  const footprint = await page.evaluate(() => window.smoke.pixels(0.45, 0.65, 0.55, 0.78));
  expect(footprint.filter((rgb) => !leads(rgb, 1))).toEqual([]);
  // At its top face, from above, the face itself
  await page.evaluate(() => {
    window.smoke.setCamera({ view: 'top' });
    window.smoke.setSection({ axis: 'z', offset: 20 });
  });
  expect((await middle()).filter((rgb) => !leads(rgb, 0))).toEqual([]);
  // From below, the bottom face hides the cap behind it
  await page.evaluate(() => {
    window.smoke.setCamera({ view: 'bottom' });
    window.smoke.setSection({ axis: 'z', offset: 0 });
  });
  expect((await middle()).filter((rgb) => !leads(rgb, 0))).toEqual([]);
  expect(errors).toEqual([]);
});
