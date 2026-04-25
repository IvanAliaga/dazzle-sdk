// Copyright 2026 Ivan Aliaga <ivan.aliaga@urp.edu.pe>
// SPDX-License-Identifier: Apache-2.0

import { DazzleServer, VectorIndex } from 'dazzle-react-native';
import faqs from '../assets/dazzle_faq.json';
import { miniEmbed } from './miniEmbed';

export interface FaqEntry {
  id: string;
  category: string;
  question: string;
  answer: string;
}

export const KbCorpus = {
  indexName:    'kb',
  hashPrefix:   'samples:kb:',
  embeddingDim: 384,
  _loaded: false,
  _byKey:   new Map<string, FaqEntry>(),
  _index:   null as VectorIndex | null,

  async loadIntoDazzle(): Promise<void> {
    if (this._loaded) return;
    this._index = await VectorIndex.create({
      name:        this.indexName,
      hashPrefix:  this.hashPrefix,
      vectorField: 'emb',
      dim:         this.embeddingDim,
      algorithm:   'hnswSq8',
      metric:      'cosine',
      initialCapacity: (faqs as FaqEntry[]).length,
    });

    const rows = faqs as FaqEntry[];
    const ids: string[] = [];
    const vectors: number[][] = [];
    for (const f of rows) {
      ids.push(`${this.hashPrefix}${f.id}`);
      vectors.push(miniEmbed(`${f.question} ${f.answer}`, this.embeddingDim));
    }
    await this._index.addBatchDirect(ids, vectors);

    this._byKey = new Map(rows.map((f) => [`${this.hashPrefix}${f.id}`, f]));
    this._loaded = true;
  },

  entry(key: string): FaqEntry | undefined {
    return this._byKey.get(key);
  },

  index(): VectorIndex | null {
    return this._index;
  },
};
