#include <cuda.h>

extern "C" {

__global__ void computeRHS(const double *f_local_d,
                        double *rhs_d,
                        double dx,
                        int mx,
                        int npx)
{
    /*
    Computes the RHS for solving for the x-derivative
    of a function f. f_local is the "local" part of
    the function which includes ghost points.

    dx is the spacing.

    nx, ny, nz define the size of d. f_local is shaped
    [nz+2, ny+2, nx+2]

    mx and npx together decide if we are evaluating
    at a boundary.
    */

    int ix = blockIdx.x*blockDim.x + threadIdx.x;
    int iy = blockIdx.y*blockDim.y + threadIdx.y;
    int iz = blockIdx.z*blockDim.z + threadIdx.z;
    int nx = gridDim.x*blockDim.x;
    int ny = gridDim.y*blockDim.y;
    int nz = gridDim.z*blockDim.z;

    int i = iz*(nx*ny) + iy*nx + ix;
    int iloc = (iz+1)*((nx+2)*(ny+2)) + (iy+1)*(nx+2) + (ix+1);

    rhs_d[i] = (3./(4*dx))*(f_local_d[iloc+1] - f_local_d[iloc-1]);

    if (mx == 0) {
        if (ix == 0) {
            rhs_d[i] = (1./(2*dx))*(-5*f_local_d[iloc] + 4*f_local_d[iloc+1] + f_local_d[iloc+2]);
        }
    }

    if (mx == npx-1) {
        if (ix == nx-1) {
            rhs_d[i] = -(1./(2*dx))*(-5*f_local_d[iloc] + 4*f_local_d[iloc-1] + f_local_d[iloc-2]);
        }
    }
}

__global__ void sumSolutions(double* x_R_d,
                             double* x_UH_d,
                             double* x_LH_d,
                             double* alpha,
                             double* beta,
                            int nx,
                            int ny,
                            int nz)
{
    /*
    Computes the sum of the solution x_R, x_UH and x_LH,
    where x_R is [nz, ny, nx] and x_LH & x_UH are [nx] sized.
    Performs the following:

    x_R + np.einsum('ij,k->ijk', alpha, x_UH_line) + np.einsum('ij,k->ijk', beta, x_LH_line)
    */
    int ix = blockIdx.x*blockDim.x + threadIdx.x;
    int iy = blockIdx.y*blockDim.y + threadIdx.y;
    int iz = blockIdx.z*blockDim.z + threadIdx.z;
    int i3d, i2d;

    i2d = iz*ny + iy;
    i3d = iz*(ny*nx) + iy*nx + ix;

    x_R_d[i3d] = x_R_d[i3d] + alpha[i2d]*x_UH_d[ix] + beta[i2d]*x_LH_d[ix];
}

__global__ void copyFaces( double* x,
             double* x_faces,
            int nx,
            int ny,
            int nz) {
    
    /*
    Copy the left and right face from the logically [nz, ny, nx] array x
    to a logically [nz, ny, 2] array x_faces 
    */

    int iy = blockIdx.y*blockDim.y + threadIdx.y;
    int iz = blockIdx.z*blockDim.z + threadIdx.z;

    int i_source;
    int i_dest;
    
    i_source = iz*(nx*ny) + iy*nx + 0;
    i_dest = iz*(2*ny) + iy*2 + 0;
    
    x_faces[i_dest] = x[i_source];

    i_source = iz*(nx*ny) + iy*nx + nx-1;
    i_dest = iz*(2*ny) + iy*2 + 1;
    
    x_faces[i_dest] = x[i_source];

}

__global__ void pThomasKernel( double *a_d,
                                 double *b_d,
                                 double *c_d,
                                 double *c2_d,
                                 double *d_d,
                                int block_size)
{
    /*
    Solves many small tridiagonal systems
    using a pThomas (thread-parallel Thomas algorithm)
    */

    int gid = blockIdx.x*blockDim.x + threadIdx.x;
    int block_start = gid*block_size;
    double bmac;

    /* do a serial TDMA on the local system */

    c2_d[0] = c_d[0]/b_d[0]; // we need c2_d, because every thread will overwrite c_d[0] otherwise
    d_d[block_start] = d_d[block_start]/b_d[0];

    for (int i=1; i<block_size; i++)
    {
        bmac = b_d[i] - a_d[i]*c2_d[i-1];
        c2_d[i] = c_d[i]/bmac;
        d_d[block_start+i] = (d_d[block_start+i] - a_d[i]*d_d[block_start+i-1])/bmac;
    }

    for (int i=block_size-2; i >= 0; i--)
    {
        d_d[block_start+i] = d_d[block_start+i] - c2_d[i]*d_d[block_start+i+1];
    }
}

__global__ void globalForwardReduction(const double *a_d,
                                const double *b_d,
                                const double *c_d,
                                double *d_d,
                                const double *k1_d,
                                const double *k2_d,
                                const double *b_first_d,
                                const double *k1_first_d,
                                const double *k1_last_d,
                                const int nx,
                                const int ny,
                                const int nz,
                                int stride)
{
    int gix = blockIdx.x*blockDim.x + threadIdx.x;
    int giy = blockIdx.y*blockDim.y + threadIdx.y;
    int giz = blockIdx.z*blockDim.z + threadIdx.z;
    int i;
    int m, n;
    int idx;
    int gi3d, gi3d0;
    double x_m, x_n;

    gi3d = giz*(nx*ny) + giy*nx + gix;
    gi3d0 = giz*(nx*ny) + giy*nx + 0;

    // forward reduction
    if (stride == nx)
    {
        stride /= 2;

        m = log2((float)stride) - 1;
        n = log2((float)stride); // the last element

        x_m = (d_d[gi3d0 + stride-1]*b_d[n] - c_d[m]*d_d[gi3d0 + 2*stride-1])/ \
                        (b_first_d[m]*b_d[n] - c_d[m]*a_d[n]);

        x_n = (b_first_d[m]*d_d[gi3d0 + 2*stride-1] - d_d[gi3d0 + stride-1]*a_d[n])/ \
                        (b_first_d[m]*b_d[n] - c_d[m]*a_d[n]);

        d_d[gi3d0 + stride-1] = x_m;
        d_d[gi3d0 + 2*stride-1] = x_n;
    }
    else
    {
        i = (stride-1) + gix*stride;
        gi3d = gi3d0 + i;

        idx = log2((float)stride) - 1;
        if (gix == 0)
        {
            d_d[gi3d] = d_d[gi3d] - d_d[gi3d - stride/2]*k1_first_d[idx] - d_d[gi3d + stride/2]*k2_d[idx];
        }
        else if (i == (nx-1))
        {
            d_d[gi3d] = d_d[gi3d] - d_d[gi3d - stride/2]*k1_last_d[idx];
        }
        else
        {
            d_d[gi3d] = d_d[gi3d] - d_d[gi3d - stride/2]*k1_d[idx] - d_d[gi3d + stride/2]*k2_d[idx];
        }
    }
}

__global__ void globalBackSubstitution(const double *a_d,
                                    const double *b_d,
                                    const double *c_d,
                                    double *d_d,
                                    const double *b_first_d,
                                    const double b1,
                                    const double c1,
                                    const double ai,
                                    const double bi,
                                    const double ci,
                                    const int nx,
                                    const int ny,
                                    const int nz,
                                    const int stride)
{
    int gix = blockIdx.x*blockDim.x + threadIdx.x;
    int giy = blockIdx.y*blockDim.y + threadIdx.y;
    int giz = blockIdx.z*blockDim.z + threadIdx.z;
    int i;
    int idx;
    int gi3d, gi3d0;

    gi3d0 = giz*(nx*ny) + giy*nx + 0;
    i = (stride/2-1) + gix*stride;
    gi3d = gi3d0 + i;

    if (stride == 2)
    {
        if (i == 0)
        {
            d_d[gi3d] = (d_d[gi3d] - c1*d_d[gi3d + 1])/b1;
        }
        else
        {
            d_d[gi3d] = (d_d[gi3d] - (ai)*d_d[gi3d - 1] - (ci)*d_d[gi3d + 1])/bi;
        }
    }
    else
    {
        idx = rint(log2((double)stride)) - 2;
        if (gix == 0) 
        {   
            d_d[gi3d] = (d_d[gi3d] - c_d[idx]*d_d[gi3d + stride/2])/b_first_d[idx];
        }
        else
        {
            d_d[gi3d] = (d_d[gi3d] - a_d[idx]*d_d[gi3d - stride/2] - c_d[idx]*d_d[gi3d + stride/2])/b_d[idx];
        }
    }
}
}
