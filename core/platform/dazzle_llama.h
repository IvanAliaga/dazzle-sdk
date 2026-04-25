/*
 * Copyright 2026 Ivan Aliaga <ivan.aliaga@urp.edu.pe>
 *
 * Licensed under the Apache License, Version 2.0 (the "License");
 * you may not use this file except in compliance with the License.
 * You may obtain a copy of the License at
 *
 *     http://www.apache.org/licenses/LICENSE-2.0
 *
 * Unless required by applicable law or agreed to in writing, software
 * distributed under the License is distributed on an "AS IS" BASIS,
 * WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
 * See the License for the specific language governing permissions and
 * limitations under the License.
 */

/*
 * dazzle_llama.h — plain-C surface over the embedded llama.cpp.
 *
 * Swift (`import DazzleC`) and Kotlin (via JNI helpers) call these
 * entry points; llama.cpp's real C++ API never crosses the language
 * boundary directly. Kept minimal on purpose — loading, tokenizing,
 * single-pass generation with a streaming callback, teardown. The
 * Swift / Kotlin wrappers turn that into `LLMClient`.
 *
 * The real llama.cpp API (llama.h) is much larger; we intentionally
 * narrow it to what the Dazzle ChatAgent actually needs so the
 * stable symbol list shrinks and local patches stay focused.
 *
 * Thread safety: each `dazzle_llama_ctx` is single-threaded — do not
 * share one across concurrent calls. Model handles (`dazzle_llama_model`)
 * can be shared across contexts, which is the intended way to reuse
 * weights.
 */

#ifndef DAZZLE_LLAMA_H
#define DAZZLE_LLAMA_H

#include <stddef.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

/* Opaque handles. Treat as `void*`; never dereference from the
 * language binding side. */
typedef struct dazzle_llama_model   dazzle_llama_model;
typedef struct dazzle_llama_ctx     dazzle_llama_ctx;

/* Per-token callback used by dazzle_llama_generate. `piece` is a
 * UTF-8 C string owned by the runtime — copy what you need, don't
 * free it. Return non-zero to request cancellation; the generator
 * will stop at the next token boundary. `user_data` is passed
 * through from the caller for state. */
typedef int (*dazzle_llama_on_token)(const char *piece, void *user_data);

/* Initialise the llama.cpp runtime (backends, logging). Safe to call
 * multiple times — the second call is a no-op. Must be called at
 * least once before loading any model. */
void dazzle_llama_backend_init(void);

/* Load a GGUF model file. Returns NULL on failure (bad path, bad
 * magic, OOM). The returned handle must be freed with
 * dazzle_llama_free_model once no contexts reference it.
 *
 * `n_gpu_layers` — set to 0 for CPU-only (recommended on mobile);
 * >0 offloads that many transformer layers to GPU backends (Metal
 * on iOS, Vulkan on Android). Ignored when llama.cpp was compiled
 * without the relevant backend. */
dazzle_llama_model *dazzle_llama_load_model(const char *path,
                                            int n_gpu_layers);

void dazzle_llama_free_model(dazzle_llama_model *model);

/* Create an inference context tied to `model`. `n_ctx` is the
 * maximum token window; 2048 is a reasonable default for 7B/13B
 * chat models, 4096+ for larger contexts. `n_threads` caps the
 * CPU worker count; pass -1 to let llama.cpp auto-size. */
dazzle_llama_ctx *dazzle_llama_new_context(dazzle_llama_model *model,
                                           int n_ctx,
                                           int n_threads);

void dazzle_llama_free_context(dazzle_llama_ctx *ctx);

/* Run one generation pass. Tokenises `prompt`, decodes up to
 * `max_tokens` new tokens, calls `on_token` for each decoded piece.
 *
 * `temperature` — sampling temperature; 0.0 = greedy decoding,
 * 0.8 is a common creative-writing value.
 * `top_p`       — nucleus sampling; pass 1.0 to disable.
 * `seed`        — PRNG seed; pass 0 (or UINT32_MAX) for "random".
 *
 * Returns the number of tokens actually emitted on success, or a
 * negative error code (see DAZZLE_LLAMA_E_* below). Stops early when
 * the callback returns non-zero or an end-of-sequence token is
 * sampled. */
int dazzle_llama_generate(dazzle_llama_ctx *ctx,
                          const char *prompt,
                          int max_tokens,
                          float temperature,
                          float top_p,
                          uint32_t seed,
                          dazzle_llama_on_token on_token,
                          void *user_data);

/* Error codes returned by dazzle_llama_generate. Keep in sync with
 * the Swift / Kotlin enums. */
#define DAZZLE_LLAMA_OK                0
#define DAZZLE_LLAMA_E_BAD_CTX        -1
#define DAZZLE_LLAMA_E_TOKENIZE       -2
#define DAZZLE_LLAMA_E_DECODE         -3
#define DAZZLE_LLAMA_E_CONTEXT_FULL   -4
#define DAZZLE_LLAMA_E_CANCELLED      -5

#ifdef __cplusplus
} /* extern "C" */
#endif

#endif /* DAZZLE_LLAMA_H */
