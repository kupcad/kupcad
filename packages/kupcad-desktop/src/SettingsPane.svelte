<!--
  @component
  The app's settings, a page over the window's workspace: the window's theme (the system's, the
  default, or light or dark) and whether the console shows under the model, each a row of its
  name and its control. Each applies as it is chosen; the close button gives the window back.
-->
<script>
  import { THEMES } from './theme.js';

  /** @import { Theme } from './theme.js' */

  /**
   * @typedef {object} Props
   * @property {Theme} theme
   * @property {boolean} console whether the console shows under the model
   * @property {(theme: Theme) => void} ontheme
   * @property {(shows: boolean) => void} onconsole
   * @property {() => void} onclose
   */

  /** @type {Props} */
  let { theme, console: showsConsole, ontheme, onconsole, onclose } = $props();

  const id = $props.id();
</script>

<div class="page">
  <header>
    <h2 id="{id}-title">Settings</h2>
    <button
      type="button"
      class="close"
      aria-label="Close settings"
      title="Close (Esc)"
      onclick={onclose}
    >
      <svg viewBox="0 0 24 24" aria-hidden="true"><path d="M6 6l12 12M18 6L6 18" /></svg>
    </button>
  </header>
  <div class="row">
    <span class="name" id="{id}-theme">Theme</span>
    <div>
      <div
        class="segments"
        role="radiogroup"
        aria-labelledby="{id}-theme"
        aria-describedby="{id}-theme-hint"
      >
        {#each THEMES as [name, label] (name)}
          <label>
            <input
              type="radio"
              name="{id}-theme"
              value={name}
              checked={theme === name}
              onchange={() => ontheme(name)}
            />
            <span>{label}</span>
          </label>
        {/each}
      </div>
      <p class="hint" id="{id}-theme-hint">System follows your computer's appearance.</p>
    </div>
  </div>
  <div class="row">
    <span class="name">Console</span>
    <label class="check">
      <input
        type="checkbox"
        class="kc-check"
        checked={showsConsole}
        onchange={(event) => onconsole(event.currentTarget.checked)}
      />
      Show the console under the model
    </label>
  </div>
</div>

<style>
  /* One column, as wide as a line reads well, in the middle of the window */
  .page {
    max-width: 640px;
    margin: 0 auto;
    padding: 24px 32px;
  }
  header {
    display: flex;
    align-items: center;
    justify-content: space-between;
    padding-bottom: 12px;
    border-bottom: 1px solid var(--kc-border);
  }
  h2 {
    margin: 0;
    font-size: 20px;
    font-weight: 600;
  }
  .close {
    display: grid;
    place-items: center;
    width: 32px;
    height: 32px;
    padding: 0;
    color: var(--kc-muted);
    background: none;
    border: none;
    border-radius: var(--kc-radius);
    cursor: pointer;
  }
  .close:hover {
    color: var(--kc-fg);
    background: var(--kc-hover);
  }
  .close:focus-visible {
    outline: 2px solid var(--kc-focus);
    outline-offset: -2px;
  }
  .close svg {
    width: 18px;
    height: 18px;
    fill: none;
    stroke: currentColor;
    stroke-width: 1.75;
    stroke-linecap: round;
  }
  /* A setting: its name on the left, its control and what it does on the right */
  .row {
    display: grid;
    grid-template-columns: 140px 1fr;
    gap: 16px;
    align-items: baseline;
    padding: 16px 0;
    border-bottom: 1px solid var(--kc-border);
  }
  .name {
    font-weight: 600;
  }
  /* The themes side by side, one control: the radios hidden, their labels the segments */
  .segments {
    display: inline-flex;
    border: 1px solid var(--kc-control-border);
    border-radius: var(--kc-radius);
    overflow: hidden;
  }
  .segments label {
    position: relative;
  }
  .segments label + label {
    border-left: 1px solid var(--kc-control-border);
  }
  .segments input {
    position: absolute;
    width: 1px;
    height: 1px;
    margin: 0;
    opacity: 0;
    pointer-events: none;
  }
  .segments span {
    display: block;
    min-width: 64px;
    padding: 4px 16px;
    text-align: center;
    cursor: pointer;
  }
  .segments label:hover span {
    background: var(--kc-hover);
  }
  /* The theme chosen: tinted and edged, as a toggle that is on */
  .segments input:checked + span {
    background: var(--kc-accent-subtle);
    box-shadow: inset 0 0 0 1px var(--kc-accent);
  }
  .segments input:focus-visible + span {
    outline: 2px solid var(--kc-focus);
    outline-offset: -2px;
  }
  .hint {
    margin: 6px 0 0;
    color: var(--kc-muted);
  }
  .check {
    display: flex;
    align-items: center;
    gap: 6px;
    cursor: pointer;
  }
</style>
