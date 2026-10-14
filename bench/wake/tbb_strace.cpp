// A few cold triangle loops under oneTBB, with a marker write before each.
#include <oneapi/tbb/blocked_range.h>
#include <oneapi/tbb/global_control.h>
#include <oneapi/tbb/parallel_for.h>
#include <cmath>
#include <cstdlib>
#include <ctime>
#include <unistd.h>
#include <vector>
static void tri(double *out, size_t lo, size_t hi) {
    for (size_t i = lo; i < hi; i++) { double s = 0; for (size_t j = 1; j <= i + 1; j++) s += std::sin(j * 1e-3); out[i] = s; }
}
int main(int argc, char **argv) {
    int nt = std::atoi(argv[1]);
    tbb::global_control gc(tbb::global_control::max_allowed_parallelism, nt);
    std::vector<double> out(300);
    auto run = [&] { tbb::parallel_for(tbb::blocked_range<size_t>(0, 300), [&](auto &r) { tri(out.data(), r.begin(), r.end()); }); };
    for (int i = 0; i < 50; i++) run();
    for (int k = 0; k < 4; k++) {
        timespec ts{0, 20000000}; nanosleep(&ts, nullptr);   // 20 ms: everyone asleep
        write(2, "MARK\n", 5);
        run();
        write(2, "DONE\n", 5);
    }
}
