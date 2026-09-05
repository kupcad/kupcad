#include <cstddef>

#if MANIFOLD_PAR == 1
#include <tbb/parallel_for.h>
#include <tbb/blocked_range.h>
#endif

extern "C" {

typedef void (*LocusParallelFunc)(size_t, void*);

// The C-ABI boundary expected by src/parallel.zig
void locus_parallel_for(size_t start, size_t end, LocusParallelFunc func, void* ctx) {
#if MANIFOLD_PAR == 1
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

} // extern "C"
