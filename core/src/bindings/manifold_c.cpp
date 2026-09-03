#include <manifold/manifoldc.h>

// Reason why we have this method here
// The Zig compiler incorrectly calculates register exhaustion when calling C functions with a large number of mixed arguments (specifically floating-point values and structs). Instead of utilizing remaining available hardware registers, Zig prematurely spills the arguments onto the stack. When the C++ function pops them off expecting the strict x86_64 System V ABI layout, the memory offsets are misaligned, causing the values to scramble or merge with adjacent variables
// More info: https://github.com/ziglang/zig/issues/22515

extern "C" {
    // Passes the 12-element matrix as a single pointer to bypass ABI register exhaustion
    ManifoldManifold* manifold_transform_array(void* mem, ManifoldManifold* m, const double* mat) {
        return manifold_transform(mem, m,
            mat[0], mat[1], mat[2],
            mat[3], mat[4], mat[5],
            mat[6], mat[7], mat[8],
            mat[9], mat[10], mat[11]);
    }
}
