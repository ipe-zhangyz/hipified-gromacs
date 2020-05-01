/*
 * This file is part of the GROMACS molecular simulation package.
 *
 * Copyright (c) 2016,2017,2018,2019, by the GROMACS development team, led by
 * Mark Abraham, David van der Spoel, Berk Hess, and Erik Lindahl,
 * and including many others, as listed in the AUTHORS file in the
 * top-level source directory and at http://www.gromacs.org.
 *
 * GROMACS is free software; you can redistribute it and/or
 * modify it under the terms of the GNU Lesser General Public License
 * as published by the Free Software Foundation; either version 2.1
 * of the License, or (at your option) any later version.
 *
 * GROMACS is distributed in the hope that it will be useful,
 * but WITHOUT ANY WARRANTY; without even the implied warranty of
 * MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the GNU
 * Lesser General Public License for more details.
 *
 * You should have received a copy of the GNU Lesser General Public
 * License along with GROMACS; if not, see
 * http://www.gnu.org/licenses, or write to the Free Software Foundation,
 * Inc., 51 Franklin Street, Fifth Floor, Boston, MA  02110-1301  USA.
 *
 * If you want to redistribute modifications to GROMACS, please
 * consider that scientific software is very special. Version
 * control is crucial - bugs must be traceable. We will be happy to
 * consider code for inclusion in the official distribution, but
 * derived work must not be called official GROMACS. Details are found
 * in the README & COPYING files - if they are missing, get the
 * official version at http://www.gromacs.org.
 *
 * To help us fund GROMACS development, we humbly ask that you cite
 * the research papers on the package. Check out http://www.gromacs.org.
 */

/*! \internal \file
 *  \brief Implements CUDA FFT routines for PME GPU.
 *
 *  \author Aleksei Iupinov <a.yupinov@gmail.com>
 *  \ingroup module_ewald
 */

#include "gmxpre.h"

#include "pme_gpu_3dfft.h"

#include "gromacs/utility/fatalerror.h"
#include "gromacs/utility/gmxassert.h"

#include "pme.cuh"
#include "pme_gpu_types.h"
#include "pme_gpu_types_host.h"
#include "pme_gpu_types_host_impl.h"

static void handleCufftError(hipfftResult_t status, const char* msg)
{
    if (status != HIPFFT_SUCCESS)
    {
        gmx_fatal(FARGS, "%s (error code %d)\n", msg, status);
    }
}

GpuParallel3dFft::GpuParallel3dFft(const PmeGpu* pmeGpu)
{
    const PmeGpuCudaKernelParams* kernelParamsPtr = pmeGpu->kernelParams.get();
    ivec                          realGridSize, realGridSizePadded, complexGridSizePadded;
    for (int i = 0; i < DIM; i++)
    {
        realGridSize[i]          = kernelParamsPtr->grid.realGridSize[i];
        realGridSizePadded[i]    = kernelParamsPtr->grid.realGridSizePadded[i];
        complexGridSizePadded[i] = kernelParamsPtr->grid.complexGridSizePadded[i];
    }

    GMX_RELEASE_ASSERT(!pme_gpu_uses_dd(pmeGpu), "FFT decomposition not implemented");

    const int complexGridSizePaddedTotal =
            complexGridSizePadded[XX] * complexGridSizePadded[YY] * complexGridSizePadded[ZZ];
    const int realGridSizePaddedTotal =
            realGridSizePadded[XX] * realGridSizePadded[YY] * realGridSizePadded[ZZ];

    realGrid_ = (hipfftReal*)kernelParamsPtr->grid.d_realGrid;
    GMX_RELEASE_ASSERT(realGrid_, "Bad (null) input real-space grid");
    complexGrid_ = (hipfftComplex*)kernelParamsPtr->grid.d_fourierGrid;
    GMX_RELEASE_ASSERT(complexGrid_, "Bad (null) input complex grid");

    hipfftResult_t result;
    /* Commented code for a simple 3D grid with no padding */
    /*
       result = hipfftPlan3d(&planR2C_, realGridSize[XX], realGridSize[YY], realGridSize[ZZ],
       HIPFFT_R2C); handleCufftError(result, "hipfftPlan3d R2C plan failure");

       result = hipfftPlan3d(&planC2R_, realGridSize[XX], realGridSize[YY], realGridSize[ZZ],
       HIPFFT_C2R); handleCufftError(result, "hipfftPlan3d C2R plan failure");
     */

    const int rank = 3, batch = 1;
    result = hipfftPlanMany(&planR2C_, rank, realGridSize, realGridSizePadded, 1, realGridSizePaddedTotal,
                           complexGridSizePadded, 1, complexGridSizePaddedTotal, HIPFFT_R2C, batch);
    handleCufftError(result, "hipfftPlanMany R2C plan failure");

    result = hipfftPlanMany(&planC2R_, rank, realGridSize, complexGridSizePadded, 1,
                           complexGridSizePaddedTotal, realGridSizePadded, 1,
                           realGridSizePaddedTotal, HIPFFT_C2R, batch);
    handleCufftError(result, "hipfftPlanMany C2R plan failure");

    hipStream_t stream = pmeGpu->archSpecific->pmeStream;
    GMX_RELEASE_ASSERT(stream, "Using the default CUDA stream for PME cuFFT");

    result = hipfftSetStream(planR2C_, stream);
    handleCufftError(result, "hipfftSetStream R2C failure");

    result = hipfftSetStream(planC2R_, stream);
    handleCufftError(result, "hipfftSetStream C2R failure");
}

GpuParallel3dFft::~GpuParallel3dFft()
{
    hipfftResult_t result;
    result = hipfftDestroy(planR2C_);
    handleCufftError(result, "hipfftDestroy R2C failure");
    result = hipfftDestroy(planC2R_);
    handleCufftError(result, "hipfftDestroy C2R failure");
}

void GpuParallel3dFft::perform3dFft(gmx_fft_direction dir, CommandEvent* /*timingEvent*/)
{
    hipfftResult_t result;
    if (dir == GMX_FFT_REAL_TO_COMPLEX)
    {
        result = hipfftExecR2C(planR2C_, realGrid_, complexGrid_);
        handleCufftError(result, "cuFFT R2C execution failure");
    }
    else
    {
        result = hipfftExecC2R(planC2R_, complexGrid_, realGrid_);
        handleCufftError(result, "cuFFT C2R execution failure");
    }
}
