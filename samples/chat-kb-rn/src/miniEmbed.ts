// Copyright 2026 Ivan Aliaga <ivan.aliaga@urp.edu.pe>
// SPDX-License-Identifier: Apache-2.0
//
// FNV-1a hash-bucket "bag of tokens" embedder — 384-dim, L2-normalised.
// Matches samples/_shared/{android,ios,flutter}/miniEmbed byte-for-
// byte so chat-kb-rn retrieves the same FAQ rows as the other ports.

export function miniEmbed(text: string, dim = 384): number[] {
  const vec = new Array<number>(dim).fill(0);

  const tokens = text
    .toLowerCase()
    .split(/[^a-z0-9]+/)
    .filter((t) => t.length > 0);

  if (tokens.length === 0) {
    vec[0] = 1;
    return vec;
  }

  for (const tok of tokens) {
    // FNV-1a, 64-bit via BigInt so we don't lose bits on the JS number
    // ceiling. Slower than native but the corpus is small (30 rows).
    let hash = 0xcbf29ce484222325n;
    for (let i = 0; i < tok.length; i++) {
      hash ^= BigInt(tok.charCodeAt(i) & 0xFF);
      hash = (hash * 0x00000100000001B3n) & 0xFFFFFFFFFFFFFFFFn;
    }
    const bucket = Number(hash % BigInt(dim));
    const signBit = Number((hash >> 32n) & 1n);
    vec[bucket] += signBit === 0 ? 1 : -1;
  }

  // L2 normalise.
  let norm = 0;
  for (const x of vec) norm += x * x;
  if (norm > 0) {
    const inv = 1 / Math.sqrt(norm);
    for (let i = 0; i < dim; i++) vec[i] *= inv;
  }
  return vec;
}
