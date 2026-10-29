# @kupcad/desktop

KupCAD's desktop app ([Tauri 2](https://v2.tauri.app)): a folder of scripts, the script open in
an editor with the language's every feature, and its model and parameters beside it. It runs the
`kupcad` it bundles, the same language server the VS Code extension runs (`kupcad lsp`), so the
scripts, their imports, packages and exports are the real file system's and the real CLI's.

## Running it

From the repository's root, with Rust installed (`.tool-versions`):

```sh
pnpm install
pnpm dev:desktop
```

It builds the core (`pnpm build:core:native`), copies `kupcad` to where the app bundles it
(`pnpm --filter @kupcad/desktop sidecar`: `src-tauri/binaries/kupcad-<target triple>`), and starts
the app on `examples/` (`tauri dev`, the page served by Vite as it changes, the Rust side rebuilt
when it does). A change to the core needs `pnpm dev:desktop` again.

`kupcad-desktop <folder>` opens that folder; with none, the app asks for one.

In this package:

```sh
pnpm dev                 # the page alone, under Vite (tauri dev runs it)
pnpm tauri dev           # the app (after `pnpm sidecar`)
pnpm tauri build         # the app bundled for this system, in src-tauri/target/release/bundle/
pnpm check               # svelte-check: the page's and the tests' types
pnpm test                # Vitest under jsdom
pnpm test:integration    # the page's server on the real kupcad (core/zig-out/bin/kupcad)
cd src-tauri && cargo test && cargo clippy --all-targets -- -D warnings
```

## Releases

A version tag builds the app on each system and architecture the CLI ships for, around that
platform's release `kupcad` (`.github/workflows/release.yml`, the `desktop` job), and the
release carries the installers beside the CLI's archives, in its `checksums.txt` too:
`kupcad-desktop_<version>_<os>_<arch>` as a `.dmg` (macOS), a `.deb` and an `.rpm` (Linux, and
an `.AppImage` for x86_64) or a `_setup.exe` (Windows). They aren't signed yet, so macOS and
Windows warn before they open one; signing needs the certificates as the repository's secrets.

## Icons

`src-tauri/icons` is made from `icon.svg` by `tauri icon` ([Tauri's guide](https://v2.tauri.app/develop/icons/)).
KupCAD's icon takes its colours from CSS variables (`--kc-icon-bg`, `--kc-icon-fg`, which the
docs site sets per theme), and `tauri icon` draws an SVG without them (all black), so `icon.svg`
is the icon with its own colours written in. macOS's `icon.icns` is made from `icon-macos.svg`
instead: `icon.svg` as a rounded tile with a transparent margin, on Apple's icon grid, so it sits
in the Dock as the other apps do. The app has no mobile build, so only the desktop files are
kept, not the `android` and `ios` folders `tauri icon` makes beside them:

```sh
cd packages/kupcad-desktop
out=$(mktemp -d) mac=$(mktemp -d)
pnpm tauri icon icon.svg -o "$out"
pnpm tauri icon icon-macos.svg -o "$mac"
cp "$out"/*.png "$out"/icon.ico "$mac"/icon.icns src-tauri/icons/
```

`tauri icon` writes the `.icns` file's images in no fixed order, so a run changes `icon.icns`
even when the icon hasn't: leave it out of the copy unless the icon changed. The PNGs must stay
RGBA: an image optimiser that turns them into palette PNGs breaks the build
(`generate_context!` panics: `icon ... is not RGBA`).

## How it is put together

* **The window** (`src/App.svelte`): the folder's tree (`FileTree.svelte`, `folder.js`: its
  scripts and the files they read, in its folders however deep, hidden folders such as `.git`
  and `.kupcad` left out), the script open in `@kupcad/editor` with the language server's
  features, and `@kupcad/ui`'s `PreviewPanel` (the model, the run's problems, the parameters).
  A folder in the tree opens and closes when clicked, or with the arrow keys (up and down,
  right into a folder, left out of it), and a script opened opens the folders it is in; which
  are closed isn't kept, so a folder opens with all of them open. Its bars resize the tree, the
  editor, the model, the parameters and the console, and the Parameters button hides the
  parameters. It takes its services as a prop (`platform.js`, Tauri's), so its tests give it
  stand-ins.
* **The files** (`FileTree.svelte`, `folder.js`, `menu.js`): a script or a folder is made in the
  tree (its bar's buttons, the File menu, ⌘N and ⇧⌘N: in the open script's folder, or a row's
  menu: in that row's), renamed (a row's menu, F2) and moved to the system's trash (a row's
  menu, Delete or ⌘⌫, once the person says so, the unsaved changes it takes said), each name
  given in a field in the tree (Enter, Escape), one that is there already or that a system
  doesn't take refused under it. A script made is opened; a script renamed, or a folder with
  one in it, stays open by its new path, its unsaved changes and undo history with it. The tree
  follows the folder: watched (the file system plugin's `watch`, its changes gathered for
  300 ms), it is listed again when something in it is made, removed or renamed, and not for a
  file only read or written in place, nor for anything in a folder the tree leaves out.
