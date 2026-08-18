#ifndef KUPCAD_WASM_STUBS_H
#define KUPCAD_WASM_STUBS_H

#include <memory>

namespace std {

struct mutex {
    constexpr mutex() noexcept = default;
    ~mutex() = default;
    mutex(const mutex&) = delete;
    mutex& operator=(const mutex&) = delete;

    void lock() {}
    bool try_lock() { return true; }
    void unlock() {}
};

struct recursive_mutex {
    constexpr recursive_mutex() noexcept = default;
    ~recursive_mutex() = default;
    recursive_mutex(const recursive_mutex&) = delete;
    recursive_mutex& operator=(const recursive_mutex&) = delete;

    void lock() {}
    bool try_lock() { return true; }
    void unlock() {}
};

template <typename... MutexTypes>
struct scoped_lock {
    explicit scoped_lock(MutexTypes&...) {}
    ~scoped_lock() = default;
    scoped_lock(const scoped_lock&) = delete;
    scoped_lock& operator=(const scoped_lock&) = delete;
};

template <typename... MutexTypes>
scoped_lock(MutexTypes&...) -> scoped_lock<MutexTypes...>;

template <typename T>
inline std::shared_ptr<T> atomic_load(const std::shared_ptr<T>* p) {
    return *p;
}

template <typename T>
inline void atomic_store(std::shared_ptr<T>* p, std::shared_ptr<T> r) {
    *p = r;
}

} // namespace std

#endif // KUPCAD_WASM_STUBS_H

extern "C" {
    // Safely ignore thread-local destructors in single-threaded WASM
    inline int __cxa_thread_atexit(void (*func)(void*), void* arg, void* dso_handle) {
        return 0;
    }
}
