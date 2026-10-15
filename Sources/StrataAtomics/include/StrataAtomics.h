#ifndef STRATA_ATOMICS_H
#define STRATA_ATOMICS_H

#include <stdint.h>
#include <stdatomic.h>
#include <string.h>

// Lock-free primitives shared between the real-time audio thread and the UI.

static inline int64_t sa_load_i64(const int64_t *p) {
    return atomic_load_explicit((const _Atomic int64_t *)p, memory_order_acquire);
}

static inline void sa_store_i64(int64_t *p, int64_t v) {
    atomic_store_explicit((_Atomic int64_t *)p, v, memory_order_release);
}

static inline int64_t sa_fetch_add_i64(int64_t *p, int64_t v) {
    return atomic_fetch_add_explicit((_Atomic int64_t *)p, v, memory_order_acq_rel);
}

static inline float sa_load_f32(const float *p) {
    uint32_t bits = atomic_load_explicit((const _Atomic uint32_t *)p, memory_order_relaxed);
    float v; memcpy(&v, &bits, sizeof v); return v;
}

static inline void sa_store_f32(float *p, float v) {
    uint32_t bits; memcpy(&bits, &v, sizeof bits);
    atomic_store_explicit((_Atomic uint32_t *)p, bits, memory_order_relaxed);
}

/// Stores `v` only if it is larger than the current value (peak meters).
static inline void sa_max_f32(float *p, float v) {
    _Atomic uint32_t *a = (_Atomic uint32_t *)p;
    uint32_t old = atomic_load_explicit(a, memory_order_relaxed);
    for (;;) {
        float cur; memcpy(&cur, &old, sizeof cur);
        if (cur >= v) return;
        uint32_t nb; memcpy(&nb, &v, sizeof nb);
        if (atomic_compare_exchange_weak_explicit(a, &old, nb, memory_order_relaxed, memory_order_relaxed)) return;
    }
}

/// Reads the value and resets it to zero.
static inline float sa_exchange_zero_f32(float *p) {
    uint32_t bits = atomic_exchange_explicit((_Atomic uint32_t *)p, 0u, memory_order_relaxed);
    float v; memcpy(&v, &bits, sizeof v); return v;
}

static inline void sa_fence(void) { atomic_thread_fence(memory_order_seq_cst); }

#endif
