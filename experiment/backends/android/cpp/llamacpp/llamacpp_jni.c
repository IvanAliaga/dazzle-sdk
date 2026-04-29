// Copyright 2026 Ivan Aliaga <ivan.aliaga@urp.edu.pe>
// SPDX-License-Identifier: Apache-2.0
//
// JNI shim around llama.cpp for on-device text embedding (E1) and LLM
// generation (E3). Both live in the same .so — separate Kotlin classes
// (DazzleEmbedder / DazzleLlm) each own their own llama_context so we
// don't collide on the `embeddings = true` / pooling config.
//
// Embedder surface (DazzleEmbedder):
//   nInit(modelPath, nCtx, nThreads)     -> handle (jlong)
//   nEmbed(handle, text)                  -> FloatArray (L2-normalised)
//   nOutputDim(handle)                    -> int
//   nFree(handle)                         -> void
//
// Generator surface (DazzleLlm):
//   nInit(modelPath, nCtx, nThreads)     -> handle (jlong)
//   nGenerate(handle, prompt, maxNew)     -> String (greedy argmax)
//   nLastPrefillUs / nLastDecodeUs / nLastNewTokens / nLastPromptTokens
//   nFree(handle)                         -> void

#include <jni.h>
#include <math.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>

#include <android/log.h>

#include "llama.h"

#define LOG_TAG "LlamaCppJNI"
#define LOGE(fmt, ...) __android_log_print(ANDROID_LOG_ERROR, LOG_TAG, fmt, ##__VA_ARGS__)
#define LOGI(fmt, ...) __android_log_print(ANDROID_LOG_INFO,  LOG_TAG, fmt, ##__VA_ARGS__)

typedef struct {
    struct llama_model   *model;
    struct llama_context *ctx;
    int                   n_embd;
    int                   n_threads;
} Handle;

static jlong h_to_j(Handle *h) { return (jlong)(intptr_t)h; }
static Handle *j_to_h(jlong j) { return (Handle *)(intptr_t)j; }

JNIEXPORT jlong JNICALL
Java_dev_dazzle_experiment_DazzleEmbedder_nInit(
        JNIEnv *env, jclass cls,
        jstring jModelPath, jint nCtx, jint nThreads) {
    static int llama_inited = 0;
    if (!llama_inited) {
        llama_backend_init();
        llama_inited = 1;
    }

    const char *model_path = (*env)->GetStringUTFChars(env, jModelPath, NULL);

    struct llama_model_params mparams = llama_model_default_params();
    mparams.n_gpu_layers = 0;  // CPU-only on Android for now.

    struct llama_model *model = llama_load_model_from_file(model_path, mparams);
    (*env)->ReleaseStringUTFChars(env, jModelPath, model_path);
    if (!model) {
        LOGE("llama_load_model_from_file failed");
        return 0;
    }

    struct llama_context_params cparams = llama_context_default_params();
    cparams.n_ctx         = (uint32_t)(nCtx > 0 ? nCtx : 512);
    cparams.n_batch       = cparams.n_ctx;
    cparams.n_threads     = nThreads > 0 ? nThreads : 4;
    cparams.n_threads_batch = cparams.n_threads;
    // Mean pooling over tokens — matches how Sentence-Transformers aggregate
    // BGE/E5/MiniLM embeddings. llama.cpp applies the pooling inside the
    // context when embeddings mode is enabled.
    cparams.embeddings    = true;
    cparams.pooling_type  = LLAMA_POOLING_TYPE_MEAN;

    struct llama_context *ctx = llama_new_context_with_model(model, cparams);
    if (!ctx) {
        LOGE("llama_new_context_with_model failed");
        llama_free_model(model);
        return 0;
    }

    Handle *h = (Handle *)calloc(1, sizeof(Handle));
    h->model     = model;
    h->ctx       = ctx;
    h->n_embd    = llama_n_embd(model);
    h->n_threads = cparams.n_threads;
    LOGI("loaded GGUF — n_embd=%d n_threads=%d", h->n_embd, h->n_threads);
    return h_to_j(h);
}

JNIEXPORT jint JNICALL
Java_dev_dazzle_experiment_DazzleEmbedder_nOutputDim(
        JNIEnv *env, jclass cls, jlong handle) {
    Handle *h = j_to_h(handle);
    return h ? h->n_embd : -1;
}

