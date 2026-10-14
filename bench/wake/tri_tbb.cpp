// Triangle loop (element i sums i sines) under oneTBB, with threads awake
// (loops back to back) and asleep (2 ms pause before each loop).
//   tri_tbb <nthreads> <n>   prints: oneTBB,<nthreads>,<n>,serial_us,awake_us,asleep_us
#include <oneapi/tbb/blocked_range.h>
#include <oneapi/tbb/global_control.h>
#include <oneapi/tbb/parallel_for.h>
#include <chrono>
#include <cmath>
#include <cstdio>
#include <cstdlib>
#include <ctime>
#include <vector>
using clk = std::chrono::steady_clock;
static void tri(double *out, size_t lo, size_t hi) {
    for (size_t i = lo; i < hi; i++) {
        double s = 0.0;
        for (size_t j = 1; j <= i + 1; j++) s += std::sin(j * 1e-3);
        out[i] = s;
    }
}
int main(int argc, char **argv) {
    int nt = std::atoi(argv[1]);
    size_t n = std::atol(argv[2]);
    tbb::global_control gc(tbb::global_control::max_allowed_parallelism, nt);
    std::vector<double> out(n);
    auto run = [&] { tbb::parallel_for(tbb::blocked_range<size_t>(0, n), [&](auto &r) { tri(out.data(), r.begin(), r.end()); }); };
    auto ns = [&] { auto t = clk::now(); run(); return std::chrono::duration<double, std::nano>(clk::now() - t).count(); };
    // Serial first, after 0.3 s of warm-up, so the core runs at full clock:
    // timed right after the 2 ms pauses below, a short loop finishes before
    // the frequency governor has raised the clock again.
    double awake = 1e30, asleep = 1e30, ser = 1e30;
    auto serial_ns = [&] {
        auto t = clk::now(); tri(out.data(), 0, n);
        return std::chrono::duration<double, std::nano>(clk::now() - t).count();
    };
    for (auto t0 = clk::now(); clk::now() - t0 < std::chrono::milliseconds(300);) serial_ns();
    for (int i = 0; i < 50; i++) { double d = serial_ns(); if (d < ser) ser = d; }
    for (int i = 0; i < 2000; i++) run();
    for (int i = 0; i < 300; i++) { double t = ns(); if (t < awake) awake = t; }
    for (int i = 0; i < 200; i++) { timespec ts{0, 2000000}; nanosleep(&ts, nullptr); double t = ns(); if (t < asleep) asleep = t; }
    std::printf("oneTBB,%d,%zu,%.1f,%.1f,%.1f\n", nt, n, ser / 1e3, awake / 1e3, asleep / 1e3);
}
