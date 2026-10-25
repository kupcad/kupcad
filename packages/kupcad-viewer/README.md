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
viewer.setEdges(false); // the shapes' edges hidden (a wireframe's stay)
viewer.setAxes(false); // the X (red), Y (green) and Z (blue) axes through the origin hidden
viewer.setCamera({ projection: 'orthographic', view: 'front' }); // moves there, framing the model
viewer.lookFrom([1, 1, 1]); // from any direction (Z up), as the view cube's corner does
new ViewCube(cubeCanvas, viewer, { theme: DARK }); // the cube, on a canvas of its own
viewer.fit(); viewer.zoom(1.25); // fits the model from where it looks; zooms in (out, below 1)
viewer.setSection({ axis: 'z', offset: 5 }); // cut away what is above z = 5, the cut capped
viewer.addEventListener('section', (event) => event.detail.section); // the wheel with Option moved it
viewer.addEventListener('select', (event) => console.log(event.detail.part)); // a click (the main
// button; the others pan and zoom), or null
viewer.select('bolt'); // tints every copy of the part
viewer.bounds; // { min, max } in mm: what a section's offset ranges over
viewer.hoverAt(x, y); // { part, face: { flat, area, normal, facing } }: what is under a point
viewer.addEventListener('hover', (event) => event.detail); // the same, with x and y, as the pointer moves
viewer.kind; // '3d' or '2d', the model shown's (a drawing isn't cut), or null for none
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
  solid the script highlights (`.highlight`, which the core tags in the GLB) is drawn in the
  theme's `highlight` colour and seen through whatever hides it (a see-through copy drawn only
  behind what is in front), in solid mode; it is a part as any other. A
  drawing is seen from the top, orthographic, each filled shape named by its id. A model that
  follows keeps the camera where it is, a model of nothing between them too (one that failed);
  the first, or one of another kind than the last shown, is framed, a solid after a drawing as
  the last solid was seen. The camera's depth takes in the model and what it stands on, however
  small the model and wherever the camera moves. A model without the selected part drops the
  selection, with a `select` event of null.
* **Under the pointer** the viewer says, a frame at most (a `hover` event, null over nothing and
  while a button drags the camera), the part and, on a solid, the face: what its feature edges
  bound (`faces.js`: triangles joined where they meet at less than the edges' 20°), flat when it
  faces one way (its area in mm², its way, and `+Z (top)` when along an axis) or curved (its
  area). A ghost, seen through, is under nothing, and neither is what a section cut away.
* **The view cube** (`ViewCube`, which the Svelte component puts in its corner unless
  `cube={false}`) is turned as the camera is; its faces (labelled TOP, FRONT, RIGHT, ..., each
  upright from its view), edges and corners, 26 ways to look, take the camera there when
  clicked, the one under the pointer lit in the selection's colour.
* **The camera** moves to a view over a moment (`motionMs`, 250 by default; at once when the page
  asks for reduced motion), turning round the model. Turned by hand it is in no named view (`view`
  is null), which a `view` event says, as it says every change. Its controls are Orca Slicer's:
  the left button turns, the middle and right ones pan; once it has the focus (a click gives it),
  `0`–`6` (alone, or with Ctrl or Cmd) look from the iso, top, bottom, front, back, left and
  right, `F` fits, `I` and `O` zoom in and out.
* **The wheel** (or two fingers on a trackpad: `wheel.js`) zooms, as a pinch does, and while
  the left or right button drags too, though not with the middle one held (the wheel, pressed,
  turns a little). With Shift it pans, the model moving as a page's content scrolls (Orca's
  Shift with two fingers on a Mac); with Option (Alt) it moves the section along its axis, a
  solid without one cut across Z from its top (Orca's Alt), which a `section` event says; with
  Cmd it turns the view, as a drag does. Ctrl is a pinch's: a browser sends one as the wheel
  with Ctrl, so Ctrl and the wheel zoom too.
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