JNIEXPORT jfloatArray JNICALL
Java_dev_dazzle_experiment_DazzleEmbedder_nEmbed(
        JNIEnv *env, jclass cls, jlong handle, jstring jText) {
    Handle *h = j_to_h(handle);
    if (!h) return NULL;

    const char *text = (*env)->GetStringUTFChars(env, jText, NULL);

    // llama.cpp's common_tokenize gives back a std::vector<llama_token>; we
    // fall back to the C API (llama_tokenize) to avoid pulling in C++ from
    // the JNI boundary.
    int max_tokens = (int)strlen(text) + 8;
    llama_token *tokens = (llama_token *)malloc(sizeof(llama_token) * max_tokens);
    int n_tokens = llama_tokenize(
        llama_get_model(h->ctx), text, (int)strlen(text),
        tokens, max_tokens,
        /*add_special=*/ true, /*parse_special=*/ false);
    (*env)->ReleaseStringUTFChars(env, jText, text);

    if (n_tokens < 0) {
        // Buffer too small — retry once.
        max_tokens = -n_tokens;
        free(tokens);
        tokens = (llama_token *)malloc(sizeof(llama_token) * max_tokens);
        n_tokens = llama_tokenize(
            llama_get_model(h->ctx), NULL, 0,
            tokens, max_tokens, true, false);
        if (n_tokens < 0) {
            LOGE("llama_tokenize failed after retry");
            free(tokens);
            return NULL;
        }
    }

    struct llama_batch batch = llama_batch_init((int32_t)n_tokens, 0, 1);
    for (int i = 0; i < n_tokens; i++) {
        batch.token   [batch.n_tokens] = tokens[i];
        batch.pos     [batch.n_tokens] = i;
        batch.n_seq_id[batch.n_tokens] = 1;
        batch.seq_id  [batch.n_tokens][0] = 0;
        batch.logits  [batch.n_tokens] = 0;
        batch.n_tokens++;
    }
    free(tokens);

    llama_kv_cache_clear(h->ctx);
    int rc = llama_decode(h->ctx, batch);
    llama_batch_free(batch);
    if (rc != 0) {
        LOGE("llama_decode rc=%d", rc);
        return NULL;
    }

    const float *pooled = llama_get_embeddings_seq(h->ctx, 0);
    if (!pooled) pooled = llama_get_embeddings(h->ctx);
    if (!pooled) {
        LOGE("no embeddings returned");
        return NULL;
    }

    // Copy out + L2 normalise.
    float *out = (float *)malloc(sizeof(float) * h->n_embd);
    double sum = 0.0;
    for (int i = 0; i < h->n_embd; i++) {
        out[i] = pooled[i];
        sum   += (double)pooled[i] * pooled[i];
    }
    float norm = (float)sqrt(sum);
    if (norm > 0.f) {
        float inv = 1.f / norm;
        for (int i = 0; i < h->n_embd; i++) out[i] *= inv;
    }

    jfloatArray ja = (*env)->NewFloatArray(env, h->n_embd);
    (*env)->SetFloatArrayRegion(env, ja, 0, h->n_embd, out);
    free(out);
    return ja;
}

JNIEXPORT void JNICALL
Java_dev_dazzle_experiment_DazzleEmbedder_nFree(
        JNIEnv *env, jclass cls, jlong handle) {
    Handle *h = j_to_h(handle);
    if (!h) return;
    if (h->ctx)   llama_free(h->ctx);
    if (h->model) llama_free_model(h->model);
    free(h);
}

// ── LLM generation (DazzleLlm) ───────────────────────────────────────────
//
// Separate handle type so the context flags don't bleed across use-cases:
// the embedder forces `embeddings=true` + mean pooling; generation needs
// neither (and both would be wrong if enabled here).

typedef struct {
    struct llama_model   *model;
    struct llama_context *ctx;
    int                   n_ctx;
    int                   n_threads;
    // Stats from the most recent nGenerate call — each reset at entry so
    // they always describe the last generation (not a running total).
    int64_t               last_prefill_us;
    int64_t               last_decode_us;
    int                   last_prompt_tokens;
    int                   last_new_tokens;
} GenHandle;

static jlong gh_to_j(GenHandle *h) { return (jlong)(intptr_t)h; }
static GenHandle *j_to_gh(jlong j) { return (GenHandle *)(intptr_t)j; }

