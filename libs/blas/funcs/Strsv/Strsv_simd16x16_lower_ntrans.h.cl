/* Copyright (c) 2017-2018 Intel Corporation
 * 
 * Licensed under the Apache License, Version 2.0 (the "License");
 * you may not use this file except in compliance with the License.
 * You may obtain a copy of the License at
 * 
 *      http://www.apache.org/licenses/LICENSE-2.0
 * 
 * Unless required by applicable law or agreed to in writing, software
 * distributed under the License is distributed on an "AS IS" BASIS,
 * WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
 * See the License for the specific language governing permissions and
 * limitations under the License.
 */

// Kernel parameters:
// VEC_SIZE - vector size used in updating right hand side
// SIMD - number of work items in one sub group
// SUB_GROUPS - number of sub groups in work group
// NOINCX - increment between values in x is equal 1
// NOINCX_ALIGNED - same as NOINCX + pointer to x is aligned to 16B

#ifndef VEC_SIZE
#define VEC_SIZE 1
#endif

#ifndef SIMD
#define SIMD 16
#endif

#ifndef SUB_GROUPS
#define SUB_GROUPS 16
#endif

#if defined(NOINCX_ALIGNED) && !defined(NOINCX)
#define NOINCX
#endif

#include "vector_operations.h"

// TODO Separate into header file
#define ICLBLAS_DIAG_NON_UNIT (0)

#define IDX(row, col, ld) ((col) * (ld) + (row))
//

#define LWG_SIZE ((SIMD) * (SUB_GROUPS))

#define UPDATE_HEIGHT ((SIMD) * (VEC_SIZE))
#define UPDATE_SKIP ((UPDATE_HEIGHT) * (SUB_GROUPS))
#define BLOCK_WIDTH (SIMD)

