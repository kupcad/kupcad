# @kupcad/ui

KupCAD's UI: the viewer of a model the core made, for any host, and the Svelte components a
host shows around it, styled by the `--kc-*` tokens.

| Import | What it is | Needs Svelte |
|---|---|---|
| `@kupcad/ui/viewer` | the viewer, a class over three.js (`Viewer`, `ViewCube`, `LIGHT`, `DARK`) | no |
| `@kupcad/ui/viewer/types` | its types, for JSDoc or TypeScript | no |
| `@kupcad/ui` | the components (`Viewer`, `ViewerPane`, `ParamsPanel`, `ConsolePanel`, `PreviewPanel`, `Splitter`, `ExportMenu`, `ShortcutsDialog`) and what they keep (settings, the view's choices) | yes |
| `@kupcad/ui/tokens.css`, `vscode.css`, `controls.css` | the tokens, VS Code's theme over them, the controls' look | no |
| `@kupcad/ui/testing` | what jsdom lacks for the viewer, and `stubRenderer` | no |

Svelte is an optional peer: a host that imports the viewer alone needs none.

## The viewer

The scene of a model the KupCAD core made: its Solids from the GLB, or a drawing from the SVG,
in the script's own coordinates (millimetres, Z up), with render modes, views, a section plane
and part picking: a class any host can own. It imports neither Svelte nor the rest of the
package (`.oxlintrc.json` holds it to that), so a host that isn't Svelte's imports it alone.

```js
import { Viewer, ViewCube, DARK } from '@kupcad/ui/viewer';

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
viewer.fit({ instant: true }); // the same at once, no move
const left = viewer.cameraState(); // plain numbers: what it looks at, from where, how much it sees
viewer.restoreCamera(left); // there again at once, through either projection, as much seen
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

For Svelte, the component around it (`@kupcad/ui`'s `Viewer`):

```svelte
<script>
  import { Viewer } from '@kupcad/ui';
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
* **Under the pointer** the viewer marks and says, a frame at most (a `hover` event, null over
  nothing and while a button drags the camera), the part and, on a solid, the face. The copy under
  it glows a little in the selection's colour and its face more (`hover-mark.js`: light added to
  what is drawn there, so the mark shows on a part of any colour). The face is what its feature edges
  bound (`faces.js`: triangles joined where they meet at less than the edges' 20°), flat when it
  faces one way (its area in mm², its way, and `+Z (top)` when along an axis) or curved (its
  area). Which triangles meet which is found once a mesh, as the pointer first meets it, in typed
  arrays (a third of a second for a million triangles), and each face once, its area kept while
  the mesh doesn't move. A ghost, seen through, is under nothing, and neither is what a section
  cut away.
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
  `--vscode-*` variables). `LIGHT` and `DARK` are the KupCAD brand's: a selection in its
  orangered on the neutrals of the package's tokens, a section's cap in dodgerblue so no
  other warm colour reads as the selection. A line takes the colour for what it is drawn on: `edges` over a
  solid's faces, `wire` on the background (a wireframe's edges, a drawing's outlines), so a dark
  theme's dark edges don't vanish in a wireframe.

The component's canvas is named for a screen reader by `label` ("The model" by default). `onmodel` is called for each model shown, not for one a later model replaced before it
was. Without `onerror`, a model it can't show is an unhandled rejection; an error of `onmodel`'s
is never passed to `onerror`.

A host's tests that mount the viewer under jsdom add `@kupcad/ui/testing` to Vitest's
`setupFiles`: what jsdom lacks of a browser and the viewer uses. Its `stubRenderer()` draws in
place of WebGL (`options.renderer`) and keeps what it was asked: the frames, the last scene and
camera, whether it was disposed, and how many renderers were made and let their WebGL context go
(a viewer and its cube let theirs go when disposed, not when the page collects them: a page has
few).

## The components

