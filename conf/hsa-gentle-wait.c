/*
 * hsa-gentle-wait.so  --  LD_PRELOAD shim for ROCm/HIP on gfx110x/gfx120x
 *
 * Works around https://github.com/ROCm/TheRock/issues/7832 : under host-memory
 * pressure a host->device copy's completion signal is not satisfied for tens of
 * seconds, and rocr::core::BusyWaitSignal::WaitRelaxed busy-spins a CPU core at
 * 100% the whole time (GPU idle, process barely killable, healthcheck can't tell).
 *
 * This intercepts the public hsa_signal_wait_* / hsa_amd_signal_wait_* entry
 * points and replaces the active spin with: a very short sched_yield() spin (so
 * fast waits stay fast), then a nanosleep poll that ramps 50us -> 2ms. A stuck
 * copy still takes as long as it takes, but the core is free, the box stays
 * responsive, and nanosleep is a signal/cancellation point so the job is killable.
 *
 * Disable at runtime with  HSA_GENTLE_WAIT=0 .
 * Set  HSA_GENTLE_WAIT_LOG=1  to print waits that exceed 1s to stderr.
 *
 * Build:  gcc -O2 -fPIC -shared -o hsa-gentle-wait.so hsa-gentle-wait.c -ldl
 */
#define _GNU_SOURCE
#include <stdint.h>
#include <stdlib.h>
#include <stdio.h>
#include <time.h>
#include <sched.h>
#include <dlfcn.h>

typedef struct { uint64_t handle; } hsa_signal_t;
typedef int64_t  hsa_signal_value_t;
typedef int      hsa_signal_condition_t;   /* EQ=0 NE=1 LT=2 GTE=3 */
typedef int      hsa_wait_state_t;

#define YIELD_SPIN_NS   50000ull      /* 50 us of sched_yield before sleeping   */
#define SLEEP_START_NS  50000L        /* first nanosleep                        */
#define SLEEP_MAX_NS    2000000L      /* cap at 2 ms                            */

static hsa_signal_value_t (*real_load)(hsa_signal_t) = NULL;
static int   g_enabled = 1;
static int   g_log     = 0;
static int   g_init    = 0;

static void init_once(void) {
    if (g_init) return;
    g_init = 1;
    const char *e = getenv("HSA_GENTLE_WAIT");
    if (e && (e[0] == '0' || e[0] == 'n' || e[0] == 'N')) g_enabled = 0;
    e = getenv("HSA_GENTLE_WAIT_LOG");
    if (e && e[0] == '1') g_log = 1;
    real_load = (hsa_signal_value_t(*)(hsa_signal_t))dlsym(RTLD_NEXT, "hsa_signal_load_scacquire");
    if (!real_load)
        real_load = (hsa_signal_value_t(*)(hsa_signal_t))dlsym(RTLD_NEXT, "hsa_signal_load_relaxed");
    if (!real_load) g_enabled = 0;   /* can't poll -> stay out of the way */
    if (g_log)
        fprintf(stderr, "[hsa-gentle-wait] active=%d (load=%p)\n", g_enabled, (void*)real_load);
}

__attribute__((constructor)) static void announce(void) {
    if (getenv("HSA_GENTLE_WAIT_LOG"))
        fprintf(stderr, "[hsa-gentle-wait] preloaded\n");
}

static inline uint64_t now_ns(void) {
    struct timespec ts;
    clock_gettime(CLOCK_MONOTONIC, &ts);
    return (uint64_t)ts.tv_sec * 1000000000ull + (uint64_t)ts.tv_nsec;
}
static inline int sat(hsa_signal_value_t v, hsa_signal_condition_t c, hsa_signal_value_t k) {
    switch (c) { case 0: return v == k; case 1: return v != k;
                 case 2: return v <  k; case 3: return v >= k; default: return 1; }
}
static inline void nap(long *ns) {
    if (*ns == 0) *ns = SLEEP_START_NS;
    else if (*ns < SLEEP_MAX_NS) { *ns <<= 1; if (*ns > SLEEP_MAX_NS) *ns = SLEEP_MAX_NS; }
    struct timespec ts = { 0, *ns };
    nanosleep(&ts, NULL);
}

/* real fallbacks, only used if the shim is disabled */
static hsa_signal_value_t (*real_wait_sc)(hsa_signal_t, hsa_signal_condition_t,
        hsa_signal_value_t, uint64_t, hsa_wait_state_t) = NULL;

