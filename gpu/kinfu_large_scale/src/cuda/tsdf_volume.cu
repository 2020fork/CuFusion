/*
 * Software License Agreement (BSD License)
 *
 *  Point Cloud Library (PCL) - www.pointclouds.org
 *  Copyright (c) 2011, Willow Garage, Inc.
 *
 *  All rights reserved.
 *
 *  Redistribution and use in source and binary forms, with or without
 *  modification, are permitted provided that the following conditions
 *  are met:
 *
 *   * Redistributions of source code must retain the above copyright
 *     notice, this list of conditions and the following disclaimer.
 *   * Redistributions in binary form must reproduce the above
 *     copyright notice, this list of conditions and the following
 *     disclaimer in the documentation and/or other materials provided
 *     with the distribution.
 *   * Neither the name of Willow Garage, Inc. nor the names of its
 *     contributors may be used to endorse or promote products derived
 *     from this software without specific prior written permission.
 *
 *  THIS SOFTWARE IS PROVIDED BY THE COPYRIGHT HOLDERS AND CONTRIBUTORS
 *  "AS IS" AND ANY EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT
 *  LIMITED TO, THE IMPLIED WARRANTIES OF MERCHANTABILITY AND FITNESS
 *  FOR A PARTICULAR PURPOSE ARE DISCLAIMED. IN NO EVENT SHALL THE
 *  COPYRIGHT OWNER OR CONTRIBUTORS BE LIABLE FOR ANY DIRECT, INDIRECT,
 *  INCIDENTAL, SPECIAL, EXEMPLARY, OR CONSEQUENTIAL DAMAGES (INCLUDING,
 *  BUT NOT LIMITED TO, PROCUREMENT OF SUBSTITUTE GOODS OR SERVICES;
 *  LOSS OF USE, DATA, OR PROFITS; OR BUSINESS INTERRUPTION) HOWEVER
 *  CAUSED AND ON ANY THEORY OF LIABILITY, WHETHER IN CONTRACT, STRICT
 *  LIABILITY, OR TORT (INCLUDING NEGLIGENCE OR OTHERWISE) ARISING IN
 *  ANY WAY OUT OF THE USE OF THIS SOFTWARE, EVEN IF ADVISED OF THE
 *  POSSIBILITY OF SUCH DAMAGE.
 *
 */

#include "device.hpp"

using namespace pcl::device;

namespace pcl
{
  namespace device
  {
    template<typename T>
    __global__ void
    initializeVolume (PtrStep<T> volume)
    {
      int x = threadIdx.x + blockIdx.x * blockDim.x;
      int y = threadIdx.y + blockIdx.y * blockDim.y;
      
      
      if (x < VOLUME_X && y < VOLUME_Y)
      {
          T *pos = volume.ptr(y) + x;
          int z_step = VOLUME_Y * volume.step / sizeof(*pos);

#pragma unroll
          for(int z = 0; z < VOLUME_Z; ++z, pos+=z_step)
             pack_tsdf (0.f, 0, *pos);
      }
    }
    
    //zc: ���ģ�� T ��ʵ��Ҫ���� bool
    template<typename T>
    __global__ void
    initFlagVolumeKernel(PtrStep<T> volume){
      int x = threadIdx.x + blockIdx.x * blockDim.x;
      int y = threadIdx.y + blockIdx.y * blockDim.y;
      
      
      if (x < VOLUME_X && y < VOLUME_Y)
      {
          T *pos = volume.ptr(y) + x;
          int z_step = VOLUME_Y * volume.step / sizeof(*pos);

#pragma unroll
          for(int z = 0; z < VOLUME_Z; ++z, pos+=z_step)
             //pack_tsdf (0.f, 0, *pos);
             *pos = false; //���Ĵ˴�?
      }
    }//initFlagVolumeKernel

    //zc: ���ģ�� T ��Ҫ���� char3, char4
    template<typename T>
    __global__ void
    initVrayPrevVolumeKrnl (PtrStep<T> volume)
    {
      int x = threadIdx.x + blockIdx.x * blockDim.x;
      int y = threadIdx.y + blockIdx.y * blockDim.y;
      
      
      if (x < VOLUME_X && y < VOLUME_Y)
      {
          T *pos = volume.ptr(y) + x;
          int z_step = VOLUME_Y * volume.step / sizeof(*pos);

#pragma unroll
          for(int z = 0; z < VOLUME_Z; ++z, pos+=z_step){
              (*pos).x = 0;
              (*pos).y = 0;
              (*pos).z = 0;
              (*pos).w = 0; //T Ŀǰ��Ȼ���� char4 (��Ϊ host �а� int �洢), ���Է����� w �� //2017-2-15 16:53:43
                   //��- ������ xyz ���� tsdf-v8 ����; ���������� w, �������� bool flagVolume; �˴�Լ��: 0-false-Ϲ��, 1-true-����; Ĭ����Ϊ 0,
          }
      }
    }//initVrayPrevVolumeKrnl


        template<typename T>
    __global__ void
    clearSliceKernel (PtrStep<T> volume, pcl::gpu::tsdf_buffer buffer, int3 minBounds, int3 maxBounds)
    {
      int x = threadIdx.x + blockIdx.x * blockDim.x;
      int y = threadIdx.y + blockIdx.y * blockDim.y;
           
      //compute relative indices
      int idX, idY;
      
      if(x < minBounds.x)
        idX = x + buffer.voxels_size.x;
      else
        idX = x;
      
      if(y < minBounds.y)
        idY = y + buffer.voxels_size.y;
      else
        idY = y;	 
              
      
      if ( x < buffer.voxels_size.x && y < buffer.voxels_size.y)
      {
          if( (idX >= minBounds.x && idX <= maxBounds.x) || (idY >= minBounds.y && idY <= maxBounds.y) )
          {
              // BLACK ZONE => clear on all Z values
         
              ///Pointer to the first x,y,0			
              T *pos = volume.ptr(y) + x;
              
              ///Get the step on Z
              int z_step = buffer.voxels_size.y * volume.step / sizeof(*pos);
                                  
              ///Get the size of the whole TSDF memory
              int size = buffer.tsdf_memory_end - buffer.tsdf_memory_start + 1;
                                
              ///Move along z axis
    #pragma unroll
              for(int z = 0; z < buffer.voxels_size.z; ++z, pos+=z_step)
              {
                ///If we went outside of the memory, make sure we go back to the begining of it
                if(pos > buffer.tsdf_memory_end)
                  pos = pos - size;
                  
                pack_tsdf (0.f, 0, *pos);
              }
           }
           else /* if( idX > maxBounds.x && idY > maxBounds.y)*/
           {
             
              ///RED ZONE  => clear only appropriate Z
             
              ///Pointer to the first x,y,0
              T *pos = volume.ptr(y) + x;
              
              ///Get the step on Z
              int z_step = buffer.voxels_size.y * volume.step / sizeof(*pos);
                           
              ///Get the size of the whole TSDF memory 
              int size = buffer.tsdf_memory_end - buffer.tsdf_memory_start + 1;
                            
              ///Move pointer to the Z origin
              pos+= minBounds.z * z_step;
              
              ///If the Z offset is negative, we move the pointer back
              if(maxBounds.z < 0)
                pos += maxBounds.z * z_step;
                
              ///We make sure that we are not already before the start of the memory
              if(pos < buffer.tsdf_memory_start)
                  pos = pos + size;

              int nbSteps = abs(maxBounds.z);
              
          #pragma unroll				
              for(int z = 0; z < nbSteps; ++z, pos+=z_step)
              {
                ///If we went outside of the memory, make sure we go back to the begining of it
                if(pos > buffer.tsdf_memory_end)
                  pos = pos - size;
                  
                pack_tsdf (0.f, 0, *pos);
              }
           } //else /* if( idX > maxBounds.x && idY > maxBounds.y)*/
       } // if ( x < VOLUME_X && y < VOLUME_Y)
    } // clearSliceKernel
       
  }
}

void
pcl::device::initVolume (PtrStep<short2> volume)
{
  dim3 block (32, 16);
  dim3 grid (1, 1, 1);
  grid.x = divUp (VOLUME_X, block.x);      
  grid.y = divUp (VOLUME_Y, block.y);

  initializeVolume<<<grid, block>>>(volume);
  cudaSafeCall ( cudaGetLastError () );
  cudaSafeCall (cudaDeviceSynchronize ());
}

void
pcl::device::initFlagVolume(PtrStep<bool> volume){
    dim3 block (16, 16);
    dim3 grid (1, 1, 1);
    grid.x = divUp (VOLUME_X, block.x);      
    grid.y = divUp (VOLUME_Y, block.y);

    //initializeVolume<<<grid, block>>>(volume);
    initFlagVolumeKernel<<<grid, block>>>(volume);

    cudaSafeCall ( cudaGetLastError () );
    cudaSafeCall (cudaDeviceSynchronize ());
}//initFlagVolume

void
pcl::device::initVrayPrevVolume(PtrStep<char4> volume){
    dim3 block (16, 16);
    dim3 grid (1, 1, 1);
    grid.x = divUp (VOLUME_X, block.x);      
    grid.y = divUp (VOLUME_Y, block.y);

    //initializeVolume<<<grid, block>>>(volume);
    //initFlagVolumeKernel<<<grid, block>>>(volume); //magCnt ���� initFlagVolumeKernel, ��Ϊ����ģ�庯��, ��ʼ�� false �� 0 һ��
    initVrayPrevVolumeKrnl<<<grid, block>>>(volume);

    cudaSafeCall ( cudaGetLastError () );
    cudaSafeCall (cudaDeviceSynchronize ());
}//initVrayPrevVolume

namespace pcl
{
  namespace device
  {
    struct Tsdf
    {
      enum
      {
        CTA_SIZE_X = 32, CTA_SIZE_Y = 8,
        //MAX_WEIGHT = 1 << 7
        MAX_WEIGHT = 1 << 9
		//MAX_WEIGHT = 15
		//MAX_WEIGHT = 255
		//MAX_WEIGHT = 15
      };

      mutable PtrStep<short2> volume;
      float3 cell_size;

      Intr intr;

      Mat33 Rcurr_inv;
      float3 tcurr;

      PtrStepSz<ushort> depth_raw; //depth in mm

      float tranc_dist_mm;

      __device__ __forceinline__ float3
      getVoxelGCoo (int x, int y, int z) const
      {
        float3 coo = make_float3 (x, y, z);
        coo += 0.5f;         //shift to cell center;

        coo.x *= cell_size.x;
        coo.y *= cell_size.y;
        coo.z *= cell_size.z;

        return coo;
      }

      __device__ __forceinline__ void
      operator () () const
      {
        int x = threadIdx.x + blockIdx.x * CTA_SIZE_X;
        int y = threadIdx.y + blockIdx.y * CTA_SIZE_Y;

        if (x >= VOLUME_X || y >= VOLUME_Y)
          return;

        short2 *pos = volume.ptr (y) + x;
        int elem_step = volume.step * VOLUME_Y / sizeof(*pos);

        for (int z = 0; z < VOLUME_Z; ++z, pos += elem_step)
        {
          float3 v_g = getVoxelGCoo (x, y, z);            //3 // p

          //tranform to curr cam coo space
          float3 v = Rcurr_inv * (v_g - tcurr);           //4

          int2 coo;           //project to current cam
          coo.x = __float2int_rn (v.x * intr.fx / v.z + intr.cx);
          coo.y = __float2int_rn (v.y * intr.fy / v.z + intr.cy);

          if (v.z > 0 && coo.x >= 0 && coo.y >= 0 && coo.x < depth_raw.cols && coo.y < depth_raw.rows)           //6
          {
            int Dp = depth_raw.ptr (coo.y)[coo.x];

            if (Dp != 0)
            {
              float xl = (coo.x - intr.cx) / intr.fx;
              float yl = (coo.y - intr.cy) / intr.fy;
              float lambda_inv = rsqrtf (xl * xl + yl * yl + 1);

              float sdf = 1000 * norm (tcurr - v_g) * lambda_inv - Dp; //mm

              sdf *= (-1);

              if (sdf >= -tranc_dist_mm)
              {
                float tsdf = fmin (1, sdf / tranc_dist_mm);

                int weight_prev;
                float tsdf_prev;

                //read and unpack
                unpack_tsdf (*pos, tsdf_prev, weight_prev);

                const int Wrk = 1;

                float tsdf_new = (tsdf_prev * weight_prev + Wrk * tsdf) / (weight_prev + Wrk);
                int weight_new = min (weight_prev + Wrk, MAX_WEIGHT);

                pack_tsdf (tsdf_new, weight_new, *pos);
              }
            }
          }
        }
      }
    };

    __global__ void
    integrateTsdfKernel (const Tsdf tsdf) {
      tsdf ();
    }

    __global__ void
    tsdf2 (PtrStep<short2> volume, const float tranc_dist_mm, const Mat33 Rcurr_inv, float3 tcurr,
           const Intr intr, const PtrStepSz<ushort> depth_raw, const float3 cell_size)
    {
      int x = threadIdx.x + blockIdx.x * blockDim.x;
      int y = threadIdx.y + blockIdx.y * blockDim.y;

      if (x >= VOLUME_X || y >= VOLUME_Y)
        return;

      short2 *pos = volume.ptr (y) + x;
      int elem_step = volume.step * VOLUME_Y / sizeof(short2);

      float v_g_x = (x + 0.5f) * cell_size.x - tcurr.x;
      float v_g_y = (y + 0.5f) * cell_size.y - tcurr.y;
      float v_g_z = (0 + 0.5f) * cell_size.z - tcurr.z;

      float v_x = Rcurr_inv.data[0].x * v_g_x + Rcurr_inv.data[0].y * v_g_y + Rcurr_inv.data[0].z * v_g_z;
      float v_y = Rcurr_inv.data[1].x * v_g_x + Rcurr_inv.data[1].y * v_g_y + Rcurr_inv.data[1].z * v_g_z;
      float v_z = Rcurr_inv.data[2].x * v_g_x + Rcurr_inv.data[2].y * v_g_y + Rcurr_inv.data[2].z * v_g_z;

//#pragma unroll
      for (int z = 0; z < VOLUME_Z; ++z)
      {
        float3 vr;
        vr.x = v_g_x;
        vr.y = v_g_y;
        vr.z = (v_g_z + z * cell_size.z);

        float3 v;
        v.x = v_x + Rcurr_inv.data[0].z * z * cell_size.z;
        v.y = v_y + Rcurr_inv.data[1].z * z * cell_size.z;
        v.z = v_z + Rcurr_inv.data[2].z * z * cell_size.z;

        int2 coo;         //project to current cam
        coo.x = __float2int_rn (v.x * intr.fx / v.z + intr.cx);
        coo.y = __float2int_rn (v.y * intr.fy / v.z + intr.cy);


        if (v.z > 0 && coo.x >= 0 && coo.y >= 0 && coo.x < depth_raw.cols && coo.y < depth_raw.rows)         //6
        {
          int Dp = depth_raw.ptr (coo.y)[coo.x]; //mm

          if (Dp != 0)
          {
            float xl = (coo.x - intr.cx) / intr.fx;
            float yl = (coo.y - intr.cy) / intr.fy;
            float lambda_inv = rsqrtf (xl * xl + yl * yl + 1);

            float sdf = Dp - norm (vr) * lambda_inv * 1000; //mm


            if (sdf >= -tranc_dist_mm)
            {
              float tsdf = fmin (1.f, sdf / tranc_dist_mm);

              int weight_prev;
              float tsdf_prev;

              //read and unpack
              unpack_tsdf (*pos, tsdf_prev, weight_prev);

              const int Wrk = 1;

              float tsdf_new = (tsdf_prev * weight_prev + Wrk * tsdf) / (weight_prev + Wrk);
              int weight_new = min (weight_prev + Wrk, Tsdf::MAX_WEIGHT);

              pack_tsdf (tsdf_new, weight_new, *pos);
            }
          }
        }
        pos += elem_step;
      }       /* for(int z = 0; z < VOLUME_Z; ++z) */
    }      /* __global__ */
  }
}


