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
 * dazzle_llama.cpp — thin wrapper over llama.cpp's C++ sampler chain +
 * decode loop, exposing the plain-C surface declared in dazzle_llama.h.
 *
 * Design points:
 *
 * - We purposely do NOT expose llama.cpp tokens, batches or samplers
 *   across the language boundary. Swift/Kotlin only see UTF-8
 *   strings and a token-by-token callback — same shape every other
 *   LLMClient adapter in the SDK uses.
 *
 * - Sampling chain: min_p (0.05) → temp → top_p → dist. Matches the
 *   default chat sampler llama.cpp ships; gives reasonable output
 *   on Gemma / Llama 3 / Qwen 2.5 GGUF without per-model tuning.
 *
 * - Error handling: return negative codes (DAZZLE_LLAMA_E_*) instead
 *   of throwing, so a C caller / Swift bridge / Kotlin JNI stub can
 *   translate them without touching a try/catch boundary.
 *
 * - Pinned to llama.cpp b4120. Bumping the tag may shift the API
 *   (eg. llama_load_model_from_file → llama_model_load_from_file in
 *   later releases) — update this TU in lockstep.
 */

#include "dazzle_llama.h"

#include "llama.h"

#include <algorithm>
#include <chrono>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <memory>
#include <string>
#include <vector>

// ── Opaque handle structs ──────────────────────────────────────────────
//
// The public header declares these as incomplete types; we define them
// here so callers only ever see `void*` equivalents.

struct dazzle_llama_model {
    ::llama_model *m = nullptr;
};

struct dazzle_llama_ctx {
    ::llama_context *ctx       = nullptr;
    const ::llama_model *model = nullptr;   // b4120: tokenize / to_piece / is_eog take model*
    int n_ctx                  = 0;
    int n_past                 = 0;         // tokens currently in KV cache
    // Per-call metrics — populated by `dazzle_llama_generate` so the
    // language binding can produce the same JSON shape as the Android
    // bench (Tabla 18 prefill/decode split, Tabla 17 prompt_tokens).
    // Reset at the start of every generate() call. Read via the
    // `dazzle_llama_last_*` accessors below.
    int64_t last_prefill_us    = 0;
    int64_t last_decode_us     = 0;
    int     last_prompt_tokens = 0;
    int     last_new_tokens    = 0;
    // Embedding-mode flag: a context built with
    // `dazzle_llama_new_embed_context` has `embeddings = true` set in
    // its llama_context_params. `dazzle_llama_embed` rejects calls on
    // non-embedding contexts to keep the prefill/decode counters and
    // the embed pooling path from sharing state.
    bool    is_embed_ctx       = false;
};

// ── Backend init ───────────────────────────────────────────────────────

static bool g_backend_inited = false;

extern "C" void dazzle_llama_backend_init(void) {
    if (g_backend_inited) return;
    ::llama_backend_init();
    // Keep logs quiet by default — consumer apps set their own if they
    // want llama.cpp chatter in logcat / os_log.
    ::llama_log_set(nullptr, nullptr);
    g_backend_inited = true;
}

// ── Load / free model ──────────────────────────────────────────────────

extern "C" dazzle_llama_model *dazzle_llama_load_model(const char *path,
                                                      int n_gpu_layers) {
    if (!path) return nullptr;
    dazzle_llama_backend_init();

    ::llama_model_params mp = ::llama_model_default_params();
    mp.n_gpu_layers = n_gpu_layers;

    // Honour DAZZLE_LLAMA_USE_MMAP={0|false} as an opt-out from file-backed
    // mmap of the .gguf weights. On EMUI 9 / Kirin 659 the iAware daemon
    // demotes (and within seconds kills) any process that triggers a large
    // mmap-fault burst — even an instrumentation-runner process — so the
    // bench needs to fall back to a plain `read()` into anon RAM. Costs
    // peak RSS but stays under iAware's "thrash" detector. See
    // research/results/cross_platform_e2e/ane_lx3_kirin659_investigation.md
    if (const char *e = std::getenv("DAZZLE_LLAMA_USE_MMAP")) {
        if (e[0] == '0' || e[0] == 'f' || e[0] == 'F' || e[0] == 'n' || e[0] == 'N') {
            mp.use_mmap = false;
        }
    }

    ::llama_model *m = ::llama_load_model_from_file(path, mp);
    if (!m) return nullptr;

    auto *handle = new dazzle_llama_model();
    handle->m = m;
    return handle;
}

