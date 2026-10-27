// The playground on one of the examples, filling the window: what `pnpm dev` serves and the smoke
// test drives, embedded as a site embeds it. The page takes @kupcad/panels's tokens, light or dark as
// the system is.

import '@kupcad/panels/tokens.css';
import { mount } from 'svelte';
import standoff from '../../../examples/standoff.kup?raw';
import { Playground } from '../src/index.js';

mount(Playground, {
  target: /** @type {HTMLElement} */ (document.querySelector('#playground')),
  props: { source: standoff, name: 'standoff' },
});