//////////////////////////////////////////////////////////////////////////////////////////////////////////////////
void
pcl::device::integrateTsdfVolume (const PtrStepSz<ushort>& depth_raw, const Intr& intr, const float3& volume_size,
                                  const Mat33& Rcurr_inv, const float3& tcurr, float tranc_dist, 
                                  PtrStep<short2> volume)
{
  Tsdf tsdf;

  tsdf.volume = volume;  
  tsdf.cell_size.x = volume_size.x / VOLUME_X;
  tsdf.cell_size.y = volume_size.y / VOLUME_Y;
  tsdf.cell_size.z = volume_size.z / VOLUME_Z;
  
  tsdf.intr = intr;

  tsdf.Rcurr_inv = Rcurr_inv;
  tsdf.tcurr = tcurr;
  tsdf.depth_raw = depth_raw;

  tsdf.tranc_dist_mm = tranc_dist*1000; //mm

  dim3 block (Tsdf::CTA_SIZE_X, Tsdf::CTA_SIZE_Y);
  dim3 grid (divUp (VOLUME_X, block.x), divUp (VOLUME_Y, block.y));

#if 0
   //tsdf2<<<grid, block>>>(volume, tranc_dist, Rcurr_inv, tcurr, intr, depth_raw, tsdf.cell_size);
   integrateTsdfKernel<<<grid, block>>>(tsdf);
#endif
  cudaSafeCall ( cudaGetLastError () );
  cudaSafeCall (cudaDeviceSynchronize ());
}


namespace pcl
{
  namespace device
  {
    __global__ void
    scaleDepth (const PtrStepSz<ushort> depth, PtrStep<float> scaled, const Intr intr)
    {
      int x = threadIdx.x + blockIdx.x * blockDim.x;
      int y = threadIdx.y + blockIdx.y * blockDim.y;

      if (x >= depth.cols || y >= depth.rows)
        return;

      int Dp = depth.ptr (y)[x];

      float xl = (x - intr.cx) / intr.fx;
      float yl = (y - intr.cy) / intr.fy;
      float lambda = sqrtf (xl * xl + yl * yl + 1);

	  float res = Dp * lambda/1000.f; //meters
	  if ( intr.trunc_dist > 0 && res > intr.trunc_dist )
		  scaled.ptr (y)[x] = 0;
	  else
		scaled.ptr (y)[x] = res;
    }

    __global__ void
    tsdf23 (const PtrStepSz<float> depthScaled, PtrStep<short2> volume,
            //const float tranc_dist, const Mat33 Rcurr_inv, const float3 tcurr, const Intr intr, const float3 cell_size, const pcl::gpu::tsdf_buffer buffer)
            const float tranc_dist, const Mat33 Rcurr_inv, const float3 tcurr, const Intr intr, const float3 cell_size, const pcl::gpu::tsdf_buffer buffer, int3 vxlDbg) //zc: ����
    {
      int x = threadIdx.x + blockIdx.x * blockDim.x;
      int y = threadIdx.y + blockIdx.y * blockDim.y;

      if (x >= buffer.voxels_size.x || y >= buffer.voxels_size.y)
        return;

      float v_g_x = (x + 0.5f) * cell_size.x - tcurr.x;
      float v_g_y = (y + 0.5f) * cell_size.y - tcurr.y;
      float v_g_z = (0 + 0.5f) * cell_size.z - tcurr.z;

      float v_g_part_norm = v_g_x * v_g_x + v_g_y * v_g_y;

      float v_x = (Rcurr_inv.data[0].x * v_g_x + Rcurr_inv.data[0].y * v_g_y + Rcurr_inv.data[0].z * v_g_z) * intr.fx;
      float v_y = (Rcurr_inv.data[1].x * v_g_x + Rcurr_inv.data[1].y * v_g_y + Rcurr_inv.data[1].z * v_g_z) * intr.fy;
      float v_z = (Rcurr_inv.data[2].x * v_g_x + Rcurr_inv.data[2].y * v_g_y + Rcurr_inv.data[2].z * v_g_z);

      float z_scaled = 0;

      float Rcurr_inv_0_z_scaled = Rcurr_inv.data[0].z * cell_size.z * intr.fx;
      float Rcurr_inv_1_z_scaled = Rcurr_inv.data[1].z * cell_size.z * intr.fy;

      float tranc_dist_inv = 1.0f / tranc_dist;

      short2* pos = volume.ptr (y) + x;
      
      // shift the pointer to relative indices
      shift_tsdf_pointer(&pos, buffer);
      
      int elem_step = volume.step * buffer.voxels_size.y / sizeof(short2);

//#pragma unroll
      for (int z = 0; z < buffer.voxels_size.z;
           ++z,
           v_g_z += cell_size.z,
           z_scaled += cell_size.z,
           v_x += Rcurr_inv_0_z_scaled,
           v_y += Rcurr_inv_1_z_scaled,
           pos += elem_step)
      {
        bool doDbgPrint = false;
        if(x > 0 && y > 0 && z > 0 //����Ĭ�� 000, ����Чֵ, �������Ӵ˼��
            && vxlDbg.x == x && vxlDbg.y == y && vxlDbg.z == z)
            doDbgPrint = true;

        // As the pointer is incremented in the for loop, we have to make sure that the pointer is never outside the memory
        if(pos > buffer.tsdf_memory_end)
          pos -= (buffer.tsdf_memory_end - buffer.tsdf_memory_start + 1);
        
        float inv_z = 1.0f / (v_z + Rcurr_inv.data[2].z * z_scaled);
        if (inv_z < 0)
            continue;

        // project to current cam
		// old code
        int2 coo =
        {
          __float2int_rn (v_x * inv_z + intr.cx),
          __float2int_rn (v_y * inv_z + intr.cy)
        };

        if (coo.x >= 0 && coo.y >= 0 && coo.x < depthScaled.cols && coo.y < depthScaled.rows)         //6
        {
          float Dp_scaled = depthScaled.ptr (coo.y)[coo.x]; //meters

          float sdf = Dp_scaled - sqrtf (v_g_z * v_g_z + v_g_part_norm);

          if(doDbgPrint){
              printf("@tsdf23: Dp_scaled, sdf, tranc_dist: %f, %f, %f, %s\n", Dp_scaled, sdf, tranc_dist, 
                  sdf >= -tranc_dist ? "sdf >= -tranc_dist" : "");
          }

          if (Dp_scaled != 0 && sdf >= -tranc_dist) //meters
          {
            float tsdf = fmin (1.0f, sdf * tranc_dist_inv);

            //read and unpack
            float tsdf_prev;
            int weight_prev;
            unpack_tsdf (*pos, tsdf_prev, weight_prev);

            const int Wrk = 1;

            float tsdf_new = (tsdf_prev * weight_prev + Wrk * tsdf) / (weight_prev + Wrk);
            int weight_new = min (weight_prev + Wrk, Tsdf::MAX_WEIGHT);

            if(doDbgPrint){
                printf("tsdf_prev, tsdf, tsdf_new: %f, %f, %f\n", tsdf_prev, tsdf, tsdf_new);
            }

            pack_tsdf (tsdf_new, weight_new, *pos);
          }
        }
        else{ //NOT (coo.x >= 0 && coo.y >= 0 && coo.x < depthScaled.cols && coo.y < depthScaled.rows)
            if(doDbgPrint){
                printf("vxlDbg.xyz:= (%d, %d, %d), coo.xy:= (%d, %d)\n", vxlDbg.x, vxlDbg.y, vxlDbg.z, coo.x, coo.y);
            }
        }

		/*
		// this time, we need an interpolation to get the depth value
		float2 coof = { v_x * inv_z + intr.cx, v_y * inv_z + intr.cy };
        int2 coo =
        {
          __float2int_rd (v_x * inv_z + intr.cx),
          __float2int_rd (v_y * inv_z + intr.cy)
        };

        if (coo.x >= 0 && coo.y >= 0 && coo.x < depthScaled.cols - 1 && coo.y < depthScaled.rows - 1 )         //6
        {
          //float Dp_scaled = depthScaled.ptr (coo.y)[coo.x]; //meters
		  float a = coof.x - coo.x;
		  float b = coof.y - coo.y;
		  float d00 = depthScaled.ptr (coo.y)[coo.x];
		  float d01 = depthScaled.ptr (coo.y+1)[coo.x];
		  float d10 = depthScaled.ptr (coo.y)[coo.x+1];
		  float d11 = depthScaled.ptr (coo.y+1)[coo.x+1];

          float Dp_scaled = 0;

		  if ( d00 != 0 && d01 != 0 && d10 != 0 && d11 != 0 && a > 0 && a < 1 && b > 0 && b < 1 )
		    Dp_scaled = ( 1 - b ) * ( ( 1 - a ) * d00 + ( a ) * d10 ) + ( b ) * ( ( 1 - a ) * d01 + ( a ) * d11 );

          float sdf = Dp_scaled - sqrtf (v_g_z * v_g_z + v_g_part_norm);

          if (Dp_scaled != 0 && sdf >= -tranc_dist) //meters
          {
            float tsdf = fmin (1.0f, sdf * tranc_dist_inv);

            //read and unpack
            float tsdf_prev;
            int weight_prev;
            unpack_tsdf (*pos, tsdf_prev, weight_prev);

            const int Wrk = 1;

            float tsdf_new = (tsdf_prev * weight_prev + Wrk * tsdf) / (weight_prev + Wrk);
            int weight_new = min (weight_prev + Wrk, Tsdf::MAX_WEIGHT);

            pack_tsdf (tsdf_new, weight_new, *pos);
          }		  
		}
		*/
      }       // for(int z = 0; z < VOLUME_Z; ++z)
    }      // __global__

    enum{FUSE_KF_AVGE, //kf tsdf ԭ����
        FUSE_RESET, //i ��� i-1
        FUSE_IGNORE_CURR //���� i
        ,FUSE_FIX_PREDICTION //�ȸ�����, �������
    };

