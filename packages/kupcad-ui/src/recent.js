// What a pane keeps of each thing it showed, for the next time it shows it: the most recently
// shown kept, as many as it keeps, the least recently shown let go past them. Only for as long
// as the pane is there: nothing is written anywhere.

/** @template T */
export class Recent {
  /** @type {Map<string, T>} */
  #kept = new Map();
  #most;

  /** @param {number} most how many it keeps */
  constructor(most) {
    this.#most = most;
  }

  /**
   * Keeps `value` for `key`, the most recent; the least recent goes past the most kept.
   * @param {string} key
   * @param {T} value
   */
  keep(key, value) {
    this.#kept.delete(key);
    this.#kept.set(key, value);
    for (const oldest of this.#kept.keys()) {
      if (this.#kept.size <= this.#most) break;
      this.#kept.delete(oldest);
    }
  }

  /**
   * What is kept for `key`, the most recent now; none for a key not kept, or let go.
   * @param {string} key
   * @returns {T | undefined}
   */
  get(key) {
    const value = this.#kept.get(key);
    if (value !== undefined) this.keep(key, value);
    return value;
  }

  get size() {
    return this.#kept.size;
  }
}
