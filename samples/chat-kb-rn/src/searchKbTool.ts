// Copyright 2026 Ivan Aliaga <ivan.aliaga@urp.edu.pe>
// SPDX-License-Identifier: Apache-2.0

import {
  JsonSchema, Tool, ToolContext, jsonSchemaObject,
} from 'dazzle-react-native';
import { FaqEntry, KbCorpus } from './kbCorpus';
import { miniEmbed } from './miniEmbed';

export interface SearchQuery { query: string; k?: number; }
export interface FaqHit {
  id: string; category: string; question: string;
  answer: string; score: number;
}

export class SearchKbTool implements Tool<SearchQuery, FaqHit[]> {
  readonly name = 'search_kb';
  readonly description =
    'Look up the top-k most relevant Dazzle FAQ rows for a natural-' +
    'language query. Use this whenever the user asks about Dazzle ' +
    'the product, the SDK API, the four LLM adapters, the benchmarks, ' +
    'or the HNSW variants. Returns the FAQ question, full answer, and ' +
    'a similarity score (lower is closer).';

  readonly argsSchema: JsonSchema = jsonSchemaObject(
    { description: 'Semantic search over the on-device Dazzle FAQ.' },
    (b) => {
      b.property('query', { type: 'string', required: true,
        description: "The user's question, verbatim or paraphrased." });
      b.property('k', { type: 'integer',
        description: 'Number of FAQ rows to return (1..10).',
        minimum: 1, maximum: 10 });
    },
  );

  argsFromJson(raw: string): SearchQuery {
    const o = JSON.parse(raw);
    return { query: String(o.query ?? ''),
             k: o.k != null ? Number(o.k) : undefined };
  }

  returnToJson(value: FaqHit[]): string {
    return JSON.stringify(value);
  }

  async invoke(args: SearchQuery, _ctx: ToolContext): Promise<FaqHit[]> {
    const k = Math.min(10, Math.max(1, args.k ?? 5));
    const idx = KbCorpus.index();
    if (!idx) return [];
    const vec = miniEmbed(args.query, KbCorpus.embeddingDim);
    const hits = await idx.searchDirect(vec, k, 10);
    const out: FaqHit[] = [];
    for (const h of hits) {
      const e = KbCorpus.entry(h.id);
      if (e) {
        out.push({
          id: e.id, category: e.category,
          question: e.question, answer: e.answer,
          score: h.distance,
        });
      }
    }
    return out;
  }
}