    __global__ void
    tsdf23_v11 (const PtrStepSz<float> depthScaled, PtrStep<short2> volume1, 
        PtrStep<short2> volume2nd, PtrStep<bool> flagVolume, PtrStep<char4> surfNormVolume, PtrStep<char4> vrayPrevVolume, const PtrStepSz<unsigned char> incidAngleMask,
        const PtrStep<float> nmap_curr_g, const PtrStep<float> nmap_model_g,
        /*��--ʵ��˳��: volume2nd, flagVolume, surfNormVolume, incidAngleMask, nmap_g,*/
        const PtrStep<float> weight_map, //v11.4
        const float tranc_dist, const Mat33 Rcurr_inv, const float3 tcurr, const Intr intr, const float3 cell_size
        , int3 vxlDbg)
    {
      int x = threadIdx.x + blockIdx.x * blockDim.x;
      int y = threadIdx.y + blockIdx.y * blockDim.y;

      if (x >= VOLUME_X || y >= VOLUME_Y)
        return;

      float v_g_x = (x + 0.5f) * cell_size.x - tcurr.x;
      float v_g_y = (y + 0.5f) * cell_size.y - tcurr.y;
      float v_g_z = (0 + 0.5f) * cell_size.z - tcurr.z;

      float v_g_part_norm = v_g_x * v_g_x + v_g_y * v_g_y;

      float v_x = (Rcurr_inv.data[0].x * v_g_x + Rcurr_inv.data[0].y * v_g_y + Rcurr_inv.data[0].z * v_g_z) * intr.fx;
      float v_y = (Rcurr_inv.data[1].x * v_g_x + Rcurr_inv.data[1].y * v_g_y + Rcurr_inv.data[1].z * v_g_z) * intr.fy;
      float v_z = (Rcurr_inv.data[2].x * v_g_x + Rcurr_inv.data[2].y * v_g_y + Rcurr_inv.data[2].z * v_g_z);

      float z_scaled = 0;

      float Rcurr_inv_0_z_scaled = Rcurr_inv.data[0].z * cell_size.z * intr.fx;
      float Rcurr_inv_1_z_scaled = Rcurr_inv.data[1].z * cell_size.z * intr.fy;

      float tranc_dist_inv = 1.0f / tranc_dist;

      short2* pos1 = volume1.ptr (y) + x;
      int elem_step = volume1.step * VOLUME_Y / sizeof(short2);

      //�ҵĿ�������:
      short2 *pos2nd = volume2nd.ptr(y) + x;

      //hadSeen-flag:
      bool *flag_pos = flagVolume.ptr(y) + x;
      int flag_elem_step = flagVolume.step * VOLUME_Y / sizeof(bool);

      //vray.prev
      char4 *vrayPrev_pos = vrayPrevVolume.ptr(y) + x;
      int vrayPrev_elem_step = vrayPrevVolume.step * VOLUME_Y / sizeof(char4);

      //surface-norm.prev
      char4 *snorm_pos = surfNormVolume.ptr(y) + x;
      int snorm_elem_step = surfNormVolume.step * VOLUME_Y / sizeof(char4);

//#pragma unroll
      for (int z = 0; z < VOLUME_Z;
           ++z,
           v_g_z += cell_size.z,
           z_scaled += cell_size.z,
           v_x += Rcurr_inv_0_z_scaled,
           v_y += Rcurr_inv_1_z_scaled,
           pos1 += elem_step,

           pos2nd += elem_step,
           flag_pos += flag_elem_step,

           vrayPrev_pos += vrayPrev_elem_step,
           snorm_pos += snorm_elem_step)
      {
        bool doDbgPrint = false;
        if(x > 0 && y > 0 && z > 0 //����Ĭ�� 000, ����Чֵ, �������Ӵ˼��
            && vxlDbg.x == x && vxlDbg.y == y && vxlDbg.z == z)
            doDbgPrint = true;

        float inv_z = 1.0f / (v_z + Rcurr_inv.data[2].z * z_scaled);
        if (inv_z < 0)
            continue;

        // project to current cam
        int2 coo =
        {
          __float2int_rn (v_x * inv_z + intr.cx),
          __float2int_rn (v_y * inv_z + intr.cy)
        };

        if (coo.x >= 0 && coo.y >= 0 && coo.x < depthScaled.cols && coo.y < depthScaled.rows)         //6
        {
          float Dp_scaled = depthScaled.ptr (coo.y)[coo.x]; //meters

          float sdf = Dp_scaled - sqrtf (v_g_z * v_g_z + v_g_part_norm);

          if(doDbgPrint){
              printf("Dp_scaled, sdf, tranc_dist, %f, %f, %f\n", Dp_scaled, sdf, tranc_dist);
              printf("coo.xy:(%d, %d)\n", coo.x, coo.y);
          }

          float weiFactor = weight_map.ptr(coo.y)[coo.x];
#if 0
          if (Dp_scaled != 0 && sdf >= -tranc_dist) //meters
#else
          //��--v11.7: �� wmap (weight) ��̬�趨 tranc_dist ����, (����׼����:
          //float tranc_dist_real = tranc_dist * weiFactor;
          float tranc_dist_real = max(2*cell_size.x, tranc_dist * weiFactor); //�ضϲ���̫��, v11.8

          if(doDbgPrint){
              printf("\ttranc_dist_real, weiFactor: %f, %f\n", tranc_dist_real, weiFactor);
          }

          if (Dp_scaled != 0 && sdf >= -tranc_dist_real) //meters
          //if (Dp_scaled != 0 && -tranc_dist_real <= sdf && sdf < tranc_dist) //meters, v11.8
#endif
          {
            float sdf_normed = sdf * tranc_dist_inv;
            float tsdf_curr = fmin (1.0f, sdf_normed);

            bool isInclined = (incidAngleMask.ptr(coo.y)[coo.x] != 0); //̫��б��, �����̫��
            float3 snorm_curr_g;
            snorm_curr_g.x = nmap_curr_g.ptr(coo.y)[coo.x];
            if(isnan(snorm_curr_g.x)){
                if(doDbgPrint)
                    printf("+++++++++++++++isnan(snorm_curr_g.x), weiFactor: %f\n", weiFactor);

                return;
            }

            snorm_curr_g.y = nmap_curr_g.ptr(coo.y + depthScaled.rows)[coo.x];
            snorm_curr_g.z = nmap_curr_g.ptr(coo.y + 2 * depthScaled.rows)[coo.x];

            float3 vrayPrev;
            //�����ѹ�һ��, ��Ȼ char->float �����, ����������һ��
            vrayPrev.x = 1.f * (*vrayPrev_pos).x / CHAR_MAX; //char2float
            vrayPrev.y = 1.f * (*vrayPrev_pos).y / CHAR_MAX;
            vrayPrev.z = 1.f * (*vrayPrev_pos).z / CHAR_MAX;

            //v11.3: �� vrayPrev_pos[3] �� hadSeenConfidence, ȡ�� hadSeen ������: //2017-3-11 21:40:24
            signed char *seenConfid = &vrayPrev_pos->w;
            const int seenConfidTh = 15;

            float3 vray; //��β�����������Ҫ�ж�, �˴�ֻ���������� nmap ���ζԴ�
                            //v11.2 �ĳɶ�Ҫ��: ���� & ���淨��˫���ж� //2017-3-8 22:00:32
            vray.x = v_g_x;
            vray.y = v_g_y;
            vray.z = v_g_z;
            //float vray_norm = norm(vray);
            float3 vray_normed = normalized(vray); //��λ��������

            float cos_vray_norm = dot(snorm_curr_g, vray_normed);
            if(cos_vray_norm > 0){ //����assert, Ҫ�����: �н�>90��, ��������볯�������ͷ
                //printf("ERROR+++++++++++++++cos_vray_norm > 0");

                //���費��֤�ⲿ����ȷԤ����
                snorm_curr_g.x *= -1;
                snorm_curr_g.y *= -1;
                snorm_curr_g.z *= -1;
            }

            float3 snormPrev;
            snormPrev.x = 1.f * (*snorm_pos).x / CHAR_MAX; //char2float
            snormPrev.y = 1.f * (*snorm_pos).y / CHAR_MAX;
            snormPrev.z = 1.f * (*snorm_pos).z / CHAR_MAX;

            //v11.9: ��ʱ�� snorm ����������س�ʼ��, ��ʵֵȴ������ȥ���� snorm @2017-4-11 17:03:51
            int snormPrevConfid = (*snorm_pos).w;
            const int snormPrevConfid_thresh = 5;

            //const bool hadSeen = *flag_pos; //���� hadSeen, ��׼ȷ
            const bool hadSeen = (*seenConfid > seenConfidTh); //v11.3: ����, ������ confid++, �ﵽ��ֵ֮��, �ű�� seen; ���ﲻ����ֵ, ��Ҫ--

            //bool isSnormPrevInit = (norm(snormPrev) > 1e-8);
            //bool isSnormPrevInit = ( (norm(snormPrev) > 1e-8) && (snormPrevConfid > snormPrevConfid_thresh) );
            bool isSnormPrevInit = (snormPrevConfid > snormPrevConfid_thresh); //ȥ�� X>1e-8 �ж�, ��Ϊ confid > th ʱ��Ȼ X �Ѿ���ʼ������

            if(doDbgPrint){
                printf("isInclined, %d\n", isInclined);
                printf("cos_vray_norm, %f; snorm_curr_g: [%f, %f, %f], vray_normed: [%f, %f, %f]\n", cos_vray_norm, snorm_curr_g.x, snorm_curr_g.y, snorm_curr_g.z, vray_normed.x, vray_normed.y, vray_normed.z);
                printf("(norm(snormPrev) == 0) == %s; (norm(snormPrev) < 1e-8) == %s\n",
                    norm(snormPrev) == 0 ? "T" : "F",
                    norm(snormPrev) < 1e-8 ? "T" : "F");
            }


            //read and unpack
            float tsdf_prev1;
            int weight_prev1;
            unpack_tsdf (*pos1, tsdf_prev1, weight_prev1);

            float tsdf_prev2nd = -123;
            int weight_prev2nd = -233;
            unpack_tsdf (*pos2nd, tsdf_prev2nd, weight_prev2nd);

            //const int w2ndCntThresh = 10; //w2nd ��������ֵ������Ϯ
            const int w2ndCntThresh = 10 * 10; //v11.4 �� weiFactor ֮��

            if(doDbgPrint){
                printf("tsdf_prev: tsdf1st: %f, %d; tsdf2nd: %f, %d;\n", tsdf_prev1, weight_prev1, tsdf_prev2nd, weight_prev2nd);
            }

            int fuse_method = FUSE_KF_AVGE; //Ĭ��ԭ����
            bool doUpdateVrayAndSnorm = false;

            const float cosThreshVray = //0.8660254f; //cos(30��)
                //0.9396926f; //cos(20��) //�� largeIncidMask ȡ 80 ��ֵʱ, �˴�ӦΪ (90-x)*2
                0.9659258f; //cos(15��) //��ΪlargeIncidMask �� 75��Ϊ��ֵ, ���������� 90-75=15 Ϊ��ֵ
                //0.996194698; //cos(5��)
            const float cosThreshSnorm = 0.8660254f; //cos(30��), �� vray ���ֿ�, ���ø�������ֵ @2017-3-15 00:39:18

            float cos_norm = dot(snormPrev, snorm_curr_g);
            float cos_vray = dot(vrayPrev, vray_normed);
            bool isNewFace = (isSnormPrevInit && cos_norm < cosThreshSnorm && cos_vray < cosThreshVray); //snorm-init ֮����� newFace �ж� @2017-4-21 00:42:00
            //bool isNewFace = (isSnormPrevInit && cos_norm < cosThreshSnorm); //ȥ�� vray �ж�, ��! ԭ��: vray ��ֹ *�ӽ��ȶ���snorm ͻ�� (��Եetc.)* ����, ������ isNewFace=true

            if(doDbgPrint){
                printf("cos_norm: snormPrev, snorm_curr_g, %f, [%f, %f, %f], [%f, %f, %f]\n", cos_norm, 
                    snormPrev.x, snormPrev.y, snormPrev.z, snorm_curr_g.x, snorm_curr_g.y, snorm_curr_g.z);
                printf("\tcos_vray, vrayPrev, vray_normed, %f, [%f, %f, %f], [%f, %f, %f]\n", cos_vray, 
                    vrayPrev.x, vrayPrev.y, vrayPrev.z, vray_normed.x, vray_normed.y, vray_normed.z);
                printf("%s, snormPrevConfid, snormPrevConfid_thresh: %d, %d\n", isNewFace ? "isNewFace-T" : "isNewFace-F", snormPrevConfid, snormPrevConfid_thresh);
                printf("\t%s\n", cos_norm > cosThreshSnorm ? "cos_norm > cosThreshSnorm" : "cos_norm <= cosThreshSnorm");
                printf("\t%s\n", cos_vray > cosThreshVray ? "cos_vray > cosThreshVray" : "cos_vray <= cosThreshVray");
            }


#if 01   //v11.3, v11.4, 
            if(isInclined){ //����Ե, doUpdateVray ���� false
                if(!hadSeen){ //�� seen-flag δ��ʼ����
                    if(doDbgPrint)
                        printf("isInclined-T; hadSeen=F; ++FUSE_KF_AVGE\n");
                    fuse_method = FUSE_KF_AVGE;

                    //*seenConfid = max(0, *seenConfid - 1);
                    //��-- ��Ҫ -1 ��, ֻ������, ��ͬʱ seenConfidTh ��ֵ���� (5 -> 15), �ӻ��� flag=true   @2017-3-23 11:11:55
                }
                else{ //if(hadSeen) //��֮ǰ seen
#if 0   //���� sdf < 0 ����ж�Ϊʲô��, Ŀǰ�о��ᵼ����ƫ��, ����   @2017-3-9 15:06:22
                    if(doDbgPrint)
                        printf("isInclined-T; hadSeen=T; %s; sdf: %f\n", sdf<0 ? "==FUSE_IGNORE_CURR" : "++FUSE_KF_AVGE", sdf);
                    if(sdf < 0)
                        fuse_method = FUSE_IGNORE_CURR;
                    else
                        fuse_method = FUSE_KF_AVGE;
#elif 1 //һ�� ignore
                    if(doDbgPrint)
                        printf("isInclined-T; hadSeen=T; \n");
                    fuse_method = FUSE_IGNORE_CURR;
#endif
                }
            }
            else{ //if(!isInclined){ //���Ǳ�Ե, ���ڲ�
                //*seenConfid = min(Tsdf::MAX_WEIGHT, *seenConfid + 1); //v11.4 �� weiFactor ֮��, ���ﷴ���� BUG!!
                *seenConfid = min(SCHAR_MAX, *seenConfid + 1);

                if(!isSnormPrevInit){ //vray.prev ��δ��ʼ��, �� < epsilon �ж�
                    //if (*seenConfid > seenConfidTh) //����� hadSeen, ���Բ�Ҫ��ô�ж�
                        //doUpdateVrayAndSnorm = true;
                }


                if(!hadSeen){ //�� seen-flag δ��ʼ����
#if 0   //< v11.3
                    if(doDbgPrint)
                        printf("isInclined-F; hadSeen=F; >>FUSE_RESET\n");
                    *flag_pos = true;
                    fuse_method = FUSE_RESET;
#elif 1 //v11.3
                    if(doDbgPrint)
                        printf("isInclined-F; hadSeen=F; seenConfid, seenConfidTh: %d, %d, ++FUSE_KF_AVGE~~~~~\n", *seenConfid, seenConfidTh); //��Ҳû�� reset ��
                    fuse_method = FUSE_KF_AVGE;
#endif
                    //if (*seenConfid > seenConfidTh) //��Ȼ hadSeen �߼��Ĺ�, ��˴���Ȼһֱ false
                    //    doUpdateVrayAndSnorm = true;
                }
                else{ //if(hadSeen) //��֮ǰ seen, ��Ȼ������ ��isInclined-F; hadSeen=F���׶�, Ҳ��Ȼ isSnormPrevInit->true, ������ if-isSnormPrevInit
                    if(doDbgPrint)
                        printf("isInclined-F; hadSeen=T;\n");

                    //if(cos_norm > cosThresh ){ //�нǽǶ� <30��, ����ͬ�ӽ�
                    if(!isNewFace){ //ͬ�ӽ�, ˫ cos �����ж�
                        //TODO...
                        fuse_method = FUSE_KF_AVGE; //��ʵĬ��

                        //if (*seenConfid > seenConfidTh) //����, ��Ϊ���� if-hadSeen ��֧��
                        if(cos_norm > cosThreshSnorm) //��֮ cos_norm < th ʱ, ���� newFace=false, ����Ӧ update
                            doUpdateVrayAndSnorm = true;

                        if(!isSnormPrevInit)
                            doUpdateVrayAndSnorm = true;
                    }
                    else{ // >30��, ������ͬ�ӽ�, ����ת��ͷ֮��
                        //if(!isSnormPrevInit) //newFace �Ľ�֮��, ���ﲻ���ٽ���
                        //    doUpdateVrayAndSnorm = true;

#if 10   //���಻����, �������岻��ȷ, ���� @2017-3-24 17:50:24
                        //����Ϊ����
                        if(tsdf_curr < 0 && tsdf_curr < tsdf_prev1){
                            if(doDbgPrint)
                                printf("\ttsdf < 0 && tsdf < tsdf_prev1; [:=prev1, curr: %f, %f\n", tsdf_prev1, tsdf_curr);

                            fuse_method = FUSE_IGNORE_CURR;
                        }
                        else if(tsdf_prev1 < 0 && tsdf_prev1 < tsdf_curr){
                            if(doDbgPrint){
                                printf("\ttsdf_prev1 < 0 && tsdf_prev1 < tsdf; [:=prev1, curr: %f, %f\n", tsdf_prev1, tsdf_curr);
                                printf("\t\t, weight_prev1, w2ndCntThresh: %d, %d\n", weight_prev1, w2ndCntThresh);
                            }
#if 0   //weight_prev1 �Ƿ�Ҫ�� w2ndCntThresh �Ա�?
                            if(weight_prev1 > w2ndCntThresh){
                                fuse_method = FUSE_FIX_PREDICTION; //�ñ��� volume, ����-��+
                            }
                            else{
                                fuse_method = FUSE_KF_AVGE; //����Ĭ���Ƿ�������
                            }
#elif 1 //1st ���� w2ndCntThresh �Ա�, ��Ϊ�������Աȿ���: weight_new2nd > w2ndCntThresh
                            fuse_method = FUSE_FIX_PREDICTION; //�ñ��� volume, ����-��+
#endif
                            //doUpdateSnorm = true; //�ŵ� FUSE_FIX_PREDICTION ���ж�
                        }
                        else if(tsdf_curr >=0 && tsdf_prev1 >= 0){
                            if(doDbgPrint){
                                printf("\ttsdf >=0 && tsdf_prev1 >= 0; [:=prev1, curr: %f, %f\n", tsdf_prev1, tsdf_curr);
                            }
                            fuse_method = FUSE_KF_AVGE;
                            doUpdateVrayAndSnorm = true;
                        }
#elif 1 //ϸ�֡�����Ϊ7��, @2017-3-24 17:51:03
                        if(tsdf_prev1 >= 0){
                            if(tsdf_curr <0){
                                fuse_method = FUSE_IGNORE_CURR;
                                doUpdateVrayAndSnorm = true;
                                
                                if(doDbgPrint)
                                    printf("+~~-,, ==FUSE_IGNORE_CURR\n");
                            }
                            else{//tsdf_curr >=0
                                if(sdf < tranc_dist){
                                    fuse_method = FUSE_KF_AVGE;

                                    if(doDbgPrint)
                                        printf("+~~��+,, ++FUSE_KF_AVGE\n");
                                }
                                else{
                                    fuse_method = FUSE_IGNORE_CURR;

                                    if(doDbgPrint)
                                        printf("+~~��+,, ==FUSE_IGNORE_CURR\n");
                                }
                            }
                        }
                        else{ //tsdf_prev1 <0
                            float abs_tsdfcurr = abs(tsdf_curr);
                            if(abs_tsdfcurr < abs(tsdf_prev1)){
                                fuse_method = FUSE_FIX_PREDICTION;

                                if(doDbgPrint){
                                    if(tsdf_curr < 0)
                                        printf("-~~��-,, >>FUSE_FIX_PREDICTION\n");
                                    else
                                        printf("-~~��+,, >>FUSE_FIX_PREDICTION\n");
                                }
                            }
                            else{
                                fuse_method = FUSE_IGNORE_CURR;

                                if(doDbgPrint){
                                    if(tsdf_curr < 0)
                                        printf("-~~��-,, ==FUSE_IGNORE_CURR\n");
                                    else
                                        printf("-~~��+,, ==FUSE_IGNORE_CURR\n");
                                }
                            }
                        }
#endif
                    }//cos vs. cosTh
                }//if-hadSeen
            }//if-isInclined
#elif 0 //v11.5; //������, ������˼·������... @2017-3-16 00:05:51
            if(isInclined){
                if(doDbgPrint)
                    printf("isInclined-T; ++FUSE_KF_AVGE\n");

                fuse_method = FUSE_KF_AVGE;
                doUpdateVrayAndSnorm = false;
            }
            else{ //if(!isInclined){ //���Ǳ�Ե, ���ڲ�
                if(doDbgPrint)
                    printf("isInclined-F;\n");

                bool isSnormPrevInit = (norm(snormPrev) > 1e-8);
                if(!isSnormPrevInit){ //vray.prev ��δ��ʼ��, �� < epsilon �ж�
                    if(doDbgPrint)
                        printf("\tisSnormPrevInit-F\n");

                    fuse_method = FUSE_KF_AVGE;
                    doUpdateVrayAndSnorm = true;
                }
                else{ //vray+snorm ����ʼ������
                    if(!isNewFace){ //ͬ�ӽ�, ˫ cos �����ж�
                        if(doDbgPrint)
                            printf("\tisNewFace-F\n");

                        fuse_method = FUSE_KF_AVGE; //��ʵĬ��
                        doUpdateVrayAndSnorm = true;
                    }
                    else{ // isNewFace, ������ͬ�ӽ�, ����ת��ͷ֮��
                        if(doDbgPrint)
                            printf("\tisNewFace-T\n");

                        //����Ϊ����
                        if(tsdf_curr < 0 && tsdf_curr < tsdf_prev1){
                            if(doDbgPrint)
                                printf("\ttsdf < 0 && tsdf < tsdf_prev1; [:=prev1, curr: %f, %f\n", tsdf_prev1, tsdf_curr);

                            fuse_method = FUSE_IGNORE_CURR;
                        }
                        else if(tsdf_prev1 < 0 && tsdf_prev1 < tsdf_curr){
                            if(doDbgPrint){
                                printf("\ttsdf_prev1 < 0 && tsdf_prev1 < tsdf; [:=prev1, curr: %f, %f\n", tsdf_prev1, tsdf_curr);
                                printf("\t\t, weight_prev1, w2ndCntThresh: %d, %d\n", weight_prev1, w2ndCntThresh);
                            }
#if 0   //weight_prev1 �Ƿ�Ҫ�� w2ndCntThresh �Ա�?
                            if(weight_prev1 > w2ndCntThresh){
                                fuse_method = FUSE_FIX_PREDICTION; //�ñ��� volume, ����-��+
                            }
                            else{
                                fuse_method = FUSE_KF_AVGE; //����Ĭ���Ƿ�������
                            }
#elif 1 //1st ���� w2ndCntThresh �Ա�, ��Ϊ�������Աȿ���: weight_new2nd > w2ndCntThresh
                            fuse_method = FUSE_FIX_PREDICTION; //�ñ��� volume, ����-��+
#endif
                            //doUpdateSnorm = true; //�ŵ� FUSE_FIX_PREDICTION ���ж�
                        }
                        else if(tsdf_curr >=0 && tsdf_prev1 >= 0){
                            if(doDbgPrint){
                                printf("\ttsdf >=0 && tsdf_prev1 >= 0; [:=prev1, curr: %f, %f\n", tsdf_prev1, tsdf_curr);
                            }
                            fuse_method = FUSE_KF_AVGE;
                            doUpdateVrayAndSnorm = true;
                        }
                    }//isNewFace
                }//vray+snorm ����ʼ������
            }
#elif 1 //v11.6: v11.5������, �ĳ� isInclined ֻ���ڿ��� vray+snorm �ĸ���; ȥ���� hadSeen-flag ����
            //�����Ǽ���, ���ǽ�������, �����Թ�
            bool isSnormPrevInit = (norm(snormPrev) > 1e-8);

            if(isInclined){
                doUpdateVrayAndSnorm = false;
            }
            else if(!isSnormPrevInit){
                doUpdateVrayAndSnorm = true;
            }

            if(!isSnormPrevInit){
                fuse_method = FUSE_KF_AVGE;
            }
            else{ //vray+snorm ����ʼ������
                if(!isNewFace){ //ͬ�ӽ�, ˫ cos �����ж�
                    if(doDbgPrint)
                        printf("\tisNewFace-F\n");

                    fuse_method = FUSE_KF_AVGE; //��ʵĬ��

                    if(!isInclined)
                        doUpdateVrayAndSnorm = true;
                }
                else{ // isNewFace, ������ͬ�ӽ�, ����ת��ͷ֮��
                    if(doDbgPrint)
                        printf("\tisNewFace-T\n");

                    //����Ϊ����
                    if(tsdf_curr < 0 && tsdf_curr < tsdf_prev1){
                        if(doDbgPrint)
                            printf("\ttsdf < 0 && tsdf < tsdf_prev1; [:=prev1, curr: %f, %f\n", tsdf_prev1, tsdf_curr);

                        fuse_method = FUSE_IGNORE_CURR;
                    }
                    else if(tsdf_prev1 < 0 && tsdf_prev1 < tsdf_curr){
                        if(doDbgPrint){
                            printf("\ttsdf_prev1 < 0 && tsdf_prev1 < tsdf; [:=prev1, curr: %f, %f\n", tsdf_prev1, tsdf_curr);
                            printf("\t\t, weight_prev1, w2ndCntThresh: %d, %d\n", weight_prev1, w2ndCntThresh);
                        }
                        fuse_method = FUSE_FIX_PREDICTION; //�ñ��� volume, ����-��+
                        //doUpdateSnorm = true; //�ŵ� FUSE_FIX_PREDICTION ���ж�
                    }
                    else if(tsdf_curr >=0 && tsdf_prev1 >= 0){
                        if(doDbgPrint){
                            printf("\ttsdf >=0 && tsdf_prev1 >= 0; [:=prev1, curr: %f, %f\n", tsdf_prev1, tsdf_curr);
                        }
                        fuse_method = FUSE_KF_AVGE;

                        if(!isInclined)
                            doUpdateVrayAndSnorm = true;
                    }
                }//isNewFace
            }//vray+snorm ����ʼ������
#endif
            const int Wrk = max(15 * weiFactor, 1.f);
            if(FUSE_KF_AVGE == fuse_method){
                float tsdf_new1 = (tsdf_prev1 * weight_prev1 + Wrk * tsdf_curr) / (weight_prev1 + Wrk);
                int weight_new1 = min (weight_prev1 + Wrk, Tsdf::MAX_WEIGHT);

                int weight_new2nd = max(weight_prev2nd - Wrk, 0); //--, ����ֹ <0

                pack_tsdf (tsdf_new1, weight_new1, *pos1);
                pack_tsdf(tsdf_prev2nd, weight_new2nd, *pos2nd); //���� 2nd �Ƿ�������ʼ����

                if(doDbgPrint)
                    printf("++FUSE_KF_AVGE, weight_new1, weight_new2nd, %d, %d\n", weight_new1, weight_new2nd);
            }
            else if(FUSE_FIX_PREDICTION == fuse_method){ //ȡ���ֱ� FUSE_RESET
#if 0   //factor/step ��ʽ����
//                   //const int pos_neg_factor = 8;
//                   int pos_neg_factor = min(weight_prev1 / 10, 1); //������ʱ���� w1 ��ʵ����, ���Բ��ֱܴ��趨�󲽳�
//                   int pnWrk = pos_neg_factor * Wrk;
//                   float tsdf_new2nd = (tsdf_prev2nd * weight_prev2nd + pnWrk * tsdf) / (weight_prev2nd + pnWrk);
//                   int weight_new2nd = min (weight_prev2nd + pnWrk, Tsdf::MAX_WEIGHT);
// 
//                   int weight_new1 = max(weight_prev1 - pnWrk, 0);
// 
//                   if(weight_new2nd > weight_new1){ //�� 2nd ��Ϯ, �򽻻� 1st/2nd, ��Զ���� 1st Ϊ��
#elif 1
                float tsdf_new2nd = (tsdf_prev2nd * weight_prev2nd + Wrk * tsdf_curr) / (weight_prev2nd + Wrk);
                int weight_new2nd = min (weight_prev2nd + Wrk, Tsdf::MAX_WEIGHT);

                //int weight_new1 = max(weight_prev1 - Wrk, 0);
                if(weight_new2nd > w2ndCntThresh){ //���� 1st/2nd, ��Զ���� 1st Ϊ�� //����ĳ�: 2nd ������Ϯ 1st, ֻҪ����ĳ������ֵ����
#endif
                    if(doDbgPrint){
                        printf("weight_new2nd > w2ndCntThresh,,, exchanging 1st-2nd\n");
                    }
                    pack_tsdf(tsdf_new2nd, weight_new2nd, *pos1); //new-2nd �ŵ� pos-1st ��
                    //pack_tsdf(tsdf_prev1, weight_new1, *pos2nd);

                    doUpdateVrayAndSnorm = true; //ֱ�� 2nd ��Ϯ, �����µ� snorm ���µ�ǰ vxl
                }
                else{ //����
                    //pack_tsdf(tsdf_prev1, weight_new1, *pos1);
                    pack_tsdf(tsdf_new2nd, weight_new2nd, *pos2nd);
                    doUpdateVrayAndSnorm = false;
                }

                if(doDbgPrint)
                    //printf("...>>FUSE_FIX_PREDICTION, weight_new1, weight_new2nd, %d, %d\n", weight_new1, weight_new2nd);
                    printf("...>>FUSE_FIX_PREDICTION, weight_new2nd, %d\n", weight_new2nd);

                //����: ����doDbgPrint, ȫ�����, ��������û���ߵ���һ���� vxl: @2017-3-11 21:22:59
                //��: ��!! ��Ϊ FUSE_FIX_PREDICTION Ŀǰ��� case: tsdf_prev1 < 0 && tsdf_prev1 < tsdf
                //printf("...>>FUSE_FIX_PREDICTION, weight_new2nd, %d,,, [xyz]=(%d, %d, %d)\n", weight_new2nd, x, y, z);
            }
            else if(FUSE_RESET == fuse_method){
                if(doDbgPrint)
                    printf(">>FUSE_RESET\n");

                pack_tsdf(tsdf_curr, 1, *pos1);
            }
            else if(FUSE_IGNORE_CURR == fuse_method){
                if(doDbgPrint)
                    printf("==FUSE_IGNORE_CURR\n");

                //DO-NOTHING!!! //��
                //IGNʱ, ҲҪ 2nd Ūһ�� @2017-3-16 03:53:08
                int weight_new2nd = max(weight_prev2nd - Wrk, 0); //--, ����ֹ <0
                pack_tsdf(tsdf_prev2nd, weight_new2nd, *pos2nd); //���� 2nd �Ƿ�������ʼ����
            }

            if(doDbgPrint)
                printf("doUpdateSnorm: %d\n", doUpdateVrayAndSnorm);

            if(doUpdateVrayAndSnorm){
                //max (-DIVISOR, min (DIVISOR, (int)nearbyintf (tsdf * DIVISOR))); //@pack_tsdf
                //��Ϊ vray_normed.xyz ��Ȼ�� <=1, ���Բ��� max/min... ��
                (*vrayPrev_pos).x = (int)nearbyintf(vray_normed.x * CHAR_MAX); //float2char
                (*vrayPrev_pos).y = (int)nearbyintf(vray_normed.y * CHAR_MAX);
                (*vrayPrev_pos).z = (int)nearbyintf(vray_normed.z * CHAR_MAX);

                //���� pcc �� nmap ����֮��, ��Ե����׼ (��Ϊ sobel?), Ҫ�е�; ������һЩ���� @2017-3-15 16:54:25
                //�� 4:=7/2+1
                const int edgeMarg = 4;
                if(coo.x < edgeMarg || coo.x >= depthScaled.cols - edgeMarg || coo.y < edgeMarg || coo.y >= depthScaled.rows - edgeMarg){
                    if(doDbgPrint)
                        printf("+++++++++++++++at edge, dont-update-snorm; coo.xy: (%d, %d)\n", coo.x, coo.y);
                }
                else{
                    //(*snorm_pos).w += 1; //�� snormPrevConfid
                    (*snorm_pos).w = min(SCHAR_MAX, snormPrevConfid + 1);

                    if(!isSnormPrevInit || isNewFace){
                        if(doDbgPrint)
                            printf("\t(!isSnormPrevInit || isNewFace): %d, %d; snormPrevConfid: %d\n", isSnormPrevInit, isNewFace, (*snorm_pos).w);

                        (*snorm_pos).x = (int)nearbyintf(snorm_curr_g.x * CHAR_MAX); //float2char
                        (*snorm_pos).y = (int)nearbyintf(snorm_curr_g.y * CHAR_MAX);
                        (*snorm_pos).z = (int)nearbyintf(snorm_curr_g.z * CHAR_MAX);
                    }
                    else{ //isSnormPrevInit && !isNewFace //v11.6: ��snorm ��ʼ������, �ҵ�ǰû��ͻ��, ���� model �ķ���, ��Ϊ����ȶ�
                        if(doDbgPrint)
                            printf("\tisSnormPrevInit && !isNewFace\n");

                        float3 snorm_model_g;
                        snorm_model_g.x = nmap_model_g.ptr(coo.y)[coo.x];
                        snorm_model_g.y = nmap_model_g.ptr(coo.y + depthScaled.rows)[coo.x];
                        snorm_model_g.z = nmap_model_g.ptr(coo.y + 2 * depthScaled.rows)[coo.x];

                        float cos_vray_norm_model = dot(snorm_model_g, vray_normed);
                        if(cos_vray_norm_model > 0){ //����assert, Ҫ�����: �н�>90��, ��������볯�������ͷ
                            //printf("ERROR+++++++++++++++cos_vray_norm > 0");

                            //���費��֤�ⲿ����ȷԤ����
                            snorm_model_g.x *= -1;
                            snorm_model_g.y *= -1;
                            snorm_model_g.z *= -1;
                        }
                        if(doDbgPrint)
                            printf("\t\tcos_vray_norm_model, %f; snorm_model_g: [%f, %f, %f], vray_normed: [%f, %f, %f]\n", cos_vray_norm_model, snorm_model_g.x, snorm_model_g.y, snorm_model_g.z, vray_normed.x, vray_normed.y, vray_normed.z);

                        float cos_norm_model_and_prev = dot(snorm_model_g, snormPrev);
                        //��--����˵, ��ʱ n_model, n_curr Ӧ�üнǺ�С (�Ѿ��������������� ��1 �˷�) //v11.7   @2017-3-17 15:52:25
                        //������Ϊ����, ���� n_model ƫ�����, ����ȫ������:
                        //if(cos_norm_model_and_prev > cosThreshSnorm){
                        //if(1){ //���� snormPrev ����

                        //zc: ���߼�: �� snorm-model/curr ����Ÿ��� @2017-4-25 21:24:23
                        float cos_norm_model_and_curr = dot(snorm_model_g, snorm_curr_g);
                        if(cos_norm_model_and_curr > cosThreshSnorm){
                            //���� __float2int_rd �� round-down �����˻�����, ��ֵ���ȶ�, ���� nearbyintf (������)?  @2017-3-15 15:33:33
                            (*snorm_pos).x = (int)nearbyintf(snorm_model_g.x * CHAR_MAX); //float2char
                            (*snorm_pos).y = (int)nearbyintf(snorm_model_g.y * CHAR_MAX);
                            (*snorm_pos).z = (int)nearbyintf(snorm_model_g.z * CHAR_MAX);
                        }
                        else{
                            //DO-NOTHING!!!
                        }
                    }
                }//cut-edgeMarg

                if(doDbgPrint){
                    printf("newVray: [%d, %d, %d]\n", (*vrayPrev_pos).x, (*vrayPrev_pos).y, (*vrayPrev_pos).z);
                    printf("\tnewSnorm: [%d, %d, %d]\n", (*snorm_pos).x, (*snorm_pos).y, (*snorm_pos).z);
                }
            }//if-(doUpdateVrayAndSnorm)
          }//if- (Dp_scaled != 0 && sdf >= -tranc_dist)
          else{
              if(doDbgPrint)
                  printf("NOT (Dp_scaled != 0 && sdf >= -tranc_dist)\n");
          }
        }//if- 0 < (x,y) < (cols,rows)
      }// for(int z = 0; z < VOLUME_Z; ++z)
    }//tsdf23_v11