The Svelte components a KupCAD host shows beside its editor: the viewer with its toolbar and
part list, the parameter panel, the console, and a language server's preview. They take
@kupcad/protocol's shapes and give back values; they hold no engine and fetch nothing, so a
host wires them to its own: the playground to @kupcad/wasm's worker, the VS Code extension's
webview and the desktop app to the language server.

```svelte
<script>
  import '@kupcad/ui/tokens.css'; // or '@kupcad/ui/vscode.css' in VS Code's webview
  import { ParamsPanel, ViewerPane } from '@kupcad/ui';

  let { preview } = $props(); // a protocol Preview: a frame read
  let overrides = $state({});
</script>

<ViewerPane model={preview.model} onscreenshot={(png) => save(png)} />
<ParamsPanel
  schema={preview.header.params.schema}
  values={preview.header.params.values}
  error={preview.header.error}
  bind:overrides
  onchange={(values) => host.setParams(values)}
/>
```

* **`ViewerPane`**: the viewer with its view cube in the corner, and a panel beside it that
  the toolbar's Panel button hides (`bind:panel`, for a host to keep): the view's controls in its top half (Solid, Wire, X-ray;
  Edges, Axes, Grid and Plate toggles; Fit, Persp, and the Iso, Top, Front and Right views, the
  one looked from pressed, a turn by hand pressing none), the model's parts in its bottom half,
  each with its colour and copies (a click on one selects its copies, as a click in the viewer
  does: `bind:selected`). A bar above: a section through the model along an axis (a solid's: a drawing, which isn't cut, or no model offers none), screenshot, an
  `actions` snippet (a host's own buttons, the Export menu), the Panel button, and a `toggles`
  snippet after it (a host's toggles of its own panes beside the pane, the Parameters button;
  `.kc-control` with `aria-expanded` gives one the Panel button's look). Below, a status
  line from `status` (`runStatusOf(header)` makes it of a frame's header: Running…, then Ready or
  Failed, with the run's time and its warnings) over the run's problems from `problems`
  (`problemsOf(header)`: why it failed, then its warnings), a few lines high; one with a line,
  clicked, goes to `onproblem`, for the host to show the script there.
  By the pointer a tooltip says what is under it: the part, its copies, volume and size (the
  frame's), and the face, flat with its area and the way it faces, or curved (`measures.js`).
  `bind:viewer` gives the viewer itself. The controls show how the viewer looks (a drawing
  switches it to the top view, orthographic; a turn of the wheel with Option moves the section,
  and its slider), and a section stays where it was put through an edit of the script, while the
  model still reaches it. A model of another `subject` (another script: the preview gives the
  document's URI) is framed: as its camera was left when it was shown last, else whole from
  where the camera looks; the same subject's next model (an edit, a parameter) keeps the camera.
  The cameras are the pane's own, in memory while it is there, the least recently shown let go
  past 32 (`recent.js`); without a subject, every model keeps the camera.
  How the view looks, as the person chose it (the render mode, edges, axes, the floor, the
  projection), is kept in the host's `settings` under the view.* keys (`VIEW_KEYS`), and followed
  as they are set wherever from: a host's settings page shows and sets the same keys
  (`viewChoices(settings)`, `viewChoice(settings, name)`, each a valid value else its default,
  `VIEW_DEFAULTS`, and the values offered: `RENDER_MODES`, `ENVIRONMENTS`, `PROJECTIONS`). A
  drawing's top orthographic view is no choice: it isn't kept, and the next solid is seen as
  chosen. At the end of the bar below, a button lists the keyboard shortcuts (`ShortcutsDialog`):
  a host's own groups (`shortcuts`) before the viewer's (`VIEWER_SHORTCUTS`: its keys, its
  pointer and wheel, named as the system names them); `bind:shortcutsOpen` opens it from a host's
  menu too.
* **`ParamsPanel`**: a control per parameter of the schema, each `group:` a section under its
  title that folds away (a header bar of its own, `--kc-section-bg` and `--kc-section-fg`, VS
  Code's side bar section headers in its webview), the parameters of no group first: a slider with a
  number for one between a `min` and a `max`, a number field, a select of the `in:` choices, a
  toggle, a text field; a tuple's places and a Map's fields side by side, each labelled on top
  (`partsOf`: a place's `title:`, else its index; a field's, else its name); and a list as its
  elements, each a control (a list of tuples or of Maps: a block of them) with a remove, and an
  add that copies the last (`newElement`, else `blankOf`), each as its `min_items` and
  `max_items` allow (`canRemove`, `canAdd`). A refusal names the place (`[1][:depth] must be at
  least 0.1`) and marks the control there, the panel's own check's (`validate`, which gives the
  path) and the run's (the frame's `error.path`). `step:` and `unit:` as given. A slider without a `step:` moves by 1
  (`stepOf`), and one over a range narrower than 1 by the power of ten that gives it ten
  positions at least; a value typed in its field is taken whatever its step. Each parameter is rows of its own, a line
  between one and the next: its `title:` (its name where it has none, and as the title's tooltip),
  its `description:` (the control's description for a screen reader too), then its control the
  panel's whole width. Each shows the value set in the panel, else
  the one the run took. A value outside the schema's range is refused in the panel, saying why,
  and never leaves it; one the run refused (the frame's `error.param`) is shown on its control.
  A value set is marked and can be reverted, which takes its refusal away too, as setting it
  back to its own value does (the one it showed before the panel set it: the run's, so a
  host's preset's too, else the script's default; all at once:
  Reset all, in a bar at the panel's top, held there as it scrolls, which says how many are
  set; the button keeps its room while none is, so nothing under the bar moves as the first is
  set or the last reverted, and a host's column leaves the bar its top); a refusal is the
  control's description for a screen reader too, after the parameter's (`aria-describedby`,
  `aria-invalid`). A choice
  with no value yet (the script computes its default, and no run took one) shows none.
  `overrides` (bindable) is what the panel sets; `onchange` gets it at each change, for the host
  to send to the core (`plainValues`, a state's values as plain data a message or a worker can
  carry).
* **`ConsolePanel`** (`console.js`): the console under a model, as OpenSCAD's: each run
  (`linesOfRun`: a line of how it went, then what it printed, its warnings and its error, a line
  that names a place clickable, `onreveal`) and a host's log (`linesOfLog`), the newest
  followed unless the person scrolled up, the oldest dropped past `MAX_LINES`
  (`appendLines`); cleared, folded to its bar, and as tall as the person drags it.
* **`PreviewPanel`**: a language server's preview, for a host that runs `kupcad lsp` (the VS
  Code extension, the desktop app): the model of the document the host says it shows, as the
  server's viewport socket sends it (`connectViewport`, which opens the socket again when it
  closes; `viewportUrl` changed, a server started again on another port, it follows it, what it
  shows and its console kept), the run's problems, and the parameters with the document's
  presets, which the toolbar's Parameters button hides for the model's width. It talks to the
  host as a `ViewerHost` (`@kupcad/protocol`'s `HostMessage` and `ViewerMessage`): the panel's
  values, a preset, an export (in the format its toolbar's `ExportMenu` chose, those the model's
  kind can be written in), a screenshot (base64) or a problem's place go to the host, which
  gives them to the server or acts on them. Its console (`console`, by default shown) keeps each
  run of the document shown, a frame sent again once, and the lines the host's `log` messages
  give. A host that keeps no presets passes
  `presets={false}`, and none are offered.
* **`ShortcutsDialog`** (`shortcuts.js`): the keys and the pointer's moves a person can't see on
  the screen, by group (`{ title, keys: [keys, what][], note? }`), in a modal dialog while
  `open` (bindable); Escape or its close button closes it, the focus back where it was.
  `ViewerPane` opens it from its bottom bar; `PreviewPanel` and the playground pass a host's
  `shortcuts` and `shortcutsOpen` through.
* **Layout** (`Splitter`, `settings.js`): the bar between two panes that resizes one of them,
  dragged or with the keys (the arrows, Shift for longer steps, Home and End), double-clicked
  back, a separator a screen reader knows (`role="separator"`, its value its size); it takes no
  room, the panes keep their borders. The sizes are kept in a host's `Settings` (`get`, `set`),
  which are reactive: a pane reads its size or state in a `$derived` and follows it as it is
  set, wherever from (another pane on the same settings, the host), with no copy of its own; a
  size dragged is the pane's own until the drag is done, and set then, once. Each host's are
  built on `memorySettings` (a `SvelteMap`), the page's life alone: `localSettings` writes each
  change to the page's localStorage too, as one JSON object, kept in memory where the page may
  not store. `sizeSetting` reads a kept size or the pane's own. `PreviewPanel` keeps its
  parameters' width and whether they show, whether the view's panel shows, and its console's
  height and state (`preview.*`) in the `settings` it is given, and follows other settings the
  host gives it.
* **Tokens**: the panels are styled by `--kc-*` variables, light and dark as the page's colour
  scheme is (`tokens.css`): the KupCAD brand, its orangered accent on white or the brand black,
  gainsboro for the surfaces. The accent is a fill, the brand black the text on it
  (`--kc-accent-fg`: white on the orange is too faint), and orange as text on the background is
  `--kc-accent-text`, a darker orange in light; `--kc-control-border` is a field's edge,
  `--kc-focus` its focus ring, `--kc-accent-subtle` what is chosen in a list. `tokens.test.js`
  holds every pair to WCAG's 4.5:1 for text and 3:1 for a control's edge, in both schemes, and
  every colour token to a mapping in `vscode.css`.
  Each colour is `light-dark()` of its two values, so the scheme decides: the system's
  (`color-scheme: light dark`), until the page chooses one with `data-theme="light"` or
  `"dark"` on its root (Starlight's convention, so a site's switch and the docs' agree) or a
  `color-scheme` of its own. The viewer's own colours and the editor's follow the same scheme.
  A host sets its own, as `vscode.css` maps VS Code's theme over them: the webview follows the
  editor's theme, never the brand.
  `--kc-viewer-*` theme the viewer (`themeFromTokens`, which reads each as the page draws it,
  opaque: any CSS colour, a `color-mix()` or an `oklch()` too, which three.js can't read); left
  unset, or set to no colour, it uses its own colours. The pane follows them as the page changes them
  (`watchTokens`: its root's or body's class or style, or the colour scheme), as VS Code does
  when its theme is switched.
* **Controls**: a button, select or field the panels draw is a `.kc-control` (`controls.css`,
  which `tokens.css` brings): a host's own take the class to look alike, the `actions` it puts
  in the pane's toolbar among them, which the pane's own styles, scoped to its markup, never
  reached. A toggle while on (`aria-pressed`, `aria-expanded`) is tinted and edged in the
  accent; `.kc-primary` makes one the bar's leading action, the accent's fill.
  A range input is a `.kc-range` and a checkbox a `.kc-check`, drawn the same in each browser
  and webview: a range's track is filled to its thumb by its `--kc-range-fill`, which a host
  sets from its value with `fillOf(value, min, max)` (WebKit and Blink fill none themselves).

## Tests

The viewer's scene logic in Node (jsdom), with a stand-in for WebGL and models the real core
makes through `@kupcad/wasm`; the components mounted under jsdom (the `testing` setup and its
`stubRenderer`), with the schemas and models the real core gives. And a smoke test in headless
Chromium (`pnpm test:browser`) that draws what the core makes in the page and reads the pixels
back: the part's colour, the background, a section cutting it all away, and a cap; and the view
cube, which turns the camera to the part clicked.