* **The scripts read** (`scripts.svelte.js`): each one's text, as it is now and as the disk had
  it last, for what is unsaved (marked in the tree and the bar; ⌘S saves it, or a moment after
  each change where the settings say). A file written in the folder, or the window coming back
  to the front, has them read again: one with nothing unsaved takes the disk's text; one with
  unsaved changes keeps them, a bar above the editor saying the disk changed (Load from disk,
  Keep mine); one removed from the disk is closed, or kept, unsaved, where it has changes (a
  save puts it back). A save finding the disk changed since asks before it writes over it, and
  an autosave never does. Each script keeps its editor's undo history while another is shown
  (the editor's `snapshot()`). The window asks before it closes, or opens another folder, on
  unsaved changes.
* **The strip, the menus and the settings** (`src/App.svelte`, `menu.js`, `SettingsPane.svelte`,
  `prefs.js`, `theme.js`): a strip at the window's left edge, as VS Code's activity bar, shows
  or hides the files, and its gear (⌘, or Ctrl+,) opens the settings: a page over the bar and
  the panes, which stay as they were under it (the editor with its edits and its undo, the
  model, the console), inert until it closes (Escape, its close button, the gear or the files
  again), the focus given back where it was. The app's menu bar (macOS's app menu first; File,
  Edit, View, Window, Help) is set from the page as the window changes (Save enabled once there
  is something to save, Open Recent's folders, Show or Hide Files); a tree's row has its own
  menu. Help's Keyboard Shortcuts, as the button at the end of the preview's bottom bar, lists
  the app's, the tree's, the editor's and the viewer's keys. The settings apply as they are
  set, from the page or not, and are kept in the app's settings file (`settings.json` in its
  config folder, macOS's `~/Library/Application Support/dev.kupcad.desktop/`, through Tauri's
  store plugin), read before the window is laid out, each change written to it, and followed
  as they are set (`@kupcad/ui`'s reactive `memorySettings` under them): the panes' sizes and
  which are hidden; the theme (`app.theme`: the system's, the default, or light or dark), which
  sets the window's appearance (Tauri's `setTheme`, app-wide on macOS) and so the page's
  `prefers-color-scheme`, which the tokens, the editor and the viewer follow; the zoom (View's
  Zoom In and Out, ⌘= and ⌘-, Actual Size: the webview's `setZoom`); the editor's font size; the
  view a model is shown in (`view.*`, which the preview's toolbar sets too); whether a script is
  saved a moment after each change (off by default); whether the console shows under the model;
  and the folders opened last (Open Recent, and the welcome's list), the last opened again at
  the start unless the settings say not to. The window's own size and place are kept by the
  window-state plugin. The icons are inline SVG: the page fetches nothing, an icon set's
  neither.
* **The language server** (`src/server.js`, `src-tauri/src/server.rs`): the native side starts
  `kupcad lsp --stdio --viewport-origin <the page's origin>` for the page and holds it, at most
  one: a page that loads again replaces the one it left, and the app stops it when it exits. Its
  stdio comes to the page over a Tauri channel and is framed for the editor's client
  (`@kupcad/editor`'s `streamTransport`); a server that ends, or doesn't start again, is started
  again a little later each time, the editors' scripts opened on it again. Its viewport socket
  admits the page by its origin, `tauri://localhost` (`http://tauri.localhost` on Windows), and
  no other page; Vite's (under `tauri dev`) in a debug build alone, as a released app would
  admit any other project's dev server on that port.
* **The preview's host** (`src/host.js`): what the panel asks, done in the page. The panel's
  values go to the server (`kupcad.setParams`) and are kept for the script; an export, in the format
  the panel's menu chose, asks where to save it (a dialog of that format alone: macOS's save
  panel offers no choice among file types, so one of them all named the file `.stl` whatever
  the model) and runs `kupcad build` with them; a screenshot
  is saved where the person says; a problem's place is shown in the editor. The server's log
  goes to the panel's console, under the model, with each run (what it printed, its warnings
  and its error). Presets aren't offered yet.
* **The native side** (`src-tauri/src/lib.rs`): the plugins (dialogs, the file system, the
  settings' store; the folders opened kept in the file system's scope across launches,
  persisted-scope, so the last one opens again; the window's size and place, window-state) and
  the app's commands: `start_server`, `write_server`, `stop_server`, `launch_folder` (the folder
  named on the command line, put in the file system's scope as a picked one is),
  `move_to_trash` (a file or folder in the scope, by its own real path: a symlink goes, not what
  it leads to; on macOS by NSFileManager, which asks the person nothing, not by the Finder) and
  `export_model`, which builds with the bundled `kupcad` only a script in the folder opened into
  a file the person saved, in a format `kupcad` writes, its parameters' names checked.

## What the page may do

The page runs no program itself: it has no shell permission, and the bundled `kupcad` runs
through the app's commands above, with the arguments they make. It reads and writes only what
the person chose (`capabilities/default.json`: the dialogs, and the file system within the
folder opened, which it watches, makes files and folders in and renames them in, and the files
saved), moves to the trash only what is in that folder, sets the window's theme, zoom and
menus, and its Content Security Policy (`tauri.conf.json`) lets it connect to the app's IPC and
the server's viewport socket on 127.0.0.1 alone. The folders the person opened stay in the
file system's scope across launches (persisted-scope), as the last one opens again.

## Tests

The folder's tree (folders in folders, what a closed folder hides, the folders a script is in,
which of the watcher's changes list it again or are a file written, the names a new entry may
take) and its files' URIs; the tree's rows (a folder opened and closed by a click or the arrow
keys, a row's menu by a right click or the keys, F2, Delete and ⌘⌫, a name given in a field in
it, left with Escape, refused with what is wrong); the scripts read (unsaved, saved, a save
that finds the disk changed, the disk's change taken or held for the person, a script removed,
a save's own write not taken for another's, renamed and dropped with what they hold); the menus
(the bar's items, what they do and when they are enabled; a row's); the zoom, font size and
recent folders as the settings keep them; the preview's host (what the panel is told, an
export with its values and its formats, a screenshot, a refused message); the language
server's lifecycle on a stand-in server (its handshake through the framing, the viewport's URL,
the commands, restarts, a server that ends before it is up or doesn't start again); the
settings page (every setting shown as kept, set as chosen, followed as it is set elsewhere);
and the window on stand-ins: a folder opened, a script opened, an edit saved with ⌘S, the
question on closing, the tree's folders closed and opened, none of it kept, the folder listed
again as it changes and no longer once another is opened; a script the disk changed followed,
or held with the person's changes for them to choose, a save asking before it writes over the
disk's, a script removed closed or saved back; each script's undo history kept; scripts and
folders made, renamed (the open one following) and moved to the trash once asked; the last
folder opened at the start or not, the recent ones listed and kept; the menu bar following the
window, the shortcuts from Help, the zoom kept; the editor's font size; autosave, never over the
disk's; the files hidden and shown, the settings over the workspace, which is inert under them
and the same once they close, over the welcome too, opened with ⌘, and closed with Escape, the
gear or the files, the focus given back; a theme chosen, kept and set again at the start, one
the settings don't know, one the window refuses; the console hidden and kept so; the theme and
the console followed as the settings are set elsewhere, and the files' width dragged kept once
the drag is done. `test:integration`
runs the page's server on the real `kupcad lsp`: the handshake, a script's diagnostics, and its
model from the viewport socket. The Rust side tests its commands' arguments, that an export's paths are checked and passed by
their real paths (no `..`, no symlink, which the file system's scope matched as written), and
that a release build doesn't admit Vite's origin.
