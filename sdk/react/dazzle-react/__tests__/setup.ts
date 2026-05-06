import { TextDecoder, TextEncoder } from 'util';

(globalThis as { TextEncoder?: typeof TextEncoder }).TextEncoder ??= TextEncoder;
(globalThis as { TextDecoder?: typeof TextDecoder }).TextDecoder ??= TextDecoder as unknown as typeof globalThis.TextDecoder;
