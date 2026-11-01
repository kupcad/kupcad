import { expect, test } from '@playwright/test';

/**
 * Where the model's canvas and the panel are drawn in a pane `width` pixels wide.
 * @param {import('@playwright/test').Page} page
 * @param {number} width
 */
async function layoutAt(page, width) {
  await page.evaluate((w) => {
    /** @type {HTMLElement} */ (document.querySelector('#pane')).style.width = `${w}px`;
  }, width);
  const box = async (/** @type {string} */ selector) =>
    /** @type {{ x: number, y: number, width: number, height: number }} */ (
      await page.locator(selector).boundingBox()
    );
  return {
    model: await box('.kc-viewer-pane .canvas'),
    panel: await box('.kc-viewer-pane .panel'),
  };
}

test("lays the panel beside the model, and under it in a phone's width", async ({ page }) => {
  const errors = /** @type {string[]} */ ([]);
  page.on('pageerror', (error) => errors.push(error.message));
  await page.goto('/pane.html');
  await page.waitForFunction(() => window.ready);

  const wide = await layoutAt(page, 900);
  expect(wide.panel.x).toBeGreaterThanOrEqual(wide.model.x + wide.model.width - 1);
  expect(Math.abs(wide.panel.y - wide.model.y)).toBeLessThan(2);

  // Narrower than 36em: under the model, as wide, and at most half the pane
  const narrow = await layoutAt(page, 360);
  expect(narrow.panel.y).toBeGreaterThanOrEqual(narrow.model.y + narrow.model.height - 1);
  expect(Math.abs(narrow.panel.width - narrow.model.width)).toBeLessThan(2);
  expect(narrow.panel.height).toBeLessThanOrEqual(300);
  expect(narrow.model.height).toBeGreaterThan(0);
  expect(errors).toEqual([]);
});

test("frames a part's swatch, so a white part shows on the light panel", async ({ page }) => {
  await page.goto('/pane.html');
  await page.waitForFunction(() => window.ready);
  const swatch = page.locator('.kc-viewer-pane .swatch');
  await expect(swatch).toHaveCount(1);
  const box = /** @type {{ x: number, y: number, width: number, height: number }} */ (
    await swatch.boundingBox()
  );
  // Its edge and the panel just past it, as drawn
  const shot = await page.screenshot({
    clip: { x: box.x - 2, y: box.y + box.height / 2, width: box.width + 4, height: 1 },
  });
  const colours = await page.evaluate(
    async (png) => {
      const bitmap = await createImageBitmap(
        new Blob([new Uint8Array(png)], { type: 'image/png' }),
      );
      const context = /** @type {OffscreenCanvasRenderingContext2D} */ (
        new OffscreenCanvas(bitmap.width, bitmap.height).getContext('2d')
      );
      context.drawImage(bitmap, 0, 0);
      const { data } = context.getImageData(0, 0, bitmap.width, 1);
      return Array.from({ length: bitmap.width }, (_, x) => data[x * 4]);
    },
    [...shot],
  );
  // Two pixels of panel, then the swatch's edge, then its white middle
  const [panel, , edge] = colours;
  const middle = colours[Math.floor(colours.length / 2)];
  expect(middle).toBe(255);
  expect(edge).toBeLessThan(panel);
  expect(edge).toBeLessThan(middle);
});
