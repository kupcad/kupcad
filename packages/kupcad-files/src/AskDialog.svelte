<!--
  @component
  A question a page asks the person, in a modal dialog: what it asks, why, and a button for each
  answer, the `primary` one focused (Enter gives it). Escape answers `cancel`. Answered, it
  closes, the focus going back to what had it, and says the answer (`onanswer`), for the host to
  drop it. For a host with no dialog of its own: the desktop app asks with the system's.
-->
<script>
  import { onMount } from 'svelte';

  /**
   * An answer: what its button says, the value it gives, and whether it is the one focused.
   * @typedef {{ text: string, value: string, primary?: boolean }} Answer
   */

  /**
   * @typedef {object} Props
   * @property {string} title what it asks
   * @property {string} [text] more of it
   * @property {readonly Answer[]} answers in the order their buttons go
   * @property {string} cancel what Escape answers
   * @property {(value: string) => void} onanswer
   */

  /** @type {Props} */
  let { title, text = '', answers, cancel, onanswer } = $props();

  const id = $props.id();
  /** @type {HTMLDialogElement} */
  let dialog;
  /** What had the focus when it opened, given it back once answered. */
  let before = /** @type {Element | null} */ (null);
  let answered = false;

  onMount(() => {
    before = document.activeElement;
    dialog.showModal();
    /** @type {HTMLButtonElement | null} */ (dialog.querySelector('.kc-primary'))?.focus();
  });

  /** @param {string} value */
  function answer(value) {
    if (answered) return;
    answered = true;
    dialog.close();
    if (before instanceof HTMLElement && before.isConnected) before.focus();
    onanswer(value);
  }

  /** @param {KeyboardEvent} event */
  function keydown(event) {
    // A browser's modal dialog closes on Escape by itself; a webview's may not
    if (event.key !== 'Escape') return;
    event.preventDefault();
    answer(cancel);
  }
</script>

<dialog
  bind:this={dialog}
  class="kc-ask"
  aria-labelledby="{id}-title"
  aria-describedby={text ? `${id}-text` : undefined}
  onkeydown={keydown}
  oncancel={(event) => {
    event.preventDefault();
    answer(cancel);
  }}
>
  <h2 id="{id}-title">{title}</h2>
  {#if text}<p id="{id}-text">{text}</p>{/if}
  <div class="answers">
    {#each answers as choice (choice.value)}
      <button
        type="button"
        class="kc-control"
        class:kc-primary={choice.primary}
        onclick={() => answer(choice.value)}
      >
        {choice.text}
      </button>
    {/each}
  </div>
</dialog>

<style>
  .kc-ask {
    width: min(26em, calc(100vw - 32px));
    margin: auto;
    padding: 16px;
    font-family: var(--kc-font);
    font-size: var(--kc-font-size);
    color: var(--kc-fg);
    background: var(--kc-bg);
    border: 1px solid var(--kc-border);
    border-radius: var(--kc-radius);
    box-shadow: 0 12px 32px rgb(0 0 0 / 0.25);
  }
  .kc-ask::backdrop {
    background: rgb(0 0 0 / 0.3);
  }
  h2 {
    margin: 0;
    font-size: 1.05em;
    font-weight: 600;
    overflow-wrap: anywhere;
  }
  p {
    margin: 8px 0 0;
    color: var(--kc-muted);
    overflow-wrap: anywhere;
  }
  .answers {
    display: flex;
    flex-wrap: wrap;
    justify-content: flex-end;
    gap: var(--kc-gap);
    margin-top: 16px;
  }
</style>
