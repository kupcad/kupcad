<!--
  @component
  The formats a model can be exported in, as a menu: those its kind can be written in (a 2D model's
  drawings alone, protocol's `exportFormatsFor`), each with what it is for. Choosing one gives it
  to `onexport` and shows the menu's name again, so the same format can be chosen next time too.
  A host then asks where: the menu is the page's, since a save dialog's file types may offer no
  choice (macOS's lists them all as one).
-->
<script>
  import { exportFormatsFor } from '@kupcad/protocol';

  /** @import { ExportFormat, Kind } from '@kupcad/protocol/types' */

  /**
   * @typedef {object} Props
   * @property {Kind} kind the model's (none while there is no run to go by)
   * @property {(format: ExportFormat) => void} onexport
   */

  /** @type {Props} */
  let { kind, onexport } = $props();

  /** @param {Event & { currentTarget: HTMLSelectElement }} event */
  function chosen(event) {
    const format = /** @type {ExportFormat} */ (event.currentTarget.value);
    event.currentTarget.value = '';
    if (format) onexport(format);
  }
</script>

<select class="kc-control" aria-label="Export" onchange={chosen}>
  <option value="" selected disabled>Export…</option>
  {#each exportFormatsFor(kind) as choice (choice.format)}
    <option value={choice.format} title={choice.detail}>{choice.label}</option>
  {/each}
</select>
