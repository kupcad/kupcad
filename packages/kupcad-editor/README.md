# @kupcad/editor

CodeMirror 6 for a KupCAD (`.kup`) script, for the web hosts (the playground, the desktop app,
later the PWA; VS Code has its own editor): the language's highlighting, its blocks indented,
its words completed, and the core's findings marked where they are, or a language server's
features. A class any host can own,
and a Svelte component around it.

```js
import { Editor } from '@kupcad/editor';

const editor = new Editor(element, {
  value: source,
  onchange: (value) => run(value), // the user's changes; a host's own (setValue) aren't told
  label: 'bracket.kup', // what the script is, for a screen reader
});
editor.setFindings(await kupcad.check(editor.value)); // underlined, in the gutter, a fix one click away
editor.setFindings([{ severity: 'error', message, line, column }]); // a place a run named: a point
editor.reveal(line, column); // the cursor there, in view, the focus in the editor
editor.setValue(other);
editor.dispose();
```

```svelte
<script>
  import { Editor } from '@kupcad/editor/svelte';
  let source = $state('cube(10)\n');
</script>

<Editor bind:value={source} {findings} bind:editor />
```

* **The language** (`language.js`): the literals are Ruby's (strings with interpolation, the
  single-quoted ones, `%w` and `%q`, heredocs, symbols, comments), so CodeMirror's Ruby mode
  reads them and indents the blocks; the words are the core's. `src/vocabulary.json` is the
  lexer's keywords, every global function (`cube`, `param`, `raise`) and every method (a
  Solid's, a value's, a class's), which `zig build grammar` writes from the core beside the VS
  Code grammar, and a core test fails while it is behind. So `raise` is a function and `import`
  a keyword, as KupCAD has them, not as Ruby does; `in` is a keyword after `for` alone. The same
  words are completed: a word with the keywords and functions, a name after a dot with the
  methods. `kupcad()` gives the language to a host's own CodeMirror.
* **Findings** (`findings.js`): the core places them by 1-based lines and columns in UTF-8 bytes
  (`@kupcad/protocol`'s `characterAt` reads them); `check`'s have an end, and a fix becomes an
  action in its tooltip, made only on the text it was found in. A place a run named (its error, a
  warning) is a point. Marked in place of the last ones given, they move with the edits made
  until the next ones come.
* **A language server** (`language-server.js`, `@codemirror/lsp-client`): for a host that runs
  `kupcad lsp` (the desktop app), over any stream of bytes, its child process's stdin and
  stdout. `streamTransport(stream, onError)` frames each message as LSP frames them on stdio
  (`Content-Length`, then the JSON) and reads the server's frames back however its chunks are
  cut (`MessageReader`); `languageServerClient({ rootUri, notifications })` is the client with
  every feature the package has, a server's own notifications (`kupcad/viewportReady`) handled
  by the host. An editor given `languageServer: { client, uri }` opens its script on the server
  (`kupcad`, its language) and takes the server's diagnostics, completion (in place of the
  vocabulary's: the server knows the script's own names), hovers, signatures, formatting,
  renaming and definitions; its host gives it no findings then.

  ```js
  const client = languageServerClient({ rootUri: 'file:///work' });
  client.connect(streamTransport({ write, read }, (error) => log(error.message)));
  new Editor(element, { value, languageServer: { client, uri: 'file:///work/part.kup' } });
  ```
* **The look** (`theme.js`): the `--kc-*` tokens of `@kupcad/ui` (the page's own colours where
  they are unset), and the code's colours by `--kc-code-keyword`, `-string`, `-comment`,
  `-constant`, `-function` and `-definition` (GitHub's, light or dark, where unset);
  `--kc-code-font` and `--kc-code-font-size`.

Tests: the highlighting, indentation and completion on the parsed text, the findings placed (the
real core's `check`, through `@kupcad/wasm`) and their fixes made, the editor and its Svelte
component under jsdom, the LSP frames cut at every byte, and an editor opening its script on a
stand-in server whose diagnostics it marks.
