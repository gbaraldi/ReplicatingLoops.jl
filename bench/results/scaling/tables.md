### nthreads default=8 interactive=1 caller pool=interactive julia=1.13.0; nthreads default=8 interactive=1 caller pool=interactive julia=1.13.0; oneTBB 2022.0 threads=9

| workload | n | serial | `@threads` | Polyester | OhMyThreads | C++ serial | oneTBB | oneTBB affinity | `pforeach` |
|---|---|---|---|---|---|---|---|---|---|
| axpy | 1000 | 91 ns | 23.0 µs | 2.29 µs | 26.8 µs | 140 ns | 22.1 µs | 27.7 µs | **728 ns** |
| axpy | 10000 | 1.56 µs | 25.8 µs | **2.5 µs** | 23.3 µs | 1.62 µs | 38.2 µs | 35.5 µs | 2.6 µs |
| axpy | 100000 | 18.9 µs | 28.7 µs | **9.64 µs** | 30.2 µs | 22.1 µs | 50.4 µs | 42.8 µs | 22.6 µs |
| axpy | 1000000 | 205.0 µs | 86.6 µs | 80.8 µs | 93.3 µs | 223.0 µs | 116.0 µs | 80.5 µs | **46.0 µs** |
| axpy | 10000000 | 3.57 ms | 1.17 ms | 778.0 µs | 1.17 ms | 3.66 ms | 1.31 ms | 474.0 µs | **320.0 µs** |
| axpy_cold | 10000 | 1.69 µs | 25.1 µs | **2.63 µs** | 27.2 µs | 1.73 µs | 50.4 µs | 64.3 µs | 2.82 µs |
| axpy_cold | 1000000 | 215.0 µs | 112.0 µs | 80.3 µs | 131.0 µs | 203.0 µs | 130.0 µs | 102.0 µs | **62.1 µs** |
| tri | 30 | 2.46 µs | 21.1 µs | **2.48 µs** | 22.5 µs | 3.95 µs | 9.13 µs | 11.5 µs | 3.14 µs |
| tri | 300 | 287.0 µs | 87.5 µs | 68.7 µs | 91.6 µs | 462.0 µs | 75.6 µs | 76.8 µs | **60.1 µs** |
| tri | 3000 | 37.3 ms | 9.65 ms | 9.58 ms | 6.93 ms | 61.0 ms | 6.84 ms | 6.83 ms | **4.17 ms** |

### nthreads default=32 interactive=1 caller pool=interactive julia=1.13.0; nthreads default=32 interactive=1 caller pool=interactive julia=1.13.0; oneTBB 2022.0 threads=33

| workload | n | serial | `@threads` | Polyester | OhMyThreads | C++ serial | oneTBB | oneTBB affinity | `pforeach` |
|---|---|---|---|---|---|---|---|---|---|
| axpy | 1000 | 91 ns | 168.0 µs | 7.4 µs | 161.0 µs | 142 ns | 19.7 µs | 24.2 µs | **732 ns** |
| axpy | 10000 | 1.54 µs | 188.0 µs | 6.85 µs | 157.0 µs | 1.63 µs | 30.3 µs | 28.4 µs | **2.6 µs** |
| axpy | 100000 | 18.8 µs | 191.0 µs | **8.17 µs** | 155.0 µs | 22.3 µs | 38.1 µs | 33.4 µs | 22.5 µs |
| axpy | 1000000 | 204.0 µs | 174.0 µs | **17.7 µs** | 186.0 µs | 221.0 µs | 84.4 µs | 51.6 µs | 46.9 µs |
| axpy | 10000000 | 4.03 ms | 1.08 ms | 123.0 µs | 932.0 µs | 3.7 ms | 1.39 ms | 288.0 µs | **112.0 µs** |
| axpy_cold | 10000 | 1.7 µs | 101.0 µs | 6.72 µs | 90.8 µs | 1.74 µs | 57.6 µs | 73.5 µs | **2.9 µs** |
| axpy_cold | 1000000 | 211.0 µs | 118.0 µs | **18.4 µs** | 126.0 µs | 204.0 µs | 115.0 µs | 98.5 µs | 71.0 µs |
| tri | 30 | 2.46 µs | 158.0 µs | 6.76 µs | 149.0 µs | 3.93 µs | 11.5 µs | 16.9 µs | **3.14 µs** |
| tri | 300 | 288.0 µs | 172.0 µs | **24.4 µs** | 177.0 µs | 462.0 µs | 37.5 µs | 39.0 µs | 60.3 µs |
| tri | 3000 | 37.3 ms | 3.56 ms | 2.43 ms | 1.96 ms | 61.2 ms | 1.91 ms | 1.9 ms | **1.26 ms** |

### nthreads default=63 interactive=1 caller pool=interactive julia=1.13.0; nthreads default=63 interactive=1 caller pool=interactive julia=1.13.0; oneTBB 2022.0 threads=64

| workload | n | serial | `@threads` | Polyester | OhMyThreads | C++ serial | oneTBB | oneTBB affinity | `pforeach` |
|---|---|---|---|---|---|---|---|---|---|
| axpy | 1000 | 91 ns | 532.0 µs | 2.99 ms | 525.0 µs | 142 ns | 20.3 µs | 26.0 µs | **873 ns** |
| axpy | 10000 | 1.54 µs | 588.0 µs | 2.02 ms | 505.0 µs | 1.62 µs | 31.1 µs | 34.6 µs | **2.63 µs** |
| axpy | 100000 | 18.9 µs | 504.0 µs | 2.39 ms | 504.0 µs | 22.2 µs | 35.1 µs | 37.9 µs | **22.8 µs** |
| axpy | 1000000 | 204.0 µs | 479.0 µs | 2.69 ms | 396.0 µs | 222.0 µs | 81.8 µs | **55.1 µs** | 99.5 µs |
| axpy | 10000000 | 4.06 ms | 1.26 ms | 5.99 ms | 1.29 ms | 3.76 ms | 1.45 ms | 244.0 µs | **141.0 µs** |
| axpy_cold | 10000 | 1.69 µs | 225.0 µs | 1.95 ms | 219.0 µs | 1.73 µs | 52.9 µs | 89.2 µs | **2.97 µs** |
| axpy_cold | 1000000 | 214.0 µs | 228.0 µs | 1.96 ms | 276.0 µs | 201.0 µs | 119.0 µs | 111.0 µs | **91.3 µs** |
| tri | 30 | 2.46 µs | 539.0 µs | 6.96 µs | 181.0 µs | 3.94 µs | 16.0 µs | 28.2 µs | **3.16 µs** |
| tri | 300 | 288.0 µs | 466.0 µs | 2.99 ms | 554.0 µs | 463.0 µs | 33.1 µs | **32.6 µs** | 75.5 µs |
| tri | 3000 | 37.2 ms | 2.19 ms | 2.92 ms | 1.49 ms | 61.1 ms | 1.13 ms | 1.12 ms | **710.0 µs** |

