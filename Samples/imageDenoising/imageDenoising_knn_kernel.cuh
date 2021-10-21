/* Copyright (c) 2021, NVIDIA CORPORATION. All rights reserved.
 *
 * Redistribution and use in source and binary forms, with or without
 * modification, are permitted provided that the following conditions
 * are met:
 *  * Redistributions of source code must retain the above copyright
 *    notice, this list of conditions and the following disclaimer.
 *  * Redistributions in binary form must reproduce the above copyright
 *    notice, this list of conditions and the following disclaimer in the
 *    documentation and/or other materials provided with the distribution.
 *  * Neither the name of NVIDIA CORPORATION nor the names of its
 *    contributors may be used to endorse or promote products derived
 *    from this software without specific prior written permission.
 *
 * THIS SOFTWARE IS PROVIDED BY THE COPYRIGHT HOLDERS ``AS IS'' AND ANY
 * EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT LIMITED TO, THE
 * IMPLIED WARRANTIES OF MERCHANTABILITY AND FITNESS FOR A PARTICULAR
 * PURPOSE ARE DISCLAIMED.  IN NO EVENT SHALL THE COPYRIGHT OWNER OR
 * CONTRIBUTORS BE LIABLE FOR ANY DIRECT, INDIRECT, INCIDENTAL, SPECIAL,
 * EXEMPLARY, OR CONSEQUENTIAL DAMAGES (INCLUDING, BUT NOT LIMITED TO,
 * PROCUREMENT OF SUBSTITUTE GOODS OR SERVICES; LOSS OF USE, DATA, OR
 * PROFITS; OR BUSINESS INTERRUPTION) HOWEVER CAUSED AND ON ANY THEORY
 * OF LIABILITY, WHETHER IN CONTRACT, STRICT LIABILITY, OR TORT
 * (INCLUDING NEGLIGENCE OR OTHERWISE) ARISING IN ANY WAY OUT OF THE USE
 * OF THIS SOFTWARE, EVEN IF ADVISED OF THE POSSIBILITY OF SUCH DAMAGE.
 */

////////////////////////////////////////////////////////////////////////////////
// KNN kernel
////////////////////////////////////////////////////////////////////////////////
__global__ void KNN(TColor *dst, int imageW, int imageH, float Noise,
                    float lerpC, cudaTextureObject_t texImage) {
  const int ix = blockDim.x * blockIdx.x + threadIdx.x;
  const int iy = blockDim.y * blockIdx.y + threadIdx.y;
  // Add half of a texel to always address exact texel centers
  const float x = (float)ix + 0.5f;
  const float y = (float)iy + 0.5f;

  if (ix < imageW && iy < imageH) {
    // Normalized counter for the weight threshold
    float fCount = 0;
    // Total sum of pixel weights
    float sumWeights = 0;
    // Result accumulator
    float3 clr = {0, 0, 0};
    // Center of the KNN window
    float4 clr00 = tex2D<float4>(texImage, x, y);

    // Cycle through KNN window, surrounding (x, y) texel
    for (float i = -KNN_WINDOW_RADIUS; i <= KNN_WINDOW_RADIUS; i++)
      for (float j = -KNN_WINDOW_RADIUS; j <= KNN_WINDOW_RADIUS; j++) {
        float4 clrIJ = tex2D<float4>(texImage, x + j, y + i);
        float distanceIJ = vecLen(clr00, clrIJ);

        // Derive final weight from color distance
        float weightIJ = __expf(
            -(distanceIJ * Noise + (i * i + j * j) * INV_KNN_WINDOW_AREA));

        // Accumulate (x + j, y + i) texel color with computed weight
        clr.x += clrIJ.x * weightIJ;
        clr.y += clrIJ.y * weightIJ;
        clr.z += clrIJ.z * weightIJ;

        // Sum of weights for color normalization to [0..1] range
        sumWeights += weightIJ;

        // Update weight counter, if KNN weight for current window texel
        // exceeds the weight threshold
        fCount += (weightIJ > KNN_WEIGHT_THRESHOLD) ? INV_KNN_WINDOW_AREA : 0;
      }

    // Normalize result color by sum of weights
    sumWeights = 1.0f / sumWeights;
    clr.x *= sumWeights;
    clr.y *= sumWeights;
    clr.z *= sumWeights;

    // Choose LERP quotient basing on how many texels
    // within the KNN window exceeded the weight threshold
    float lerpQ = (fCount > KNN_LERP_THRESHOLD) ? lerpC : 1.0f - lerpC;

    // Write final result to global memory
    clr.x = lerpf(clr.x, clr00.x, lerpQ);
    clr.y = lerpf(clr.y, clr00.y, lerpQ);
    clr.z = lerpf(clr.z, clr00.z, lerpQ);
    dst[imageW * iy + ix] = make_color(clr.x, clr.y, clr.z, 0);
  };
}