extern "C" void dazzle_llama_free_model(dazzle_llama_model *model) {
    if (!model) return;
    if (model->m) ::llama_free_model(model->m);
    delete model;
}

// ── New / free context ─────────────────────────────────────────────────

extern "C" dazzle_llama_ctx *dazzle_llama_new_context(dazzle_llama_model *model,
                                                      int n_ctx,
                                                      int n_threads) {
    if (!model || !model->m) return nullptr;

    ::llama_context_params cp = ::llama_context_default_params();
    cp.n_ctx        = (n_ctx > 0) ? (uint32_t)n_ctx : 2048;
    // n_batch == n_ctx so prompts up to context-size prefill in a single
    // llama_decode call. Avoids the split-prefill bug pass 15 of the
    // Kirin investigation pinned: on Cortex-A53 v8.0 the v8.0 ggml fp16
    // fallback hangs / aborts when the prompt is split across multiple
    // batches. Same fix the embedder needed (item 2 of the §5.9.5
    // engineering sidebar). Costs ~30 MB extra compute buffer for n_ctx
    // = 2048; negligible vs. the model weights themselves.
    cp.n_batch      = cp.n_ctx;
    cp.n_ubatch     = cp.n_ctx;
    cp.n_threads    = (n_threads > 0) ? n_threads : 4;
    cp.n_threads_batch = cp.n_threads;
    // Flash attention off — not universally supported on all backends
    // we ship, and saves a branch in the kernel-select path.
    cp.flash_attn   = false;

    ::llama_context *raw = ::llama_new_context_with_model(model->m, cp);
    if (!raw) return nullptr;

    auto *handle    = new dazzle_llama_ctx();
    handle->ctx     = raw;
    handle->model   = model->m;
    handle->n_ctx   = (int)cp.n_ctx;
    handle->n_past  = 0;
    return handle;
}

extern "C" void dazzle_llama_free_context(dazzle_llama_ctx *ctx) {
    if (!ctx) return;
    if (ctx->ctx) ::llama_free(ctx->ctx);
    delete ctx;
}

// ── Generate ───────────────────────────────────────────────────────────

/* Tokenise `text` with llama.cpp's tokenizer. Returns tokens vector;
 * empty on failure. `add_bos` follows the model's default. */
static std::vector<::llama_token> tokenise(const ::llama_model *model,
                                           const std::string &text,
                                           bool add_bos) {
    // First call sizes the buffer; second call fills it.
    int n = -::llama_tokenize(model, text.c_str(), (int)text.size(),
                              nullptr, 0, add_bos, /*parse_special*/ true);
    if (n < 0) return {};
    std::vector<::llama_token> out((size_t)n);
    int written = ::llama_tokenize(model, text.c_str(), (int)text.size(),
                                   out.data(), (int)out.size(),
                                   add_bos, /*parse_special*/ true);
    if (written < 0) return {};
    out.resize((size_t)written);
    return out;
}

/* Convert one token to its UTF-8 piece. Handles SPM / BPE alike. */
static std::string detokenise_one(const ::llama_model *model,
                                  ::llama_token tok) {
    char buf[64];
    int n = ::llama_token_to_piece(model, tok, buf, sizeof(buf),
                                   /*lstrip*/ 0, /*special*/ false);
    if (n < 0) {
        std::vector<char> big((size_t)-n);
        int nn = ::llama_token_to_piece(model, tok, big.data(),
                                        (int)big.size(), 0, false);
        if (nn <= 0) return {};
        return std::string(big.data(), (size_t)nn);
    }
    return std::string(buf, (size_t)n);
}

