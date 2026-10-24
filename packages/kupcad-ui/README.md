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

* **`ViewerPane`**: @kupcad/viewer with a toolbar (render mode, view, orthographic, floor, a
  section through the model along an axis, fit, screenshot) and the model's parts, each with its
  colour and copies; a click on one selects its copies, as a click in the viewer does
  (`bind:selected`). `bind:viewer` gives the viewer itself. The toolbar shows how the viewer
  looks (a drawing switches it to the top view, orthographic), and a section stays where it was
  put through an edit of the script, while the model still reaches it.
* **`ParamsPanel`**: a control per parameter of the schema, grouped by `group:`: a slider with a
  number for one between a `min` and a `max`, a number field, a select of the `in:` choices, a
  toggle, a text field; `step:` and `unit:` as given. Each shows the value set in the panel, else
  the one the run took. A value outside the schema's range is refused in the panel, saying why,
  and never leaves it; one the run refused (the frame's `error.param`) is shown on its control.
  A value set is marked and can be reverted, which takes its refusal away too; a refusal is the
  control's description for a screen reader (`aria-describedby`, `aria-invalid`). A choice
  with no value yet (the script computes its default, and no run took one) shows none.
  `overrides` (bindable) is what the panel sets; `onchange` gets it at each change, for the host
  to send to the core.
* **Tokens**: the panels are styled by `--kc-*` variables, light and dark as the page's colour
  scheme is (`tokens.css`); a host sets its own, as `vscode.css` maps VS Code's theme over them.
  `--kc-viewer-*` theme the viewer (`themeFromTokens`, which reads a hex colour's alpha away);
  left unset, it uses its own colours. The pane follows them as the page changes them
  (`watchTokens`: its root's or body's class or style, or the colour scheme), as VS Code does
  when its theme is switched.

Tests mount the panels under jsdom (@kupcad/viewer's `testing` setup and its `stubRenderer`),
with the schemas and models the real core gives through @kupcad/wasm.
