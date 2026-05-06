// Polyfill TextEncoder / TextDecoder for jest's jsdom environment.
// jsdom 26 doesn't expose them on `globalThis` even though Node.js
// provides them in `util`.  This keeps tests platform-neutral.

import { TextDecoder, TextEncoder } from 'util';

(globalThis as { TextEncoder?: typeof TextEncoder }).TextEncoder ??= TextEncoder;
(globalThis as { TextDecoder?: typeof TextDecoder }).TextDecoder ??= TextDecoder as unknown as typeof globalThis.TextDecoder;
