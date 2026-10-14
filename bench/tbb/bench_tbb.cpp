// oneTBB version of bench/bench.jl: same workloads, sizes and timing method.
//
//   bench_tbb <nthreads> [impl...]
//
// impl is serial, tbb (parallel_for with the default auto_partitioner),
// tbb_affinity (a persistent affinity_partitioner per workload, which replays
// the previous loop's chunk-to-thread mapping) or tbb_static. Prints
// `RESULT <workload> <impl> <size> <ns>` like bench.jl.
#include <oneapi/tbb/blocked_range.h>
#include <oneapi/tbb/global_control.h>
#include <oneapi/tbb/parallel_for.h>
#include <oneapi/tbb/partitioner.h>

#include <chrono>
#include <cmath>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <ctime>
#include <random>
#include <string>
#include <vector>

using clk = std::chrono::steady_clock;

static double now_s() {
    return std::chrono::duration<double>(clk::now().time_since_epoch()).count();
}

// Best mean time per call over 7 batches of at least 2 ms, after 0.3 s warmup.
template <class F> static double bench_ns(F f) {
    for (double t0 = now_s(); now_s() - t0 < 0.3;) f();
    long inner = 1;
    double t = now_s();
    f();
    t = now_s() - t;
    while (t < 2e-3) {  // t is the time of the whole batch of `inner` calls
        inner *= 2;
        t = now_s();
        for (long i = 0; i < inner; i++) f();
        t = now_s() - t;
    }
    double best = 1e30;
    for (int rep = 0; rep < 7; rep++) {
        t = now_s();
        for (long i = 0; i < inner; i++) f();
        t = now_s() - t;
        if (t / inner < best) best = t / inner;
    }
    return best * 1e9;
}

// Best single call after sleeping 2 ms, so idle threads have gone to sleep.
template <class F> static double cold_ns(F f) {
    for (double t0 = now_s(); now_s() - t0 < 0.3;) f();
    double best = 1e30;
    for (int rep = 0; rep < 200; rep++) {
        timespec ts{0, 2000000};
        nanosleep(&ts, nullptr);
        auto t = clk::now();
        f();
        double ns = std::chrono::duration<double, std::nano>(clk::now() - t).count();
        if (ns < best) best = ns;
    }
    return best;
}

static void result(const char *w, const std::string &impl, long n, double ns) {
    std::printf("RESULT %s %s %ld %ld\n", w, impl.c_str(), n, std::lround(ns));
    std::fflush(stdout);
}

static inline void axpy_range(double *y, const double *x, double a, size_t lo, size_t hi) {
    for (size_t i = lo; i < hi; i++) y[i] = std::fma(a, x[i], y[i]);
}

static inline void tri_range(double *out, size_t lo, size_t hi) {
    for (size_t i = lo; i < hi; i++) {  // element i (0-based) is Julia's i+1
        double s = 0.0;
        for (size_t j = 1; j <= i + 1; j++) s += std::sin(j * 1e-3);
        out[i] = s;
    }
}

// Run body(lo, hi) over [0, n) with the chosen implementation.
template <class B>
static void run(const std::string &impl, size_t n, tbb::affinity_partitioner &ap, B body) {
    using R = tbb::blocked_range<size_t>;
    auto f = [&](const R &r) { body(r.begin(), r.end()); };
    if (impl == "serial")
        body(0, n);
    else if (impl == "tbb")
        tbb::parallel_for(R(0, n), f);
    else if (impl == "tbb_affinity")
        tbb::parallel_for(R(0, n), f, ap);
    else if (impl == "tbb_static")
        tbb::parallel_for(R(0, n), f, tbb::static_partitioner());
    else {
        std::fprintf(stderr, "unknown impl %s\n", impl.c_str());
        std::exit(1);
    }
}

static std::vector<double> rand_vec(size_t n, std::mt19937_64 &rng) {
    std::uniform_real_distribution<double> u(0.0, 1.0);
    std::vector<double> v(n);
    for (auto &e : v) e = u(rng);
    return v;
}

int main(int argc, char **argv) {
    if (argc < 2) {
        std::fprintf(stderr, "usage: %s nthreads [impl...]\n", argv[0]);
        return 1;
    }
    int nt = std::atoi(argv[1]);
    tbb::global_control gc(tbb::global_control::max_allowed_parallelism, nt);
    std::vector<std::string> impls;
    for (int i = 2; i < argc; i++) impls.push_back(argv[i]);
    if (impls.empty()) impls = {"serial", "tbb", "tbb_affinity", "tbb_static"};
    std::printf("# oneTBB %d.%d threads=%d\n", TBB_VERSION_MAJOR, TBB_VERSION_MINOR, nt);

    std::mt19937_64 rng(1);
    for (auto &impl : impls) {
        for (long n : {1000L, 10000L, 100000L, 1000000L, 10000000L}) {
            auto y = rand_vec(n, rng), x = rand_vec(n, rng);
            tbb::affinity_partitioner ap;
            double *yp = y.data();
            const double *xp = x.data();
            result("axpy", impl, n, bench_ns([&] {
                       run(impl, n, ap, [&](size_t lo, size_t hi) { axpy_range(yp, xp, 1.0001, lo, hi); });
                   }));
        }
        for (long n : {10000L, 1000000L}) {
            auto y = rand_vec(n, rng), x = rand_vec(n, rng);
            tbb::affinity_partitioner ap;
            double *yp = y.data();
            const double *xp = x.data();
            result("axpy_cold", impl, n, cold_ns([&] {
                       run(impl, n, ap, [&](size_t lo, size_t hi) { axpy_range(yp, xp, 1.0001, lo, hi); });
                   }));
        }
        for (long n : {30L, 300L, 3000L}) {
            std::vector<double> out(n);
            tbb::affinity_partitioner ap;
            double *op = out.data();
            result("tri", impl, n, bench_ns([&] {
                       run(impl, n, ap, [&](size_t lo, size_t hi) { tri_range(op, lo, hi); });
                   }));
        }
    }
    return 0;
}