static int64_t now_us(void) {
    struct timespec ts;
    clock_gettime(CLOCK_MONOTONIC, &ts);
    return (int64_t)ts.tv_sec * 1000000LL + (int64_t)ts.tv_nsec / 1000LL;
}

JNIEXPORT jlong JNICALL
Java_dev_dazzle_experiment_DazzleLlm_nInit(
        JNIEnv *env, jclass cls,
        jstring jModelPath, jint nCtx, jint nThreads) {
    static int llama_inited = 0;
    if (!llama_inited) {
        llama_backend_init();
        llama_inited = 1;
    }

    const char *model_path = (*env)->GetStringUTFChars(env, jModelPath, NULL);

    struct llama_model_params mparams = llama_model_default_params();
    mparams.n_gpu_layers = 0;

    struct llama_model *model = llama_load_model_from_file(model_path, mparams);
    (*env)->ReleaseStringUTFChars(env, jModelPath, model_path);
    if (!model) {
        LOGE("DazzleLlm: llama_load_model_from_file failed");
        return 0;
    }

    struct llama_context_params cparams = llama_context_default_params();
    cparams.n_ctx           = (uint32_t)(nCtx > 0 ? nCtx : 2048);
    cparams.n_batch         = cparams.n_ctx;
    cparams.n_threads       = nThreads > 0 ? nThreads : 4;
    cparams.n_threads_batch = cparams.n_threads;
    // embeddings=false (default) — generation wants per-token logits.

    struct llama_context *ctx = llama_new_context_with_model(model, cparams);
    if (!ctx) {
        LOGE("DazzleLlm: llama_new_context_with_model failed");
        llama_free_model(model);
        return 0;
    }

    GenHandle *h = (GenHandle *)calloc(1, sizeof(GenHandle));
    h->model     = model;
    h->ctx       = ctx;
    h->n_ctx     = (int)cparams.n_ctx;
    h->n_threads = cparams.n_threads;
    LOGI("DazzleLlm loaded — n_ctx=%d n_threads=%d", h->n_ctx, h->n_threads);
    return gh_to_j(h);
}