    __global__ void
    tsdf23_v11_remake (const PtrStepSz<float> depthScaled, PtrStep<short2> volume1, 
        PtrStep<short2> volume2nd, PtrStep<bool> flagVolume, PtrStep<char4> surfNormVolume, PtrStep<char4> vrayPrevVolume, const PtrStepSz<unsigned char> incidAngleMask,
        const PtrStep<float> nmap_curr_g, const PtrStep<float> nmap_model_g,
        /*��--ʵ��˳��: volume2nd, flagVolume, surfNormVolume, incidAngleMask, nmap_g,*/
        const PtrStep<float> weight_map, //v11.4
        const float tranc_dist, const Mat33 Rcurr_inv, const float3 tcurr, const Intr intr, const float3 cell_size
        , int3 vxlDbg)
    {
      int x = threadIdx.x + blockIdx.x * blockDim.x;
      int y = threadIdx.y + blockIdx.y * blockDim.y;

      if (x >= VOLUME_X || y >= VOLUME_Y)
        return;

      float v_g_x = (x + 0.5f) * cell_size.x - tcurr.x;
      float v_g_y = (y + 0.5f) * cell_size.y - tcurr.y;
      float v_g_z = (0 + 0.5f) * cell_size.z - tcurr.z;

      float v_g_part_norm = v_g_x * v_g_x + v_g_y * v_g_y;

      float v_x = (Rcurr_inv.data[0].x * v_g_x + Rcurr_inv.data[0].y * v_g_y + Rcurr_inv.data[0].z * v_g_z) * intr.fx;
      float v_y = (Rcurr_inv.data[1].x * v_g_x + Rcurr_inv.data[1].y * v_g_y + Rcurr_inv.data[1].z * v_g_z) * intr.fy;
      float v_z = (Rcurr_inv.data[2].x * v_g_x + Rcurr_inv.data[2].y * v_g_y + Rcurr_inv.data[2].z * v_g_z);

      float z_scaled = 0;

      float Rcurr_inv_0_z_scaled = Rcurr_inv.data[0].z * cell_size.z * intr.fx;
      float Rcurr_inv_1_z_scaled = Rcurr_inv.data[1].z * cell_size.z * intr.fy;

      float tranc_dist_inv = 1.0f / tranc_dist;

      short2* pos1 = volume1.ptr (y) + x;
      int elem_step = volume1.step * VOLUME_Y / sizeof(short2);

      //�ҵĿ�������:
      short2 *pos2nd = volume2nd.ptr(y) + x;

      //hadSeen-flag:
      bool *flag_pos = flagVolume.ptr(y) + x;
      int flag_elem_step = flagVolume.step * VOLUME_Y / sizeof(bool);

      //vray.prev
      char4 *vrayPrev_pos = vrayPrevVolume.ptr(y) + x;
      int vrayPrev_elem_step = vrayPrevVolume.step * VOLUME_Y / sizeof(char4);

      //surface-norm.prev
      char4 *snorm_pos = surfNormVolume.ptr(y) + x;
      int snorm_elem_step = surfNormVolume.step * VOLUME_Y / sizeof(char4);

//#pragma unroll
      for (int z = 0; z < VOLUME_Z;
           ++z,
           v_g_z += cell_size.z,
           z_scaled += cell_size.z,
           v_x += Rcurr_inv_0_z_scaled,
           v_y += Rcurr_inv_1_z_scaled,
           pos1 += elem_step,

           pos2nd += elem_step,
           flag_pos += flag_elem_step,

           vrayPrev_pos += vrayPrev_elem_step,
           snorm_pos += snorm_elem_step)
      {
        bool doDbgPrint = false;
        if(x > 0 && y > 0 && z > 0 //����Ĭ�� 000, ����Чֵ, �������Ӵ˼��
            && vxlDbg.x == x && vxlDbg.y == y && vxlDbg.z == z)
            doDbgPrint = true;

        float inv_z = 1.0f / (v_z + Rcurr_inv.data[2].z * z_scaled);
        if (inv_z < 0)
            continue;

        // project to current cam
        int2 coo =
        {
          __float2int_rn (v_x * inv_z + intr.cx),
          __float2int_rn (v_y * inv_z + intr.cy)
        };

        if (coo.x >= 0 && coo.y >= 0 && coo.x < depthScaled.cols && coo.y < depthScaled.rows)         //6
        {
          float Dp_scaled = depthScaled.ptr (coo.y)[coo.x]; //meters

          float sdf = Dp_scaled - sqrtf (v_g_z * v_g_z + v_g_part_norm);

          if(doDbgPrint){
              printf("Dp_scaled, sdf, tranc_dist, %f, %f, %f\n", Dp_scaled, sdf, tranc_dist);
              printf("coo.xy:(%d, %d)\n", coo.x, coo.y);
          }

          float weiFactor = weight_map.ptr(coo.y)[coo.x];
#if 0
          if (Dp_scaled != 0 && sdf >= -tranc_dist) //meters
#else
          //��--v11.7: �� wmap (weight) ��̬�趨 tranc_dist ����, (����׼����:
          //float tranc_dist_real = tranc_dist * weiFactor;
          float tranc_dist_real = max(2*cell_size.x, tranc_dist * weiFactor); //�ضϲ���̫��, v11.8

          if(doDbgPrint){
              printf("\ttranc_dist_real, weiFactor: %f, %f\n", tranc_dist_real, weiFactor);
          }

          if (Dp_scaled != 0 && sdf >= -tranc_dist_real) //meters
          //if (Dp_scaled != 0 && -tranc_dist_real <= sdf && sdf < tranc_dist) //meters, v11.8
#endif
          {
            float sdf_normed = sdf * tranc_dist_inv;
            float tsdf_curr = fmin (1.0f, sdf_normed);

            bool isInclined = (incidAngleMask.ptr(coo.y)[coo.x] != 0); //̫��б��, �����̫��
            float3 snorm_curr_g;
            snorm_curr_g.x = nmap_curr_g.ptr(coo.y)[coo.x];
            if(isnan(snorm_curr_g.x)){
                if(doDbgPrint)
                    printf("+++++++++++++++isnan(snorm_curr_g.x), weiFactor: %f\n", weiFactor);

                return;
            }

            snorm_curr_g.y = nmap_curr_g.ptr(coo.y + depthScaled.rows)[coo.x];
            snorm_curr_g.z = nmap_curr_g.ptr(coo.y + 2 * depthScaled.rows)[coo.x];

            float3 vrayPrev;
            //�����ѹ�һ��, ��Ȼ char->float �����, ����������һ��
            vrayPrev.x = 1.f * (*vrayPrev_pos).x / CHAR_MAX; //char2float
            vrayPrev.y = 1.f * (*vrayPrev_pos).y / CHAR_MAX;
            vrayPrev.z = 1.f * (*vrayPrev_pos).z / CHAR_MAX;

            //v11.3: �� vrayPrev_pos[3] �� hadSeenConfidence, ȡ�� hadSeen ������: //2017-3-11 21:40:24
            signed char *seenConfid = &vrayPrev_pos->w;
            const int seenConfidTh = 15;

            float3 vray; //��β�����������Ҫ�ж�, �˴�ֻ���������� nmap ���ζԴ�
                            //v11.2 �ĳɶ�Ҫ��: ���� & ���淨��˫���ж� //2017-3-8 22:00:32
            vray.x = v_g_x;
            vray.y = v_g_y;
            vray.z = v_g_z;
            //float vray_norm = norm(vray);
            float3 vray_normed = normalized(vray); //��λ��������

            float cos_vray_norm = dot(snorm_curr_g, vray_normed);
            if(cos_vray_norm > 0){ //����assert, Ҫ�����: �н�>90��, ��������볯�������ͷ
                //printf("ERROR+++++++++++++++cos_vray_norm > 0");

                //���費��֤�ⲿ����ȷԤ����
                snorm_curr_g.x *= -1;
                snorm_curr_g.y *= -1;
                snorm_curr_g.z *= -1;
            }

            float3 snormPrev;
            snormPrev.x = 1.f * (*snorm_pos).x / CHAR_MAX; //char2float
            snormPrev.y = 1.f * (*snorm_pos).y / CHAR_MAX;
            snormPrev.z = 1.f * (*snorm_pos).z / CHAR_MAX;

            //v11.9: ��ʱ�� snorm ����������س�ʼ��, ��ʵֵȴ������ȥ���� snorm @2017-4-11 17:03:51
            signed char *snormPrevConfid = &snorm_pos->w;
            const int snormPrevConfid_thresh = 5;

            //const bool hadSeen = *flag_pos; //���� hadSeen, ��׼ȷ
            const bool hadSeen = (*seenConfid > seenConfidTh); //v11.3: ����, ������ confid++, �ﵽ��ֵ֮��, �ű�� seen; ���ﲻ����ֵ, ��Ҫ--

            //bool isSnormPrevInit = (norm(snormPrev) > 1e-8);
            //bool isSnormPrevInit = ( (norm(snormPrev) > 1e-8) && (snormPrevConfid > snormPrevConfid_thresh) );
            bool isSnormPrevInit = (*snormPrevConfid > snormPrevConfid_thresh); //ȥ�� X>1e-8 �ж�, ��Ϊ confid > th ʱ��Ȼ X �Ѿ���ʼ������

            if(doDbgPrint){
                printf("isInclined, %d\n", isInclined);
                printf("cos_vray_norm, %f; snorm_curr_g: [%f, %f, %f], vray_normed: [%f, %f, %f]\n", cos_vray_norm, snorm_curr_g.x, snorm_curr_g.y, snorm_curr_g.z, vray_normed.x, vray_normed.y, vray_normed.z);
                printf("(norm(snormPrev) == 0) == %s; (norm(snormPrev) < 1e-8) == %s\n",
                    norm(snormPrev) == 0 ? "T" : "F",
                    norm(snormPrev) < 1e-8 ? "T" : "F");
            }


            //read and unpack
            float tsdf_prev1;
            int weight_prev1;
            unpack_tsdf (*pos1, tsdf_prev1, weight_prev1);

            float tsdf_prev2nd = -123;
            int weight_prev2nd = -233;
            unpack_tsdf (*pos2nd, tsdf_prev2nd, weight_prev2nd);

            //const int w2ndCntThresh = 10; //w2nd ��������ֵ������Ϯ
            const int w2ndCntThresh = 10 * 10; //v11.4 �� weiFactor ֮��

            if(doDbgPrint){
                printf("tsdf_prev: tsdf1st: %f, %d; tsdf2nd: %f, %d;\n", tsdf_prev1, weight_prev1, tsdf_prev2nd, weight_prev2nd);
            }

            int fuse_method = FUSE_KF_AVGE; //Ĭ��ԭ����
            bool doUpdateVrayAndSnorm = false;

            const float cosThreshVray = //0.8660254f; //cos(30��)
                //0.9396926f; //cos(20��) //�� largeIncidMask ȡ 80 ��ֵʱ, �˴�ӦΪ (90-x)*2
                0.9659258f; //cos(15��) //��ΪlargeIncidMask �� 75��Ϊ��ֵ, ���������� 90-75=15 Ϊ��ֵ
                //0.996194698; //cos(5��)
            const float cosThreshSnorm = 0.8660254f; //cos(30��), �� vray ���ֿ�, ���ø�������ֵ @2017-3-15 00:39:18

            float cos_norm = dot(snormPrev, snorm_curr_g);
            float cos_vray = dot(vrayPrev, vray_normed);
            bool isNewFace = (isSnormPrevInit && cos_norm < cosThreshSnorm && cos_vray < cosThreshVray); //snorm-init ֮����� newFace �ж� @2017-4-21 00:42:00
            //bool isNewFace = (isSnormPrevInit && cos_norm < cosThreshSnorm); //ȥ�� vray �ж�, ��! ԭ��: vray ��ֹ *�ӽ��ȶ���snorm ͻ�� (��Եetc.)* ����, ������ isNewFace=true

            //zc: �����ж�, �� weight-factor ̫С(��, ��Ե����), ��ֱ�Ӿ�ֵ, �Ҳ� updateVray @2017-7-13 22:29:39
            if(weiFactor > 0.2){


            if(doDbgPrint){
                printf("cos_norm: snormPrev, snorm_curr_g, %f, [%f, %f, %f], [%f, %f, %f]\n", cos_norm, 
                    snormPrev.x, snormPrev.y, snormPrev.z, snorm_curr_g.x, snorm_curr_g.y, snorm_curr_g.z);
                printf("\tcos_vray, vrayPrev, vray_normed, %f, [%f, %f, %f], [%f, %f, %f]\n", cos_vray, 
                    vrayPrev.x, vrayPrev.y, vrayPrev.z, vray_normed.x, vray_normed.y, vray_normed.z);
                printf("%s, snormPrevConfid, snormPrevConfid_thresh: %d, %d\n", isNewFace ? "isNewFace-T" : "isNewFace-F", *snormPrevConfid, snormPrevConfid_thresh);
                printf("\t%s\n", cos_norm > cosThreshSnorm ? "cos_norm > cosThreshSnorm" : "cos_norm <= cosThreshSnorm");
                printf("\t%s\n", cos_vray > cosThreshVray ? "cos_vray > cosThreshVray" : "cos_vray <= cosThreshVray");
            }


            if(isInclined){ //����Ե, doUpdateVray ���� false
                if(!hadSeen){ //�� seen-flag δ��ʼ����
                    if(doDbgPrint)
                        printf("isInclined-T; hadSeen=F; ++FUSE_KF_AVGE\n");
                    fuse_method = FUSE_KF_AVGE;

                    //*seenConfid = max(0, *seenConfid - 1);
                    //��-- ��Ҫ -1 ��, ֻ������, ��ͬʱ seenConfidTh ��ֵ���� (5 -> 15), �ӻ��� flag=true   @2017-3-23 11:11:55
                }
                else{ //if(hadSeen) //��֮ǰ seen
#if 0   //���� sdf < 0 ����ж�Ϊʲô��, Ŀǰ�о��ᵼ����ƫ��, ����   @2017-3-9 15:06:22
                    if(doDbgPrint)
                        printf("isInclined-T; hadSeen=T; %s; sdf: %f\n", sdf<0 ? "==FUSE_IGNORE_CURR" : "++FUSE_KF_AVGE", sdf);
                    if(sdf < 0)
                        fuse_method = FUSE_IGNORE_CURR;
                    else
                        fuse_method = FUSE_KF_AVGE;
#elif 1 //һ�� ignore
                    if(doDbgPrint)
                        printf("isInclined-T; hadSeen=T; \n");
                    fuse_method = FUSE_IGNORE_CURR;
#endif
                }
            }
            else{ //if(!isInclined){ //���Ǳ�Ե, ���ڲ�
                //*seenConfid = min(Tsdf::MAX_WEIGHT, *seenConfid + 1); //v11.4 �� weiFactor ֮��, ���ﷴ���� BUG!!
                *seenConfid = min(SCHAR_MAX, *seenConfid + 1);

                if(!isSnormPrevInit){ //vray.prev ��δ��ʼ��, �� < epsilon �ж�
                    //if (*seenConfid > seenConfidTh) //����� hadSeen, ���Բ�Ҫ��ô�ж�
                        //doUpdateVrayAndSnorm = true;
                }


                if(!hadSeen){ //�� seen-flag δ��ʼ����
#if 0   //< v11.3
                    if(doDbgPrint)
                        printf("isInclined-F; hadSeen=F; >>FUSE_RESET\n");
                    *flag_pos = true;
                    fuse_method = FUSE_RESET;
#elif 1 //v11.3
                    if(doDbgPrint)
                        printf("isInclined-F; hadSeen=F; seenConfid, seenConfidTh: %d, %d, ++FUSE_KF_AVGE~~~~~\n", *seenConfid, seenConfidTh); //��Ҳû�� reset ��
                    fuse_method = FUSE_KF_AVGE;
#endif
                    //if (*seenConfid > seenConfidTh) //��Ȼ hadSeen �߼��Ĺ�, ��˴���Ȼһֱ false
                    //    doUpdateVrayAndSnorm = true;
                }
                else{ //if(hadSeen) //��֮ǰ seen, ��Ȼ������ ��isInclined-F; hadSeen=F���׶�, Ҳ��Ȼ isSnormPrevInit->true, ������ if-isSnormPrevInit
                    if(doDbgPrint)
                        printf("isInclined-F; hadSeen=T;\n");

                    //if(cos_norm > cosThresh ){ //�нǽǶ� <30��, ����ͬ�ӽ�
                    if(!isNewFace){ //ͬ�ӽ�, ˫ cos �����ж�
                        //TODO...
                        fuse_method = FUSE_KF_AVGE; //��ʵĬ��

                        //if (*seenConfid > seenConfidTh) //����, ��Ϊ���� if-hadSeen ��֧��
#if 0
                        if(cos_norm > cosThreshSnorm) //��֮ cos_norm < th ʱ, ���� newFace=false, ����Ӧ update
                            doUpdateVrayAndSnorm = true;

                        if(!isSnormPrevInit)
                            doUpdateVrayAndSnorm = true;
#elif 1 //�ĳɱ�Ȼ update @2017-7-13 15:45:12
                        doUpdateVrayAndSnorm = true;
#endif
                    }
                    else{ // >30��, ������ͬ�ӽ�, ����ת��ͷ֮��
                        //if(!isSnormPrevInit) //newFace �Ľ�֮��, ���ﲻ���ٽ���
                        //    doUpdateVrayAndSnorm = true;

#if 10   //���಻����, �������岻��ȷ, ���� @2017-3-24 17:50:24
                        //����Ϊ����
                        if(tsdf_curr < 0 && tsdf_curr < tsdf_prev1){
                            if(doDbgPrint)
                                printf("\ttsdf < 0 && tsdf < tsdf_prev1; [:=prev1, curr: %f, %f\n", tsdf_prev1, tsdf_curr);

                            fuse_method = FUSE_IGNORE_CURR;
                        }
                        else if(tsdf_prev1 < 0 && tsdf_prev1 < tsdf_curr){
                            if(doDbgPrint){
                                printf("\ttsdf_prev1 < 0 && tsdf_prev1 < tsdf; [:=prev1, curr: %f, %f\n", tsdf_prev1, tsdf_curr);
                                printf("\t\t, weight_prev1, w2ndCntThresh: %d, %d\n", weight_prev1, w2ndCntThresh);
                            }
#if 0   //weight_prev1 �Ƿ�Ҫ�� w2ndCntThresh �Ա�?
                            if(weight_prev1 > w2ndCntThresh){
                                fuse_method = FUSE_FIX_PREDICTION; //�ñ��� volume, ����-��+
                            }
                            else{
                                fuse_method = FUSE_KF_AVGE; //����Ĭ���Ƿ�������
                            }
#elif 1 //1st ���� w2ndCntThresh �Ա�, ��Ϊ�������Աȿ���: weight_new2nd > w2ndCntThresh
                            fuse_method = FUSE_FIX_PREDICTION; //�ñ��� volume, ����-��+
#endif
                            //doUpdateSnorm = true; //�ŵ� FUSE_FIX_PREDICTION ���ж�
                        }
                        else if(tsdf_curr >=0 && tsdf_prev1 >= 0){
                            if(doDbgPrint){
                                printf("\ttsdf >=0 && tsdf_prev1 >= 0; [:=prev1, curr: %f, %f\n", tsdf_prev1, tsdf_curr);
                            }
                            fuse_method = FUSE_KF_AVGE;
                            doUpdateVrayAndSnorm = true;
                        }
#endif
                    }//cos vs. cosTh
                }//if-hadSeen
            }//if-isInclined
            }//if-(weiFactor > 0.2)

            const int Wrk = max(15 * weiFactor, 1.f);
            if(FUSE_KF_AVGE == fuse_method){
                float tsdf_new1 = (tsdf_prev1 * weight_prev1 + Wrk * tsdf_curr) / (weight_prev1 + Wrk);
                int weight_new1 = min (weight_prev1 + Wrk, Tsdf::MAX_WEIGHT);

                int weight_new2nd = max(weight_prev2nd - Wrk, 0); //--, ����ֹ <0

                pack_tsdf (tsdf_new1, weight_new1, *pos1);
                pack_tsdf(tsdf_prev2nd, weight_new2nd, *pos2nd); //���� 2nd �Ƿ�������ʼ����

                if(doDbgPrint)
                    printf("++FUSE_KF_AVGE, weight_new1, weight_new2nd, %d, %d\n", weight_new1, weight_new2nd);
            }
            else if(FUSE_FIX_PREDICTION == fuse_method){ //ȡ���ֱ� FUSE_RESET
#if 0   //factor/step ��ʽ����
//                   //const int pos_neg_factor = 8;
//                   int pos_neg_factor = min(weight_prev1 / 10, 1); //������ʱ���� w1 ��ʵ����, ���Բ��ֱܴ��趨�󲽳�
//                   int pnWrk = pos_neg_factor * Wrk;
//                   float tsdf_new2nd = (tsdf_prev2nd * weight_prev2nd + pnWrk * tsdf) / (weight_prev2nd + pnWrk);
//                   int weight_new2nd = min (weight_prev2nd + pnWrk, Tsdf::MAX_WEIGHT);
// 
//                   int weight_new1 = max(weight_prev1 - pnWrk, 0);
// 
//                   if(weight_new2nd > weight_new1){ //�� 2nd ��Ϯ, �򽻻� 1st/2nd, ��Զ���� 1st Ϊ��
#elif 1
                float tsdf_new2nd = (tsdf_prev2nd * weight_prev2nd + Wrk * tsdf_curr) / (weight_prev2nd + Wrk);
                int weight_new2nd = min (weight_prev2nd + Wrk, Tsdf::MAX_WEIGHT);

                //int weight_new1 = max(weight_prev1 - Wrk, 0);
                if(weight_new2nd > w2ndCntThresh){ //���� 1st/2nd, ��Զ���� 1st Ϊ�� //����ĳ�: 2nd ������Ϯ 1st, ֻҪ����ĳ������ֵ����
#endif
                    if(doDbgPrint){
                        printf("weight_new2nd > w2ndCntThresh,,, exchanging 1st-2nd\n");
                    }
                    pack_tsdf(tsdf_new2nd, weight_new2nd, *pos1); //new-2nd �ŵ� pos-1st ��
                    //pack_tsdf(tsdf_prev1, weight_new1, *pos2nd);

                    doUpdateVrayAndSnorm = true; //ֱ�� 2nd ��Ϯ, �����µ� snorm ���µ�ǰ vxl
                }
                else{ //����
                    //pack_tsdf(tsdf_prev1, weight_new1, *pos1);
                    pack_tsdf(tsdf_new2nd, weight_new2nd, *pos2nd);
                    doUpdateVrayAndSnorm = false;
                }

                if(doDbgPrint)
                    //printf("...>>FUSE_FIX_PREDICTION, weight_new1, weight_new2nd, %d, %d\n", weight_new1, weight_new2nd);
                    printf("...>>FUSE_FIX_PREDICTION, weight_new2nd, %d\n", weight_new2nd);

                //����: ����doDbgPrint, ȫ�����, ��������û���ߵ���һ���� vxl: @2017-3-11 21:22:59
                //��: ��!! ��Ϊ FUSE_FIX_PREDICTION Ŀǰ��� case: tsdf_prev1 < 0 && tsdf_prev1 < tsdf
                //printf("...>>FUSE_FIX_PREDICTION, weight_new2nd, %d,,, [xyz]=(%d, %d, %d)\n", weight_new2nd, x, y, z);
            }
            else if(FUSE_RESET == fuse_method){
                if(doDbgPrint)
                    printf(">>FUSE_RESET\n");

                pack_tsdf(tsdf_curr, 1, *pos1);
            }
            else if(FUSE_IGNORE_CURR == fuse_method){
                if(doDbgPrint)
                    printf("==FUSE_IGNORE_CURR\n");

                //DO-NOTHING!!! //��
                //IGNʱ, ҲҪ 2nd Ūһ�� @2017-3-16 03:53:08
                int weight_new2nd = max(weight_prev2nd - Wrk, 0); //--, ����ֹ <0
                pack_tsdf(tsdf_prev2nd, weight_new2nd, *pos2nd); //���� 2nd �Ƿ�������ʼ����
            }

            if(doDbgPrint)
                printf("doUpdateSnorm: %d\n", doUpdateVrayAndSnorm);

            if(doUpdateVrayAndSnorm){
                //max (-DIVISOR, min (DIVISOR, (int)nearbyintf (tsdf * DIVISOR))); //@pack_tsdf
                //��Ϊ vray_normed.xyz ��Ȼ�� <=1, ���Բ��� max/min... ��
                (*vrayPrev_pos).x = (int)nearbyintf(vray_normed.x * CHAR_MAX); //float2char
                (*vrayPrev_pos).y = (int)nearbyintf(vray_normed.y * CHAR_MAX);
                (*vrayPrev_pos).z = (int)nearbyintf(vray_normed.z * CHAR_MAX);

                //���� pcc �� nmap ����֮��, ��Ե����׼ (��Ϊ sobel?), Ҫ�е�; ������һЩ���� @2017-3-15 16:54:25
                //�� 4:=7/2+1
                const int edgeMarg = 4;
                if(coo.x < edgeMarg || coo.x >= depthScaled.cols - edgeMarg || coo.y < edgeMarg || coo.y >= depthScaled.rows - edgeMarg){
                    if(doDbgPrint)
                        printf("+++++++++++++++at edge, dont-update-snorm; coo.xy: (%d, %d)\n", coo.x, coo.y);
                }
                else{
                    //(*snorm_pos).w += 1; //�� snormPrevConfid
                    *snormPrevConfid = min(SCHAR_MAX, *snormPrevConfid + 1);

                    if(!isSnormPrevInit || isNewFace){
                        if(doDbgPrint)
                            printf("\t(!isSnormPrevInit || isNewFace): %d, %d; snormPrevConfid: %d\n", isSnormPrevInit, isNewFace, (*snorm_pos).w);

                        (*snorm_pos).x = (int)nearbyintf(snorm_curr_g.x * CHAR_MAX); //float2char
                        (*snorm_pos).y = (int)nearbyintf(snorm_curr_g.y * CHAR_MAX);
                        (*snorm_pos).z = (int)nearbyintf(snorm_curr_g.z * CHAR_MAX);
                    }
                    else{ //isSnormPrevInit && !isNewFace //v11.6: ��snorm ��ʼ������, �ҵ�ǰû��ͻ��, ���� model �ķ���, ��Ϊ����ȶ�
                        if(doDbgPrint)
                            printf("\tisSnormPrevInit && !isNewFace\n");

                        float3 snorm_model_g;
                        snorm_model_g.x = nmap_model_g.ptr(coo.y)[coo.x];
                        snorm_model_g.y = nmap_model_g.ptr(coo.y + depthScaled.rows)[coo.x];
                        snorm_model_g.z = nmap_model_g.ptr(coo.y + 2 * depthScaled.rows)[coo.x];

                        float cos_vray_norm_model = dot(snorm_model_g, vray_normed);
                        if(cos_vray_norm_model > 0){ //����assert, Ҫ�����: �н�>90��, ��������볯�������ͷ
                            //printf("ERROR+++++++++++++++cos_vray_norm > 0");

                            //���費��֤�ⲿ����ȷԤ����
                            snorm_model_g.x *= -1;
                            snorm_model_g.y *= -1;
                            snorm_model_g.z *= -1;
                        }
                        if(doDbgPrint)
                            printf("\t\tcos_vray_norm_model, %f; snorm_model_g: [%f, %f, %f], vray_normed: [%f, %f, %f]\n", cos_vray_norm_model, snorm_model_g.x, snorm_model_g.y, snorm_model_g.z, vray_normed.x, vray_normed.y, vray_normed.z);

                        float cos_norm_model_and_prev = dot(snorm_model_g, snormPrev);
                        //��--����˵, ��ʱ n_model, n_curr Ӧ�üнǺ�С (�Ѿ��������������� ��1 �˷�) //v11.7   @2017-3-17 15:52:25
                        //������Ϊ����, ���� n_model ƫ�����, ����ȫ������:
                        //if(cos_norm_model_and_prev > cosThreshSnorm){
                        //if(1){ //���� snormPrev ����

                        //zc: ���߼�: �� snorm-model/curr ����Ÿ��� @2017-4-25 21:24:23
                        float cos_norm_model_and_curr = dot(snorm_model_g, snorm_curr_g);
                        if(cos_norm_model_and_curr > cosThreshSnorm){
                            //���� __float2int_rd �� round-down �����˻�����, ��ֵ���ȶ�, ���� nearbyintf (������)?  @2017-3-15 15:33:33
                            (*snorm_pos).x = (int)nearbyintf(snorm_model_g.x * CHAR_MAX); //float2char
                            (*snorm_pos).y = (int)nearbyintf(snorm_model_g.y * CHAR_MAX);
                            (*snorm_pos).z = (int)nearbyintf(snorm_model_g.z * CHAR_MAX);
                        }
                        else{
                            //DO-NOTHING!!!
                        }
                    }
                }//cut-edgeMarg

                if(doDbgPrint){
                    printf("newVray: [%d, %d, %d]\n", (*vrayPrev_pos).x, (*vrayPrev_pos).y, (*vrayPrev_pos).z);
                    printf("\tnewSnorm: [%d, %d, %d]\n", (*snorm_pos).x, (*snorm_pos).y, (*snorm_pos).z);
                }
            }//if-(doUpdateVrayAndSnorm)
          }//if- (Dp_scaled != 0 && sdf >= -tranc_dist)
          else{
              if(doDbgPrint)
                  printf("NOT (Dp_scaled != 0 && sdf >= -tranc_dist)\n");
          }
        }//if- 0 < (x,y) < (cols,rows)
      }// for(int z = 0; z < VOLUME_Z; ++z)
    }//tsdf23_v11_remake


