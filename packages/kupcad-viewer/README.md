# @kupcad/viewer

The scene of a model the KupCAD core made: its Solids from the GLB, or a drawing from the SVG,
in the script's own coordinates (millimetres, Z up), with render modes, views, a section plane
and part picking. A class any host can own, and a Svelte component around it.

```js
import { Viewer, DARK } from '@kupcad/viewer';

const viewer = new Viewer(canvas, { theme: DARK, environment: 'grid' });
await viewer.setModel(preview.model); // @kupcad/protocol's Model, from a preview frame
viewer.setRenderMode('xray'); // 'solid' | 'xray' | 'wireframe'
viewer.setCamera({ projection: 'orthographic', view: 'front' }); // frames the model from there
viewer.setSection({ axis: 'z', offset: 5 }); // cut away what is above z = 5, the cut capped
viewer.addEventListener('select', (event) => console.log(event.detail.part)); // a click on a part
viewer.select('bolt'); // tints every copy of the part
viewer.bounds; // { min, max } in mm: what a section's offset ranges over
const png = await viewer.screenshot();
```

```svelte
<script>
  import Viewer from '@kupcad/viewer/Viewer.svelte';
  let selected = $state(null);
</script>

<Viewer model={preview.model} renderMode="solid" bind:selected />
```

* **The model:** each copy of a part is a node of the GLB named as the frame's `parts[].nodes`
  say, so the viewer knows every mesh's part; ghosts are seen through and can't be picked. A
  drawing is seen from the top, orthographic, each filled shape named by its id. A model that
  follows keeps the camera where it is; the first, or one of another kind, is framed.
* **Rendering** is on demand: when the model, a setting or the camera changes, once a frame. A
  solid shows its feature edges; x-ray sees through it; a wireframe is the edges alone.
* **A section** clips every material at its plane and caps the cut where it runs inside a
  solid (three.js's stencil technique).
* **Draco:** a model built with `--draco` needs `dracoDecoderPath`, where three.js's decoder files
  are; the decoder is loaded only when a model needs it.
* **Themes** are colours (`LIGHT`, `DARK`, or a host's own, as the VS Code webview maps its
  `--vscode-*` variables).

Tests: the scene logic in Node (jsdom), with a stand-in for WebGL and models the real core makes
through `@kupcad/wasm`; and a smoke test in headless Chromium (`pnpm test:browser`) that draws
what the core makes in the page and reads the pixels back: the part's colour, the background, a
section cutting it all away, and a cap.
