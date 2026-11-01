// The pane smoke test's page: the ViewerPane, in a box whose width the test sets, laid out by
// the browser (its narrow layout is a container query, which jsdom doesn't apply).

import { mount } from 'svelte';
import ViewerPane from '../src/ViewerPane.svelte';

mount(ViewerPane, { target: /** @type {HTMLElement} */ (document.querySelector('#pane')) });
window.ready = true;
