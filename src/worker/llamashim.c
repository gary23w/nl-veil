/*
 * llamashim.c — the veil_ll_* facade over the embedded inference library (llama.h).
 *
 * Scalars and pointers only, no by-value structs across the FFI line: the llama_* param
 * structs are large and change across pins, and a Zig extern-struct transcription would
 * break SILENTLY (ABI skew) the day the dependency is bumped. Constructing them here,
 * against the real header, turns any upstream field change into a compile error instead.
 *
 * Compiled only in -Dbuiltin=true builds (see build.zig addLlamaCpp); the Zig side is
 * src/worker/llamaeng.zig.
 */
#include <stdint.h>
#include <stdbool.h>
#include <string.h>
#include "llama.h"

void veil_ll_backend_init(void) {
    llama_backend_init();
}

static void veil_ll_log_null(enum ggml_log_level level, const char * text, void * user) {
    (void) level; (void) text; (void) user;
}

/* The library logs model-load internals to stderr by default; the server owns its own logs. */
void veil_ll_log_quiet(void) {
    llama_log_set(veil_ll_log_null, NULL);
}

struct llama_model * veil_ll_load(const char * path) {
    struct llama_model_params p = llama_model_default_params();
    p.n_gpu_layers = 0; /* CPU-only build */
    return llama_model_load_from_file(path, p);
}

/* Metadata-only load: vocab + header, no weight tensors. Cheap (~100ms on a 7GB file) —
 * lets /api/show and the status route report arch/params before anyone pays a full load. */
struct llama_model * veil_ll_load_meta(const char * path) {
    struct llama_model_params p = llama_model_default_params();
    p.n_gpu_layers = 0;
    p.vocab_only = true;
    return llama_model_load_from_file(path, p);
}

void veil_ll_model_free(struct llama_model * m) {
    llama_model_free(m);
}

struct llama_context * veil_ll_ctx_new(struct llama_model * m, uint32_t n_ctx, uint32_t n_batch, int32_t n_threads) {
    struct llama_context_params p = llama_context_default_params();
    p.n_ctx   = n_ctx;
    p.n_batch = n_batch;
    if (n_threads > 0) {
        p.n_threads       = n_threads;
        p.n_threads_batch = n_threads;
    }
    return llama_init_from_model(m, p);
}

void veil_ll_ctx_free(struct llama_context * c) {
    llama_free(c);
}

const struct llama_vocab * veil_ll_vocab(const struct llama_model * m) {
    return llama_model_get_vocab(m);
}

int32_t veil_ll_tokenize(const struct llama_vocab * v, const char * text, int32_t len, llama_token * toks, int32_t cap, bool add_special, bool parse_special) {
    return llama_tokenize(v, text, len, toks, cap, add_special, parse_special);
}

int32_t veil_ll_decode(struct llama_context * c, llama_token * toks, int32_t n) {
    return llama_decode(c, llama_batch_get_one(toks, n));
}

void veil_ll_mem_clear(struct llama_context * c) {
    llama_memory_clear(llama_get_memory(c), true);
}

/* Drop cached positions [p0, p1) of the single serving sequence — the prefix-reuse primitive. */
bool veil_ll_seq_rm(struct llama_context * c, int32_t p0, int32_t p1) {
    return llama_memory_seq_rm(llama_get_memory(c), 0, p0, p1);
}

struct llama_sampler * veil_ll_sampler_new(float temp, float top_p, uint32_t seed) {
    struct llama_sampler_chain_params cp = llama_sampler_chain_default_params();
    struct llama_sampler * chain = llama_sampler_chain_init(cp);
    if (temp <= 0.0f) {
        llama_sampler_chain_add(chain, llama_sampler_init_greedy());
    } else {
        if (top_p > 0.0f && top_p < 1.0f) {
            llama_sampler_chain_add(chain, llama_sampler_init_top_p(top_p, 1));
        }
        llama_sampler_chain_add(chain, llama_sampler_init_temp(temp));
        llama_sampler_chain_add(chain, llama_sampler_init_dist(seed));
    }
    return chain;
}

void veil_ll_sampler_free(struct llama_sampler * s) {
    llama_sampler_free(s);
}

llama_token veil_ll_sample(struct llama_sampler * s, struct llama_context * c) {
    return llama_sampler_sample(s, c, -1);
}

bool veil_ll_is_eog(const struct llama_vocab * v, llama_token t) {
    return llama_vocab_is_eog(v, t);
}

int32_t veil_ll_piece(const struct llama_vocab * v, llama_token t, char * buf, int32_t cap) {
    return llama_token_to_piece(v, t, buf, cap, 0, true);
}

int32_t veil_ll_n_ctx_train(const struct llama_model * m) {
    return llama_model_n_ctx_train(m);
}

uint64_t veil_ll_n_params(const struct llama_model * m) {
    return llama_model_n_params(m);
}

int32_t veil_ll_meta(const struct llama_model * m, const char * key, char * buf, size_t cap) {
    return llama_model_meta_val_str(m, key, buf, cap);
}
