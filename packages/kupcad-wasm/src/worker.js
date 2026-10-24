// The worker's entry (createKupcadWorker starts it): the core serves the page on the worker's
// own port.

import { serve } from './serve.js';

/** @import { PortLike } from './types.js' */

serve(/** @type {PortLike} */ (/** @type {unknown} */ (globalThis)));
