#!/usr/bin/env node
// The `kupcad` command npm installs: the native kupcad for this system, run as it is
// (lib/launch.js).

import { launch } from '../lib/launch.js';

process.exitCode = launch(process.argv.slice(2));
