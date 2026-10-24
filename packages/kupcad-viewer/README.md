# @kupcad/viewer

The scene of a model the KupCAD core made: its Solids from the GLB, or a drawing from the SVG,
in the script's own coordinates (millimetres, Z up), with render modes, views, a section plane
and part picking. A class any host can own, and a Svelte component around it.

```js
import { Viewer, DARK } from '@kupcad/viewer';

const viewer = new Viewer(canvas, { theme: DARK, environment: 'grid' });
await viewer.setModel(preview.model); // @kupcad/protocol's Model, from a preview frame; false
// when a model asked for later replaced it before it was shown
viewer.setRenderMode('xray'); // 'solid' | 'xray' | 'wireframe'
viewer.setCamera({ projection: 'orthographic', view: 'front' }); // frames the model from there
viewer.setSection({ axis: 'z', offset: 5 }); // cut away what is above z = 5, the cut capped
viewer.addEventListener('select', (event) => console.log(event.detail.part)); // a click (the main
// button; the others pan and zoom), or null
viewer.select('bolt'); // tints every copy of the part
viewer.bounds; // { min, max } in mm: what a section's offset ranges over
const png = await viewer.screenshot();
```

```svelte
<script>
  import { Viewer } from '@kupcad/viewer/svelte';
  let selected = $state(null);
</script>

<Viewer model={preview.model} renderMode="solid" bind:selected onmodel={(viewer) => viewer.bounds} />
```

* **The model:** each copy of a part is a node of the GLB named as the frame's `parts[].nodes`
  say, so the viewer knows every mesh's part; ghosts are seen through and can't be picked. A
  drawing is seen from the top, orthographic, each filled shape named by its id. A model that
  follows keeps the camera where it is, a model of nothing between them too (one that failed);
  the first, or one of another kind than the last shown, is framed, a solid after a drawing as
  the last solid was seen. The camera's depth takes in the model and what it stands on, however
  small the model and wherever the camera moves. A model without the selected part drops the
  selection, with a `select` event of null.
* **Rendering** is on demand: when the model, a setting or the camera changes, once a frame. A
  solid shows its feature edges; x-ray sees through it; a wireframe is the edges alone.
* **A section** clips every material of a solid's model at its plane and caps the cut where it
  runs inside a solid (three.js's stencil technique), but in a wireframe; a drawing isn't cut. A
  part cut away isn't picked.
* **Draco:** a model built with `--draco` needs `dracoDecoderPath`, where three.js's decoder files
  are; the decoder is loaded only when a model needs it.
* **Themes** are colours (`LIGHT`, `DARK`, or a host's own, as the VS Code webview maps its
  `--vscode-*` variables).

The component's canvas is named for a screen reader by `label` ("The model" by default). `onmodel` is called for each model shown, not for one a later model replaced before it
was. Without `onerror`, a model it can't show is an unhandled rejection; an error of `onmodel`'s
is never passed to `onerror`.

A host's tests that mount the viewer under jsdom add `@kupcad/viewer/testing` to Vitest's
`setupFiles`: what jsdom lacks of a browser and the viewer uses. Its `stubRenderer()` draws in
place of WebGL (`options.renderer`) and keeps what it was asked: the frames, the last scene and
camera, and whether it was disposed.

Tests: the scene logic in Node (jsdom), with a stand-in for WebGL and models the real core makes
through `@kupcad/wasm`; and a smoke test in headless Chromium (`pnpm test:browser`) that draws
what the core makes in the page and reads the pixels back: the part's colour, the background, a
section cutting it all away, and a cap.
