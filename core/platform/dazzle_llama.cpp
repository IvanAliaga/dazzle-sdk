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
#include <cstdio>
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
    // n_batch / n_ubatch must be ≥ the prompt length we feed to
    // llama_decode in one shot, otherwise ggml_abort kills the process
    // (SIGABRT in llama_decode assertions). Scale with n_ctx so the
    // wrapper accepts any prompt that fits in the context window.
    // Confirmed via crash on iPhone 12 Pro / iOS 26.3 (May 2026): a
    // 590-token prompt aborted with the previous hardcoded 512.
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

    // 1. Tokenise
    auto tokens = tokenise(ctx->model, std::string(prompt), /*add_bos*/ true);
    if (tokens.empty()) return DAZZLE_LLAMA_E_TOKENIZE;
    if ((int)tokens.size() >= ctx->n_ctx) return DAZZLE_LLAMA_E_CONTEXT_FULL;

    // 2. Prompt decode — batch the entire prompt in one shot.
    {
        ::llama_batch batch = ::llama_batch_get_one(tokens.data(),
                                                   (int32_t)tokens.size());
        if (::llama_decode(ctx->ctx, batch) != 0) {
            return DAZZLE_LLAMA_E_DECODE;
        }
        ctx->n_past += (int)tokens.size();
    }

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
    return (rc == DAZZLE_LLAMA_E_CANCELLED) ? DAZZLE_LLAMA_E_CANCELLED : emitted;
}
