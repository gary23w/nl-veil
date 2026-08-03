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

/* n_gpu_layers: 0 = CPU only; large (999) = offload everything a present accelerator can take.
 * With no usable device at runtime the library warns and loads CPU buffers — same file, same
 * call, graceful floor. */
struct llama_model * veil_ll_load(const char * path, int32_t n_gpu_layers) {
    struct llama_model_params p = llama_model_default_params();
    p.n_gpu_layers = n_gpu_layers;
    return llama_model_load_from_file(path, p);
}

/* FREE VRAM on the first GPU-class device, in MiB (0 = no device, or the backend cannot say).
 *
 * Why the engine needs this: on Windows an over-budget VRAM allocation does NOT fail — the driver
 * oversubscribes into shared system memory — so "did ggml_backend_alloc succeed?" is not a fit
 * test. It succeeded right before a crash where five nvlddmkm errors killed the process. Measuring
 * what is actually LEFT after the context exists is the only honest check, and it is what lets the
 * engine leave headroom for the other tenants on the card (the desk's own GL context, the browser
 * the veil drives, the desktop compositor). */
size_t veil_ll_gpu_free_mb(void) {
    size_t n = ggml_backend_dev_count();
    for (size_t i = 0; i < n; i++) {
        ggml_backend_dev_t d = ggml_backend_dev_get(i);
        if (ggml_backend_dev_type(d) != GGML_BACKEND_DEVICE_TYPE_GPU) continue;
        size_t free_b = 0, total_b = 0;
        ggml_backend_dev_memory(d, &free_b, &total_b);
        return free_b / (1024 * 1024);
    }
    return 0;
}

/* Description of the first GPU-class compute device the runtime can actually see (empty when
 * none): what the status row shows so "is it on the GPU?" is never a guess. */
int32_t veil_ll_gpu_desc(char * buf, size_t cap) {
    size_t n = ggml_backend_dev_count();
    for (size_t i = 0; i < n; i++) {
        ggml_backend_dev_t d = ggml_backend_dev_get(i);
        if (ggml_backend_dev_type(d) == GGML_BACKEND_DEVICE_TYPE_GPU) {
            const char * desc = ggml_backend_dev_description(d);
            if (!desc) return 0;
            size_t len = strlen(desc);
            if (len > cap) len = cap;
            memcpy(buf, desc, len);
            return (int32_t) len;
        }
    }
    return 0;
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

/* n_ctx_total is the WHOLE kv allocation shared by n_seq slots (the engine sizes it as
 * per-slot-window * slots). Decode threads and batch (prefill) threads split: decode is
 * memory-bandwidth-bound and wants ~physical cores; prefill is compute-bound and scales wider. */
/* kv_q8: store the K/V cache as q8_0 instead of f16, ~halving the cache's memory for a quality
 * cost that is negligible at 8 bits. This is what makes a useful context window fit beside the
 * weights on a 12GB card: at f16 the engine had to step 16384 -> 4096 to keep a safe VRAM reserve,
 * and 4096 cannot even hold the harness's own ~6.4k-token prefix, so the model could not serve a
 * single turn. Quantized V requires flash attention, so it is requested together (AUTO lets the
 * backend refuse and fall back rather than fail the load). */
struct llama_context * veil_ll_ctx_new(struct llama_model * m, uint32_t n_ctx_total, uint32_t n_batch, int32_t n_threads, int32_t n_threads_batch, uint32_t n_seq, bool kv_q8) {
    struct llama_context_params p = llama_context_default_params();
    p.n_ctx     = n_ctx_total;
    p.n_batch   = n_batch;
    p.n_seq_max = n_seq > 0 ? n_seq : 1;
    if (n_threads > 0)       p.n_threads       = n_threads;
    if (n_threads_batch > 0) p.n_threads_batch = n_threads_batch;
    if (kv_q8) {
        p.type_k = GGML_TYPE_Q8_0;
        p.type_v = GGML_TYPE_Q8_0;
        p.flash_attn_type = LLAMA_FLASH_ATTN_TYPE_AUTO;
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

/* One decode of `n` tokens into sequence `seq` at positions [first_pos, first_pos+n). Logits are
 * computed only for the final token when logits_last (the sampling read); pure prefill chunks pass
 * false and skip the lm_head entirely. Static scratch is safe: the engine is single-flight by its
 * own mutex, so exactly one decode is ever in here. */
int32_t veil_ll_decode_seq(struct llama_context * c, llama_token * toks, int32_t n, int32_t first_pos, int32_t seq, bool logits_last) {
    enum { CAP = 4096 };
    static llama_pos     pos[CAP];
    static int32_t       nsq[CAP];
    static llama_seq_id  sid;
    static llama_seq_id *sidp[CAP];
    static int8_t        lgt[CAP];
    if (n <= 0 || n > CAP) return -1;
    sid = (llama_seq_id) seq;
    for (int32_t i = 0; i < n; i++) {
        pos[i]  = first_pos + i;
        nsq[i]  = 1;
        sidp[i] = &sid;
        lgt[i]  = (logits_last && i == n - 1) ? 1 : 0;
    }
    struct llama_batch b = { n, toks, NULL, pos, nsq, sidp, lgt };
    return llama_decode(c, b);
}

void veil_ll_mem_clear(struct llama_context * c) {
    llama_memory_clear(llama_get_memory(c), true);
}

/* Drop cached positions [p0, p1) of one slot's sequence — the prefix-reuse primitive. */
bool veil_ll_seq_rm(struct llama_context * c, int32_t seq, int32_t p0, int32_t p1) {
    return llama_memory_seq_rm(llama_get_memory(c), (llama_seq_id) seq, p0, p1);
}

/* Chain order mirrors the conventional local-serving default: top_k first (cuts the 262k-entry
 * vocab to k before anything sorts), then top_p, temperature, and the seeded pick. top_k is the
 * cheap gate that keeps per-token sampling cost flat on huge vocabularies. */
struct llama_sampler * veil_ll_sampler_new(float temp, int32_t top_k, float top_p, uint32_t seed) {
    struct llama_sampler_chain_params cp = llama_sampler_chain_default_params();
    struct llama_sampler * chain = llama_sampler_chain_init(cp);
    if (temp <= 0.0f) {
        llama_sampler_chain_add(chain, llama_sampler_init_greedy());
    } else {
        if (top_k > 0) {
            llama_sampler_chain_add(chain, llama_sampler_init_top_k(top_k));
        }
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

/* The model's transformer layer count — the ONLY meaningful unit for partial offload. Without it
 * an offload "ladder" of 999/749/499 is a fiction: llama clamps n_gpu_layers to this number, so
 * every one of those rungs means "all layers" and the ladder never actually steps down. Readable
 * from a vocab-only load (hparams live in the GGUF header), so the engine knows it before it
 * commits any weights. */
int32_t veil_ll_n_layer(const struct llama_model * m) {
    return llama_model_n_layer(m);
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