extern "C" int dazzle_llama_generate(dazzle_llama_ctx *ctx,
                                     const char *prompt,
                                     int max_tokens,
                                     float temperature,
                                     float top_p,
                                     uint32_t seed,
                                     dazzle_llama_on_token on_token,
                                     void *user_data) {
    if (!ctx || !ctx->ctx || !ctx->model || !prompt) {
        return DAZZLE_LLAMA_E_BAD_CTX;
    }

    // Fresh generation — wipe any previously-decoded KV cache. We keep
    // the context alive across calls so the caller can reuse the same
    // weights + sampler state shape; only the token history is reset.
    ::llama_kv_cache_clear(ctx->ctx);
    ctx->n_past = 0;
    ctx->last_prefill_us    = 0;
    ctx->last_decode_us     = 0;
    ctx->last_prompt_tokens = 0;
    ctx->last_new_tokens    = 0;
    auto t_us = []() -> int64_t {
        using clock = std::chrono::steady_clock;
        return std::chrono::duration_cast<std::chrono::microseconds>(
            clock::now().time_since_epoch()).count();
    };

    // 1. Tokenise
    auto tokens = tokenise(ctx->model, std::string(prompt), /*add_bos*/ true);
    if (tokens.empty()) return DAZZLE_LLAMA_E_TOKENIZE;
    if ((int)tokens.size() >= ctx->n_ctx) return DAZZLE_LLAMA_E_CONTEXT_FULL;
    ctx->last_prompt_tokens = (int)tokens.size();

    // 2. Prompt decode — batch the entire prompt in one shot.
    {
        const int64_t t0 = t_us();
        ::llama_batch batch = ::llama_batch_get_one(tokens.data(),
                                                   (int32_t)tokens.size());
        if (::llama_decode(ctx->ctx, batch) != 0) {
            return DAZZLE_LLAMA_E_DECODE;
        }
        ctx->n_past += (int)tokens.size();
        ctx->last_prefill_us = t_us() - t0;
    }
    const int64_t t_decode_start = t_us();

    // 3. Build sampler chain. We create it per-call so seed / temp /
    //    top_p can change between invocations without teardown.
    ::llama_sampler_chain_params sp = ::llama_sampler_chain_default_params();
    ::llama_sampler *smpl = ::llama_sampler_chain_init(sp);
    // Small floor — drops very-low-prob tokens that skew temperature.
    ::llama_sampler_chain_add(smpl, ::llama_sampler_init_min_p(0.05f, 1));
    if (top_p > 0.0f && top_p < 1.0f) {
        ::llama_sampler_chain_add(smpl, ::llama_sampler_init_top_p(top_p, 1));
    }
    if (temperature <= 0.0f) {
        ::llama_sampler_chain_add(smpl, ::llama_sampler_init_greedy());
    } else {
        ::llama_sampler_chain_add(smpl, ::llama_sampler_init_temp(temperature));
        ::llama_sampler_chain_add(smpl, ::llama_sampler_init_dist(seed));
    }

    int emitted = 0;
    int rc = DAZZLE_LLAMA_OK;

    for (int step = 0; step < max_tokens; step++) {
        // 4. Sample next token from the current logits.
        ::llama_token next = ::llama_sampler_sample(smpl, ctx->ctx, -1);
        ::llama_sampler_accept(smpl, next);

        if (::llama_token_is_eog(ctx->model, next)) break;

        std::string piece = detokenise_one(ctx->model, next);
        if (!piece.empty() && on_token) {
            int keep_going = on_token(piece.c_str(), user_data);
            if (keep_going != 0) {
                rc = DAZZLE_LLAMA_E_CANCELLED;
                break;
            }
        }
        emitted++;

        // 5. Feed the sampled token back for the next position.
        if (ctx->n_past + 1 >= ctx->n_ctx) { rc = DAZZLE_LLAMA_E_CONTEXT_FULL; break; }
        ::llama_batch batch = ::llama_batch_get_one(&next, 1);
        if (::llama_decode(ctx->ctx, batch) != 0) {
            rc = DAZZLE_LLAMA_E_DECODE;
            break;
        }
        ctx->n_past += 1;
    }

    ::llama_sampler_free(smpl);
    ctx->last_decode_us  = t_us() - t_decode_start;
    ctx->last_new_tokens = emitted;
    return (rc == DAZZLE_LLAMA_E_CANCELLED) ? DAZZLE_LLAMA_E_CANCELLED : emitted;
}

