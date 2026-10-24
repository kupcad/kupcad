import { LIGHT } from '@kupcad/viewer';
import { expect, it, vi } from 'vitest';
import { themeFromTokens, watchTokens } from './theme.js';

it("takes the viewer's colours from the --kc-viewer-* tokens, its own where one is unset", () => {
  const element = document.createElement('div');
  element.style.setProperty('--kc-viewer-background', '#101010');
  element.style.setProperty('--kc-viewer-selection', ' rgb(1, 2, 3) ');
  document.body.append(element);
  expect(themeFromTokens(element)).toEqual({
    ...LIGHT,
    background: '#101010',
    selection: 'rgb(1, 2, 3)',
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
  stop();
  root.style.setProperty('--kc-viewer-background', '#405060');
  await new Promise((resolve) => setTimeout(resolve));
  expect(backgrounds).toEqual([LIGHT.background, '#102030']);
  root.removeAttribute('style');
  element.remove();
});
