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

// A decoded mesh: positions (3 floats per point) and triangle indices, malloc'd
typedef struct {
    float* positions;
    size_t num_vertices;
    uint32_t* indices;
    size_t num_indices;
} DracoDecodedMesh;

// Decodes a Draco mesh buffer into `out`; returns 0 on success. Used to read exports back
int draco_decode_mesh(const uint8_t* data, size_t size, DracoDecodedMesh* out);

// Frees the memory allocated by draco_decode_mesh
void draco_free_decoded_mesh(DracoDecodedMesh* mesh);

#ifdef __cplusplus
}
#endif

#endif // DRACO_C_H
