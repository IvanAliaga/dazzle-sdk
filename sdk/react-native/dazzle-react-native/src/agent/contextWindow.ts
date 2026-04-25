// Copyright 2026 Ivan Aliaga <ivan.aliaga@urp.edu.pe>
// SPDX-License-Identifier: Apache-2.0

export type ContextWindow =
  | { kind: 'lastN'; n: number }
  | { kind: 'all' }
  | { kind: 'vectorRecall'; keepRecent: number; k: number };

export type CompactionPolicy =
  | { kind: 'none' }
  | { kind: 'maxTurns'; maxTurns: number };

export const defaultCompaction: CompactionPolicy = {
  kind: 'maxTurns',
  maxTurns: 200,
};
