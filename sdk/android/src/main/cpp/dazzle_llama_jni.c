/*
 * Copyright 2026 Ivan Aliaga <ivan.aliaga@urp.edu.pe>
 *
 * Licensed under the Apache License, Version 2.0 (the "License");
 * you may not use this file except in compliance with the License.
 *
 * dazzle_llama_jni.c — JNI shim over dazzle_llama_* (the plain-C
 * surface defined in core/platform/dazzle_llama.h). Kotlin
 * LlamaCppClient calls these.
 *
 * Kept intentionally thin: every Java_dev_dazzle_sdk_edge_LlamaNative_*
 * entry point converts JNI types to plain C and delegates. The
 * inference lives in dazzle_llama.cpp; this file is marshalling.
 */

#include <jni.h>
#include <stdint.h>
#include <stdlib.h>
#include <string.h>

#include "dazzle_llama.h"

/* ── Callback plumbing ────────────────────────────────────────────────
 *
 * The Kotlin side passes a Runnable-like callback we invoke from C.
 * dazzle_llama_on_token is `int (*)(const char*, void*)`; we bundle
 * JNIEnv + the Kotlin callback jobject into a small struct and pass
 * that as user_data. The struct lives on the stack of the Java_*
 * shim so its lifetime covers the whole generate call. */

typedef struct {
    JNIEnv *env;
    jobject callback;       // Kotlin object implementing onToken(String) -> Boolean
    jmethodID method;       // cached method id for onToken
    jint cancelled;
} dazzle_llama_cb_ctx;

static int dazzle_llama_jni_on_token(const char *piece, void *user_data) {
    dazzle_llama_cb_ctx *cb = (dazzle_llama_cb_ctx *)user_data;
    if (!cb || !cb->callback || !cb->method) return 0;

    jstring jpiece = (*cb->env)->NewStringUTF(cb->env, piece);
    jboolean keep_going = (*cb->env)->CallBooleanMethod(
        cb->env, cb->callback, cb->method, jpiece);
    (*cb->env)->DeleteLocalRef(cb->env, jpiece);

    /* Kotlin exception bubbling out of the callback is treated as a
     * hard cancel — clear + stop so we don't leak the exception
     * state through subsequent JNI calls. */
    if ((*cb->env)->ExceptionCheck(cb->env)) {
        (*cb->env)->ExceptionClear(cb->env);
        cb->cancelled = 1;
        return 1;
    }
    /* Callback returned true → keep going; false → stop. That maps
     * to our C convention of `0 = keep_going, nonzero = cancel`. */
    if (keep_going == JNI_FALSE) {
        cb->cancelled = 1;
        return 1;
    }
    return 0;
}

/* ── Backend init ────────────────────────────────────────────────────*/

JNIEXPORT void JNICALL
Java_dev_dazzle_sdk_edge_LlamaNative_nBackendInit(JNIEnv *env, jclass cls) {
    (void)env; (void)cls;
    dazzle_llama_backend_init();
}

/* ── Model load / free ───────────────────────────────────────────────*/

JNIEXPORT jlong JNICALL
Java_dev_dazzle_sdk_edge_LlamaNative_nLoadModel(
        JNIEnv *env, jclass cls, jstring jpath, jint n_gpu_layers) {
    (void)cls;
    const char *path = (*env)->GetStringUTFChars(env, jpath, NULL);
    dazzle_llama_model *m = dazzle_llama_load_model(path, (int)n_gpu_layers);
    (*env)->ReleaseStringUTFChars(env, jpath, path);
    return (jlong)(intptr_t)m;
}

JNIEXPORT void JNICALL
Java_dev_dazzle_sdk_edge_LlamaNative_nFreeModel(
        JNIEnv *env, jclass cls, jlong handle) {
    (void)env; (void)cls;
    dazzle_llama_free_model((dazzle_llama_model *)(intptr_t)handle);
}

/* ── Context new / free ──────────────────────────────────────────────*/

JNIEXPORT jlong JNICALL
Java_dev_dazzle_sdk_edge_LlamaNative_nNewContext(
        JNIEnv *env, jclass cls, jlong model_handle, jint n_ctx, jint n_threads) {
    (void)env; (void)cls;
    dazzle_llama_ctx *ctx = dazzle_llama_new_context(
        (dazzle_llama_model *)(intptr_t)model_handle,
        (int)n_ctx, (int)n_threads);
    return (jlong)(intptr_t)ctx;
}

JNIEXPORT void JNICALL
Java_dev_dazzle_sdk_edge_LlamaNative_nFreeContext(
        JNIEnv *env, jclass cls, jlong handle) {
    (void)env; (void)cls;
    dazzle_llama_free_context((dazzle_llama_ctx *)(intptr_t)handle);
}

/* ── Generate ────────────────────────────────────────────────────────*/

JNIEXPORT jint JNICALL
Java_dev_dazzle_sdk_edge_LlamaNative_nGenerate(
        JNIEnv *env, jclass cls,
        jlong ctx_handle, jstring jprompt,
        jint max_tokens, jfloat temperature, jfloat top_p, jint seed,
        jobject jcallback /* dev.dazzle.sdk.edge.LlamaTokenCallback */) {
    (void)cls;
    const char *prompt = (*env)->GetStringUTFChars(env, jprompt, NULL);

    /* Look up onToken(String)->Boolean on the callback's class once,
     * cache on the stack for the lifetime of this call. */
    jclass cb_cls = (*env)->GetObjectClass(env, jcallback);
    jmethodID on_token = (*env)->GetMethodID(env, cb_cls, "onToken", "(Ljava/lang/String;)Z");

    dazzle_llama_cb_ctx cb = {
        .env       = env,
        .callback  = jcallback,
        .method    = on_token,
        .cancelled = 0,
    };

    int rc = dazzle_llama_generate(
        (dazzle_llama_ctx *)(intptr_t)ctx_handle,
        prompt,
        (int)max_tokens,
        (float)temperature,
        (float)top_p,
        (uint32_t)seed,
        &dazzle_llama_jni_on_token,
        &cb);

    (*env)->ReleaseStringUTFChars(env, jprompt, prompt);
    return (jint)rc;
}