// First sub group solves top left BLOCK_WIDTH x BLOCK_WIDTH triangle using intel sub group extension, then shares results to other threads using local memory.
// After solve, all threads (LWG_SIZE threads) update VEC_SIZE x BLOCK_WIDTH row in parallel, looping over whole height of column.
// Then situation repeats in next column, all threads move by BLOCK_WIDTH to the right.
__attribute__((intel_reqd_sub_group_size(SIMD)))
__attribute__((reqd_work_group_size(LWG_SIZE, 1, 1)))
__kernel void Strsv_simd16x16_lower_ntrans(int diag, uint n, __global float* A, uint lda, __global float* x, uint incx)
{
    const uint sgid = get_sub_group_id();
    const uint sglid = get_sub_group_local_id();

    const bool diag_non_unit = diag == ICLBLAS_DIAG_NON_UNIT;

    __local float local_x[BLOCK_WIDTH];

    uint group_col = 0;
    while (group_col + BLOCK_WIDTH <= n)
    {
        // Solve BLOCK_WIDTH x BLOCK_WIDTH in sub group 0
        if (sgid == 0) {
            // Load right-hand side x into private memory
#ifdef NOINCX
            float this_x = as_float(intel_sub_group_block_read((__global uint*)x + group_col));
#else
            float this_x = x[(group_col + sglid)*incx];
#endif

            uint ind_A = IDX(group_col, group_col, lda);
            __attribute__((opencl_unroll_hint(SIMD)))
            for (uint simd_idx = 0; simd_idx < SIMD; ++simd_idx)
            {
                // Load this column from A into private memory
                float this_A = as_float(intel_sub_group_block_read((__global uint*)A + ind_A));

                if (diag_non_unit && sglid == simd_idx)
                {
                    this_x /= this_A;
                }

                float update_value = sub_group_broadcast(this_x, simd_idx);
                // Update lower x values
                if (sglid > simd_idx)
                {
                    this_x = mad(-this_A, update_value, this_x);
                }

                ind_A += lda;
            }

            // Update right-hand side x in global matrix and write to local memory
#ifdef NOINCX_ALIGNED
            intel_sub_group_block_write((__global uint*)x + group_col, as_uint(this_x));
#else
            x[(group_col + sglid) * incx] = this_x;
#endif
            local_x[sglid] = this_x;
        }
        barrier(CLK_LOCAL_MEM_FENCE);
        // Load calculated right-hand side
        float update_x = local_x[sglid];

        uint sub_group_row = group_col + BLOCK_WIDTH + sgid * UPDATE_HEIGHT;

        // Update right hand side using VEC_SIZE block read/write functions
        while (sub_group_row + UPDATE_SKIP <= n)
        {
#ifdef NOINCX
            FLOAT_VS this_x = AS_FLOAT_VS( BLOCK_READ_VS( (__global uint*)x + sub_group_row));
#else
            FLOAT_VS this_x = FLOAT_LIST_LOAD_VS( x, (sub_group_row + sglid) * incx, SIMD * incx );
#endif

            uint ind_A = IDX(sub_group_row, group_col, lda);
            __attribute__((opencl_unroll_hint(SIMD)))
            for (uint simd_idx = 0; simd_idx < SIMD; ++simd_idx)
            {
                FLOAT_VS this_A = AS_FLOAT_VS( BLOCK_READ_VS( (__global uint*)A + ind_A ) );
                float update_value = sub_group_broadcast(update_x, simd_idx);
                this_x = mad(-this_A, update_value, this_x);

                ind_A += lda;
            }

#ifdef NOINCX_ALIGNED
            BLOCK_WRITE_VS( (__global uint*)x + sub_group_row, AS_UINT_VS( this_x ) );
#else
            __attribute__((opencl_unroll_hint(VEC_SIZE)))
            for (uint elem = 0; elem < VEC_SIZE; ++elem)
            {
                x[sub_group_row + elem * SIMD + sglid] = VEC_ACCESS_VS(this_x, elem);
            }
#endif

            sub_group_row += UPDATE_SKIP;
        }

        // Update rest of right hand side x
        if (sub_group_row < n)
        {
            __attribute__((opencl_unroll_hint(VEC_SIZE)))
            for (uint elem = 0; elem < VEC_SIZE; ++elem)
            {
                float this_x = sub_group_row + sglid < n ? x[(sub_group_row + sglid) * incx] : 0.f;

                uint ind_A = IDX(sub_group_row + sglid, group_col, lda);
                __attribute__((opencl_unroll_hint(SIMD)))
                for (uint simd_idx = 0; simd_idx < SIMD; ++simd_idx)
                {
                    float update_value = sub_group_broadcast(update_x, simd_idx);
                    if (sub_group_row + sglid < n)
                    {
                        float this_A = A[ind_A];
                        this_x = mad(-this_A, update_value, this_x);
                    }

                    ind_A += lda;
                }

                if (sub_group_row + sglid < n)
                {
                    x[(sub_group_row + sglid) * incx] = this_x;
                }

                sub_group_row += SIMD;
            }
        }

        group_col += BLOCK_WIDTH;
        barrier(CLK_GLOBAL_MEM_FENCE);
    }

    // Leftovers - number of rows left is smaller than BLOCK_WIDTH
    // Solve in one sub group using subset of work items
    if (group_col < n && sgid == 0)
    {
        if (group_col + sglid < n)
        {
            float this_x = x[(group_col + sglid) * incx];

            uint ind_A = IDX(group_col + sglid, group_col, lda);
            __attribute__((opencl_unroll_hint(SIMD)))
            for (uint simd_idx = 0; simd_idx < SIMD; ++simd_idx)
            {
                if (group_col + sglid < n)
                {
                    float this_A = A[ind_A];

                    if (diag_non_unit && sglid == simd_idx)
                    {
                        this_x /= this_A;
                    }

                    float update_value = intel_sub_group_shuffle(this_x, simd_idx);
                    if (sglid > simd_idx)
                    {
                        this_x = mad(-this_A, update_value, this_x);
                    }

                    ind_A += lda;
                }
            }

            x[(group_col + sglid) * incx] = this_x;
        }
    }
}

#undef LWG_SIZE
#undef UPDATE_HEIGHT
#undef UPDATE_SKIP
#undef BLOCK_WIDTH