static hsa_signal_value_t gentle_one(hsa_signal_t s, hsa_signal_condition_t c,
        hsa_signal_value_t k, uint64_t timeout_ns) {
    uint64_t start = now_ns();
    uint64_t yield_until = start + YIELD_SPIN_NS;
    long snap = 0;
    for (;;) {
        hsa_signal_value_t v = real_load(s);
        if (sat(v, c, k)) {
            if (g_log) {
                uint64_t d = now_ns() - start;
                if (d > 300000000ull)   /* > 0.3 s */
                    fprintf(stderr, "[hsa-gentle-wait] slow wait: %.2f s (would have spun a core)\n", d / 1e9);
            }
            return v;
        }
        uint64_t t = now_ns();
        if (timeout_ns != UINT64_MAX && (t - start) >= timeout_ns) return v;
        if (t < yield_until) sched_yield();
        else nap(&snap);
    }
}

hsa_signal_value_t hsa_signal_wait_scacquire(hsa_signal_t s, hsa_signal_condition_t c,
        hsa_signal_value_t k, uint64_t timeout, hsa_wait_state_t ws) {
    init_once();
    if (!g_enabled) {
        if (!real_wait_sc) real_wait_sc = dlsym(RTLD_NEXT, "hsa_signal_wait_scacquire");
        return real_wait_sc(s, c, k, timeout, ws);
    }
    (void)ws;
    return gentle_one(s, c, k, timeout);
}
hsa_signal_value_t hsa_signal_wait_acquire(hsa_signal_t s, hsa_signal_condition_t c,
        hsa_signal_value_t k, uint64_t timeout, hsa_wait_state_t ws) {
    return hsa_signal_wait_scacquire(s, c, k, timeout, ws);
}
hsa_signal_value_t hsa_signal_wait_relaxed(hsa_signal_t s, hsa_signal_condition_t c,
        hsa_signal_value_t k, uint64_t timeout, hsa_wait_state_t ws) {
    return hsa_signal_wait_scacquire(s, c, k, timeout, ws);
}

uint32_t hsa_amd_signal_wait_any(uint32_t n, hsa_signal_t *sigs, hsa_signal_condition_t *conds,
        hsa_signal_value_t *vals, uint64_t timeout, hsa_wait_state_t ws,
        hsa_signal_value_t *satisfying_value) {
    init_once();
    if (!g_enabled) {
        static uint32_t (*real)(uint32_t, hsa_signal_t*, hsa_signal_condition_t*,
                hsa_signal_value_t*, uint64_t, hsa_wait_state_t, hsa_signal_value_t*) = NULL;
        if (!real) real = dlsym(RTLD_NEXT, "hsa_amd_signal_wait_any");
        return real(n, sigs, conds, vals, timeout, ws, satisfying_value);
    }
    (void)ws;
    uint64_t start = now_ns(), yield_until = start + YIELD_SPIN_NS;
    long snap = 0;
    for (;;) {
        for (uint32_t i = 0; i < n; i++) {
            hsa_signal_value_t v = real_load(sigs[i]);
            if (sat(v, conds[i], vals[i])) {
                if (satisfying_value) *satisfying_value = v;
                if (g_log && now_ns() - start > 300000000ull)
                    fprintf(stderr, "[hsa-gentle-wait] slow wait_any: %.2f s (would have spun a core)\n",
                            (now_ns() - start) / 1e9);
                return i;
            }
        }
        uint64_t t = now_ns();
        if (timeout != UINT64_MAX && (t - start) >= timeout) {
            if (satisfying_value) *satisfying_value = 0;
            return n;
        }
        if (t < yield_until) sched_yield(); else nap(&snap);
    }
}

uint32_t hsa_amd_signal_wait_all(uint32_t n, hsa_signal_t *sigs, hsa_signal_condition_t *conds,
        hsa_signal_value_t *vals, uint64_t timeout, hsa_wait_state_t ws,
        hsa_signal_value_t *satisfying_values) {
    init_once();
    if (!g_enabled) {
        static uint32_t (*real)(uint32_t, hsa_signal_t*, hsa_signal_condition_t*,
                hsa_signal_value_t*, uint64_t, hsa_wait_state_t, hsa_signal_value_t*) = NULL;
        if (!real) real = dlsym(RTLD_NEXT, "hsa_amd_signal_wait_all");
        return real(n, sigs, conds, vals, timeout, ws, satisfying_values);
    }
    (void)ws;
    uint64_t start = now_ns(), yield_until = start + YIELD_SPIN_NS;
    long snap = 0;
    for (;;) {
        int all = 1;
        for (uint32_t i = 0; i < n; i++) {
            hsa_signal_value_t v = real_load(sigs[i]);
            if (satisfying_values) satisfying_values[i] = v;
            if (!sat(v, conds[i], vals[i])) all = 0;
        }
        if (all) {
            if (g_log && now_ns() - start > 300000000ull)
                fprintf(stderr, "[hsa-gentle-wait] slow wait_all: %.2f s (would have spun a core)\n",
                        (now_ns() - start) / 1e9);
            return 0;
        }
        uint64_t t = now_ns();
        if (timeout != UINT64_MAX && (t - start) >= timeout) return n;
        if (t < yield_until) sched_yield(); else nap(&snap);
    }
}
