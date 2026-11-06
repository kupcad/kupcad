#include <cstddef>

// KUPCAD_TBB: the build has oneTBB, so the loop runs on its threads. Without it
// (WebAssembly, or a build with -Dmanifold_parallel=false) the indices run in order on the
// calling thread.
#if defined(KUPCAD_TBB)
#include <tbb/parallel_for.h>
#include <tbb/blocked_range.h>
#include <tbb/info.h>
#endif

extern "C" {

typedef void (*KupcadParallelBody)(size_t, void*);

// The C-ABI boundary src/bindings/parallel.zig expects: `body(i, ctx)` for each i in
// [start, end), on oneTBB's threads when built with it.
void kupcad_parallel_for(size_t start, size_t end, KupcadParallelBody body, void* ctx) {
#if defined(KUPCAD_TBB)
    tbb::parallel_for(tbb::blocked_range<size_t>(start, end),
        [=](const tbb::blocked_range<size_t>& r) {
            for (size_t i = r.begin(); i != r.end(); ++i) body(i, ctx);
        }
    );
#else
    for (size_t i = start; i < end; ++i) body(i, ctx);
#endif
}

// How many threads kupcad_parallel_for may use: oneTBB's default concurrency, or 1.
size_t kupcad_parallel_threads(void) {
#if defined(KUPCAD_TBB)
    int n = tbb::info::default_concurrency();
    return n > 0 ? (size_t)n : 1;
#else
    return 1;
#endif
}

} // extern "C"
