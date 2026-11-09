// What jsdom lacks for tests of these components, done as a browser does it: imported once
// before them (Vitest's `setupFiles`), here and by a host testing its own components with them
// (`@kupcad/files/jsdom`):
// - a popover (ContextMenu's), shown and hidden: jsdom's own styles hide every popover, so one
//   shown is displayed here; hidden, the focus is moved off it, and its `toggle` event said a
//   moment later. As in a browser, showing one shown or hiding one hidden does nothing: jsdom
//   (from 31) says `focusout` as the focus is moved off, and a menu that closes on it hides
//   itself again, which said a second `toggle`;
// - a modal dialog (AskDialog's), shown and closed, its closing said by a `close` event.

HTMLElement.prototype.showPopover ??= /** @this {HTMLElement} */ function showPopover() {
  if (this.dataset.shown === 'true') return;
  this.dataset.shown = 'true';
  this.style.display = 'block';
};
HTMLElement.prototype.hidePopover ??= /** @this {HTMLElement} */ function hidePopover() {
  if (this.dataset.shown !== 'true') return;
  delete this.dataset.shown;
  this.style.removeProperty('display');
  if (this.contains(document.activeElement)) {
    /** @type {HTMLElement} */ (document.activeElement).blur();
  }
  setTimeout(() => this.dispatchEvent(Object.assign(new Event('toggle'), { newState: 'closed' })));
};

HTMLDialogElement.prototype.showModal ??= /** @this {HTMLDialogElement} */ function showModal() {
  this.open = true;
};
HTMLDialogElement.prototype.close ??= /** @this {HTMLDialogElement} */ function close() {
  if (!this.open) return;
  this.open = false;
  this.dispatchEvent(new Event('close'));
};
