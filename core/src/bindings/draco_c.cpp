#include "draco_c.h"
#include "draco/compression/encode.h"
#include "draco/mesh/mesh.h"
#include <cstdlib>
#include <cstring>

// --- Draco Configuration Constants ---
constexpr int kDracoEncodingSpeed = 5; // 0 (Slowest/Best) to 10 (Fastest/Worst)
constexpr int kDracoDecodingSpeed = 5; // 0 (Slowest/Best) to 10 (Fastest/Worst)
constexpr int kVerticesPerFace = 3;    // Triangles
constexpr int kPositionDimensions = 3; // X, Y, Z

extern "C" {

DracoEncodedBuffer draco_encode_mesh(
    const float* positions,
    size_t num_vertices,
    const uint32_t* indices,
    size_t num_indices,
    int pos_quantization_bits
) {
    draco::Mesh mesh;

    // 1. Add POSITION attribute
    draco::PointAttribute att;
    att.Init(draco::GeometryAttribute::POSITION, kPositionDimensions, draco::DT_FLOAT32, false, num_vertices);
    int att_id = mesh.AddAttribute(att, true, num_vertices);

    for (size_t i = 0; i < num_vertices; ++i) {
        mesh.attribute(att_id)->SetAttributeValue(draco::AttributeValueIndex(i), positions + (i * kPositionDimensions));
    }
    mesh.set_num_points(num_vertices);

    // 2. Add Face Indices
    size_t num_faces = num_indices / kVerticesPerFace;
    mesh.SetNumFaces(num_faces);
    for (size_t i = 0; i < num_faces; ++i) {
        draco::Mesh::Face face;
        face[0] = draco::PointIndex(indices[i * kVerticesPerFace + 0]);
        face[1] = draco::PointIndex(indices[i * kVerticesPerFace + 1]);
        face[2] = draco::PointIndex(indices[i * kVerticesPerFace + 2]);
        mesh.SetFace(draco::FaceIndex(i), face);
    }

    // 3. Encode Mesh
    draco::Encoder encoder;
    if (pos_quantization_bits > 0) {
        encoder.SetAttributeQuantization(draco::GeometryAttribute::POSITION, pos_quantization_bits);
    }
    encoder.SetSpeedOptions(kDracoEncodingSpeed, kDracoDecodingSpeed);

    draco::EncoderBuffer buffer;
    draco::Status status = encoder.EncodeMeshToBuffer(mesh, &buffer);

    if (!status.ok()) {
        return { nullptr, 0 };
    }

    uint8_t* out_data = static_cast<uint8_t*>(malloc(buffer.size()));
    if (!out_data) return { nullptr, 0 };

    memcpy(out_data, buffer.data(), buffer.size());

    return { out_data, buffer.size() };
}

void draco_free_buffer(DracoEncodedBuffer buf) {
    if (buf.data) {
        free(const_cast<uint8_t*>(buf.data));
    }
}

}
