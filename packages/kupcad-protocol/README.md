# @kupcad/protocol

What the KupCAD core sends its front ends, as the core sends it: the preview frame (a model as
GLB or SVG, with its parts, warnings, parameters and why a run failed), the parameter schema of
`kupcad doc`, the findings of `kupcad check`, and the language server's notification and
commands; and the messages between a host and its viewer. Types, and the few pure functions every
host needs to read them. No dependencies.

```js
import { readFrame, isCompatible, SET_PARAMS_COMMAND } from '@kupcad/protocol';
/** @import { Preview, UiSchema, Finding } from '@kupcad/protocol/types' */

// A frame from the language server's viewport socket, or from @kupcad/wasm's preview
socket.binaryType = 'arraybuffer';
socket.onmessage = ({ data }) => {
  const { header, model } = readFrame(data);
  viewer.setModel(model); // { kind: '3d', glb, parts } | { kind: '2d', svg } | { kind: 'none' }
  params.show(header.params.schema, header.params.values);
  if (header.error) log.error(header.error); // message, line, column, the parameter refused
};

// The panel's values go back to the document the frame names
client.sendRequest('workspace/executeCommand', {
  command: SET_PARAMS_COMMAND,
  arguments: [{ uri: header.document, values: { width: 40 } }],
});
```

## What it holds

* `src/types.d.ts` (`@kupcad/protocol/types`): `FrameHeader`, `Part`, `Warning`, `Failure`,
  `Model`, `Preview`, `UiSchema`, `ParamSpec`, `ParamValues`, `ExportFormat`, `Finding`, `CheckFinding`,
  `VersionInfo`, `ViewportReady`, `SetParamsArgument`, `PreviewArgument`. Field for field what
  the core writes; a field it may leave out is `null`, never missing, but for the ones a frame
  of an older core lacks, which are optional (a frame's `output`, what the run printed, and
  `outputCut`).
* `readFrame(bytes)`: a frame (`ArrayBuffer` or `Uint8Array`) as a `Preview`, its GLB a view on
  the bytes, not a copy. A frame cut short, a header that isn't a JSON object, or a frame of a
  protocol version or kind this package doesn't know throws a `ProtocolError`.
* `PROTOCOL_VERSION` and `isCompatible(version)`: the version this package reads, the one a frame,
  `kupcad/viewportReady` and `kupcad version --json` carry. It goes up when a shape changes; a
  field added as optional (a frame's `document`) leaves it.
* `VIEWPORT_READY_NOTIFICATION`, `SET_PARAMS_COMMAND` and `PREVIEW_COMMAND`: the language
  server's names.
* `HostMessage` and `ViewerMessage`: what a host (the VS Code extension, the desktop app) and its
  viewer say to each other: the document shown, its panel's values, its presets' names and the
  host's log (`log`, for the viewer's console) one way; `ready`, `setParams`, a preset to apply or to save, a screenshot, a problem and a place
  in the script to reveal (`reveal`: a warning's line and column) the other. `isHostMessage` and `isViewerMessage` read
  one as it arrives untyped (`postMessage`), and `isParamValues` the values in it. A
  `ViewerHost` is the host as its viewer talks to it (`post`, `listen`).
* Presets (`Presets`): a script's named sets of values, kept beside it as JSON a person edits
  (`bracket.kup`'s in `bracket.presets.json`, `{ "presets": { "Small": { "width": 20 } } }`).
  `presetsPathOf(scriptPath)`, `readPresets(text)` (a `PresetsError` saying why a file isn't
  one) and `writePresets(presets)`; each host reads and writes the file with its own file
  system.
* `EXPORT_FORMATS`: the formats the core writes a model in (`kupcad build`, `@kupcad/wasm`'s
  `build`), each with its name and what it is for, in the order a host offers them.
* What every host of the viewer does alike (`host.js`): `ScriptValues`, the values each
  script's parameters were given (what the server runs it with, what an export builds it
  with); `viewportUrl(port)`, the viewport socket's URL from the port `kupcad/viewportReady`
  names (null for one that is no port); and `anotherDocument(message, shown)`, the document a page's
  message names when it isn't the one shown, which a host refuses.
* `whyBuildFailed(stderr)`: what a failed `kupcad build` said of why (the run's error, a syntax
  error at its place, the CLI's refusal, its summary; not its log nor the script's own output),
  for a host that runs it to tell the person; null when it said nothing that does.
* `errorText(error)`: what an error says, for a person: an Error's message, anything else
  thrown as text. Every host's messages and logs say it the same way.
* `characterAt(text, column)`: where a column the core names (1-based, in UTF-8 bytes: a
  warning's, a finding's) is in a line's text, as JavaScript and an editor count (UTF-16 code
  units from 0).

## Kept in step with the core

The tests read real headers the core's preview worker sent (`src/fixtures/`, written by
`pnpm fixtures` from a core build), and read the protocol version and the names out of the core's
sources, so a change there fails here until this package follows it.
