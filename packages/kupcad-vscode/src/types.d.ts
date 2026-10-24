// The shapes the extension's parts agree on, beside the protocol's.

import type { ParamValues } from '@kupcad/protocol/types';

/** What the viewer needs of the language server: the client's (LanguageServer), or a test's. */
export interface ServerLink {
  /** The viewport socket's port, once the server announced one this extension can read. */
  readonly viewportPort: number | null;
  /** Calls `listener` with the port each time the server announces its socket (a restart too). */
  onViewport(listener: (port: number) => void): { dispose(): void };
  /** The viewport shows the document at `uri`, whose frame is sent though it was before. */
  preview(uri: string): Promise<void>;
  /** The document at `uri` runs with `values` from now on. */
  setParams(uri: string, values: ParamValues): Promise<void>;
}

/** What the viewer's webview API gives the page (`acquireVsCodeApi()`), as far as it uses it. */
export interface WebviewApi {
  postMessage(message: unknown): void;
}

declare global {
  /** The webview's API, which the page gets once. */
  function acquireVsCodeApi(): WebviewApi;
}
