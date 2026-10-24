# @kupcad/protocol

What the KupCAD core sends its front ends, as the core sends it: the preview frame (a model as
GLB or SVG, with its parts, warnings, parameters and why a run failed), the parameter schema of
`kupcad doc`, the findings of `kupcad check`, and the language server's notification and command.
Types, and the few pure functions every host needs to read them. No dependencies.

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
  `VersionInfo`, `ViewportReady`, `SetParamsArgument`. Field for field what the core writes; a
  field it may leave out is `null`, never missing.
* `readFrame(bytes)`: a frame (`ArrayBuffer` or `Uint8Array`) as a `Preview`, its GLB a view on
  the bytes, not a copy. A frame cut short, a header that isn't a JSON object, or a frame of a
  protocol version or kind this package doesn't know throws a `ProtocolError`.
* `PROTOCOL_VERSION` and `isCompatible(version)`: the version this package reads, the one a frame,
  `kupcad/viewportReady` and `kupcad version --json` carry. It goes up when a shape changes; a
  field added as optional (a frame's `document`) leaves it.
* `VIEWPORT_READY_NOTIFICATION` and `SET_PARAMS_COMMAND`: the language server's names.

## Kept in step with the core

The tests read real headers the core's preview worker sent (`src/fixtures/`, written by
`pnpm fixtures` from a core build), and read the protocol version and the names out of the core's
sources, so a change there fails here until this package follows it.
