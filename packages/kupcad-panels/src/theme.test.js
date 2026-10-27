import { DARK, LIGHT } from '@kupcad/viewer';
import { expect, it, vi } from 'vitest';
import { themeFromTokens, viewerColor, watchTokens } from './theme.js';

it("takes the viewer's colours from the --kc-viewer-* tokens, its own where one is unset", () => {
  const element = document.createElement('div');
  element.style.setProperty('--kc-viewer-background', '#101010');
  element.style.setProperty('--kc-viewer-selection', ' rgb(1, 2, 3) ');
  element.style.setProperty('--kc-viewer-highlight', '#c050a0');
  document.body.append(element);
  expect(themeFromTokens(element)).toEqual({
    ...LIGHT,
    background: '#101010',
    selection: 'rgb(1, 2, 3)',
    highlight: '#c050a0',
  });
  element.remove();
});

it('reads a hex colour with an alpha as the colour alone, which the viewer can draw', () => {
  const element = document.createElement('div');
  element.style.setProperty('--kc-viewer-background', '#1e1e1eff');
  element.style.setProperty('--kc-viewer-grid', '#abcd');
  document.body.append(element);
  const theme = themeFromTokens(element);
  expect([theme.background, theme.grid]).toEqual(['#1e1e1e', '#abc']);
  element.remove();
});

it("gives the tokens' theme as the page's root changes them, once for each change, until stopped", async () => {
  const element = document.createElement('div');
  document.body.append(element);
  /** @type {string[]} */
  const backgrounds = [];
  const stop = watchTokens(element, (theme) => backgrounds.push(theme.background));
  const root = document.documentElement;
  root.style.setProperty('--kc-viewer-background', '#102030');
  await vi.waitFor(() => expect(backgrounds).toEqual([LIGHT.background, '#102030']));
  // A change of something else gives nothing
  root.style.setProperty('--other', '1');
  await new Promise((resolve) => setTimeout(resolve));
  expect(backgrounds).toEqual([LIGHT.background, '#102030']);
  stop();
  root.style.setProperty('--kc-viewer-background', '#405060');
  await new Promise((resolve) => setTimeout(resolve));
  expect(backgrounds).toEqual([LIGHT.background, '#102030']);
  root.removeAttribute('style');
  element.remove();
});

it("takes the viewer's dark colours for the tokens unset, in a dark colour scheme", () => {
  vi.stubGlobal('matchMedia', (/** @type {string} */ query) => ({
    matches: query === '(prefers-color-scheme: dark)',
  }));
  try {
    expect(themeFromTokens(document.body)).toEqual(DARK);
  } finally {
    vi.unstubAllGlobals();
  }
});

/**
 * A 2D context as a browser's reads a colour: the colours `drawn` knows (their pixel's sRGB)
 * taken as the fill, and any other leaving the fill as it was.
 * @param {Record<string, [number, number, number, number]>} drawn
 */
function browserContext(drawn) {
  let fill = '#000000';
  /** @type {[number, number, number, number]} */
  let pixel = [0, 0, 0, 0];
  return {
    get fillStyle() {
      return fill;
    },
    set fillStyle(color) {
      if (Object.hasOwn(drawn, color) || color === '#000000' || color === '#ffffff') fill = color;
    },
    clearRect() {
      pixel = [0, 0, 0, 0];
    },
    fillRect() {
      pixel = drawn[fill] ?? pixel;
    },
    getImageData: () => /** @type {ImageData} */ ({ data: new Uint8ClampedArray(pixel) }),
  };
}

it('reads a colour as the browser draws it, opaque, and none it reads not', () => {
  // As Chromium draws them: the fill keeps the first two as they are, which three.js reads not
  const context = /** @type {any} */ (
    browserContext({
      'color-mix(in srgb, red, blue)': [128, 0, 128, 255],
      'oklch(0.6 0.15 250)': [39, 132, 213, 255],
      'rgba(10, 20, 30, 0.5)': [10, 20, 30, 128],
    })
  );
  expect(viewerColor('color-mix(in srgb, red, blue)', context)).toBe('#800080');
  expect(viewerColor('oklch(0.6 0.15 250)', context)).toBe('#2784d5');
  expect(viewerColor('rgba(10, 20, 30, 0.5)', context)).toBe('#0a141e');
  expect(viewerColor('no colour', context)).toBe('');
  expect(viewerColor('', context)).toBe('');
});
