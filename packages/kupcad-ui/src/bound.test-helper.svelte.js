// A value a test binds a component's prop to (`bind:`), reactive as a parent's $state is: the
// component reads a bound prop through its parent's getter, so a plain one never tells it of a
// change it made itself.

/**
 * @template T
 * @param {T} initial
 * @returns {{ value: T }}
 */
export function bound(initial) {
  let value = $state(initial);
  return {
    get value() {
      return value;
    },
    set value(next) {
      value = next;
    },
  };
}
