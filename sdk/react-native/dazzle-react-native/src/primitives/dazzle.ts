// Copyright 2026 Ivan Aliaga <ivan.aliaga@urp.edu.pe>
// SPDX-License-Identifier: Apache-2.0
//
// Dazzle client facade — factory every primitive hangs off of.
// Mirrors `Dazzle` in Kotlin / Swift / Dart.

import { HashKey } from './hash';
import { ListKey } from './list';
import { SetKey } from './set';
import { SortedSetKey } from './sortedSet';
import { StreamKey } from './stream';
import { StringKey } from './string';

export class Dazzle {
  hash(key: string): HashKey { return new HashKey(key); }
  sortedSet(key: string): SortedSetKey { return new SortedSetKey(key); }
  set(key: string): SetKey { return new SetKey(key); }
  list(key: string): ListKey { return new ListKey(key); }
  stream(key: string): StreamKey { return new StreamKey(key); }
  string(key: string): StringKey { return new StringKey(key); }
}
