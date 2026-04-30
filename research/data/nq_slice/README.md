# NQ-open retrieval mini-slice (E2 / E3)

Materialised from `sentence-transformers/natural-questions` (pair
split, for passages) + `google-research-datasets/nq_open` (for
canonical short answers, joined by question text).

- passage source:   `https://huggingface.co/datasets/sentence-transformers/natural-questions/resolve/main/pair/train-00000-of-00001.parquet`
- answer source:    `https://huggingface.co/datasets/google-research-datasets/nq_open/resolve/main/nq_open/train-00000-of-00001.parquet` +
                    `https://huggingface.co/datasets/google-research-datasets/nq_open/resolve/main/nq_open/validation-00000-of-00001.parquet`
- seed:             `42`
- queries:          `200`  (`200` with short_answers attached)
- passages:         `2000`
- gold/queries:     `1` (one positive passage per query)
- max_query_chars:   `256`
- max_passage_chars: `1800`
- sha256 (first 16):  `63be4b8894c71ff3`

Each query JSON row has `_id`, `text`, `gold` (list of passage ids),
and optionally `short_answers` (list of alias strings from nq_open).
Queries without a short_answers field have no canonical answer in
nq_open; EM / F1 scoring should skip them.

Regenerate:

```
python3 research/scripts/nq_slice.py
```