    __global__ void
    tsdf23normal_hack (const PtrStepSz<float> depthScaled, PtrStep<short2> volume,
                  const float tranc_dist, const Mat33 Rcurr_inv, const float3 tcurr, const Intr intr, const float3 cell_size)
    {
        int x = threadIdx.x + blockIdx.x * blockDim.x;
        int y = threadIdx.y + blockIdx.y * blockDim.y;

        if (x >= VOLUME_X || y >= VOLUME_Y)
            return;

        const float v_g_x = (x + 0.5f) * cell_size.x - tcurr.x;
        const float v_g_y = (y + 0.5f) * cell_size.y - tcurr.y;
        float v_g_z = (0 + 0.5f) * cell_size.z - tcurr.z;

        float v_g_part_norm = v_g_x * v_g_x + v_g_y * v_g_y;

        float v_x = (Rcurr_inv.data[0].x * v_g_x + Rcurr_inv.data[0].y * v_g_y + Rcurr_inv.data[0].z * v_g_z) * intr.fx;
        float v_y = (Rcurr_inv.data[1].x * v_g_x + Rcurr_inv.data[1].y * v_g_y + Rcurr_inv.data[1].z * v_g_z) * intr.fy;
        float v_z = (Rcurr_inv.data[2].x * v_g_x + Rcurr_inv.data[2].y * v_g_y + Rcurr_inv.data[2].z * v_g_z);

        float z_scaled = 0;

        float Rcurr_inv_0_z_scaled = Rcurr_inv.data[0].z * cell_size.z * intr.fx;
        float Rcurr_inv_1_z_scaled = Rcurr_inv.data[1].z * cell_size.z * intr.fy;

        float tranc_dist_inv = 1.0f / tranc_dist;

        short2* pos = volume.ptr (y) + x;
        int elem_step = volume.step * VOLUME_Y / sizeof(short2);

        //#pragma unroll
        for (int z = 0; z < VOLUME_Z;
            ++z,
            v_g_z += cell_size.z,
            z_scaled += cell_size.z,
            v_x += Rcurr_inv_0_z_scaled,
            v_y += Rcurr_inv_1_z_scaled,
            pos += elem_step)
        {
            float inv_z = 1.0f / (v_z + Rcurr_inv.data[2].z * z_scaled);
            if (inv_z < 0)
                continue;

            // project to current cam
            int2 coo =
            {
                __float2int_rn (v_x * inv_z + intr.cx),
                __float2int_rn (v_y * inv_z + intr.cy)
            };

            if (coo.x >= 0 && coo.y >= 0 && coo.x < depthScaled.cols && coo.y < depthScaled.rows)         //6
            {
                float Dp_scaled = depthScaled.ptr (coo.y)[coo.x]; //meters

                float sdf = Dp_scaled - sqrtf (v_g_z * v_g_z + v_g_part_norm);

                if (Dp_scaled != 0 && sdf >= -tranc_dist) //meters
                {
                    float tsdf = fmin (1.0f, sdf * tranc_dist_inv);                                              

                    bool integrate = true;
                    if ((x > 0 &&  x < VOLUME_X-2) && (y > 0 && y < VOLUME_Y-2) && (z > 0 && z < VOLUME_Z-2))
                    {
                        const float qnan = numeric_limits<float>::quiet_NaN();
                        float3 normal = make_float3(qnan, qnan, qnan);

                        float Fn, Fp;
                        int Wn = 0, Wp = 0;
                        unpack_tsdf (*(pos + elem_step), Fn, Wn);
                        unpack_tsdf (*(pos - elem_step), Fp, Wp);

                        if (Wn > 16 && Wp > 16) 
                            normal.z = (Fn - Fp)/cell_size.z;

                        unpack_tsdf (*(pos + volume.step/sizeof(short2) ), Fn, Wn);
                        unpack_tsdf (*(pos - volume.step/sizeof(short2) ), Fp, Wp);

                        if (Wn > 16 && Wp > 16) 
                            normal.y = (Fn - Fp)/cell_size.y;

                        unpack_tsdf (*(pos + 1), Fn, Wn);
                        unpack_tsdf (*(pos - 1), Fp, Wp);

                        if (Wn > 16 && Wp > 16) 
                            normal.x = (Fn - Fp)/cell_size.x;

                        if (normal.x != qnan && normal.y != qnan && normal.z != qnan)
                        {
                            float norm2 = dot(normal, normal);
                            if (norm2 >= 1e-10)
                            {
                                normal *= rsqrt(norm2);

                                float nt = v_g_x * normal.x + v_g_y * normal.y + v_g_z * normal.z;
                                float cosine = nt * rsqrt(v_g_x * v_g_x + v_g_y * v_g_y + v_g_z * v_g_z);

                                if (cosine < 0.5)
                                    integrate = false;
                            }
                        }
                    }

                    if (integrate)
                    {
                        //read and unpack
                        float tsdf_prev;
                        int weight_prev;
                        unpack_tsdf (*pos, tsdf_prev, weight_prev);

                        const int Wrk = 1;

                        float tsdf_new = (tsdf_prev * weight_prev + Wrk * tsdf) / (weight_prev + Wrk);
                        int weight_new = min (weight_prev + Wrk, Tsdf::MAX_WEIGHT);

                        pack_tsdf (tsdf_new, weight_new, *pos);
                    }
                }
            }
        }       // for(int z = 0; z < VOLUME_Z; ++z)
    }      // __global__
  }

