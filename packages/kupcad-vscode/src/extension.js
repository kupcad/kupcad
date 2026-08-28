import * as vscode from 'vscode';
import * as path from 'path';
import { LanguageClient, TransportKind } from 'vscode-languageclient/node';

let client;

export const activate = (context) => {
	context.subscriptions.push(
		vscode.commands.registerCommand('kupcad.showUI', () => {
			const panel = vscode.window.createWebviewPanel(
				'webviewPanel', 'My Webview', vscode.ViewColumn.One,
				{ enableScripts: true }
			);

			const isDev = context.extensionMode === vscode.ExtensionMode.Development;

			if (isDev) {
				// Point straight to Vite dev server with Hot Module Replacement
				panel.webview.html = `
          <!DOCTYPE html>
          <html>
            <body>
              <div id="root"></div>
              <script type="module" src="http://localhost:5173/src/main.tsx"></script>
            </body>
          </html>`;
			} else {
				// Fallback to compiled production assets when deployed
				const diskPath = vscode.Uri.file(path.join(context.extensionPath, 'dist-webview', 'index.html'));
				// Load file structure via panel.webview.asWebviewUri(diskPath)
			}
		})
	);

	// Resolve the path to your compiled Zig executable
	// `context.extensionPath` is `packages/vscode/`
	// We navigate up two directories to reach `core/zig-out/bin/kupcad`
	const serverPath = path.resolve(context.extensionPath, '../../core/zig-out/bin/kupcad');

	// Define how to start the language server
	const serverOptions = {
		run: { command: serverPath, args: ['lsp'], transport: TransportKind.stdio },
		debug: { command: serverPath, args: ['lsp'], transport: TransportKind.stdio }
	};

	// Define client options (Listen to .kup files)
	const clientOptions = {
		documentSelector: [{ scheme: 'file', language: 'kupcad' }],
		synchronize: {
			fileEvents: vscode.workspace.createFileSystemWatcher('**/*.kup')
		}
	};

	// Create and start the Language Client
	client = new LanguageClient(
		'kupcadLanguageServer',
		'KupCAD Language Server',
		serverOptions,
		clientOptions
	);

	// Start the client (this also spawns the Zig server)
	client.start().then(() => {
		console.log("KupCAD LSP Client successfully started!");
	}).catch((error) => {
		// This will pop up a visible error notification in VS Code
		vscode.window.showErrorMessage(`Failed to start KupCAD LSP: ${error.message}`);
		console.error("LSP Startup Error:", error);
	});
}

export const deactivate = () => {
	if (!client) {
		return undefined;
	}
	return client.stop();
}
