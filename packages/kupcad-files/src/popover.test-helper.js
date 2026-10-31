// What jsdom lacks for the components' tests: a popover (ContextMenu's), shown and hidden as a
// browser's is. jsdom's own styles hide every popover, so one shown is displayed here; hidden,
// the focus is moved off it, and its `toggle` event said a moment later, as a browser does.

HTMLElement.prototype.showPopover ??= /** @this {HTMLElement} */ function showPopover() {
  this.dataset.shown = 'true';
  this.style.display = 'block';
};
HTMLElement.prototype.hidePopover ??= /** @this {HTMLElement} */ function hidePopover() {
  delete this.dataset.shown;
  this.style.removeProperty('display');
  if (this.contains(document.activeElement)) {
    /** @type {HTMLElement} */ (document.activeElement).blur();
  }
  setTimeout(() => this.dispatchEvent(Object.assign(new Event('toggle'), { newState: 'closed' })));
};
