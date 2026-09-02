#ifndef DRACO_C_H
#define DRACO_C_H

#include <stddef.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

// Flat C struct to hold the encoded byte buffer and its size
typedef struct {
    const uint8_t* data;
    size_t size;
} DracoEncodedBuffer;

// C-compatible wrapper around draco::Encoder
DracoEncodedBuffer draco_encode_mesh(
    const float* positions,
    size_t num_vertices,
    const uint32_t* indices,
    size_t num_indices,
    int pos_quantization_bits
);

// Frees the memory allocated by draco_encode_mesh
void draco_free_buffer(DracoEncodedBuffer buf);

#ifdef __cplusplus
}
#endif

#endif // DRACO_C_H
