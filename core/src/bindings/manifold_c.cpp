#include <manifold/manifoldc.h>

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