// ── Per-call metric accessors ──────────────────────────────────────────
//
// Mirror the Android JNI's GenHandle counters so the iOS bench can
// produce the same JSON shape (embed_us / search_us / prefill_us /
// decode_us / total_us / prompt_tokens / new_tokens) without bringing
// the chat-message wrapper overhead. All four read the snapshot left
// by the most-recent `dazzle_llama_generate` call on `ctx`; calling
// them on a context that has never generated returns 0.
extern "C" int64_t dazzle_llama_last_prefill_us(dazzle_llama_ctx *ctx) {
    return ctx ? ctx->last_prefill_us : 0;
}
extern "C" int64_t dazzle_llama_last_decode_us(dazzle_llama_ctx *ctx) {
    return ctx ? ctx->last_decode_us : 0;
}
extern "C" int dazzle_llama_last_prompt_tokens(dazzle_llama_ctx *ctx) {
    return ctx ? ctx->last_prompt_tokens : 0;
}
extern "C" int dazzle_llama_last_new_tokens(dazzle_llama_ctx *ctx) {
    return ctx ? ctx->last_new_tokens : 0;
}

// ── Embed context + embed call ─────────────────────────────────────────
//
// Mean-pooled mean-token embedding via `embeddings = true` on the
// llama context, mirroring `DazzleEmbedder.kt`. Two entry points:
// build a dedicated embedding context with `dazzle_llama_new_embed_context`
// (no shared state with a generate context — embeddings + KV-cache
// don't compose cleanly under the b4120 llama API), then `embed()` to
// produce one fp32 vector per call.
extern "C" dazzle_llama_ctx *dazzle_llama_new_embed_context(
        dazzle_llama_model *model, int n_ctx, int n_threads) {
    if (!model || !model->m) return nullptr;

    ::llama_context_params cp = ::llama_context_default_params();
    cp.n_ctx           = (n_ctx > 0) ? (uint32_t)n_ctx : 512;
    // n_batch == n_ctx so a single passage of up to n_ctx tokens
    // prefills in one llama_decode call, avoiding the ggml fp16 fallback
    // split-prefill bug that hangs on Cortex-A53 / SD662 v8.0
    // (see paper §5.9.5 sidebar item 2).
    cp.n_batch         = cp.n_ctx;
    cp.n_ubatch        = cp.n_ctx;
    cp.n_threads       = (n_threads > 0) ? n_threads : 4;
    cp.n_threads_batch = cp.n_threads;
    cp.flash_attn      = false;
    cp.embeddings      = true;
    cp.pooling_type    = LLAMA_POOLING_TYPE_MEAN;

    ::llama_context *raw = ::llama_new_context_with_model(model->m, cp);
    if (!raw) return nullptr;

    auto *handle = new dazzle_llama_ctx();
    handle->ctx           = raw;
    handle->model         = model->m;
    handle->n_ctx         = (int)cp.n_ctx;
    handle->is_embed_ctx  = true;
    return handle;
}

extern "C" int dazzle_llama_embed_dim(dazzle_llama_ctx *ctx) {
    if (!ctx || !ctx->model) return 0;
    return ::llama_n_embd(ctx->model);
}

extern "C" int dazzle_llama_embed(dazzle_llama_ctx *ctx,
                                  const char *prompt,
                                  float *out, int out_dim) {
    if (!ctx || !ctx->ctx || !ctx->model || !prompt || !out) {
        return DAZZLE_LLAMA_E_BAD_CTX;
    }
    if (!ctx->is_embed_ctx) return DAZZLE_LLAMA_E_BAD_CTX;
    const int dim = ::llama_n_embd(ctx->model);
    if (out_dim < dim) return DAZZLE_LLAMA_E_BAD_CTX;

    ::llama_kv_cache_clear(ctx->ctx);

    auto tokens = tokenise(ctx->model, std::string(prompt), /*add_bos*/ true);
    if (tokens.empty()) return DAZZLE_LLAMA_E_TOKENIZE;
    if ((int)tokens.size() > ctx->n_ctx) return DAZZLE_LLAMA_E_CONTEXT_FULL;

    ::llama_batch batch = ::llama_batch_get_one(tokens.data(),
                                                (int32_t)tokens.size());
    if (::llama_decode(ctx->ctx, batch) != 0) {
        return DAZZLE_LLAMA_E_DECODE;
    }

    // Sequence-pooled embedding (LLAMA_POOLING_TYPE_MEAN at context
    // creation time). Single-sequence: id 0.
    const float *src = ::llama_get_embeddings_seq(ctx->ctx, 0);
    if (!src) src = ::llama_get_embeddings(ctx->ctx);
    if (!src) return DAZZLE_LLAMA_E_DECODE;

    std::memcpy(out, src, (size_t)dim * sizeof(float));
    return dim;
}