JNIEXPORT jstring JNICALL
Java_dev_dazzle_experiment_DazzleLlm_nGenerate(
        JNIEnv *env, jclass cls,
        jlong handle, jstring jPrompt, jint maxNewTokens) {
    GenHandle *h = j_to_gh(handle);
    if (!h) return NULL;
    h->last_prefill_us = 0;
    h->last_decode_us  = 0;
    h->last_prompt_tokens = 0;
    h->last_new_tokens = 0;

    const char *prompt = (*env)->GetStringUTFChars(env, jPrompt, NULL);

    // 1) Tokenize prompt.
    int plen       = (int)strlen(prompt);
    int max_tokens = plen + 16;
    llama_token *tokens = (llama_token *)malloc(sizeof(llama_token) * max_tokens);
    int n_prompt = llama_tokenize(
        h->model, prompt, plen,
        tokens, max_tokens,
        /*add_special=*/ true, /*parse_special=*/ true);
    if (n_prompt < 0) {
        max_tokens = -n_prompt;
        free(tokens);
        tokens = (llama_token *)malloc(sizeof(llama_token) * max_tokens);
        n_prompt = llama_tokenize(
            h->model, prompt, plen,
            tokens, max_tokens, true, true);
    }
    (*env)->ReleaseStringUTFChars(env, jPrompt, prompt);
    if (n_prompt <= 0) {
        LOGE("DazzleLlm: tokenize failed (%d)", n_prompt);
        free(tokens);
        return NULL;
    }

    // Guard against prompts that already blow past the context window —
    // leave at least `maxNewTokens` room for generation.
    int budget = h->n_ctx - (maxNewTokens > 0 ? maxNewTokens : 1);
    if (n_prompt > budget) {
        LOGE("DazzleLlm: prompt (%d) > ctx-budget (%d); truncating head",
             n_prompt, budget);
        int drop = n_prompt - budget;
        memmove(tokens, tokens + drop, sizeof(llama_token) * budget);
        n_prompt = budget;
    }
    h->last_prompt_tokens = n_prompt;

    // 2) Prefill: one batch with all prompt tokens, logits on the last one.
    int64_t t0 = now_us();
    llama_kv_cache_clear(h->ctx);
    struct llama_batch batch = llama_batch_init((int32_t)n_prompt, 0, 1);
    for (int i = 0; i < n_prompt; i++) {
        batch.token   [batch.n_tokens] = tokens[i];
        batch.pos     [batch.n_tokens] = i;
        batch.n_seq_id[batch.n_tokens] = 1;
        batch.seq_id  [batch.n_tokens][0] = 0;
        batch.logits  [batch.n_tokens] = (i == n_prompt - 1) ? 1 : 0;
        batch.n_tokens++;
    }
    free(tokens);
    int rc = llama_decode(h->ctx, batch);
    llama_batch_free(batch);
    if (rc != 0) {
        LOGE("DazzleLlm: prefill llama_decode rc=%d", rc);
        return NULL;
    }
    h->last_prefill_us = now_us() - t0;

    // 3) Sampler chain: greedy (argmax) for reproducibility.
    struct llama_sampler *smpl = llama_sampler_chain_init(
        llama_sampler_chain_default_params());
    llama_sampler_chain_add(smpl, llama_sampler_init_greedy());

    // 4) Decode loop.
    size_t cap  = 512;
    size_t used = 0;
    char  *out  = (char *)malloc(cap);
    out[0] = '\0';

    int64_t t1 = now_us();
    int pos = n_prompt;
    int max_new = maxNewTokens > 0 ? maxNewTokens : 128;
    struct llama_batch step = llama_batch_init(1, 0, 1);
    for (int i = 0; i < max_new; i++) {
        llama_token id = llama_sampler_sample(smpl, h->ctx, -1);
        if (llama_token_is_eog(h->model, id)) break;

        // Detokenize this one token and append.
        char pbuf[128];
        int n = llama_token_to_piece(h->model, id, pbuf, sizeof(pbuf),
                                     /*lstrip=*/ 0, /*special=*/ false);
        if (n > 0) {
            if (used + (size_t)n + 1 > cap) {
                cap = (used + n + 1) * 2;
                out = (char *)realloc(out, cap);
            }
            memcpy(out + used, pbuf, n);
            used += n;
            out[used] = '\0';
        }

        llama_sampler_accept(smpl, id);
        h->last_new_tokens++;

        // Feed the sampled token back for the next step.
        step.n_tokens = 0;
        step.token   [step.n_tokens] = id;
        step.pos     [step.n_tokens] = pos++;
        step.n_seq_id[step.n_tokens] = 1;
        step.seq_id  [step.n_tokens][0] = 0;
        step.logits  [step.n_tokens] = 1;
        step.n_tokens = 1;
        rc = llama_decode(h->ctx, step);
        if (rc != 0) {
            LOGE("DazzleLlm: decode rc=%d at step %d", rc, i);
            break;
        }
    }
    llama_batch_free(step);
    llama_sampler_free(smpl);
    h->last_decode_us = now_us() - t1;

    jstring result = (*env)->NewStringUTF(env, out);
    free(out);
    return result;
}

JNIEXPORT jlong JNICALL
Java_dev_dazzle_experiment_DazzleLlm_nLastPrefillUs(
        JNIEnv *env, jclass cls, jlong handle) {
    GenHandle *h = j_to_gh(handle);
    return h ? (jlong)h->last_prefill_us : -1;
}

JNIEXPORT jlong JNICALL
Java_dev_dazzle_experiment_DazzleLlm_nLastDecodeUs(
        JNIEnv *env, jclass cls, jlong handle) {
    GenHandle *h = j_to_gh(handle);
    return h ? (jlong)h->last_decode_us : -1;
}

JNIEXPORT jint JNICALL
Java_dev_dazzle_experiment_DazzleLlm_nLastPromptTokens(
        JNIEnv *env, jclass cls, jlong handle) {
    GenHandle *h = j_to_gh(handle);
    return h ? (jint)h->last_prompt_tokens : -1;
}

JNIEXPORT jint JNICALL
Java_dev_dazzle_experiment_DazzleLlm_nLastNewTokens(
        JNIEnv *env, jclass cls, jlong handle) {
    GenHandle *h = j_to_gh(handle);
    return h ? (jint)h->last_new_tokens : -1;
}

JNIEXPORT void JNICALL
Java_dev_dazzle_experiment_DazzleLlm_nFree(
        JNIEnv *env, jclass cls, jlong handle) {
    GenHandle *h = j_to_gh(handle);
    if (!h) return;
    if (h->ctx)   llama_free(h->ctx);
    if (h->model) llama_free_model(h->model);
    free(h);
}
