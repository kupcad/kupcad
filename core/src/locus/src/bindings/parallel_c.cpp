#include <stddef.h>

#if MANIFOLD_PAR == 1
#include <tbb/parallel_for.h>
#endif

extern "C" {
    void locus_parallel_for(size_t start, size_t end, void (*func)(size_t, void*), void* ctx) {
#if MANIFOLD_PAR == 1
        tbb::parallel_for(start, end, [=](size_t i) {
            func(i, ctx);
        });
#else
        for (size_t i = start; i < end; ++i) {
            func(i, ctx);
        }
#endif
    }
}
