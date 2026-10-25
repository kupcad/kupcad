# @kupcad/site

KupCAD's site, made with [Astro](https://astro.build): the playground's page now, the
documentation later. Its interactive parts are Svelte islands; `/playground` is
`@kupcad/playground` on one of the examples (`examples/standoff.kup`), the whole window.

## Running it

From the repository's root:

```sh
pnpm install
pnpm dev:playground
```

It builds the core to WebAssembly (`pnpm build:core:wasm`), copies the module into
`@kupcad/wasm`, and serves the site at <http://127.0.0.1:4321/playground>, a change to a page or
to a package it uses shown as you save it. A change to the core needs `pnpm dev:playground` again
(or the two build steps, then a reload).

In this package:

```sh
pnpm dev            # the site, served as you change it
pnpm build          # the static site, in dist/
pnpm preview        # dist/ served as it would be
pnpm check          # astro check: the pages' types
pnpm test:browser   # the smoke test: the built site in headless Chromium
```

## How it is put together

* `src/layouts/Page.astro`: a page, with `@kupcad/ui`'s tokens (light or dark as the visitor's
  system is) and the window filled.
* `src/pages/playground.astro`: the playground, `client:only="svelte"` (the core runs in a Web
  Worker, the viewer draws with WebGL: nothing of it renders on a server), on an example read as
  text from `examples/`.
* `astro.config.mjs`: Svelte, and the core's worker bundled as an ES module (it imports the rest
  of `@kupcad/wasm`), which Vite does in development alone otherwise. The core's module and
  three.js's decoders are assets of the build.
* `smoke/playground.spec.js`: the built site served (`astro preview`), the playground's example
  run to Ready by the real worker, its parts and parameters shown, `param` highlighted as a
  function, and a script that raises saying so.
