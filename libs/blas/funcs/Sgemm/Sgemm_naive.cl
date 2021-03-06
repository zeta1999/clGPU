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

__kernel void Sgemm_naive(int transa, int transb, int m, int n, int k, float alpha, __global float* A, int lda, __global float* B, int ldb, float beta, __global float* C, int ldc)
{
    bool isANTrans = (transa == 0);
    bool isBNTrans = (transb == 0);

    if(isANTrans && isBNTrans)
    {
        for(int i = 0; i < m; i++)
        {
            for(int j = 0; j < n; j++)
            {
                float value = 0.f;

                for(int l = 0; l < k; l++)
                {
                    value += A[l * lda + i] * B[j * ldb + l];
                }

                C[j * ldc + i] = alpha * value + beta * C[j * ldc + i];
            }
        }
    }

    if(isANTrans && !isBNTrans)
    {
        for(int i = 0; i < m; i++)
        {
            for(int j = 0; j < n; j++)
            {
                float value = 0.f;

                for(int l = 0; l < k; l++)
                {
                    value += A[l * lda + i] * B[l * ldb + j];
                }

                C[j * ldc + i] = alpha * value + beta * C[j * ldc + i];
            }
        }
    }

    if(!isANTrans && isBNTrans)
    {
        for(int i = 0; i < m; i++)
        {
            for(int j = 0; j < n; j++)
            {
                float value = 0.f;

                for(int l = 0; l < k; l++)
                {
                    value += A[i * lda + l] * B[j * ldb + l];
                }

                C[j * ldc + i] = alpha * value + beta * C[j * ldc + i];
            }
        }
    }

    if(!isANTrans && !isBNTrans)
    {
        for(int i = 0; i < m; i++)
        {
            for(int j = 0; j < n; j++)
            {
                float value = 0.f;

                for(int l = 0; l < k; l++)
                {
                    value += A[i * lda + l] * B[l * ldb + j];
                }

                C[j * ldc + i] = alpha * value + beta * C[j * ldc + i];
            }
        }
    }
}
