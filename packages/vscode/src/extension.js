import * as vscode from 'vscode';
import * as path from 'path';

export function activate(context) {
	context.subscriptions.push(
		vscode.commands.registerCommand('myExtension.showUI', () => {
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
              <script type="module" src="http://localhost:5173/@react-refresh"></script>
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
}
