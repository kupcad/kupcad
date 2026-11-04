#include <manifold/manifoldc.h>
#include <cstddef>

#if KUPCAD_TBB
#include <memory>
#include <new>
#include <tbb/global_control.h>
#endif
#if KUPCAD_TBB && !defined(_WIN32)
#include <pthread.h>
#endif

// Reason why we have this method here
// The Zig compiler incorrectly calculates register exhaustion when calling C functions with a large number of mixed arguments (specifically floating-point values and structs). Instead of utilizing remaining available hardware registers, Zig prematurely spills the arguments onto the stack. When the C++ function pops them off expecting the strict x86_64 System V ABI layout, the memory offsets are misaligned, causing the values to scramble or merge with adjacent variables
// More info: https://github.com/ziglang/zig/issues/22515

extern "C" {
    // Whether this C++ was compiled with its asserts: only Debug builds are (build.zig's
    // cxxFlags adds -DNDEBUG otherwise, for Manifold, Draco and these bindings).
    bool kupcad_cpp_asserts_enabled() {
#ifdef NDEBUG
        return false;
#else
        return true;
#endif
    }

    // Caps the threads Manifold's parallel algorithms (oneTBB's) may use; 0 lifts the cap.
    // Without oneTBB (wasm, -Dmanifold_parallel=false) everything runs on one thread anyway.
    void kupcad_set_max_threads(size_t threads) {
#if KUPCAD_TBB
        static std::unique_ptr<tbb::global_control> control;
        control.reset();
        if (threads > 0) control = std::make_unique<tbb::global_control>(tbb::global_control::max_allowed_parallelism, threads);
#else
        (void)threads;
#endif
    }

#if KUPCAD_TBB && !defined(_WIN32)
    // oneTBB's worker threads don't survive a fork: the child has none of them, and the first
    // parallel algorithm there woke threads that weren't there (it trapped). So they end before
    // the fork, and each process starts its own when it next needs them. With a build running
    // on another thread then, finalize can't end them, and leaves them.
    static void kupcad_end_workers() {
        tbb::task_scheduler_handle handle{tbb::attach{}};
        tbb::finalize(handle, std::nothrow);
    }

    static void kupcad_end_workers_at_fork() {
        pthread_atfork(kupcad_end_workers, nullptr, nullptr);
    }
#endif

    // Ends oneTBB's worker threads before every fork of the process from now on, for a host
    // that loads libkupcad and may fork (a preforking web server); once, however often called.
    // Not the CLI's: it never forks with workers it needs to keep.
    void kupcad_end_workers_before_fork() {
#if KUPCAD_TBB && !defined(_WIN32)
        static pthread_once_t once = PTHREAD_ONCE_INIT;
        pthread_once(&once, kupcad_end_workers_at_fork);
#endif
    }

    // Passes the 12-element matrix as a single pointer to bypass ABI register exhaustion
    ManifoldManifold* manifold_transform_array(void* mem, ManifoldManifold* m, const double* mat) {
        return manifold_transform(mem, m,
            mat[0], mat[1], mat[2],
            mat[3], mat[4], mat[5],
            mat[6], mat[7], mat[8],
            mat[9], mat[10], mat[11]);
    }
}
