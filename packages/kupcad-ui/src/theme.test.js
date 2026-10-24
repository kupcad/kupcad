import { LIGHT } from '@kupcad/viewer';
import { expect, it } from 'vitest';
import { themeFromTokens } from './theme.js';

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
