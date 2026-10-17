#include <cstddef>

// LOCUS_TBB: the build has oneTBB, so the loop runs on its threads. Without it (WebAssembly,
// or a build with -Dmanifold_parallel=false) the indices run in order on the calling thread.
#if defined(LOCUS_TBB)
#include <tbb/parallel_for.h>
#include <tbb/blocked_range.h>
#endif

extern "C" {

typedef void (*LocusParallelFunc)(size_t, void*);

// The C-ABI boundary expected by src/parallel.zig
void locus_parallel_for(size_t start, size_t end, LocusParallelFunc func, void* ctx) {
#if defined(LOCUS_TBB)
    tbb::parallel_for(tbb::blocked_range<size_t>(start, end),
        [=](const tbb::blocked_range<size_t>& r) {
            for (size_t i = r.begin(); i != r.end(); ++i) {
                // Call back into Zig's compiled logic
                func(i, ctx);
            }
        }
    );
#else
    for (size_t i = start; i < end; ++i) {
        func(i, ctx);
    }
#endif
}

// Whether locus_parallel_for spreads its work over threads.
bool locus_parallel_threads(void) {
#if defined(LOCUS_TBB)
    return true;
#else
    return false;
#endif
}

} // extern "C"
