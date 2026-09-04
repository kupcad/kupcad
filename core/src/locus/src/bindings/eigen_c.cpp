#include <Eigen/Dense>
#include <unsupported/Eigen/NonLinearOptimization>
#include <unsupported/Eigen/NumericalDiff>

extern "C" {
    typedef int (*LocusResidualFunc)(const double* x, double* fvec, void* user_data);

    // Adapter bridging Eigen's generic functor requirement to our C function pointer
    struct LocusFunctor {
        // Eigen Functor Requirements
        typedef double Scalar;
        enum {
            InputsAtCompileTime = Eigen::Dynamic,
            ValuesAtCompileTime = Eigen::Dynamic
        };
        typedef Eigen::Matrix<Scalar, InputsAtCompileTime, 1> InputType;
        typedef Eigen::Matrix<Scalar, ValuesAtCompileTime, 1> ValueType;
        typedef Eigen::Matrix<Scalar, ValuesAtCompileTime, InputsAtCompileTime> JacobianType;

        int m_inputs, m_values;
        LocusResidualFunc m_func;
        void* m_user_data;

        LocusFunctor(int inputs, int values, LocusResidualFunc func, void* user_data)
            : m_inputs(inputs), m_values(values), m_func(func), m_user_data(user_data) {}

        // Computes the residuals. The NumericalDiff wrapper uses this to calculate Jacobians.
        int operator()(const InputType &x, ValueType &fvec) const {
            return m_func(x.data(), fvec.data(), m_user_data);
        }

        int inputs() const { return m_inputs; }
        int values() const { return m_values; }
    };

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

    int eigen_lm_solve(
        int num_unknowns,
        int num_residuals,
        LocusResidualFunc func,
        void* user_data,
        double* x_in_out,
        double tol,
        int max_fev
    ) {
        LocusFunctor functor(num_unknowns, num_residuals, func, user_data);
        Eigen::NumericalDiff<LocusFunctor> numDiff(functor);
        Eigen::LevenbergMarquardt<Eigen::NumericalDiff<LocusFunctor>, double> lm(numDiff);

        lm.parameters.ftol = tol;
        lm.parameters.xtol = tol;
        lm.parameters.maxfev = max_fev;

        Eigen::VectorXd x = Eigen::Map<Eigen::VectorXd>(x_in_out, num_unknowns);
        int info = lm.minimize(x);

        // Map result back to raw C array
        Eigen::Map<Eigen::VectorXd>(x_in_out, num_unknowns) = x;
        return info;
    }
}
