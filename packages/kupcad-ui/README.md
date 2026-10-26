# @kupcad/ui

The Svelte panels a KupCAD host shows beside its editor: the viewer with its toolbar and part
list, and the parameter panel. They take @kupcad/protocol's shapes and give back values; they
hold no engine and fetch nothing, so a host wires them to its own: the playground to
@kupcad/wasm's worker, the VS Code extension's webview to the language server.

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

* **`ViewerPane`**: @kupcad/viewer with its view cube in the corner, and a panel beside it that
  the toolbar's Panel button hides: the view's controls in its top half (Solid, Wire, X-ray;
  Edges, Axes, Grid and Plate toggles; Fit, Persp, and the Iso, Top, Front and Right views, the
  one looked from pressed, a turn by hand pressing none), the model's parts in its bottom half,
  each with its colour and copies (a click on one selects its copies, as a click in the viewer
  does: `bind:selected`). A bar above: a section through the model along an axis, screenshot, and
  an `actions` snippet (a host's own buttons, the VS Code extension's Export). Below, a status
  line from `status` (`runStatusOf(header)` makes it of a frame's header: Running…, then Ready or
  Failed, with the run's time and its warnings) over the run's problems from `problems`
  (`problemsOf(header)`: why it failed, then its warnings), a few lines high; one with a line,
  clicked, goes to `onproblem`, for the host to show the script there.
  By the pointer a tooltip says what is under it: the part, its copies, volume and size (the
  frame's), and the face, flat with its area and the way it faces, or curved (`measures.js`).
  `bind:viewer` gives the viewer itself. The controls show how the viewer looks (a drawing
  switches it to the top view, orthographic; a turn of the wheel with Option moves the section,
  and its slider), and a section stays where it was put through an edit of the script, while the
  model still reaches it.
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
  A value set is marked and can be reverted, which takes its refusal away too; a refusal is the
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
  shows and its console kept), the run's problems, and the parameters with the document's presets. It talks to the
  host as a `ViewerHost` (`@kupcad/protocol`'s `HostMessage` and `ViewerMessage`): the panel's
  values, a preset, an export (in the format its toolbar's `ExportMenu` chose, those the model's
  kind can be written in), a screenshot (base64) or a problem's place go to the host, which
  gives them to the server or acts on them. Its console (`console`, by default shown) keeps each
  run of the document shown, a frame sent again once, and the lines the host's `log` messages
  give. A host that keeps no presets passes
  `presets={false}`, and none are offered.
* **Layout** (`Splitter`, `settings.js`): the bar between two panes that resizes one of them,
  dragged or with the keys (the arrows, Shift for longer steps, Home and End), double-clicked
  back, a separator a screen reader knows (`role="separator"`, its value its size); it takes no
  room, the panes keep their borders. The sizes are kept in a host's `Settings` (`get`, `set`):
  `localSettings`, the page's localStorage as one JSON object, kept in memory where the page may
  not store; `memorySettings`, the page's life alone; `sizeSetting` reads a kept size or the
  pane's own. `PreviewPanel` keeps its parameters' width and its console's height and state
  (`preview.*`) in the `settings` it is given.
* **Tokens**: the panels are styled by `--kc-*` variables, light and dark as the page's colour
  scheme is (`tokens.css`); a host sets its own, as `vscode.css` maps VS Code's theme over them.
  `--kc-viewer-*` theme the viewer (`themeFromTokens`, which reads each as the page draws it,
  opaque: any CSS colour, a `color-mix()` or an `oklch()` too, which three.js can't read); left
  unset, or set to no colour, it uses its own colours. The pane follows them as the page changes them
  (`watchTokens`: its root's or body's class or style, or the colour scheme), as VS Code does
  when its theme is switched.
* **Controls**: a button, select or field the panels draw is a `.kc-control` (`controls.css`,
  which `tokens.css` brings): a host's own take the class to look alike, the `actions` it puts
  in the pane's toolbar among them, which the pane's own styles, scoped to its markup, never
  reached.

Tests mount the panels under jsdom (@kupcad/viewer's `testing` setup and its `stubRenderer`),
with the schemas and models the real core gives through @kupcad/wasm.
