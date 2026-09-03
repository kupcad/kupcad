#include <Eigen/Dense>

extern "C" {
    double locus_eigen_det3(const double* mat) {
        // Eigen defaults to column-major, but since we are taking the determinant,
        // det(A) == det(A^T), so memory layout order does not affect the result.
        Eigen::Map<const Eigen::Matrix3d> m(mat);
        return m.determinant();
    }

    double locus_eigen_det4(const double* mat) {
        Eigen::Map<const Eigen::Matrix4d> m(mat);
        return m.determinant();
    }

    void locus_eigen_pca_normal(const double* pts, int num_pts, double* out_normal) {
        if (num_pts < 3) {
            out_normal[0] = 0.0; out_normal[1] = 0.0; out_normal[2] = 1.0;
            return;
        }

        // Map the flat double array to a 3xN Eigen matrix
        Eigen::Map<const Eigen::Matrix<double, 3, Eigen::Dynamic>> P(pts, 3, num_pts);

        // Calculate the centroid and center the point cloud
        Eigen::Vector3d centroid = P.rowwise().mean();
        Eigen::Matrix<double, 3, Eigen::Dynamic> centered = P.colwise() - centroid;

        // Perform Singular Value Decomposition (SVD)
        Eigen::JacobiSVD<Eigen::MatrixXd> svd(centered, Eigen::ComputeThinU);

        // The normal of the best-fit plane is the least principal component (last column of U)
        Eigen::Vector3d normal = svd.matrixU().col(2);

        out_normal[0] = normal.x();
        out_normal[1] = normal.y();
        out_normal[2] = normal.z();
    }
}