    __global__ void
    tsdf23test (const PtrStepSz<float> depthScaled, PtrStep<short2> volume,
            const float tranc_dist, const Mat33 Rcurr_inv, const float3 tcurr, const Intr intr, const float3 cell_size, const pcl::gpu::tsdf_buffer buffer)
    {
      int x = threadIdx.x + blockIdx.x * blockDim.x;
      int y = threadIdx.y + blockIdx.y * blockDim.y;

      if (x >= buffer.voxels_size.x || y >= buffer.voxels_size.y)
        return;

      float v_g_x = (x + 0.5f) * cell_size.x - tcurr.x;
      float v_g_y = (y + 0.5f) * cell_size.y - tcurr.y;
      float v_g_z = (0 + 0.5f) * cell_size.z - tcurr.z;

      float v_g_part_norm = v_g_x * v_g_x + v_g_y * v_g_y;

      float v_x = (Rcurr_inv.data[0].x * v_g_x + Rcurr_inv.data[0].y * v_g_y + Rcurr_inv.data[0].z * v_g_z) * intr.fx;
      float v_y = (Rcurr_inv.data[1].x * v_g_x + Rcurr_inv.data[1].y * v_g_y + Rcurr_inv.data[1].z * v_g_z) * intr.fy;
      float v_z = (Rcurr_inv.data[2].x * v_g_x + Rcurr_inv.data[2].y * v_g_y + Rcurr_inv.data[2].z * v_g_z);

      float z_scaled = 0;

      float Rcurr_inv_0_z_scaled = Rcurr_inv.data[0].z * cell_size.z * intr.fx;
      float Rcurr_inv_1_z_scaled = Rcurr_inv.data[1].z * cell_size.z * intr.fy;

      float tranc_dist_inv = 1.0f / tranc_dist;

      short2* pos = volume.ptr (y) + x;
      
      // shift the pointer to relative indices
      shift_tsdf_pointer(&pos, buffer);
      
      int elem_step = volume.step * buffer.voxels_size.y / sizeof(short2);

//#pragma unroll
      for (int z = 0; z < buffer.voxels_size.z;
           ++z,
           v_g_z += cell_size.z,
           z_scaled += cell_size.z,
           v_x += Rcurr_inv_0_z_scaled,
           v_y += Rcurr_inv_1_z_scaled,
           pos += elem_step)
      {
        
        // As the pointer is incremented in the for loop, we have to make sure that the pointer is never outside the memory
        if(pos > buffer.tsdf_memory_end)
          pos -= (buffer.tsdf_memory_end - buffer.tsdf_memory_start + 1);
        
        float inv_z = 1.0f / (v_z + Rcurr_inv.data[2].z * z_scaled);
        if (inv_z < 0)
            continue;

        // project to current cam
		// old code
        int2 coo =
        {
          __float2int_rn (v_x * inv_z + intr.cx),
          __float2int_rn (v_y * inv_z + intr.cy)
        };

        if (coo.x >= 0 && coo.y >= 0 && coo.x < depthScaled.cols && coo.y < depthScaled.rows)         //6
        {
          float Dp_scaled = depthScaled.ptr (coo.y)[coo.x]; //meters

          float sdf = Dp_scaled - sqrtf (v_g_z * v_g_z + v_g_part_norm);

          if (Dp_scaled != 0 && sdf >= -tranc_dist) //meters
          {
            float tsdf = fmin (1.0f, sdf * tranc_dist_inv);

            //read and unpack
            float tsdf_prev;
            int weight_prev;
            unpack_tsdf (*pos, tsdf_prev, weight_prev);

            const int Wrk = 1;

            float tsdf_new = (tsdf_prev * weight_prev + Wrk * tsdf) / (weight_prev + Wrk);
            int weight_new = min (weight_prev + Wrk, Tsdf::MAX_WEIGHT);

            pack_tsdf (tsdf_new, weight_new, *pos);
          }
        }
      }       // for(int z = 0; z < VOLUME_Z; ++z)
    }      // __global__
}

