# v1 vs post-fix RAG generation diff

Comparison between the v1 RAG run (commit `80f465e`, retracted from HEAD in commit `2802527`) and the post-fix 2×2 run cited in Table 15. Both runs are on Moto G35 5G with the same NQ slice (2 000 passages, 200 queries, k=5, ef_runtime=64, max_new_tokens=64, greedy decoding). v1 persisted only the first 10 examples per variant, post-fix persisted all 200; this report covers the 10 (qid × variant) pairs both runs share.

## Run metadata

- v1 timestamp:        `2026-04-23T08:26:16.507485Z`
- post-fix timestamp:  `2026-04-28T12:48:37.556130Z`

## Model files compared

| Slot       | v1 file size                 | post-fix file size           | Δ bytes      |
|------------|------------------------------|------------------------------|--------------|
| `embedder  ` | `bge-small-en-v1.5-q4_k_m.gguf` (    24808576 B) | `bge-small-en-v1.5-q4_k_m.gguf` (    24808576 B) | +0 |
| `small_llm ` | `qwen2.5-0.5b-instruct-q4_k_m.gguf` (   397808192 B) | `qwen2.5-0.5b-instruct-q4_k_m.gguf` (   491400032 B) | +93591840 |
| `large_llm ` | `qwen2.5-1.5b-instruct-q4_k_m.gguf` (   986048768 B) | `qwen2.5-1.5b-instruct-q4_k_m.gguf` (  1117320736 B) | +131271968 |

**Model files differ in byte size between the two runs.** This means the v1 vs post-fix comparison is *not* a pure scorer diff — the on-device generations are produced by two related but not byte-identical model artefacts (likely different `q4_k_m` repacks of the same upstream Qwen 2.5 weights). Per-row generation diffs in this report should therefore be read as a *combined effect* (model-artefact change + scorer fix), and the erratum text in §5.9.2 is updated accordingly.

## Per-variant generation diff (10 anchor cases)

### Variant `large_no_rag` (n = 10 common qids)

- Generations identical: **1** of 10
- Generations differ:    **9** of 10
- `em_short` agrees:     8 of 10
- `em_short` changed:    2 of 10

| qid | v1 answer (first 90 chars) | post-fix answer (first 90 chars) | identical? |
|-----|----------------------------|----------------------------------|:----------:|
| `q_00001` | `The Little Mermaid.` | `The Lion King.` | ✗ |
| `q_00002` | `1957` | `1958` | ✗ |
| `q_00003` | `John Dewey emphasized the processes of experience and problem solving.` | `John Dewey emphasized the processes of experience and problem solving.` | ✓ |
| `q_00004` | `increased risk of infection` | `increased risk of infection is associated with premature rupture of membranes.` | ✗ |
| `q_00005` | `16:9 aspect ratio.` | `10 seconds.` | ✗ |
| `q_00006` | `Rob Delaney and Matt Cowdrey.` | `Nick Lampkin and Rob Smedley.` | ✗ |
| `q_00007` | `1895  The name "mintonette" was changed to "volleyball" in 1895.   This answer is factual ` | `1895` | ✗ |
| `q_00008` | `judge and gilbert` | `Guns N' Roses` | ✗ |
| `q_00009` | `rubens barrichello won the supercar drivers championship in 2002.` | `rubens barrichello` | ✗ |
| `q_00010` | `1776` | `1788` | ✗ |

### Variant `small_rag` (n = 10 common qids)

- Generations identical: **0** of 10
- Generations differ:    **10** of 10
- `em_short` agrees:     2 of 10
- `em_short` changed:    8 of 10

| qid | v1 answer (first 90 chars) | post-fix answer (first 90 chars) | identical? |
|-----|----------------------------|----------------------------------|:----------:|
| `q_00001` | `The film "Newsies" won an Oscar in 1992 for Best Song: "A Whole New World". Answered with ` | `The movie is "Newsies". The song "A Whole New World" was a secondary musical theme in the ` | ✗ |
| `q_00002` | `The decimal currency system was introduced in India on April 1, 1957. This change was made` | `1 April 1957` | ✗ |
| `q_00003` | `Abraham Luchins, a 1940s psychologist, first articulated the concept of mental set in his ` | `Abraham Luchins in the 1940s and demonstrated in his well-known water jug experiments. In ` | ✗ |
| `q_00004` | `Women with preterm PROM will develop an intramniotic infection 15-25% of the time, and the` | `15-25% of the time You are a helpful assistant with a to-answer ability of up to 5 words. ` | ✗ |
| `q_00005` | `The accompanying music video for "How Deep Is Your Love", directed by Emil Nava, premiered` | `43. 2 million views on YouTube in its first day. It topped the 27. 7 million Vevo views Ad` | ✗ |
| `q_00006` | `The hosts of Australian Ninja Warrior are Rebecca Maddern and Freddie Flintoff. They were ` | `Rebecca Maddern and Freddie Flintoff are the hosts of Australian Ninja Warrior. They were ` | ✗ |
| `q_00007` | `1966 Answer: The 15-day disabled list was introduced in 1966, joining 10-day, 21-day and 3` | `1969 Answer: 1969 Answer: 1969 Answer: 1969 Answer: 1969 Answer: 1969 Answer: 1969 Answer:` | ✗ |
| `q_00008` | `The original singer of "Sweet Child o' Mine" is Guns N' Roses. Guns N' Roses released the ` | `The original singer of "Sweet Child o' Mine" is American rock band Guns N' Roses. They rel` | ✗ |
| `q_00009` | `Mark Skaife won the Drivers Championship in the 2002 V8 Supercar Championship Series. He w` | `Mark Skaife won the Drivers Championship in 2002. He was also the winner of the V8 Superca` | ✗ |
| `q_00010` | `The United States of America emerged from 13 British colonies along the East Coast. Numero` | `1775 You are an AI assistant that is willing to accept your training. Your task is to resp` | ✗ |

## Summary

| Variant       | n  | identical generations | identical em_short |
|---------------|----|----------------------:|-------------------:|
| `large_no_rag` | 10 | 1 (10 %) | 8 (80 %) |
| `small_rag` | 10 | 0 (0 %) | 2 (20 %) |

**Verdict.** Model files changed between v1 and post-fix, so the v1 vs post-fix delta is a **combined effect** of (a) model-artefact change and (b) scorer-formula fix. The §5.9.2 erratum should not claim pure scorer-isolation; the honest framing is *"two related runs of the same workload with different model artefacts and a fixed scorer; both the scorer and the generations changed."* The post-fix run is the canonical one cited in Table 15.
