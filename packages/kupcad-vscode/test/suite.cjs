// What test/run.js has VS Code run in its extension host: the extension, built, on the real
// kupcad lsp. CommonJS, which the host loads; a failed check fails the run.

const assert = require('node:assert/strict');
const path = require('node:path');
const vscode = require('vscode');

const WORKSPACE = /** @type {string} */ (process.env.KUPCAD_WORKSPACE);
/** How long the server may take to answer: it starts with the first document. */
const ANSWER_MS = 30_000;
const POLL_MS = 100;

/**
 * What `check` gives once it gives something (not undefined, null, false or an empty array),
 * asked again until then; a failure saying `what` after ANSWER_MS.
 * @template T
 * @param {() => T | PromiseLike<T>} check
 * @param {string} what
 * @returns {Promise<T>}
 */
async function eventually(check, what) {
  const until = Date.now() + ANSWER_MS;
  for (;;) {
    const value = await check();
    if (value && !(Array.isArray(value) && value.length === 0)) return value;
    if (Date.now() > until) throw new Error(`timed out waiting for ${what}`);
    await new Promise((resolve) => setTimeout(resolve, POLL_MS));
  }
}

/** @param {string} name a file of the workspace */
async function open(name) {
  const document = await vscode.workspace.openTextDocument(path.join(WORKSPACE, name));
  await vscode.window.showTextDocument(document);
  return document;
}

/** @type {[string, () => Promise<void>][]} */
const TESTS = [
  [
    'a .kup file is KupCAD, and opening one starts the extension',
    async () => {
      const document = await open('cube.kup');
      assert.equal(document.languageId, 'kupcad');
      const extension = vscode.extensions.all.find((e) => e.packageJSON.publisher === 'kupcad');
      assert.ok(extension, 'the extension is installed');
      await eventually(() => extension.isActive, 'the extension to start');
    },
  ],
  [
    "a script's errors are the server's diagnostics, where they are",
    async () => {
      const { uri } = await open('broken.kup');
      const [diagnostic] = await eventually(
        () => vscode.languages.getDiagnostics(uri),
        "broken.kup's diagnostics",
      );
      assert.equal(diagnostic.severity, vscode.DiagnosticSeverity.Error);
      assert.match(diagnostic.message, /r_paren/);
      assert.equal(diagnostic.range.start.line, 1);
    },
  ],
  [
    'formatting a document is the server’s, as `kupcad fmt` formats it',
    async () => {
      const document = await open('unformatted.kup');
      /** @type {vscode.TextEdit[]} */
      const edits = await eventually(
        () =>
          vscode.commands.executeCommand('vscode.executeFormatDocumentProvider', document.uri, {
            tabSize: 2,
            insertSpaces: true,
          }),
        'the edits formatting makes',
      );
      const edit = new vscode.WorkspaceEdit();
      edit.set(document.uri, edits);
      assert.ok(await vscode.workspace.applyEdit(edit));
      assert.equal(document.getText(), 'cube(10)\nx = 1 + 2\n');
    },
  ],
  [
    'a built-in says what it is on hover',
    async () => {
      const document = await open('cube.kup');
      /** @type {vscode.Hover[]} */
      const hovers = await eventually(
        () =>
          vscode.commands.executeCommand(
            'vscode.executeHoverProvider',
            document.uri,
            new vscode.Position(0, 1),
          ),
        "cube's hover",
      );
      const text = hovers
        .flatMap((hover) => hover.contents)
        .map((part) => (typeof part === 'string' ? part : part.value))
        .join('\n');
      assert.match(text, /cube/);
    },
  ],
  [
    'Open Viewer opens the viewer beside the script',
    async () => {
      await open('cube.kup');
      await vscode.commands.executeCommand('kupcad.openViewer');
      await eventually(
        () =>
          vscode.window.tabGroups.all
            .flatMap((group) => group.tabs)
            .some(
              (tab) =>
                tab.input instanceof vscode.TabInputWebview &&
                tab.input.viewType.endsWith('kupcad.viewer'),
            ),
        'the viewer to open',
      );
    },
  ],
];

exports.run = async function run() {
  const failed = [];
  for (const [name, test] of TESTS) {
    try {
      await test();
      console.log(`✓ ${name}`);
    } catch (error) {
      failed.push(name);
      console.error(`✗ ${name}\n`, error);
    }
  }
  if (failed.length > 0) throw new Error(`${failed.length} of ${TESTS.length} failed`);
  console.log(`${TESTS.length} passed`);
};