//////////////////////////////////////////////////////////////////////////////////////////////////////////////////
void
pcl::device::integrateTsdfVolume (const PtrStepSz<ushort>& depth, const Intr& intr,
                                  const float3& volume_size, const Mat33& Rcurr_inv, const float3& tcurr, 
                                  float tranc_dist,
                                  //PtrStep<short2> volume, const pcl::gpu::tsdf_buffer* buffer, DeviceArray2D<float>& depthScaled)
                                  PtrStep<short2> volume, const pcl::gpu::tsdf_buffer* buffer, DeviceArray2D<float>& depthScaled, int3 vxlDbg) //zc: ����
{
  depthScaled.create (depth.rows, depth.cols);

  dim3 block_scale (32, 8);
  dim3 grid_scale (divUp (depth.cols, block_scale.x), divUp (depth.rows, block_scale.y));

  //scales depth along ray and converts mm -> meters. 
  scaleDepth<<<grid_scale, block_scale>>>(depth, depthScaled, intr);
  cudaSafeCall ( cudaGetLastError () );

  float3 cell_size;
  cell_size.x = volume_size.x / buffer->voxels_size.x;
  cell_size.y = volume_size.y / buffer->voxels_size.y;
  cell_size.z = volume_size.z / buffer->voxels_size.z;

  //dim3 block(Tsdf::CTA_SIZE_X, Tsdf::CTA_SIZE_Y);
  dim3 block (16, 16);
  dim3 grid (divUp (buffer->voxels_size.x, block.x), divUp (buffer->voxels_size.y, block.y));

  //tsdf23<<<grid, block>>>(depthScaled, volume, tranc_dist, Rcurr_inv, tcurr, intr, cell_size, *buffer);    
  tsdf23<<<grid, block>>>(depthScaled, volume, tranc_dist, Rcurr_inv, tcurr, intr, cell_size, *buffer, vxlDbg);    

//  for ( int i = 0; i < 100; i++ )
//    tsdf23test<<<grid, block>>>(depthScaled, volume, tranc_dist, Rcurr_inv, tcurr, intr, cell_size, *buffer);    

  //tsdf23normal_hack<<<grid, block>>>(depthScaled, volume, tranc_dist, Rcurr_inv, tcurr, intr, cell_size);

  cudaSafeCall ( cudaGetLastError () );
  cudaSafeCall (cudaDeviceSynchronize ());
}

/////////////////////////////////////////////////////////////////////////////////////////////////////////////////
void 
pcl::device::integrateTsdfVolume_v11 (const PtrStepSz<ushort>& depth, const Intr& intr, const float3& volume_size, 
    const Mat33& Rcurr_inv, const float3& tcurr, float tranc_dist, PtrStep<short2> volume, 
    PtrStep<short2> volume2nd, PtrStep<bool> flagVolume, PtrStep<char4> surfNormVolume, PtrStep<char4> vrayPrevVolume, DeviceArray2D<unsigned char> incidAngleMask, 
    const MapArr& nmap_curr_g, const MapArr &nmap_model_g,
    const MapArr &weight_map, //v11.4
    DeviceArray2D<float>& depthScaled, int3 vxlDbg)
{
    depthScaled.create (depth.rows, depth.cols);

    dim3 block_scale (32, 8);
    dim3 grid_scale (divUp (depth.cols, block_scale.x), divUp (depth.rows, block_scale.y));

    //scales depth along ray and converts mm -> meters. 
    scaleDepth<<<grid_scale, block_scale>>>(depth, depthScaled, intr);
    cudaSafeCall ( cudaGetLastError () );

    float3 cell_size;
    cell_size.x = volume_size.x / VOLUME_X;
    cell_size.y = volume_size.y / VOLUME_Y;
    cell_size.z = volume_size.z / VOLUME_Z;

    //dim3 block(Tsdf::CTA_SIZE_X, Tsdf::CTA_SIZE_Y);
    dim3 block (16, 16);
    dim3 grid (divUp (VOLUME_X, block.x), divUp (VOLUME_Y, block.y));

    printf("vxlDbg@integrateTsdfVolume_v11: [%d, %d, %d]\n", vxlDbg.x, vxlDbg.y, vxlDbg.z);

    //tsdf23<<<grid, block>>>(depthScaled, volume, tranc_dist, Rcurr_inv, tcurr, intr, cell_size);    
    //tsdf23_v11<<<grid, block>>>(depthScaled, volume, 
    tsdf23_v11_remake<<<grid, block>>>(depthScaled, volume, 
        volume2nd, flagVolume, surfNormVolume, vrayPrevVolume, incidAngleMask, 
        nmap_curr_g, nmap_model_g,
        weight_map,
        tranc_dist, Rcurr_inv, tcurr, intr, cell_size, vxlDbg);    
}//integrateTsdfVolume_v11

