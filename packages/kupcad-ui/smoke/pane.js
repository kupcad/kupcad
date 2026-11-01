// The pane smoke test's page: the ViewerPane, in a box whose width the test sets, laid out by
// the browser (its narrow layout is a container query, which jsdom doesn't apply), showing a
// model the core makes in the page: a white part, whose swatch must show on the light panel.

import { createKupcad } from '@kupcad/wasm';
import { mount } from 'svelte';
import ViewerPane from '../src/ViewerPane.svelte';
// The colours a host gives the pane
import '../src/tokens.css';

const core = await createKupcad({ log: () => {} });
const { model } = await core.preview('cube(5).named("white").material(color: "#ffffff")');
mount(ViewerPane, {
  target: /** @type {HTMLElement} */ (document.querySelector('#pane')),
  props: { model },
});
window.ready = true;
