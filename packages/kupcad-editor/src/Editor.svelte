<!--
  @component
  The editor for Svelte: CodeMirror on a KupCAD script, filling its box. `value` is bindable (the
  user's changes set it, a host's reach the editor), and so is `editor`, the Editor itself, for
  what isn't state: `reveal(line, column)`, `focus()`. `findings` are marked as given; with a
  `languageServer` (set when it mounts) the server's are, and no findings are given.
-->
<script>
  import { onMount } from 'svelte';
  import { Editor } from './editor.js';

  /** @import { Mark } from './findings.js' */

  /**
   * @typedef {object} Props
   * @property {string} [value] the script; bindable
   * @property {readonly Mark[]} [findings] what to mark in it: `check`'s, a run's error
   * @property {Editor | null} [editor] the Editor, once mounted; bindable
   * @property {string} [label] what the script is, for a screen reader
   * @property {(value: string) => void} [onchange] the user changed the script
   * @property {import('./editor.js').EditorOptions['languageServer']} [languageServer] the
   *   server the script is known to, by its URI
   */

  /** @type {Props} */
  let {
    value = $bindable(''),
    findings = [],
    editor = $bindable(null),
    label = 'The script',
    onchange,
    languageServer,
  } = $props();

  /** @type {HTMLDivElement} */
  let root;

  onMount(() => {
    const made = new Editor(root, {
      value,
      label,
      languageServer,
      onchange: (next) => {
        value = next;
        onchange?.(next);
      },
    });
    editor = made;
    return () => {
      made.dispose();
      editor = null;
    };
  });

  $effect(() => {
    editor?.setValue(value);
  });
  $effect(() => {
    editor?.setFindings(findings);
  });
</script>

<div class="kc-editor" bind:this={root}></div>

<style>
  .kc-editor {
    height: 100%;
    min-height: 0;
  }
</style>
