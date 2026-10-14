// 1M-element axpy under oneTBB, back to back and after 2 ms and 50 ms idle.
//   axpy1m_tbb <nthreads>   prints: impl,mode,us,speedup
#include <oneapi/tbb/blocked_range.h>
#include <oneapi/tbb/global_control.h>
#include <oneapi/tbb/parallel_for.h>
#include <oneapi/tbb/partitioner.h>
#include <chrono>
#include <cmath>
#include <cstdio>
#include <cstdlib>
#include <ctime>
#include <random>
#include <vector>
using clk = std::chrono::steady_clock;
static double now_s() { return std::chrono::duration<double>(clk::now().time_since_epoch()).count(); }
template <class F> static double hot(F f) {
    for (double t0 = now_s(); now_s() - t0 < 0.5;) f();
    double best = 1e30;
    for (int r = 0; r < 7; r++) {
        long n = 0; double t = now_s();
        while (now_s() - t < 0.02) { f(); n++; }
        double m = (now_s() - t) / n; if (m < best) best = m;
    }
    return best * 1e6;
}
template <class F> static double gap(F f, long ns, int reps) {
    for (double t0 = now_s(); now_s() - t0 < 0.3;) f();
    double best = 1e30;
    for (int r = 0; r < reps; r++) {
        timespec ts{ns / 1000000000L, ns % 1000000000L}; nanosleep(&ts, nullptr);
        double t = now_s(); f(); double d = (now_s() - t) * 1e6; if (d < best) best = d;
    }
    return best;
}
int main(int argc, char **argv) {
    int nt = std::atoi(argv[1]);
    tbb::global_control gc(tbb::global_control::max_allowed_parallelism, nt);
    size_t n = 1000000;
    std::vector<double> y(n), x(n);
    std::mt19937_64 rng(1); std::uniform_real_distribution<double> u(0, 1);
    for (auto &e : y) e = u(rng); for (auto &e : x) e = u(rng);
    double *yp = y.data(); const double *xp = x.data();
    auto body = [&](const tbb::blocked_range<size_t> &r) { for (size_t i = r.begin(); i < r.end(); i++) yp[i] = std::fma(1.0001, xp[i], yp[i]); };
    double ser = hot([&] { body(tbb::blocked_range<size_t>(0, n)); });
    tbb::affinity_partitioner ap;
    auto plain = [&] { tbb::parallel_for(tbb::blocked_range<size_t>(0, n), body); };
    auto aff = [&] { tbb::parallel_for(tbb::blocked_range<size_t>(0, n), body, ap); };
    const char *names[2] = {"oneTBB", "oneTBB affinity"};
    for (int k = 0; k < 2; k++) {
        double h = k ? hot(aff) : hot(plain);
        double g2 = k ? gap(aff, 2000000, 200) : gap(plain, 2000000, 200);
        double g50 = k ? gap(aff, 50000000, 40) : gap(plain, 50000000, 40);
        std::printf("%s,back to back,%.1f,%.3g\n%s,after 2 ms idle,%.1f,%.3g\n%s,after 50 ms idle,%.1f,%.3g\n",
                    names[k], h, ser / h, names[k], g2, ser / g2, names[k], g50, ser / g50);
    }
}