/////////////////////////////////////////////////////////////////////////////////////////////////////////////////
void 
pcl::device::clearTSDFSlice (PtrStep<short2> volume, pcl::gpu::tsdf_buffer* buffer, int shiftX, int shiftY, int shiftZ)
{
    int newX = buffer->origin_GRID.x + shiftX;
    int newY = buffer->origin_GRID.y + shiftY;

    int3 minBounds, maxBounds;
    
	/*
    //X
    if(newX >= 0)
    {
     minBounds.x = buffer->origin_GRID.x;
     maxBounds.x = newX;    
    }
    else
    {
     minBounds.x = newX + buffer->voxels_size.x; 
     maxBounds.x = buffer->origin_GRID.x + buffer->voxels_size.x;
    }
    
    if(minBounds.x > maxBounds.x)
     std::swap(minBounds.x, maxBounds.x);
      
   
    //Y
    if(newY >= 0)
    {
     minBounds.y = buffer->origin_GRID.y;
     maxBounds.y = newY;
    }
    else
    {
     minBounds.y = newY + buffer->voxels_size.y; 
     maxBounds.y = buffer->origin_GRID.y + buffer->voxels_size.y;
    }
    
    if(minBounds.y > maxBounds.y)
     std::swap(minBounds.y, maxBounds.y);
	 */
	if ( shiftX >= 0 ) {
		minBounds.x = buffer->origin_GRID.x;
		maxBounds.x = newX - 1;
	} else {
		minBounds.x = newX;
		maxBounds.x = buffer->origin_GRID.x - 1;
	}
	if ( minBounds.x < 0 ) {
		minBounds.x += buffer->voxels_size.x;
		maxBounds.x += buffer->voxels_size.x;
	}

	if ( shiftY >= 0 ) {
		minBounds.y = buffer->origin_GRID.y;
		maxBounds.y = newY - 1;
	} else {
		minBounds.y = newY;
		maxBounds.y = buffer->origin_GRID.y - 1;
	}
	if ( minBounds.y < 0 ) {
		minBounds.y += buffer->voxels_size.y;
		maxBounds.y += buffer->voxels_size.y;
	}
    //Z
     minBounds.z = buffer->origin_GRID.z;
     maxBounds.z = shiftZ;
  
    // call kernel
    dim3 block (32, 16);
    dim3 grid (1, 1, 1);
    grid.x = divUp (buffer->voxels_size.x, block.x);      
    grid.y = divUp (buffer->voxels_size.y, block.y);
    
    clearSliceKernel<<<grid, block>>>(volume, *buffer, minBounds, maxBounds);
    cudaSafeCall ( cudaGetLastError () );
    cudaSafeCall (cudaDeviceSynchronize ());
   
}//clearTSDFSlice

/////////////////////////////////////////////////////////////////////////////////////////////////////////////////
//������ contour_cue_impl.cu, ��Ϊ�ֶ��޷���ӵ��˹���, �������� cmake, ���»���; ����ֱ��Դ�뿽��
namespace zc{

//@brief gpu kernel function to generate the Contour-Correspondence-Candidates
//@param[in] angleThreshCos, MAX cosine of the angle threshold
//@ע�� kernel ������������Ϊ GPU �ڴ�ָ�����󿽱���e.g., ����Ϊ float3 ���� float3&
__global__ void 
cccKernel(const float3 camPos, const PtrStep<float> vmap, const PtrStep<float> nmap, float angleThreshCos, PtrStepSz<_uchar> outMask){
    int x = threadIdx.x + blockIdx.x * blockDim.x,
        y = threadIdx.y + blockIdx.y * blockDim.y;
    //printf("### %d, %d\n", x, y);

    int cols = outMask.cols,
        rows = outMask.rows;

    if(!(x < cols && y < rows))
        return;

    outMask.ptr(y)[x] = 0;

    if(isnan(nmap.ptr(y)[x]) || isnan(vmap.ptr(y)[x])){
        //printf("\tisnan: %d, %d\n", x, y);
        return;
    }

    float3 n, vRay;
    n.x = nmap.ptr(y)[x];
    n.y = nmap.ptr(y + rows)[x];
    n.z = nmap.ptr(y + 2 * rows)[x];

    vRay.x = camPos.x - vmap.ptr(y)[x];
    vRay.y = camPos.y - vmap.ptr(y + rows)[x];
    vRay.z = camPos.z - vmap.ptr(y + 2 * rows)[x];

    double nMod = norm(n); //�����Ϻ����1��
    double vRayMod = norm(vRay);
    //printf("@@@ %f, %f\n", nMod, vRayMod);

    double cosine = dot(n, vRay) / (vRayMod * nMod);
    if(abs(cosine) < angleThreshCos)
        outMask.ptr(y)[x] = UCHAR_MAX;
}//cccKernel

void contourCorrespCandidate(const float3 &camPos, const MapArr &vmap, const MapArr &nmap, int angleThresh, pcl::device::MaskMap &outMask ){
    int cols = vmap.cols();
    int rows = vmap.rows() / 3;
    
    outMask.create(rows, cols);

    dim3 block(32, 8);
    dim3 grid(divUp(cols, block.x), divUp(rows, block.y));

    const float angleThreshCos = cos(angleThresh * 3.14159265359f / 180.f);
    //printf("vmap, nmap shape: [%d, %d], [%d, %d]\n", vmap.rows(), vmap.cols(), nmap.rows(), nmap.cols()); //test OK
    cccKernel<<<grid, block>>>(camPos, vmap, nmap, angleThreshCos, outMask);

    cudaSafeCall(cudaDeviceSynchronize());
    cudaSafeCall(cudaGetLastError());
}//contourCorrespCandidate

__global__ void
calcWmapKernel(int rows, int cols, const PtrStep<float> vmapLocal, const PtrStep<float> nmapLocal, const PtrStepSz<_uchar> contMask, PtrStepSz<float> wmap_out){
    int x = threadIdx.x + blockIdx.x * blockDim.x,
        y = threadIdx.y + blockIdx.y * blockDim.y;

    const float qnan = pcl::device::numeric_limits<float>::quiet_NaN();
    if(!(x < cols && y < rows))
        return;

    //������:
    bool doDbgPrint = false;
//     if(x == 388 && y == 292)
//         doDbgPrint = true;

    wmap_out.ptr(y)[x] = 0; //Ĭ�ϳ�ʼȨ��=0

    float3 vray; //local
    vray.x = vmapLocal.ptr(y)[x];
    if(isnan(vray.x))
        return;

    vray.y = vmapLocal.ptr(y + rows)[x];
    vray.z = vmapLocal.ptr(y + 2 * rows)[x]; //meters

    float3 snorm;
    snorm.x = nmapLocal.ptr(y)[x];
    snorm.y = nmapLocal.ptr(y + rows)[x];
    snorm.z = nmapLocal.ptr(y + 2 * rows)[x];

    //���費ȷ�� normalize ��: Ҫ��һ��, ��ȷ�� snorm �����ӵ�: Ҫ abs
    float cosine = dot(vray, snorm) / (norm(snorm) * norm(vray));
    cosine = abs(cosine);

#if 0   //v0: KinectFusion �����ᵽ�� "������...", �ֲ�
    //wmap_out.ptr(y)[x] = cosine * zmin / max(zmin, vray.z); //���Ų��ܿ���, ��Χ���ڹ� ( cos->0, z->+inf ); ������� minXXfactor Լ�� ��
#elif 10 //v1: �п������ŷ�Χ
    const float minCosFactor = .5f; //cos min��������, ���� 90��, ����Ҳ�� 1/2, ����̫С
    const float cosMin = 0.5f; //60��, �� theta<60��, �������ӹ̶�Ϊ 1, ����ȫ������� 0~60��ʱ�����ֵ
    float cosFactor = 1;
    if(cosine < cosMin)
        cosFactor = 1 - (1 - 2 * cosine) * (1 - minCosFactor) / 1; //�����ĸ�� 1= (1-0)

    const float minZfactor = .5f; //���ֵ min��������
    const float zmin = 0.5f,
                zmax = 3.f; //meters, zmax �˴�����������޶������Ч���, ֻ��ȷ�� zmax ��, ����Ϊ minZfactor (ԭ������=1/6)

    float oldMinZfactor = zmin / zmax;
    //float zFactor = 1 - (1 - vray.z) * (1 - minZfactor)/ (1 - rawMinZfactor); //��
    float zFactor = zmin / min(zmax, max(zmin, vray.z)); //1/6 <= factor <= 1
    //��--[1/6, 1] -> [.5, 1]
    zFactor = 1 - (1 - zFactor) * (1 - minZfactor) / (1 - oldMinZfactor);

    float contFactor = 1;
    if(contMask.ptr(y)[x] != 0) //��Ե��Ȩ, ��ֹ����
        contFactor = 0.3f;

    wmap_out.ptr(y)[x] = cosFactor * zFactor * contFactor;
#endif 

}//calcWmapKernel

//@brief v2, ֮ǰ contMask ����������Ȩ�� mask, �ĳɸ�����, ƽ������Ȩ�� (������ edgeDistMap)
//@param[in] edgeDistMap, ����Ե���ؾ��� mat: ֵԽС,���ԵԽ��, tsdfȨ���Լ�tsdf�ض���ֵԽС; ��Ҫ��� vmap.z ת��������߶Ⱦ���,
//@param[in] fxy, ��һ������Լ��, �������� 
__global__ void
calcWmapKernel(int rows, int cols, const PtrStep<float> vmapLocal, const PtrStep<float> nmapLocal, const PtrStepSz<float> edgeDistMap, float fxy, PtrStepSz<float> wmap_out){
    int x = threadIdx.x + blockIdx.x * blockDim.x,
        y = threadIdx.y + blockIdx.y * blockDim.y;

    const float qnan = pcl::device::numeric_limits<float>::quiet_NaN();
    if(!(x < cols && y < rows))
        return;

    //������:
    bool doDbgPrint = false;
//     if(x == 388 && y == 292)
//         doDbgPrint = true;

    wmap_out.ptr(y)[x] = 0; //Ĭ�ϳ�ʼȨ��=0

    float3 vray; //local
    vray.x = vmapLocal.ptr(y)[x];
    if(isnan(vray.x))
        return;

    vray.y = vmapLocal.ptr(y + rows)[x];
    vray.z = vmapLocal.ptr(y + 2 * rows)[x]; //meters

    float3 snorm;
    snorm.x = nmapLocal.ptr(y)[x];
    snorm.y = nmapLocal.ptr(y + rows)[x];
    snorm.z = nmapLocal.ptr(y + 2 * rows)[x];

    //���費ȷ�� normalize ��: Ҫ��һ��, ��ȷ�� snorm �����ӵ�: Ҫ abs
    float cosine = dot(vray, snorm) / (norm(snorm) * norm(vray));
    cosine = abs(cosine); //ȡ���

#if 0   //v0: KinectFusion �����ᵽ�� "������...", �ֲ�
    //wmap_out.ptr(y)[x] = cosine * zmin / max(zmin, vray.z); //���Ų��ܿ���, ��Χ���ڹ� ( cos->0, z->+inf ); ������� minXXfactor Լ�� ��
#elif 10 //v1: �п������ŷ�Χ
    const float minCosFactor = .3f; //cos min��������, ���� 90��, ����Ҳ�� 1/2, ����̫С
    const float cosMin = 0.5f; //60��, �� theta<60��, �������ӹ̶�Ϊ 1, ����ȫ������� 0~60��ʱ�����ֵ
    float cosFactor = 1;
    if(cosine < cosMin) //ȷ����Ҫ cos >1
        cosFactor = 1 - (1 - 2 * cosine) * (1 - minCosFactor) / 1; //�����ĸ�� 1= (1-0)

    const float minZfactor = .5f; //���ֵ min��������
    const float zmin = 0.5f,
                zmax = 3.f; //meters, zmax �˴�����������޶������Ч���, ֻ��ȷ�� zmax ��, ����Ϊ minZfactor (ԭ������=1/6)

    float oldMinZfactor = zmin / zmax;
    //float zFactor = 1 - (1 - vray.z) * (1 - minZfactor)/ (1 - rawMinZfactor); //��
    float zFactor = zmin / min(zmax, max(zmin, vray.z)); //1/6 <= factor <= 1
    //��--[1/6, 1] -> [.5, 1]
    zFactor = 1 - (1 - zFactor) * (1 - minZfactor) / (1 - oldMinZfactor);

#if 0   //contMask ��������
    float contFactor = 1;
    if(contMask.ptr(y)[x] != 0) //��Ե��Ȩ, ��ֹ����
        contFactor = 0.3f;

    wmap_out.ptr(y)[x] = cosFactor * zFactor * contFactor;
#elif 1 //edgeDistMap ��������
    const float maxEdgeDist = 30; //in mm
    float edgeDistMm = edgeDistMap.ptr(y)[x] / fxy * vray.z * 1e3; //in mm

    float edgeDistFactor = 1.f;
    if(edgeDistMm < maxEdgeDist) //������ 1
        edgeDistFactor = edgeDistMm / maxEdgeDist;

    wmap_out.ptr(y)[x] = cosFactor * zFactor * edgeDistFactor;
#endif

#endif //�������޿���


}//calcWmapKernel-v2

void calcWmap(const MapArr &vmapLocal, const MapArr &nmapLocal, const pcl::device::MaskMap &contMask, MapArr &wmap_out){
    int cols = vmapLocal.cols(),
        rows = vmapLocal.rows() / 3;

    wmap_out.create(rows, cols);

    dim3 block(32, 8);
    dim3 grid(divUp(cols, block.x), divUp(rows, block.y));

    calcWmapKernel<<<grid, block>>>(rows, cols, vmapLocal, nmapLocal, contMask, wmap_out);
    
    cudaSafeCall(cudaGetLastError());
    cudaSafeCall(cudaDeviceSynchronize());
}//calcWmap

void calcWmap(const MapArr &vmapLocal, const MapArr &nmapLocal, const DeviceArray2D<float> &edgeDistMap, const float fxy, MapArr &wmap_out){
    int cols = vmapLocal.cols(),
        rows = vmapLocal.rows() / 3;

    wmap_out.create(rows, cols);

    dim3 block(32, 8);
    dim3 grid(divUp(cols, block.x), divUp(rows, block.y));

    calcWmapKernel<<<grid, block>>>(rows, cols, vmapLocal, nmapLocal, edgeDistMap, fxy, wmap_out);
    
    cudaSafeCall(cudaGetLastError());
    cudaSafeCall(cudaDeviceSynchronize());
}//calcWmap

__global__ void
transformVmapKernel(int rows, int cols, const PtrStep<float> vmap_src, const Mat33 Rmat, const float3 tvec, PtrStepSz<float> vmap_dst){
    int x = threadIdx.x + blockIdx.x * blockDim.x,
        y = threadIdx.y + blockIdx.y * blockDim.y;

    const float qnan = pcl::device::numeric_limits<float>::quiet_NaN();
    if(!(x < cols && y < rows))
        return;

    float3 vsrc, vdst = make_float3(qnan, qnan, qnan);
    vsrc.x = vmap_src.ptr(y)[x];

    if(!isnan(vsrc.x)){
        vsrc.y = vmap_src.ptr(y + rows)[x];
        vsrc.z = vmap_src.ptr(y + 2 * rows)[x];

        vdst = Rmat * vsrc + tvec;

        vmap_dst.ptr (y + rows)[x] = vdst.y;
        vmap_dst.ptr (y + 2 * rows)[x] = vdst.z;
    }

    //ȷʵӦ������������Ƿ� isnan(vdst.x)
    vmap_dst.ptr(y)[x] = vdst.x;
}//transformVmapKernel

void transformVmap( const MapArr &vmap_src, const Mat33 &Rmat, const float3 &tvec, MapArr &vmap_dst ){
    int cols = vmap_src.cols(),
        rows = vmap_src.rows() / 3;

    vmap_dst.create(rows * 3, cols);
    
    dim3 block(32, 8);
    dim3 grid(divUp(cols, block.x), divUp(rows, block.y));

    transformVmapKernel<<<grid, block>>>(rows, cols, vmap_src, Rmat, tvec, vmap_dst);

    cudaSafeCall(cudaGetLastError());
    cudaSafeCall(cudaDeviceSynchronize());
}//transformVmap

}//namespace zc