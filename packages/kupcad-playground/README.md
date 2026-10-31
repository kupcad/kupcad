# @kupcad/playground

KupCAD in a page: a script's editor beside its model and its parameters, all run in the browser
by the core compiled to WebAssembly, in a worker. One Svelte component, which the site and the
browser IDE embed; it keeps nothing of the page's.

```svelte
<script>
  import { Playground } from '@kupcad/playground';
  import '@kupcad/ui/tokens.css';
</script>

<Playground source={'cube(10)\n'} name="bracket" />
```

* **Props:** `source` (the script it starts with), `name` (what the downloads are named after),
  `kupcad` (a core to run it with; by default one it starts with `createKupcadWorker` and ends
  with itself), `wasm` (that worker's module, when not the one `@kupcad/wasm` ships),
  `viewerOptions`, `settings`, `shortcuts` (a page's own, listed before the viewer's in the
  pane's shortcuts dialog) and `shortcutsOpen` (bindable).
* **For a host that shares or saves the script** (the site's Share, the browser IDE): `onsource`
  is called with the script at each of the person's edits (not with the `source` it was given),
  and an `actions` snippet puts the host's own buttons in the model's toolbar, after Export
  (`.kc-control` gives them its look). It keeps no draft: a page loaded again shows `source`.
* **For a host that gives it other scripts** (examples to choose from): `load(script)` (the
  component's, by `bind:this`) puts one in the editor in place of the person's, which the
  editor's undo takes back, and runs it at once on its own values, its model framed whole (an
  edit's keeps the camera); the core, the console and the layout stay as they are.
* **For a host of several scripts** (the browser IDE's project): `open(script, restore)` opens one
  as another document, the editor made again on it with an undo history of its own (none of the last
  one's), run as `load` runs one; `open(text, restore, 'json')` opens a JSON file of the project (a
  package's `kupcad.json` or `kupcad.lock`, data a script imports) the same way, edited with nothing
  run, no model, status or parameters shown. `snapshot()` is the editor as it is, its undo history
  with it, for `open` to give back when the host opens that file again; `run()` runs the script
  again as it is (what it imports changed), and `focus()` puts the focus in the editor (a script the
  host just made). `files` is what the script's imports read, by the paths the script names them by
  (`import { } from "./lib.kup"` reads `lib.kup`), given with each run and export as the core's
  calls take them. `download` (exported) saves bytes or a Blob as a file, as the exports are saved.
* **When it runs** (`runner.js`, `Runner`): once the script stays as it is for a moment after an
  edit (`DELAY_MS`, 300), at once when a parameter's value changes or it starts (with a script: one
  that starts empty runs nothing, and says nothing of a run, until something is typed). A run under
  way when the next starts is stopped (the worker drops or ends its call), so what is shown is the
  last script's. A run is `check` first, whose findings the editor marks at once, then the preview:
  the model, how the run went, its parameters.
* **What the editor marks** (`marks.js`): `check`'s findings, and the places the run named (why
  it failed, a warning on a line); not the run's error where `check` found errors already (a
  script that doesn't parse fails the run for the same reason). Findings of a script changed
  since aren't marked, nor a run's places in one.
* **The pane** (`@kupcad/ui`'s `ViewerPane`): the model, the view's controls and the parts, how
  the run went and its problems, one clicked taking the editor to its line. Its toolbar exports
  the model in any format its kind can be written in (`@kupcad/ui`'s `ExportMenu`, built with
  the panel's values) and saves a screenshot, as downloads named after `name`; a build that fails
  says why. The parameters (`ParamsPanel`) are beside it.
* **The layout**: the bars between the script, the model, the parameters and the console
  resize them (`@kupcad/ui`'s `Splitter`), and the toolbar's Parameters button hides the
  parameters for the model's width; the sizes, and what is hidden or folded, are kept in
  `settings`, by default the page's localStorage (`localSettings`, the `playground.*` keys), and
  how the view looks too (the pane's `view.*` keys), all followed as they are set. A page 800px
  wide or less stacks the panes, each at a height of its own (the script a few lines, the model
  4:3 of its width, at most 32em, the console and the parameters as tall as their lines), and
  the playground scrolls; on a phone the view's panel is under the model (`ViewerPane`'s).
* **The console** (`@kupcad/ui`'s `ConsolePanel`, under the model): each run, what it printed
  (`puts`, `print`, `inspect`), its warnings and its error, a line naming a place taking the
  editor there, and the core's log (the worker module's stdout and stderr).

## Running it

From the repository's root:

```sh
pnpm install
pnpm dev:playground
```

It builds the core to WebAssembly (`pnpm build:core:wasm`), copies the module into
`@kupcad/wasm`, and serves the playground's page (`dev/`: the component on
`examples/standoff.kup`, the whole window, light or dark as the system is) at
<http://127.0.0.1:4321/>, a change to it or to a package it uses shown as you save it. A change to
the core needs `pnpm dev:playground` again (or the two build steps, then a reload).

In this package:

```sh
pnpm dev            # the page, served as you change it
pnpm check          # svelte-check: the component's, the page's and the tests' types
pnpm test           # Vitest under jsdom
pnpm test:browser   # the smoke test: the page built, in headless Chromium
```

## Tests

The runner's timing against a stand-in for the core, the marks, the downloads, and the component
on the real core (`@kupcad/wasm`'s `testCore`) under jsdom: the model shown, the findings and the
run's error marked, a problem clicked revealing its line, an edit and a value running again, a
script loaded in place of the one shown, an export downloaded and one refused. In a browser, with the real worker, the smoke test
(`smoke/playground.spec.js`): the page built (`vite build`, the worker an ES module as a site's
build makes it) and served, the example run to Ready, its parts and parameters shown, `param`
highlighted as a function, and a script that raises saying so.