extern "C" void cuda_KNN(TColor *d_dst, int imageW, int imageH, float Noise,
                         float lerpC, cudaTextureObject_t texImage) {
  dim3 threads(BLOCKDIM_X, BLOCKDIM_Y);
  dim3 grid(iDivUp(imageW, BLOCKDIM_X), iDivUp(imageH, BLOCKDIM_Y));

  KNN<<<grid, threads>>>(d_dst, imageW, imageH, Noise, lerpC, texImage);
}

////////////////////////////////////////////////////////////////////////////////
// Stripped KNN kernel, only highlighting areas with different LERP directions
////////////////////////////////////////////////////////////////////////////////
__global__ void KNNdiag(TColor *dst, int imageW, int imageH, float Noise,
                        float lerpC, cudaTextureObject_t texImage) {
  const int ix = blockDim.x * blockIdx.x + threadIdx.x;
  const int iy = blockDim.y * blockIdx.y + threadIdx.y;
  // Add half of a texel to always address exact texel centers
  const float x = (float)ix + 0.5f;
  const float y = (float)iy + 0.5f;

  if (ix < imageW && iy < imageH) {
    // Normalized counter for the weight threshold
    float fCount = 0;
    // Center of the KNN window
    float4 clr00 = tex2D<float4>(texImage, x, y);

    // Cycle through KNN window, surrounding (x, y) texel
    for (float i = -KNN_WINDOW_RADIUS; i <= KNN_WINDOW_RADIUS; i++)
      for (float j = -KNN_WINDOW_RADIUS; j <= KNN_WINDOW_RADIUS; j++) {
        float4 clrIJ = tex2D<float4>(texImage, x + j, y + i);
        float distanceIJ = vecLen(clr00, clrIJ);

        // Derive final weight from color and geometric distance
        float weightIJ = __expf(
            -(distanceIJ * Noise + (i * i + j * j) * INV_KNN_WINDOW_AREA));

        // Update weight counter, if KNN weight for current window texel
        // exceeds the weight threshold
        fCount +=
            (weightIJ > KNN_WEIGHT_THRESHOLD) ? INV_KNN_WINDOW_AREA : 0.0f;
      }

    // Choose LERP quotient basing on how many texels
    // within the KNN window exceeded the weight threshold
    float lerpQ = (fCount > KNN_LERP_THRESHOLD) ? 1.0f : 0;

    // Write final result to global memory
    dst[imageW * iy + ix] = make_color(lerpQ, 0, (1.0f - lerpQ), 0);
  };
}

extern "C" void cuda_KNNdiag(TColor *d_dst, int imageW, int imageH, float Noise,
                             float lerpC, cudaTextureObject_t texImage) {
  dim3 threads(BLOCKDIM_X, BLOCKDIM_Y);
  dim3 grid(iDivUp(imageW, BLOCKDIM_X), iDivUp(imageH, BLOCKDIM_Y));

  KNNdiag<<<grid, threads>>>(d_dst, imageW, imageH, Noise, lerpC, texImage);
}
