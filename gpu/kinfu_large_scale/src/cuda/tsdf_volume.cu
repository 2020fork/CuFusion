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

/*__global__ */__device__
const float COS30 = 0.8660254f
    ,COS45 = 0.7071f
    ,COS60 = 0.5f
    ,COS75 = 0.258819f
    ,COS80 = 0.173649f
    ;

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

        ,MAX_WEIGHT_V13 = 1<<8
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

#if 01
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
            //v17, Ϊ��� v17 �� w ������ĩλ�����λ, ���������޸�: unpack ʱ /2, pack ʱ *2; @2018-1-22 02:01:27
            weight_prev = weight_prev >> 1;

            const int Wrk = 1;

            float tsdf_new = (tsdf_prev * weight_prev + Wrk * tsdf) / (weight_prev + Wrk);
            int weight_new = min (weight_prev + Wrk, Tsdf::MAX_WEIGHT);

            if(doDbgPrint){
                printf("tsdf_prev, tsdf, tsdf_new: %f, %f, %f\n", tsdf_prev, tsdf, tsdf_new);
            }

            weight_new = weight_new << 1; //ʡ����+0, v17 �ı��λĬ��ֵ=0
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
    }      // __global__ tsdf23

    __global__ void
    tsdf23_s2s (const PtrStepSz<float> depthScaled, PtrStep<short2> volume,
            const float tranc_dist, const float eta, //s2s (delta, eta)
            const Mat33 Rcurr_inv, const float3 tcurr, 
            const Intr intr, const float3 cell_size, int3 vxlDbg) //zc: ����
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
        bool doDbgPrint = false;
        if(x > 0 && y > 0 && z > 0 //����Ĭ�� 000, ����Чֵ, �������Ӵ˼��
            && vxlDbg.x == x && vxlDbg.y == y && vxlDbg.z == z)
            doDbgPrint = true;

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
              printf("@tsdf23_s2s: Dp_scaled, sdf, tranc_dist: %f, %f, %f, %s; sdf/tdist: %f, coo.xy: (%d, %d)\n", Dp_scaled, sdf, tranc_dist, 
                  sdf >= -tranc_dist ? "sdf >= -tranc_dist" : "", sdf/tranc_dist, coo.x, coo.y);
          }

          //if (Dp_scaled != 0 && sdf >= -tranc_dist) //meters
          if (Dp_scaled != 0 && sdf >= -eta) //meters //�Ƚ� eta , ���� delta (tdist)
          {
            float tsdf = fmin (1.0f, sdf * tranc_dist_inv);

            if(sdf < -tranc_dist)
                tsdf = -1.0f;

#if 10   //�����ۼ�
            //read and unpack
            float tsdf_prev;
            int weight_prev;
            unpack_tsdf (*pos, tsdf_prev, weight_prev);
            //v17, Ϊ��� v17 �� w ������ĩλ�����λ, ���������޸�: unpack ʱ /2, pack ʱ *2; @2018-1-22 02:01:27
            weight_prev = weight_prev >> 1;

            const int Wrk = 1;

            float tsdf_new = (tsdf_prev * weight_prev + Wrk * tsdf) / (weight_prev + Wrk);
            int weight_new = min (weight_prev + Wrk, Tsdf::MAX_WEIGHT);

            if(doDbgPrint){
                printf("tsdf_prev, tsdf_curr, tsdf_new: %f, %f, %f; wp, wnew: %d, %d\n", tsdf_prev, tsdf, tsdf_new, weight_prev, weight_new);
            }
#elif 1 //ֱ�� set volume Ϊ��ǰ dmap ӳ����
            float tsdf_new = tsdf;
            int weight_new = 1;
#endif
            weight_new = weight_new << 1; //ʡ����+0, v17 �ı��λĬ��ֵ=0
            pack_tsdf (tsdf_new, weight_new, *pos);
          }
          else{ //(Dp_scaled == 0 || sdf < -eta)
            //float tsdf_new = 0;
            //int weight_new = 0;
            //pack_tsdf (tsdf_new, weight_new, *pos);
            if(doDbgPrint)
                printf("NOT (Dp_scaled != 0 && sdf >= -eta)\n");
          }
        }
        else{ //NOT (coo.x >= 0 && coo.y >= 0 && coo.x < depthScaled.cols && coo.y < depthScaled.rows)
            if(doDbgPrint){
                printf("vxlDbg.xyz:= (%d, %d, %d), coo.xy:= (%d, %d)\n", vxlDbg.x, vxlDbg.y, vxlDbg.z, coo.x, coo.y);
            }
        }
      }       // for(int z = 0; z < VOLUME_Z; ++z)
    }//__global__ tsdf23_s2s

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
        if(doDbgPrint)
            printf("inv_z:= %f\n", inv_z);

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

                            //if(cos_norm > 0) //��Լ��: ����ͻ�䲻�ܳ�90��; ��Ϊ�˷�ֹ��Ƭ����, ��ԭʼ���ͼ����, ���¾ɵı��淨�����;  @2017-11-17 15:39:06
                            //��--�Ƶ� v12 ��, ������ @2017-12-3 22:09:36
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
                    printf("++FUSE_KF_AVGE, tsdf_new1, weight_new1; tsdf_prev2nd, weight_new2nd, (%f, %d), (%f, %d)\n", tsdf_new1, weight_new1, tsdf_prev2nd, weight_new2nd);
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
                    printf("...>>FUSE_FIX_PREDICTION, tsdf_new2nd, weight_new2nd, %f, %d\n", tsdf_new2nd, weight_new2nd);

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
                    printf("==FUSE_IGNORE_CURR: weight_prev2nd, Wrk: %d, %d\n", weight_prev2nd, Wrk);

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
                    }//if-(isSnormPrevInit && !isNewFace)
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
    tsdf23_v12 (const PtrStepSz<float> depthScaled, PtrStep<short2> volume1, 
        PtrStep<short2> volume2nd, PtrStep<bool> flagVolume, PtrStep<char4> surfNormVolume, PtrStep<char4> vrayPrevVolume, const PtrStepSz<unsigned char> incidAngleMask,
        const PtrStep<float> nmap_curr_g, const PtrStep<float> nmap_model_g,
        /*��--ʵ��˳��: volume2nd, flagVolume, surfNormVolume, incidAngleMask, nmap_g,*/
        const PtrStep<float> weight_map, //v11.4
        const PtrStepSz<short> diff_dmap, //v12.1
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
          short diff_depth = diff_dmap.ptr(coo.y)[coo.x];
#if 0
          if (Dp_scaled != 0 && sdf >= -tranc_dist) //meters
#else
          //��--v11.7: �� wmap (weight) ��̬�趨 tranc_dist ����, (����׼����:
          //float tranc_dist_real = tranc_dist * weiFactor;
          float tranc_dist_real = max(2*cell_size.x, tranc_dist * weiFactor); //�ضϲ���̫��, v11.8

          if(doDbgPrint){
              printf("\ttranc_dist_real, weiFactor: (%f, %f); diff_depth:= %d\n", tranc_dist_real, weiFactor, diff_depth);
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
#elif 0 //1st ���� w2ndCntThresh �Ա�, ��Ϊ�������Աȿ���: weight_new2nd > w2ndCntThresh
                            fuse_method = FUSE_FIX_PREDICTION; //�ñ��� volume, ����-��+
#elif 0 //v12.1 �ĳ�: ���帺ʱ, �ж� diff_depth @2017-12-3 22:29:04
                            //����, ûɶ�� @2017-12-4 02:59:18
                            if(tsdf_curr <= 0){ //ͬ��
                                fuse_method = FUSE_FIX_PREDICTION;
                            }
                            else{ //if(tsdf_curr > 0) //���帺
                                if(diff_depth > 30) //diff�㹻��, ������FIX; ������AVG; //������ diff<0
                                    fuse_method = FUSE_FIX_PREDICTION;
                                else
                                    fuse_method = FUSE_KF_AVGE; //��ʵĬ��
                            }
#elif 1 //v12.2 ��Ƭ��, �������帺ʱ, �ڲ������, ���ⶼ����, �����Ҳ��������
                            //�˲���˼·: �����(��)֮��ֻ��һ��voxΪ��ʱ, ����vox��ֵΪ��, ��Ҫ���帺; ����� vox�ϴ�ʱ�Ƚ�����; �Բ��� @2017-12-10 22:29:45

                            if(tsdf_curr < 0) //ͬ��, ���� FIX
                                fuse_method = FUSE_FIX_PREDICTION; 
                            else{
                                //���´��� ���帺 ����:
                                int grid_dx, grid_dy, grid_dz;
                                grid_dx = grid_dy = grid_dz = 0;

                                //����ֵ, �ж� vray ������Χ 27(ʵ��26) �������һ��; 
                                //�򲻻ᶼ< sqrt(1/3), �ʲ��õ��� dxyz=000
                                const float vray_which_grid_thresh = 0.577350269; //sqrt(1/3)

                                if(vray_normed.x > vray_which_grid_thresh)
                                    grid_dx = 1;
                                else if(vray_normed.x < -vray_which_grid_thresh)
                                    grid_dx = -1;
                                //else grid_dx = 0; //Ĭ��

                                if(vray_normed.y > vray_which_grid_thresh)
                                    grid_dy = 1;
                                else if(vray_normed.y < -vray_which_grid_thresh)
                                    grid_dy = -1;

                                if(vray_normed.z > vray_which_grid_thresh)
                                    grid_dz = 1;
                                else if(vray_normed.z < -vray_which_grid_thresh)
                                    grid_dz = -1;

                                int nbr_x, nbr_y, nbr_z;
                                nbr_x = min(VOLUME_X-1, max(0, x+grid_dx));
                                nbr_y = min(VOLUME_Y-1, max(0, y+grid_dy));
                                nbr_z = min(VOLUME_Z-1, max(0, z+grid_dz));

                                //volume1 ��, �����߷���, ��ǰ vox ���ڽ�(nbr) vox:
                                short2 *nbr_pos1 = volume1.ptr(nbr_y) + nbr_x;
                                nbr_pos1 += nbr_z * elem_step;

                                float nbr_tsdf_prev1;
                                int nbr_weight_prev1;
                                unpack_tsdf(*nbr_pos1, nbr_tsdf_prev1, nbr_weight_prev1);

                                char4 *nbr_vrayPrev_pos = vrayPrevVolume.ptr(nbr_y) + nbr_x;
                                //int vrayPrev_elem_step = vrayPrevVolume.step * VOLUME_Y / sizeof(char4);
                                nbr_vrayPrev_pos += nbr_z * vrayPrev_elem_step;

                                float3 nbr_vrayPrev;

                                //�����ѹ�һ��, ��Ȼ char->float �����, ����������һ��
                                nbr_vrayPrev.x = 1.f * (*nbr_vrayPrev_pos).x / CHAR_MAX; //char2float
                                nbr_vrayPrev.y = 1.f * (*nbr_vrayPrev_pos).y / CHAR_MAX;
                                nbr_vrayPrev.z = 1.f * (*nbr_vrayPrev_pos).z / CHAR_MAX;

                                float cos_vrayCurr_nbrPrev = dot(nbr_vrayPrev, vray_normed);

                                if(nbr_tsdf_prev1 < 0)
                                    fuse_method = FUSE_FIX_PREDICTION;
                                else{ //if(nbr_tsdf_prev1 >= 0) 
                                    if(cos_vrayCurr_nbrPrev >= 0)
                                        fuse_method = FUSE_FIX_PREDICTION;
                                    else //if(cos_vrayCurr_nbrPrev < 0) //��ʱ��Ҫ FIX, ����������� tsdf ͬ��
                                        fuse_method = FUSE_KF_AVGE; 
                                }
                            }//if-(tsdf_curr >= 0)
#elif 1 //v12.3 //˼·:������, �����˲���vox2, �� vox2 �Ƿ��ȶ�
                            //���㹲ʶ: 
                            //1, ���帺ʱ, ���� diff>0
                            //2, ���ȶ�����, �ó�; �ȶ�����, ���ó�


#endif
                            //doUpdateSnorm = true; //�ŵ� FUSE_FIX_PREDICTION ���ж�
                        }
                        else if(tsdf_curr >=0 && tsdf_prev1 >= 0){
                            if(doDbgPrint){
                                printf("\ttsdf >=0 && tsdf_prev1 >= 0; [:=prev1, curr: %f, %f\n", tsdf_prev1, tsdf_curr);
                            }
                            fuse_method = FUSE_KF_AVGE;

                            if(cos_norm > 0) //��Լ��: ����ͻ�䲻�ܳ�90��; ��Ϊ�˷�ֹ��Ƭ����, ��ԭʼ���ͼ����, ���¾ɵı��淨�����;  @2017-11-17 15:39:06
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
                    printf("++FUSE_KF_AVGE, tsdf_new1, weight_new1; tsdf_prev2nd, weight_new2nd, (%f, %d), (%f, %d)\n", tsdf_new1, weight_new1, tsdf_prev2nd, weight_new2nd);
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
                //if(weight_new2nd > w2ndCntThresh){ //���� 1st/2nd, ��Զ���� 1st Ϊ�� //����ĳ�: 2nd ������Ϯ 1st, ֻҪ����ĳ������ֵ����
                if(weight_new2nd > weight_prev1 / 2){ //��ô���� w2 ���ȶ���? �����ó�����ֵ, ���� w1/2 (���Ǿ����Գ���), ����: �� w1 ���ȶ�, �� w2 ��Ϯ��(��)�� @2017-12-10 22:42:57
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
                    printf("...>>FUSE_FIX_PREDICTION, tsdf_new2nd, weight_new2nd, (%f, %d); tprev1, wprev1: (%f, %d)\n", tsdf_new2nd, weight_new2nd, tsdf_prev1, weight_prev1);

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
                    printf("==FUSE_IGNORE_CURR: weight_prev2nd, Wrk: %d, %d\n", weight_prev2nd, Wrk);

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
                    }//if-(isSnormPrevInit && !isNewFace)
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
    }//tsdf23_v12

    enum{   //v13.2
        SAME_SIDE_VIEW
        ,OPPOSITE_VIEW
        ,GRAZING_VIEW   //�ݶ�: ���ں� @2017-12-22 14:44:08
        ,GRAZING_VIEW_POS
        ,GRAZING_VIEW_NEG
    };

    enum{
        WEIGHT_RESET_FLAG = -1
        ,WEIGHT_SCALE = 10 //���� w float ����ʱ, w<1 �ᱻ int �ض�, �� unpack ��/pack ǰ ��� scale, �����м�����ʱ int�ضϵ��³���

        ,TDIST_MIN_MM = 5 //5mm
        ,TDIST_MAX_MM = 25 //25mm
    };
#define SLIGHT_POSITIVE 1e-2

    //������ʱ��ͬ v12, host ���������ݽ��� v12 ��    @2018-1-5 16:30:48
    __global__ void
    tsdf23_v13 (const PtrStepSz<float> depthScaled, PtrStep<short2> volume1, 
        PtrStep<short2> volume2nd, PtrStep<bool> flagVolume, PtrStep<char4> surfNormVolume, PtrStep<char4> vrayPrevVolume, const PtrStepSz<unsigned char> incidAngleMask,
        const PtrStep<float> nmap_curr_g, const PtrStep<float> nmap_model_g,
        /*��--ʵ��˳��: volume2nd, flagVolume, surfNormVolume, incidAngleMask, nmap_g,*/
        const PtrStep<float> weight_map, //v11.4
        const PtrStepSz<short> diff_dmap, //v12.1
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
      float pendingFixThresh = cell_size.x * tranc_dist_inv * 3; //v13.4+ �õ�: �ݶ� 3*vox ���

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

          //zc: ���v11, �ݷ��� tranc_dist_real ����, ���Կ� @2017-12-13 10:54:29
          //if (Dp_scaled != 0 && sdf >= -tranc_dist) //meters
          
          //��--���û� tranc_dist_real; Ч������, �ȵ�������Ȩ�غ�, ��Եֻ����������? @2017-12-29 10:58:14
          float tranc_dist_real = max(2*cell_size.x, tranc_dist * weiFactor); //�ضϲ���̫��, v11.8
          if(doDbgPrint) printf("\ttranc_dist_real, weiFactor: %f, %f\n", tranc_dist_real, weiFactor);

          if (Dp_scaled != 0 && sdf >= -tranc_dist_real) //meters
          {
            //����Ľ�:
            //1, tsdf=sdf_normed, ֱ���� sdf ֵ, ���� fmin (1.0f, sdf_normed);
            //2, snorm ���»���: curr & prev_model ˭ abs-tsdf С, ��˭�� norm?  //�������£�
            //3, ��ͬ�ӽ��ж�����: ��������vray, ֻ�� snorm; �ݶ�����ѹ���� char4; c&prev snorm-angle >30��
            //  ��--��Ȼ���� vray-snorm_p �н���Ϊ��ͬ�ӽ��ж�ָ��
            //4, �����ж���ͬ�ӽ�
            //5, FIX ���Բ�Ҫ�� volume2nd Ӱ��, ֱ���ô�Ȩ��
            //6, ������ wmap, incidMask, ƽʱ��Ȩ��, ׷����ͨ�����Ϲ⻬

            float sdf_normed = sdf * tranc_dist_inv;
            float tsdf_curr = fmin (1.0f, sdf_normed);
            //float tsdf_curr = sdf_normed; //����ԭ����: tsdf ���ǽض�, ���ò��ضϵļ���, ���� sdf_normed @2017-12-25 01:53:06

            float3 snorm_curr_g;
            snorm_curr_g.x = nmap_curr_g.ptr(coo.y)[coo.x];
            if(isnan(snorm_curr_g.x)){
                if(doDbgPrint)
                    printf("+++++++++++++++isnan(snorm_curr_g.x), weiFactor: %f\n", weiFactor);

                return;
            }

            snorm_curr_g.y = nmap_curr_g.ptr(coo.y + depthScaled.rows)[coo.x];
            snorm_curr_g.z = nmap_curr_g.ptr(coo.y + 2 * depthScaled.rows)[coo.x];

            float3 vray;
            vray.x = v_g_x;
            vray.y = v_g_y;
            vray.z = v_g_z;
            //float vray_norm = norm(vray);
            float3 vray_normed = normalized(vray); //��λ��������

            float cos_vray_norm_curr = dot(snorm_curr_g, vray_normed);
            if(cos_vray_norm_curr > 0){ //����assert, Ҫ�����: �н�>90��, ��������볯�������ͷ
                //printf("ERROR+++++++++++++++cos_vray_norm > 0");

                //���費��֤�ⲿ����ȷԤ����
                snorm_curr_g.x *= -1;
                snorm_curr_g.y *= -1;
                snorm_curr_g.z *= -1;
            }

            float3 snorm_prev_g;
            snorm_prev_g.x = 1.f * (*snorm_pos).x / CHAR_MAX; //char2float
            snorm_prev_g.y = 1.f * (*snorm_pos).y / CHAR_MAX;
            snorm_prev_g.z = 1.f * (*snorm_pos).z / CHAR_MAX;

            //v11.9: ��ʱ�� snorm ����������س�ʼ��, ��ʵֵȴ������ȥ���� snorm @2017-4-11 17:03:51
            signed char *snormPrevConfid = &snorm_pos->w;
            const int snormPrevConfid_thresh = 5;

            //bool isSnormPrevInit = (norm(snormPrev) > 1e-8);
            //bool isSnormPrevInit = ( (norm(snormPrev) > 1e-8) && (snormPrevConfid > snormPrevConfid_thresh) );
            bool isSnormPrevInit = (*snormPrevConfid > snormPrevConfid_thresh); //ȥ�� X>1e-8 �ж�, ��Ϊ confid > th ʱ��Ȼ X �Ѿ���ʼ������

            //read and unpack
            float tsdf_prev1;
            int weight_prev1;
            unpack_tsdf (*pos1, tsdf_prev1, weight_prev1);

            int fuse_method = FUSE_KF_AVGE; //Ĭ��ԭ����
            bool doUpdateVrayAndSnorm = false;

            const float COS30 = 0.8660254f
                       ,COS45 = 0.7071f
                       ,COS60 = 0.5f
                       ,COS75 = 0.258819f
                       ;
            const float cosThreshSnorm = COS30; //cos(30��), �� vray ���ֿ�, ���ø�������ֵ @2017-3-15 00:39:18

            float cos_snorm_p_c = dot(snorm_prev_g, snorm_curr_g);
            //bool isNewFace = (isSnormPrevInit && cos_snorm_p_c < cosThreshSnorm /*&& cos_vray < cosThreshVray*/); //snorm-init ֮����� newFace �ж� @2017-4-21 00:42:00
            //��--ȥ�� vray �ж�
            //����--����, ����Ե��ʼʱ�����ȶ�, �������޷����� @2017-12-20 09:38:00
            float cos_vray_norm_prev = dot(snorm_prev_g, vray_normed);
            //bool isNewFace = (isSnormPrevInit && cos_vray_norm_prev > 0); //��֮ǰsnormУ������, ������Ϊ: ͬ���ӽ���, cos(vray, n_p)<0
            int view_case = SAME_SIDE_VIEW; //����ȡ�� isNewFace @2017-12-22 10:58:03
            if(isSnormPrevInit){ //����δ snorm-init, ������Ĭ�� same-view
                if(abs(cos_vray_norm_prev) < COS75){ //б���ж�
                    view_case = GRAZING_VIEW; //v13.3: ��DEPRECATED�� ��, �� p�ڱ�Ե���·���-���߼нǺܴ�, ���޷��� c����; ��ʼ��,֮���,����޸�?

                    //if(abs(cos_vray_norm_curr) < COS75) //v13.3.2: ���뵱ǰ֡Ҳ��б��, ���򱣳� same-side ���� ��DEPRECATED��
                    //    view_case = GRAZING_VIEW;

                    //v13.4: �˻ص� vray ֻ�� snorm-prev �Ƚ�, �� ���� pos-neg-graz ���ֲ��Էֿ�����, ���ںϲ��Ը�Ϊ: 
                    //1. �� p>0:: ����: �� snorm-confid== MAX, ������ c����, ������ (wc=0); �� else: wc=1 �ں�;    snorm ��������
                    //2. �� p<0, ���� �� |p| > cellSz/tdist * �� ��e.g.: 600mm/256=2.34mm, ��/25=0.09375 �ǹ�һ���ľ���vox�߶�; ���Ǿ���ϵ��, �ݶ� 3, ��Ҫ |p|>3����
                    //                  ������ vox: snorm=0, confid=0, tsdf=SLIGHT_POSITIVE(΢>0, Ϊ���й����, ��ȡ����; ���ֺ�ҪС, �Ա�����ױ�����֡����)
                    //             �� �� else, �� c����
                    
                    //������ GRAZING_VIEW, ���� ENUM pos-neg-graz, ���ڴ������, �� cos><0 & p><0 ���жϡ� @2017-12-24 23:53:48
                    //if(cos_vray_norm_prev < 0)
                    //    view_case = GRAZING_VIEW_POS;
                    //else
                    //    view_case = GRAZING_VIEW_NEG;
                }
                else if(cos_vray_norm_prev < -COS75){ //ͬ������
                    view_case = SAME_SIDE_VIEW;
                }
                else{ //if(cos_vray_norm_prev > COS75) //��������
                    view_case = OPPOSITE_VIEW;
                }

            }


            if(doDbgPrint){
                printf("vray_normed: [%f, %f, %f]; cos_vray_norm_prev, %f; cos_vray_norm_curr, %f (%s, ALWAYS cos<0)\n", 
                    vray_normed.x, vray_normed.y, vray_normed.z, cos_vray_norm_prev, cos_vray_norm_curr, cos_vray_norm_curr>0? "��":"��");
                //�����ӡ snorm У��֮ǰ�� cos-vray-snorm_c (У��֮���Ȼ cos <0 ��); snorm ȴ��У��֮��� @2017-12-20 10:43:19
                printf("cos_snorm_p_c: %f ---snorm_prev_g, snorm_curr_g: [%f, %f, %f], [%f, %f, %f]\n", 
                    cos_snorm_p_c, snorm_prev_g.x, snorm_prev_g.y, snorm_prev_g.z, snorm_curr_g.x, snorm_curr_g.y, snorm_curr_g.z);

                printf("isSnormPrevInit: %s, --snormPrevConfid: %d\n", 
                    isSnormPrevInit ? "TRUE":"FALSE", *snormPrevConfid);

                //printf("%s isNewFace:::", isNewFace? "YES":"NOT");
                printf("%s", view_case==SAME_SIDE_VIEW ? "SAME-SIDE" : (view_case==GRAZING_VIEW ? "GRAZING" : "OPPO-SIDE") );
                printf("::: tsdf_prev1, tsdf_curr: %f, %f\n", tsdf_prev1, tsdf_curr);
            }

            //1, weighting ����
            //float weight_curr = 1; //AVG, FIX, IGN, ������, ��Ȩ�ؾ���һ�� @2017-12-14 10:53:54
            float weight_curr = 0; //���� view_case ������֮��, Ĭ��Ȩ������
            float tsdf_new1 = SLIGHT_POSITIVE; //����º�� tsdf & w
            int weight_new = WEIGHT_RESET_FLAG;
            bool grazing_reset = false;

            //if(!isNewFace){ //ͬ�ӽ�, 
            if(SAME_SIDE_VIEW == view_case){
                /*
                //��DEPRECATED��
                if(tsdf_curr < 0 && tsdf_prev1 >= 0){ //������
                    //����: 1, curr ��ǳ; 2, prev�ܴ�, ��۲⵽Զ����������, ��֮ǰ��ΪĳЩ��Եȫ����, ����ΪԶ������, ��Ҫ����
                    if(tsdf_prev1 > 1)
                        fuse_method = FUSE_FIX_PREDICTION;
                    //else //Ĭ�� AVG
                        //fuse_method = FUSE_KF_AVGE;
                }
                else if(tsdf_curr < 0 && tsdf_prev1 < 0){ //���帺
                    //Ĭ�� AVG
                }
                else if(tsdf_curr >= 0 && tsdf_prev1 >= 0){ //������
                    //Ĭ�� AVG
                }
                else{ //if(tsdf_curr >=0 && tsdf_prev1 < 0) //���帺

                }
                */

                /*
                //��DEPRECATED��
                if(tsdf_prev1 >= 0){ //prev��
                    //weight_curr = min(1, tsdf_prev1 / min(1, abs(tsdf_curr)) ); //��, ���� min
                    //weight_curr = max(1, tsdf_prev1 / max(1, abs(tsdf_curr)) ); //��ĸ����, �ȼۼ�
                    weight_curr = max(1.f, min(tsdf_prev1, tsdf_prev1 / abs(tsdf_curr)) ); //

                    //��-ReLU, ��ȡmax; ���� LReLU, ��: 
                    //http://blog.csdn.net/mao_xiao_feng/article/details/53242235?locationNum=9&fps=1
                }
                else{ //if-(tsdf_prev1 < 0)
                    //w_curr Ĭ��=1
                    //�� c(+)>>p(-), ��ʵ
                }
                */

                weight_curr = (abs(tsdf_prev1)<=1 && abs(tsdf_curr)<=1) ? 1 : abs(tsdf_prev1 / tsdf_curr); //�� tsdf û�� sdf, ��˴������1, �� pack ʱ��ǿ�ƹ�һ��, ���Դ˴���Ч
                weight_curr = weight_curr * weight_curr;
            }
#if 0   //v13.4: GRAZING_VIEW, not graz-pos-neg
            else if(GRAZING_VIEW == view_case){//�Ը���
                if(*snormPrevConfid > Tsdf::MAX_WEIGHT_V13 / 2.f){
                    weight_curr = 0;
                }
                else{//snormPrevConfid ��С
                    if(tsdf_prev1 > 0){
                        weight_curr = 1;
                    }
                    else{ //tsdf_prev1 <0
                        float pendingFixThresh = cell_size.x * tranc_dist_inv * 3; //�ݶ� 3*vox ���
                        if(doDbgPrint){
                            printf("GRAZING_VIEW-snormPrevConfid(<Th)-tsdf_prev1(<0)-pendingFixThresh: %f\n", pendingFixThresh);
                            printf("\ttsdf_prev1 > -pendingFixThresh: %s; sdf_normed: %f\n", tsdf_prev1 > -pendingFixThresh ? "TTT" : "FFF", sdf_normed);
                        }

                        if(tsdf_prev1 > -pendingFixThresh){
                            weight_curr = 0;
                        }
                        else{//tsdf_prev1 < -pendingFixThresh
                            if(sdf_normed > 1){
                                *snormPrevConfid = 0;
                                //snorm=0�� �ݲ���, ��Ϊ confid ����, ������Ȼ�������� snorm?

                                grazing_reset = true;
                                //tsdf_new1 = 0.1f; //�ź���, ������ᱻ���渲�ǻ���
                                //weight_new = 0;
                            }
                        }
                    }

                }
            }
#elif 0 //v13.5: GRAZ �ж����ȼ�: �� c��1; if-c>>1, ��� graz-pos-neg; �� ???
            //�� sdf-normed ��, ���ں��� tsdf
            else if(GRAZING_VIEW == view_case){//�Ը���
                if(doDbgPrint){
                    printf("GRAZING_VIEW--sdf_normed=%f (%s)--cos_V_N_p=%f (%s)\
                           --tsdf_prev1=%f (%s)-pendingFixThresh: %f\n", 
                        sdf_normed, sdf_normed > 1 ? ">1" : "<=1", 
                        cos_vray_norm_prev, cos_vray_norm_prev < 0 ? "<0" : ">=0",
                        tsdf_prev1, tsdf_prev1 > 0 ? ">0" : "<=0",
                        pendingFixThresh);
                    printf("\tabs(tsdf_prev1) < pendingFixThresh: %s;\n", \
                        abs(tsdf_prev1) < pendingFixThresh ? "TTT" : "FFF");
                }
                if(sdf_normed <= 1){ //��ʵҲ�� |..|<=1, ��Ϊ������ ..>= -1
                    weight_curr = 1;
                }
                else{//sdf_normed > 1
                    if(cos_vray_norm_prev < 0){ //��֮ǰ������ GRAZING_VIEW_POS
                        weight_curr = 0; //��: 1, ����ȫ����, ����Զ�������ӳ���������Чpx
                    }
                    else{ //cos_vray_norm_prev > 0, �� graz-neg
                        if(tsdf_prev1 > 0){
                            weight_curr = 0;
                        }
                        else{ //tsdf_prev1 <0
                            //if(doDbgPrint){
                            //    printf("GRAZING_VIEW-(sdf_normed > 1)-(cos_vray_norm_prev < 0)-(tsdf_prev1 <0)-pendingFixThresh: %f\n", pendingFixThresh);
                            //    printf("\ttsdf_prev1 > -pendingFixThresh: %s; sdf_normed: %f\n", tsdf_prev1 > -pendingFixThresh ? "TTT" : "FFF", sdf_normed);
                            //}

                            if(tsdf_prev1 > -pendingFixThresh)
                                weight_curr = 0;
                            else{//tsdf_prev1 < -pendingFixThresh
                                //if(sdf_normed > 1){ //�����ж���
                                *snormPrevConfid = 0;
                                //snorm=0�� �ݲ���, ��Ϊ confid ����, ������Ȼ�������� snorm?

                                grazing_reset = true;
                                //tsdf_new1 = 0.1f; //�ź���, ������ᱻ���渲�ǻ���
                                //weight_new = 0;
                            }
                        }
                    }
                }
            }
#elif 1 //v13.6: �� v13.5 �߼�:: �� |sdf|<1, AVG(w=0); ��ĳ����Լ�� RESET(confid=0); ��else IGN(w=0);
            else if(GRAZING_VIEW == view_case){//�Ը���
                weight_curr = 0; //�߼���������ȫ������

                if(doDbgPrint){
                    printf("GRAZING_VIEW--sdf_normed=%f (%s)--cos_V_N_p=%f (%s)"
                           "--tsdf_prev1=%f (%s)-pendingFixThresh: %f\n", 
                           sdf_normed, sdf_normed > 1 ? ">1" : "<=1", 
                           cos_vray_norm_prev, cos_vray_norm_prev < 0 ? "<0" : ">=0",
                           tsdf_prev1, tsdf_prev1 > 0 ? ">0" : "<=0",
                           pendingFixThresh);
                    printf("\tabs(tsdf_prev1) < pendingFixThresh: %s;\n", \
                        abs(tsdf_prev1) < pendingFixThresh ? "TTT" : "FFF");
                }
                if(sdf_normed <= 1){ //��ʵҲ�� |..|<=1, ��Ϊ������ ..>= -1; ���߼����� sdf==tsdf
#if 0   //v13.6 ���� |sdf|<1 �� wc=1 ����; ����: sdf_prev=-0.2, confid=127, sdf_curr=0.7, ��ô��? GRAZ ״̬��, �� curr ���ó�� prev
                    weight_curr = 1;
#elif 0 //v13.7��DEPRECATED�� ֮ǰΪɶ�趨 wc=1�� Ϊ���չ�graz������, ��Ե������Ϊ �������, �ж�Ϊ graz, ��Ҫƽ����
                    //���Դ��߼�Ҳ����, �޷���ȷ��������� @2017-12-29 09:11:04
                    if(cos_snorm_p_c > COS45)
                        weight_curr = 1;
                    else
                        weight_curr = 0;
#elif 0 //v13.8 ���� w �� confid �� p-c-dist (Dpc) ˫��������, ģ���˹����/��������: 
                    //�� confid Խ��, sigmaԽС, ������ curr Խ�ϸ�; �� p-c-dist Խ��, curr �� mu ԽԶ, Ȩ��ԽС
                    //�����߽���Ϊ: ��������:wc= min(0, max(1, 1-c*(Dpc-th_min)/(M*(TH-th)) ) ) 
                    //��--��, if Dpc<th: wc=1; ��, elif Dpc>TH; wc=0; �� else �м�״̬: wc= 1-c*(Dpc-th_min)/[M*(TH-th)]

                    const float tsdf_th_min = 0.2, //e.g.: 25mm*0.2=5mm
                        tsdf_TH_max = 0.6;    //e.g.: 25mm*0.6=15mm

                    float dpc = abs(tsdf_curr - tsdf_prev1);
                    weight_curr = 1 - 1.f * *snormPrevConfid / SCHAR_MAX * (dpc - tsdf_th_min) / (tsdf_TH_max - tsdf_th_min);
                    weight_curr = max(0.f, min(1.f, weight_curr));
#elif 1 //v13.9, �޸ķֶκ�����ʽ, ��Ҫ���� th, TH; Ҫ���� confid ��̬�仯�� sigma
                    float dpc = abs(tsdf_curr - tsdf_prev1);
                    float sigma = 1 - 1.f * *snormPrevConfid / SCHAR_MAX; //confid~(0,127) --> sigma~(1,0)
                    sigma = 0.2 * sigma + 0.1; //(0,1)--> (0.1, 0.3)

                    weight_curr = 1 - 1.f * *snormPrevConfid / SCHAR_MAX * (dpc - sigma) / (2 * sigma); //��ĸ�� 3��-��=2��
                    weight_curr = max(0.f, min(1.f, weight_curr));
#endif
                }
                else{//sdf_normed > 1 //���ڽ������, ������Զ�����ӵ�����
                    if(cos_vray_norm_prev > 0 && tsdf_prev1 < -pendingFixThresh) //��, 1, �����ӽ�; 2, �ܸ�, p<<0
                    //if(tsdf_prev1 < -pendingFixThresh) //v13.10, ���ж� p<<0, ȥ���������ӽǡ�Լ�� \
                            ��--������ cos_vray_norm_prev ����Ϊ: grazʱ, ��ʱ��Եȫ����, ����Զ�������"����", ���� pendingFixThresh ����, ��Ϊ���ֵ���ܲ��ȶ�, 
                    {
                        //��--��Ҫ��ʵ3D����ࡰ1/8������ֵȫ <0, ȷ�����ƻ������; ���� v12
                        int sx = snorm_prev_g.x > 0 ? 1 : -1, //sign, ������
                            sy = snorm_prev_g.y > 0 ? 1 : -1,
                            sz = snorm_prev_g.z > 0 ? 1 : -1;
                        bool doBreak = false;
                        int nbr_x = -1,
                            nbr_y = -1,
                            nbr_z = -1;
                        float nbr_tsdf;
                        int nbr_weight;
                        for(int ix=0; ix<=1 && !doBreak; ix++){
                            for(int iy=0; iy<=1 && !doBreak; iy++){
                                for(int iz=0; iz<=1 && !doBreak; iz++){
                                    if(0==ix && 0==iy && 0==iz)
                                        continue;

                                    nbr_x = min(VOLUME_X-1, max(0, x + ix*sx));
                                    nbr_y = min(VOLUME_Y-1, max(0, y + iy*sy));
                                    nbr_z = min(VOLUME_Z-1, max(0, z + iz*sz));

                                    short2 *nbr_pos = volume1.ptr(nbr_y) + nbr_x;
                                    nbr_pos += nbr_z * elem_step;

                                    //float nbr_tsdf;
                                    //int nbr_weight;
                                    unpack_tsdf(*nbr_pos, nbr_tsdf, nbr_weight);
                                    if(WEIGHT_RESET_FLAG != nbr_weight && nbr_tsdf > 0){
                                        doBreak = true;
                                        break; //����ʽ�ж���ʵҲ����ν����
                                    }
                                }
                            }
                        }//for-ix

                        if(doDbgPrint){
                            printf("\tdoBreak: %s\n", doBreak ? "doBreakTTT" : "doBreakFFF-grazing_reset");
                            printf("\tNBR-XYZ: %d, %d, %d; NBR-TSDF/w: %f, %d\n", nbr_x, nbr_y, nbr_z, nbr_tsdf, nbr_weight);
                        }

                        if(false == doBreak){
                            *snormPrevConfid = 0;
                            grazing_reset = true;
                        }
                        else
                            weight_curr = 0;
                    }//if-cos>0 & p<<0
                    else
                        weight_curr = 0;
                }//else-sdf_normed > 1
            }//elif-(GRAZING_VIEW == view_case)
#elif 1
            else if(GRAZING_VIEW_POS == view_case){
                if(snormPrevConfid < Tsdf::MAX_WEIGHT_V13 / 2.f)
                    weight_curr = 1;
                else
                    weight_curr = 0;
            }
            else if(GRAZING_VIEW_NEG == view_case){
            }
#endif
            //else{ //if-isNewFace //v13.2 ����
            else if(OPPOSITE_VIEW == view_case){ //֮ǰ if-isNewFace 
#if 0   //v13.old   ֮ǰ: ���� p, c tsdf ֵ, ���� w �ں�Ȩ��; ����w ���ȶ�, ����; ��Ӧ�����ȷ @2018-1-2 07:32:41

                //���ӽ�, ԭ����: 
                //1, ����������Ƶ�����; 
                //2, ���ͼ���˶�ģ��/��׼����, ���²�׼, Ӱ�쵽ĳЩvox; ��Ҫ��: ĳʱ�� Dmap(i) ���(�������) ���б��污Ƭ�ṹʱ, Ҫ���⴦��
                if(tsdf_prev1 >= 0){ //prev��
                    //weight_curr = max(0, tsdf_prev1 / tsdf_curr);
                    //��-�� curr<0ʱ, w=max(0, -X)=0; curr>0ʱ, c<<p ��Ȩ�ش�
                    //weight_curr = min(tsdf_prev1, max(0, tsdf_prev1 / tsdf_curr) ); //������: ���� prev<1 ����
                    //weight_curr = min(max(1.f, tsdf_prev1), max(0.f, tsdf_prev1 / tsdf_curr) );
                    weight_curr = min(max(1.f, tsdf_prev1), max(0.f, tsdf_prev1 / (tsdf_curr + (tsdf_curr>0 ? 1 : -1) * 0.01)) ); //�������
                }
                else{ //if-(tsdf_prev1 < 0) //��Ȼ p>-1, ����̫��
                    //w_curr Ĭ��=1
                    //��ǰ: �� tprev ��������; ���: �� diffDmap //��������

                    //if(tsdf_curr + tsdf_prev1 > 0) //��ǰ֡����������: 1, ����۲�, ����������׼, ���¾ֲ����ͷ��; 2, ����۲⵽Զ����������
                    //    weight_curr = 1;
                    //else
                    //    weight_curr = (tsdf_curr+1) / max(tsdf_prev1+1, 0.1);
                    weight_curr = tsdf_curr + tsdf_prev1 > 0 ? 
                        //1 : (tsdf_curr+1) / max(tsdf_prev1+1, 0.1); //1 ������, ����: �� tcurr �ܴ�, ��Ӧ��СȨ��, 1̫��
                        (-tsdf_prev1 / tsdf_curr) : (tsdf_curr+1) / max(tsdf_prev1+1, 0.1);
                }//if-tprev><0
#elif 1 //v13.10
                if(doDbgPrint){
                    printf("\tabs(tsdf_prev1) < abs(tsdf_curr): %s\n", abs(tsdf_prev1) < abs(tsdf_curr) ? "TTT-curr��Զ" : "FFF+curr����");
                }

                //if(tsdf_prev1 >= 0)
                if(abs(tsdf_prev1) < abs(tsdf_curr)) //prev ����������
                    weight_curr = 0;
                else //curr ����������
                    weight_curr = 10;


#endif
            //}//if-isNewFace OR NOT
            }//if-OPPOSITE_VIEW
            
            if(doDbgPrint){
                printf("\tweight_prev1, weight_curr:: %d, %f\n", weight_prev1, weight_curr);
            }

            //2, ���� tsdf, weight, snorm
            if(WEIGHT_RESET_FLAG != weight_prev1) //�����ĸ����
                tsdf_new1 = (tsdf_prev1 * weight_prev1 + tsdf_curr * weight_curr) 
                / (weight_prev1 + weight_curr);
            weight_new = weight_prev1; //Ĭ�ϲ�����

            //if(!isNewFace){ //��ͬ��, 
            if(SAME_SIDE_VIEW == view_case){
                //if(grazing_reset) //grazing_reset �ֲ�����, ���������ж�
                if(WEIGHT_RESET_FLAG == weight_prev1 && sdf_normed > 1){ //GRAZ ʱ, sdf>1 ʱ grazing_reset �Ľ��, 
                    if(doDbgPrint)
                        printf("\tWEIGHT_RESET_FLAG == weight_prev1 && sdf_normed > 1\n");
                }
                else{ //�� ���� same-side, δ�ܹ� grazing_reset Ӱ��; �� �� graz-reset, ���� sdf<1;
                    //Ȩ���ۻ�
                    weight_new = min(weight_prev1 + weight_curr, (float)Tsdf::MAX_WEIGHT_V13);

                    if(isSnormPrevInit){
                        //if(doDbgPrint) printf("snorm_curr_g-111: [%f, %f, %f]\n", snorm_curr_g.x, snorm_curr_g.y, snorm_curr_g.z);

                        //�𲽡���΢���·�����
                        snorm_curr_g = (snorm_prev_g * weight_prev1 + snorm_curr_g * weight_curr) 
                            * (1./(weight_prev1 + weight_curr) ); //float3 û���س���

                        //if(doDbgPrint) printf("snorm_curr_g-222: [%f, %f, %f], norm(snorm_curr_g):= %f\n", snorm_curr_g.x, snorm_curr_g.y, snorm_curr_g.z, norm(snorm_curr_g));

                        //snorm_curr_g *= 1./norm(snorm_curr_g);
                        snorm_curr_g = normalized(snorm_curr_g);

                        //if(doDbgPrint) printf("snorm_curr_g-333: [%f, %f, %f]\n", snorm_curr_g.x, snorm_curr_g.y, snorm_curr_g.z);
                    }

                    //�᲻����Ϊ char �洢, ǰ��ĸ���û����? ��֪�� @2017-12-18 00:55:39
                    (*snorm_pos).x = (int)nearbyintf(snorm_curr_g.x * CHAR_MAX); //float2char
                    (*snorm_pos).y = (int)nearbyintf(snorm_curr_g.y * CHAR_MAX);
                    (*snorm_pos).z = (int)nearbyintf(snorm_curr_g.z * CHAR_MAX);

                    //�������Ŷ�+1
                    //(*snormPrevConfid) +=1; //Ҫ������!
                    *snormPrevConfid = min(SCHAR_MAX, *snormPrevConfid + 1);

                    if(doDbgPrint){
                        printf("\t*snormPrevConfid+1\n");
                        //printf("��snorm_pos.x��: %d, %d, %f, %f, %d\n", (*snorm_pos).x, snorm_pos->x, snorm_curr_g.x * CHAR_MAX, nearbyintf(snorm_curr_g.x * CHAR_MAX), (int)nearbyintf(snorm_curr_g.x * CHAR_MAX));
                        //printf("��snorm_pos.y��: %d, %d, %f, %f, %d\n", (*snorm_pos).y, snorm_pos->y, snorm_curr_g.y * CHAR_MAX, nearbyintf(snorm_curr_g.y * CHAR_MAX), (int)nearbyintf(snorm_curr_g.y * CHAR_MAX));
                        //printf("��snorm_pos.z��: %d, %d, %f, %f, %d\n", (*snorm_pos).z, snorm_pos->z, snorm_curr_g.z * CHAR_MAX, nearbyintf(snorm_curr_g.z * CHAR_MAX), (int)nearbyintf(snorm_curr_g.z * CHAR_MAX));
                    }
                }
            }
            //else{ //������, 
            else if(OPPOSITE_VIEW == view_case){
                //Ȩ�صݼ���һ�� //���� @2017-12-17 23:56:00
                //weight_new = max(weight_prev1 - weight_curr, Tsdf::MAX_WEIGHT_V13 / 2.f);
                //��-����, ��Ȩ��û�� MAX/2 ��? //�� snorm-initialized-confidence-thresh, ��Ϊ�ﲻ���� thresh �����ߵ������֧
                weight_new = max(int(weight_prev1 - weight_curr), snormPrevConfid_thresh);

                //���� w_curr �ϴ�ʱ, ��Ҫ curr �� prev ʱ, �Źĵ�����
                if(weight_curr > 1){
                    (*snormPrevConfid) -=1;

                    if(doDbgPrint){
                        printf("*snormPrevConfid---1\n");
                    }
                }
                if(*snormPrevConfid <= snormPrevConfid_thresh){
                    *snormPrevConfid = snormPrevConfid_thresh + 1;

                    //ֱ���� curr ����:
                    (*snorm_pos).x = (int)nearbyintf(snorm_curr_g.x * CHAR_MAX); //float2char
                    (*snorm_pos).y = (int)nearbyintf(snorm_curr_g.y * CHAR_MAX);
                    (*snorm_pos).z = (int)nearbyintf(snorm_curr_g.z * CHAR_MAX);
                }
            }
            else if(GRAZING_VIEW == view_case){
                //DO-NOTHING
                if(grazing_reset){
                    tsdf_new1 = SLIGHT_POSITIVE;
                    weight_new = WEIGHT_RESET_FLAG; //-1, �Ǹ����, ��ʾ grazing_reset ��
                }
                else /*if(WEIGHT_RESET_FLAG != weight_new)*/{
                    //����ע�� WEIGHT_RESET_FLAG
                    if(WEIGHT_RESET_FLAG == weight_prev1)
                        weight_prev1 = 0;

                    //���� same-side, Ȩ���ۻ�, norm Ҳ����У��, ǰ�� GRAZING_VIEW ������Ѿ����� weight_curr
                    weight_new = min(weight_prev1 + weight_curr, (float)Tsdf::MAX_WEIGHT_V13);

                    //�𲽡���΢���·�����
                    snorm_curr_g = (snorm_prev_g * weight_prev1 + snorm_curr_g * weight_curr) 
                        * (1./(weight_prev1 + weight_curr) ); //float3 û���س���
                    snorm_curr_g = normalized(snorm_curr_g);

                    (*snorm_pos).x = (int)nearbyintf(snorm_curr_g.x * CHAR_MAX); //float2char
                    (*snorm_pos).y = (int)nearbyintf(snorm_curr_g.y * CHAR_MAX);
                    (*snorm_pos).z = (int)nearbyintf(snorm_curr_g.z * CHAR_MAX);

                    //graz �£��������Ŷȡ���+1��
                    //*snormPrevConfid = min(SCHAR_MAX, *snormPrevConfid + 1);

                }
            }//if-(GRAZING_VIEW == view_case)

            //if(WEIGHT_RESET_FLAG != weight_prev1)
                pack_tsdf(tsdf_new1, weight_new, *pos1);

            if(doDbgPrint){
                printf("\ttsdf_new1, weight_new:: %f, %d\n", tsdf_new1, weight_new);
                printf("\tnew-snorm(*snorm_pos): [%d, %d, %d]\n", snorm_pos->x, snorm_pos->y, snorm_pos->z);
                printf("\tnew-snorm(*snorm_pos): [%f, %f, %f]\n", 1.f * (*snorm_pos).x / CHAR_MAX, 1.f * (*snorm_pos).y / CHAR_MAX, 1.f * (*snorm_pos).z / CHAR_MAX);
            }

          }//if-(Dp_scaled != 0 && sdf >= -tranc_dist) 
          else{
              if(doDbgPrint)
                  printf("NOT (Dp_scaled != 0 && sdf >= -tranc_dist)\n");
          }
        }//if- 0 < (x,y) < (cols,rows)
      }// for(int z = 0; z < VOLUME_Z; ++z)
    }//tsdf23_v13

    //v13 ��������: ������ snormPrevConfid ��Ϊ�� weight_curr & weight_new ��û�зֲ棿 ���ʼ��һ�£��Ƿ����һ��������    @2018-1-5 16:41:01
    //v14 ʧ��: ��ѵ:= �� ��Ҫֱ�� reset!! û�к��ҩ; �� ��������, ��ȷʵ�����׵���ƫ�� bias (2017��ƪ��ʿ����Ҳ�ᵽ); ���ܲ����˹/����ƽ��
    __global__ void
    tsdf23_v14 (const PtrStepSz<float> depthScaled, PtrStep<short2> volume1, 
        PtrStep<short2> volume2nd, PtrStep<bool> flagVolume, PtrStep<char4> surfNormVolume, PtrStep<char4> vrayPrevVolume, const PtrStepSz<unsigned char> incidAngleMask,
        const PtrStep<float> nmap_curr_g, const PtrStep<float> nmap_model_g,
        /*��--ʵ��˳��: volume2nd, flagVolume, surfNormVolume, incidAngleMask, nmap_g,*/
        const PtrStep<float> weight_map, //v11.4
        const PtrStepSz<short> diff_dmap, //v12.1
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
      float pendingFixThresh = cell_size.x * tranc_dist_inv * 3; //v13.4+ �õ�: �ݶ� 3*vox ���

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

          float tranc_dist_real = max(2*cell_size.x, tranc_dist * weiFactor); //�ضϲ���̫��, v11.8
          if(doDbgPrint) printf("\ttranc_dist_real, weiFactor: %f, %f\n", tranc_dist_real, weiFactor);

          //if (Dp_scaled != 0 && sdf >= -tranc_dist) //meters
          if (Dp_scaled != 0 && sdf >= -tranc_dist_real) //meters
          {
            float sdf_normed = sdf * tranc_dist_inv;
            float tsdf_curr = fmin (1.0f, sdf_normed);

            float3 snorm_curr_g;
            snorm_curr_g.x = nmap_curr_g.ptr(coo.y)[coo.x];
            if(isnan(snorm_curr_g.x)){
                if(doDbgPrint)
                    printf("+++++++++++++++isnan(snorm_curr_g.x), weiFactor: %f\n", weiFactor);

                return;
            }

            snorm_curr_g.y = nmap_curr_g.ptr(coo.y + depthScaled.rows)[coo.x];
            snorm_curr_g.z = nmap_curr_g.ptr(coo.y + 2 * depthScaled.rows)[coo.x];

            float3 vray;
            vray.x = v_g_x;
            vray.y = v_g_y;
            vray.z = v_g_z;
            //float vray_norm = norm(vray);
            float3 vray_normed = normalized(vray); //��λ��������

            float cos_vray_norm_curr = dot(snorm_curr_g, vray_normed);
            if(cos_vray_norm_curr > 0){ //����assert, Ҫ�����: �н�>90��, ��������볯�������ͷ
                //printf("ERROR+++++++++++++++cos_vray_norm > 0");

                //���費��֤�ⲿ����ȷԤ����
                snorm_curr_g.x *= -1;
                snorm_curr_g.y *= -1;
                snorm_curr_g.z *= -1;
            }

            float3 snorm_prev_g;
            snorm_prev_g.x = 1.f * (*snorm_pos).x / CHAR_MAX; //char2float
            snorm_prev_g.y = 1.f * (*snorm_pos).y / CHAR_MAX;
            snorm_prev_g.z = 1.f * (*snorm_pos).z / CHAR_MAX;

            //read and unpack
            float tsdf_prev1;
            int weight_prev1;
            unpack_tsdf (*pos1, tsdf_prev1, weight_prev1);

            //signed char *snormPrevConfid = &snorm_pos->w;
            //��-v14 ����ȥ�� snormPrevConfid ������, �� w �������
            //const int snormPrevConfid_thresh = 5;

            //bool isSnormPrevInit = (*snormPrevConfid > snormPrevConfid_thresh); //ȥ�� X>1e-8 �ж�, ��Ϊ confid > th ʱ��Ȼ X �Ѿ���ʼ������
            bool isSnormPrevInit = weight_prev1 > 0; //v14 ������ w ��� snormPrevConfid ������

            const float COS30 = 0.8660254f
                       ,COS45 = 0.7071f
                       ,COS60 = 0.5f
                       ,COS75 = 0.258819f
                       ;
            const float cosThreshSnorm = COS30; //cos(30��), �� vray ���ֿ�, ���ø�������ֵ @2017-3-15 00:39:18

            float cos_snorm_p_c = dot(snorm_prev_g, snorm_curr_g);
            float cos_vray_norm_prev = dot(snorm_prev_g, vray_normed);

            int view_case = SAME_SIDE_VIEW; //����ȡ�� isNewFace @2017-12-22 10:58:03
            if(isSnormPrevInit){ //v14: ���� w
                if(abs(cos_vray_norm_prev) < COS75){ //б���ж�
                    view_case = GRAZING_VIEW; //v13.3: �� p�ڱ�Ե���·���-���߼нǺܴ�, ��ʼ��,֮���,����޸�?
                }
                else if(cos_vray_norm_prev < -COS75){ //ͬ������
                    view_case = SAME_SIDE_VIEW;
                }
                else{ //if(cos_vray_norm_prev > COS75) //��������
                    view_case = OPPOSITE_VIEW;
                }
            }

            if(doDbgPrint){
                printf("vray_normed: [%f, %f, %f]; cos_vray_norm_prev, %f; cos_vray_norm_curr, %f (%s, ALWAYS cos<0)\n", 
                    vray_normed.x, vray_normed.y, vray_normed.z, cos_vray_norm_prev, cos_vray_norm_curr, cos_vray_norm_curr>0? "��":"��");
                //�����ӡ snorm У��֮ǰ�� cos-vray-snorm_c (У��֮���Ȼ cos <0 ��); snorm ȴ��У��֮��� @2017-12-20 10:43:19
                printf("cos_snorm_p_c: %f ---snorm_prev_g, snorm_curr_g: [%f, %f, %f], [%f, %f, %f]\n", 
                    cos_snorm_p_c, snorm_prev_g.x, snorm_prev_g.y, snorm_prev_g.z, snorm_curr_g.x, snorm_curr_g.y, snorm_curr_g.z);

                printf("isSnormPrevInit: %s, \n", isSnormPrevInit ? "TTT" : "FFF");
                //printf("isSnormPrevInit: %s, --snormPrevConfid: %d\n", 
                //    isSnormPrevInit ? "TRUE":"FALSE", *snormPrevConfid);

                //printf("%s isNewFace:::", isNewFace? "YES":"NOT");
                printf("%s", view_case==SAME_SIDE_VIEW ? "SAME-SIDE" : (view_case==GRAZING_VIEW ? "GRAZING" : "OPPO-SIDE") );
                printf("::: tsdf_prev1, tsdf_curr: %f, %f\n", tsdf_prev1, tsdf_curr);
            }

            //1, weighting ����
            //float weight_curr = 1; //AVG, FIX, IGN, ������, ��Ȩ�ؾ���һ�� @2017-12-14 10:53:54
            float weight_curr = 0; //���� view_case ������֮��, Ĭ��Ȩ������
            float tsdf_new1 = SLIGHT_POSITIVE; //����º�� tsdf & w
            int weight_new = WEIGHT_RESET_FLAG;
            bool grazing_reset = false;

            if(SAME_SIDE_VIEW == view_case){
                weight_curr = 1;
            }
            else if(GRAZING_VIEW == view_case){//�Ը���
                weight_curr = 0; //�߼���������ȫ������

                if(doDbgPrint){
                    printf("GRAZING_VIEW--sdf_normed=%f (%s)--cos_V_N_p=%f (%s)"
                        "--tsdf_prev1=%f (%s)-pendingFixThresh: %f\n", 
                        sdf_normed, sdf_normed > 1 ? ">1" : "<=1", 
                        cos_vray_norm_prev, cos_vray_norm_prev < 0 ? "<0" : ">=0",
                        tsdf_prev1, tsdf_prev1 > 0 ? ">0" : "<=0",
                        pendingFixThresh);
                    printf("\tabs(tsdf_prev1) < pendingFixThresh: %s;\n", \
                        abs(tsdf_prev1) < pendingFixThresh ? "TTT" : "FFF");
                }
                if(sdf_normed <= 1){ //��ʵҲ�� |..|<=1, ��Ϊ������ ..>= -1; ���߼����� sdf==tsdf
                    //v13.9, ��������, �޸ķֶκ�����ʽ, ��Ҫ���� th, TH; Ҫ���� confid ��̬�仯�� sigma
                    float dpc = abs(tsdf_curr - tsdf_prev1);
                    float sigma = 1 - 1.f * weight_prev1 / Tsdf::MAX_WEIGHT_V13; //confid~(0,127) --> sigma~(1,0)
                    sigma = 0.2 * sigma + 0.1; //(0,1)--> (0.1, 0.3)

                    weight_curr = 1 - 1.f * weight_prev1 / Tsdf::MAX_WEIGHT_V13 * (dpc - sigma) / (2 * sigma); //��ĸ�� 3��-��=2��
                    weight_curr = max(0.f, min(1.f, weight_curr));
                }
                else{//sdf_normed > 1 //���ڽ������, ������Զ�����ӵ�����
                    if(cos_vray_norm_prev > 0 && tsdf_prev1 < -pendingFixThresh) //��, 1, �����ӽ�; 2, �ܸ�, p<<0
                        //if(tsdf_prev1 < -pendingFixThresh) //v13.10, ���ж� p<<0, ȥ���������ӽǡ�Լ�� \
                        ��--������ cos_vray_norm_prev ����Ϊ: grazʱ, ��ʱ��Եȫ����, ����Զ�������"����", ���� pendingFixThresh ����, ��Ϊ���ֵ���ܲ��ȶ�, 
                    {
                        //��--��Ҫ��ʵ3D����ࡰ1/8������ֵȫ <0, ȷ�����ƻ������; ���� v12
                        int sx = snorm_prev_g.x > 0 ? 1 : -1, //sign, ������
                            sy = snorm_prev_g.y > 0 ? 1 : -1,
                            sz = snorm_prev_g.z > 0 ? 1 : -1;
                        bool doBreak = false;
                        int nbr_x = -1,
                            nbr_y = -1,
                            nbr_z = -1;
                        float nbr_tsdf;
                        int nbr_weight;
                        for(int ix=0; ix<=1 && !doBreak; ix++){
                            for(int iy=0; iy<=1 && !doBreak; iy++){
                                for(int iz=0; iz<=1 && !doBreak; iz++){
                                    if(0==ix && 0==iy && 0==iz)
                                        continue;

                                    nbr_x = min(VOLUME_X-1, max(0, x + ix*sx));
                                    nbr_y = min(VOLUME_Y-1, max(0, y + iy*sy));
                                    nbr_z = min(VOLUME_Z-1, max(0, z + iz*sz));

                                    short2 *nbr_pos = volume1.ptr(nbr_y) + nbr_x;
                                    nbr_pos += nbr_z * elem_step;

                                    //float nbr_tsdf;
                                    //int nbr_weight;
                                    unpack_tsdf(*nbr_pos, nbr_tsdf, nbr_weight);
                                    if(WEIGHT_RESET_FLAG != nbr_weight && nbr_tsdf > 0){
                                        doBreak = true;
                                        break; //����ʽ�ж���ʵҲ����ν����
                                    }
                                }
                            }
                        }//for-ix

                        if(doDbgPrint){
                            printf("\tdoBreak: %s\n", doBreak ? "doBreakTTT" : "doBreakFFF-grazing_reset");
                            printf("\tNBR-XYZ: %d, %d, %d; NBR-TSDF/w: %f, %d\n", nbr_x, nbr_y, nbr_z, nbr_tsdf, nbr_weight);
                        }

                        if(false == doBreak){
                            //*snormPrevConfid = 0;
                            weight_new = WEIGHT_RESET_FLAG; //֮������� vox ��Ȼ��Ч
                            grazing_reset = true; //����ǰѭ������Ч
                        }
                        else
                            weight_curr = 0;
                    }//if-cos>0 & p<<0
                    else
                        weight_curr = 0; //��дһ��, �ö�, ��ʵĬ��
                }//else-sdf_normed > 1
            }//elif-(GRAZING_VIEW == view_case)
            else if(OPPOSITE_VIEW == view_case){ //֮ǰ if-isNewFace 
                //v13.10
                if(doDbgPrint){
                    printf("\tabs(tsdf_prev1) < abs(tsdf_curr): %s\n", abs(tsdf_prev1) < abs(tsdf_curr) ? "TTT-curr��Զ" : "FFF+curr����");
                }

                weight_curr = 0; //Ĭ������

                //if(tsdf_prev1 >= 0){ //�� p+, ���� c+/- �����ܳ�
                //    weight_curr = 0;
                //}
                //if(abs(tsdf_prev1) < abs(tsdf_curr)) //prev ����������
                //    weight_curr = 0;
                //else //curr ����������
                //    weight_curr = 10;

                if(tsdf_prev1 < 0 && abs(tsdf_prev1) > abs(tsdf_curr)){
                    //��=���� p-, �� |p|>|c|, �š����ܡ�c �� p; ����Ҫ�ж��� norm_p ����, ���� nbr ȫ<0, ȷ�������

                    //������ ���� GRAZING_VIEW �߼����� @2018-1-7 21:25:12
                    int sx = snorm_prev_g.x > 0 ? 1 : -1, //sign, ������
                        sy = snorm_prev_g.y > 0 ? 1 : -1,
                        sz = snorm_prev_g.z > 0 ? 1 : -1;
                    bool doBreak = false;
                    int nbr_x = -1,
                        nbr_y = -1,
                        nbr_z = -1;
                    float nbr_tsdf;
                    int nbr_weight;
                    for(int ix=0; ix<=1 && !doBreak; ix++){
                        for(int iy=0; iy<=1 && !doBreak; iy++){
                            for(int iz=0; iz<=1 && !doBreak; iz++){
                                if(0==ix && 0==iy && 0==iz)
                                    continue;

                                nbr_x = min(VOLUME_X-1, max(0, x + ix*sx));
                                nbr_y = min(VOLUME_Y-1, max(0, y + iy*sy));
                                nbr_z = min(VOLUME_Z-1, max(0, z + iz*sz));

                                short2 *nbr_pos = volume1.ptr(nbr_y) + nbr_x;
                                nbr_pos += nbr_z * elem_step;

                                //float nbr_tsdf;
                                //int nbr_weight;
                                unpack_tsdf(*nbr_pos, nbr_tsdf, nbr_weight);
                                if(WEIGHT_RESET_FLAG != nbr_weight && nbr_tsdf > 0){
                                    doBreak = true;
                                    break; //����ʽ�ж���ʵҲ����ν����
                                }
                            }
                        }
                    }//for-ix

                    if(doDbgPrint){
                        printf("\tdoBreak: %s\n", doBreak ? "doBreakTTT" : "doBreakFFF-grazing_reset");
                        printf("\tNBR-XYZ: %d, %d, %d; NBR-TSDF/w: %f, %d\n", nbr_x, nbr_y, nbr_z, nbr_tsdf, nbr_weight);
                    }

                    if(false == doBreak){
                        //weight_curr = 10;

                        grazing_reset = true;
                    }

                }
            }//if-OPPOSITE_VIEW

            if(doDbgPrint){
                printf("\tweight_prev1, weight_curr:: %d, %f\n", weight_prev1, weight_curr);
            }

            //2, ���� tsdf, weight, snorm
            if(WEIGHT_RESET_FLAG != weight_prev1) //�����ĸ����
                tsdf_new1 = (tsdf_prev1 * weight_prev1 + tsdf_curr * weight_curr) 
                / (weight_prev1 + weight_curr);
            weight_new = weight_prev1; //Ĭ�ϲ�����

            if(SAME_SIDE_VIEW == view_case){
                //if(grazing_reset) //grazing_reset �ֲ�����, ���������ж�
                if(WEIGHT_RESET_FLAG == weight_prev1 && sdf_normed > 1){ //GRAZ ʱ, sdf>1 ʱ grazing_reset �Ľ��, 
                    if(doDbgPrint)
                        printf("\tWEIGHT_RESET_FLAG == weight_prev1 && sdf_normed > 1\n");
                }
                else{ //�� ���� same-side, δ�ܹ� grazing_reset Ӱ��; �� �� graz-reset, ���� sdf<1;
                    //Ȩ���ۻ�
                    if(WEIGHT_RESET_FLAG == weight_prev1)
                        weight_prev1 = 0;
                    weight_new = min(weight_prev1 + weight_curr, (float)Tsdf::MAX_WEIGHT_V13);

                    if(isSnormPrevInit){
                        //if(doDbgPrint) printf("snorm_curr_g-111: [%f, %f, %f]\n", snorm_curr_g.x, snorm_curr_g.y, snorm_curr_g.z);

                        //�𲽡���΢���·�����
                        snorm_curr_g = (snorm_prev_g * weight_prev1 + snorm_curr_g * weight_curr) 
                            * (1./(weight_prev1 + weight_curr) ); //float3 û���س���

                        //if(doDbgPrint) printf("snorm_curr_g-222: [%f, %f, %f], norm(snorm_curr_g):= %f\n", snorm_curr_g.x, snorm_curr_g.y, snorm_curr_g.z, norm(snorm_curr_g));

                        //snorm_curr_g *= 1./norm(snorm_curr_g);
                        snorm_curr_g = normalized(snorm_curr_g);

                        //if(doDbgPrint) printf("snorm_curr_g-333: [%f, %f, %f]\n", snorm_curr_g.x, snorm_curr_g.y, snorm_curr_g.z);
                    }

                    //�᲻����Ϊ char �洢, ǰ��ĸ���û����? ��֪�� @2017-12-18 00:55:39
                    (*snorm_pos).x = (int)nearbyintf(snorm_curr_g.x * CHAR_MAX); //float2char
                    (*snorm_pos).y = (int)nearbyintf(snorm_curr_g.y * CHAR_MAX);
                    (*snorm_pos).z = (int)nearbyintf(snorm_curr_g.z * CHAR_MAX);
                }
            }
            else if(GRAZING_VIEW == view_case){
                if(grazing_reset){
                    tsdf_new1 = SLIGHT_POSITIVE;
                    weight_new = WEIGHT_RESET_FLAG; //-1, �Ǹ����, ��ʾ grazing_reset ��
                }
                else /*if(WEIGHT_RESET_FLAG != weight_new)*/{
                    //����ע�� WEIGHT_RESET_FLAG
                    if(WEIGHT_RESET_FLAG == weight_prev1)
                        weight_prev1 = 0;

                    //���� same-side, Ȩ���ۻ�, norm Ҳ����У��, ǰ�� GRAZING_VIEW ������Ѿ����� weight_curr
                    weight_new = min(weight_prev1 + weight_curr, (float)Tsdf::MAX_WEIGHT_V13);

                    //�𲽡���΢���·�����
                    snorm_curr_g = (snorm_prev_g * weight_prev1 + snorm_curr_g * weight_curr) 
                        * (1./(weight_prev1 + weight_curr) ); //float3 û���س���
                    snorm_curr_g = normalized(snorm_curr_g);

                    (*snorm_pos).x = (int)nearbyintf(snorm_curr_g.x * CHAR_MAX); //float2char
                    (*snorm_pos).y = (int)nearbyintf(snorm_curr_g.y * CHAR_MAX);
                    (*snorm_pos).z = (int)nearbyintf(snorm_curr_g.z * CHAR_MAX);

                    //graz �£��������Ŷȡ���+1��
                    //*snormPrevConfid = min(SCHAR_MAX, *snormPrevConfid + 1);

                }
            }//if-(GRAZING_VIEW == view_case)
            else if(OPPOSITE_VIEW == view_case){
#if 0 //v14: �����ϼ�С w-new, ֱ���� vox ��� SAME �߼�

                weight_new = max(int(weight_prev1 - weight_curr), 0);

                //���� w_curr �ϴ�ʱ, ��Ҫ curr �� prev ʱ, �Źĵ�����
                //if(weight_curr > 1){
                //    (*snormPrevConfid) -=1;

                //    if(doDbgPrint){
                //        printf("*snormPrevConfid---1\n");
                //    }
                //}

                //if(*snormPrevConfid <= snormPrevConfid_thresh){
                //    *snormPrevConfid = snormPrevConfid_thresh + 1;

                //    //ֱ���� curr ����:
                //    (*snorm_pos).x = (int)nearbyintf(snorm_curr_g.x * CHAR_MAX); //float2char
                //    (*snorm_pos).y = (int)nearbyintf(snorm_curr_g.y * CHAR_MAX);
                //    (*snorm_pos).z = (int)nearbyintf(snorm_curr_g.z * CHAR_MAX);
                //}
#elif 1 //v14.1: oppo �����ý���Ȩ��, ֱ�� reset
                if(grazing_reset){
                    tsdf_new1 = SLIGHT_POSITIVE;
                    weight_new = WEIGHT_RESET_FLAG; //-1, �Ǹ����, ��ʾ grazing_reset ��

                    (*snorm_pos).x = (int)nearbyintf(snorm_curr_g.x * CHAR_MAX); //float2char
                    (*snorm_pos).y = (int)nearbyintf(snorm_curr_g.y * CHAR_MAX);
                    (*snorm_pos).z = (int)nearbyintf(snorm_curr_g.z * CHAR_MAX);
                }
#endif
            }//if-(OPPOSITE_VIEW == view_case)

            if(WEIGHT_RESET_FLAG != weight_prev1)
                pack_tsdf(tsdf_new1, weight_new, *pos1);

            if(doDbgPrint){
                printf("\ttsdf_new1, weight_new:: %f, %d\n", tsdf_new1, weight_new);
                printf("\tnew-snorm(*snorm_pos): [%d, %d, %d]\n", snorm_pos->x, snorm_pos->y, snorm_pos->z);
                printf("\tnew-snorm(*snorm_pos): [%f, %f, %f]\n", 1.f * (*snorm_pos).x / CHAR_MAX, 1.f * (*snorm_pos).y / CHAR_MAX, 1.f * (*snorm_pos).z / CHAR_MAX);
            }
          }//if-(Dp_scaled != 0 && sdf >= -tranc_dist) 
          else{
              if(doDbgPrint)
                  printf("NOT (Dp_scaled != 0 && sdf >= -tranc_dist)\n");
          }
        }//if- 0 < (x,y) < (cols,rows)
      }// for(int z = 0; z < VOLUME_Z; ++z)
    }//tsdf23_v14

    //���� v14 ��ѵ, ��˼·: ���жϸ�ֵ��; ���ҽ���: �� p<0 ��ֵ����; �� w����, ��˵��֮ǰ�۲�"����"; �� cos-vray-n_p >cos75��, ������oppo�۲�, ��grazing; �� ������ n_p ����, ����ȷ�����ڹ����
    __global__ void
    tsdf23_v15 (const PtrStepSz<float> depthScaled, PtrStep<short2> volume1, 
        PtrStep<short2> volume2nd, PtrStep<bool> flagVolume, PtrStep<char4> surfNormVolume, PtrStep<char4> vrayPrevVolume, const PtrStepSz<unsigned char> incidAngleMask,
        const PtrStep<float> nmap_curr_g, const PtrStep<float> nmap_model_g,
        /*��--ʵ��˳��: volume2nd, flagVolume, surfNormVolume, incidAngleMask, nmap_g,*/
        const PtrStep<float> weight_map, //v11.4
        const PtrStepSz<short> diff_dmap, //v12.1
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
      float pendingFixThresh = cell_size.x * tranc_dist_inv * 3; //v13.4+ �õ�: �ݶ� 3*vox ���

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

          float tranc_dist_real = max(2*cell_size.x, tranc_dist * weiFactor); //�ضϲ���̫��, v11.8
          if(doDbgPrint) printf("\ttranc_dist_real, weiFactor: %f, %f\n", tranc_dist_real, weiFactor);

          //if (Dp_scaled != 0 && sdf >= -tranc_dist) //meters
          if (Dp_scaled != 0 && sdf >= -tranc_dist_real) //meters
          {
            float sdf_normed = sdf * tranc_dist_inv;
            float tsdf_curr = fmin (1.0f, sdf_normed);

            float3 snorm_curr_g;
            snorm_curr_g.x = nmap_curr_g.ptr(coo.y)[coo.x];
            if(isnan(snorm_curr_g.x)){
                if(doDbgPrint)
                    printf("+++++++++++++++isnan(snorm_curr_g.x), weiFactor: %f\n", weiFactor);

                return;
            }

            snorm_curr_g.y = nmap_curr_g.ptr(coo.y + depthScaled.rows)[coo.x];
            snorm_curr_g.z = nmap_curr_g.ptr(coo.y + 2 * depthScaled.rows)[coo.x];

            float3 vray;
            vray.x = v_g_x;
            vray.y = v_g_y;
            vray.z = v_g_z;
            //float vray_norm = norm(vray);
            float3 vray_normed = normalized(vray); //��λ��������

            float cos_vray_norm_curr = dot(snorm_curr_g, vray_normed);
            if(cos_vray_norm_curr > 0){ //����assert, Ҫ�����: �н�>90��, ��������볯�������ͷ
                //printf("ERROR+++++++++++++++cos_vray_norm > 0");

                //���費��֤�ⲿ����ȷԤ����
                snorm_curr_g.x *= -1;
                snorm_curr_g.y *= -1;
                snorm_curr_g.z *= -1;
            }

            float3 snorm_prev_g;
            snorm_prev_g.x = 1.f * (*snorm_pos).x / CHAR_MAX; //char2float
            snorm_prev_g.y = 1.f * (*snorm_pos).y / CHAR_MAX;
            snorm_prev_g.z = 1.f * (*snorm_pos).z / CHAR_MAX;

            //read and unpack
            float tsdf_prev1;
            float weight_prev1;
            int weight_prev1_scaled;
            unpack_tsdf (*pos1, tsdf_prev1, weight_prev1_scaled);
            weight_prev1 = 1.f * weight_prev1_scaled / WEIGHT_SCALE; //���ڽ���������� float w<1 ת int �ضϵĴ���

            //signed char *snormPrevConfid = &snorm_pos->w;
            //��-v14 ����ȥ�� snormPrevConfid ������, �� w �������
            //const int snormPrevConfid_thresh = 5;

            //bool isSnormPrevInit = (*snormPrevConfid > snormPrevConfid_thresh); //ȥ�� X>1e-8 �ж�, ��Ϊ confid > th ʱ��Ȼ X �Ѿ���ʼ������
            //bool isSnormPrevInit = weight_prev1 > 0; //v14 ������ w ��� snormPrevConfid ������
            bool isSnormPrevInit = weight_prev1 > 1; //v15 ��Ϊ global_time_ == 0 ʱ, �Ѿ� w=1

            const float COS30 = 0.8660254f
                       ,COS45 = 0.7071f
                       ,COS60 = 0.5f
                       ,COS75 = 0.258819f
                       ;
            const float cosThreshSnorm = COS30; //cos(30��), �� vray ���ֿ�, ���ø�������ֵ @2017-3-15 00:39:18

            float cos_snorm_p_c = dot(snorm_prev_g, snorm_curr_g);
            float cos_vray_norm_prev = dot(snorm_prev_g, vray_normed);

            int view_case = SAME_SIDE_VIEW; //����ȡ�� isNewFace @2017-12-22 10:58:03
            if(isSnormPrevInit){ //v14: ���� w
#if 0   //OLD, 
                if(abs(cos_vray_norm_prev) < COS75){ //б���ж�
                    view_case = GRAZING_VIEW; //v13.3: �� p�ڱ�Ե���·���-���߼нǺܴ�, ��ʼ��,֮���,����޸�?
                }
                else if(cos_vray_norm_prev < -COS75){ //ͬ������
                    view_case = SAME_SIDE_VIEW;
                }
                else{ //if(cos_vray_norm_prev > COS75) //��������
                    view_case = OPPOSITE_VIEW;
                }
#elif 1 //v15.2: Ϊ��Ӧ oppo ���νض�, �ſ� graz ����, �� oppo �������ϸ�
                if(cos_vray_norm_prev < -COS75){ //ͬ������
                    view_case = SAME_SIDE_VIEW;
                }
                else if(abs(cos_vray_norm_prev) < COS75 || abs(cos_vray_norm_curr) < COS75){
                    view_case = GRAZING_VIEW; //v13.3: �� p�ڱ�Ե���·���-���߼нǺܴ�, ��ʼ��,֮���,����޸�?
                }
                else{ //if(cos_vray_norm_prev > COS75) //��������
                    view_case = OPPOSITE_VIEW;
                }

#endif
            }

            if(doDbgPrint){
                printf("vray_normed: [%f, %f, %f]; cos_vray_norm_prev, %f; cos_vray_norm_curr, %f (%s, ALWAYS cos<0)\n", 
                    vray_normed.x, vray_normed.y, vray_normed.z, cos_vray_norm_prev, cos_vray_norm_curr, cos_vray_norm_curr>0? "��":"��");
                //�����ӡ snorm У��֮ǰ�� cos-vray-snorm_c (У��֮���Ȼ cos <0 ��); snorm ȴ��У��֮��� @2017-12-20 10:43:19
                printf("cos_snorm_p_c: %f ---snorm_prev_g, snorm_curr_g: [%f, %f, %f], [%f, %f, %f]\n", 
                    cos_snorm_p_c, snorm_prev_g.x, snorm_prev_g.y, snorm_prev_g.z, snorm_curr_g.x, snorm_curr_g.y, snorm_curr_g.z);

                printf("isSnormPrevInit: %s, \n", isSnormPrevInit ? "TTT" : "FFF");
                //printf("isSnormPrevInit: %s, --snormPrevConfid: %d\n", 
                //    isSnormPrevInit ? "TRUE":"FALSE", *snormPrevConfid);

                //printf("%s isNewFace:::", isNewFace? "YES":"NOT");
                printf("%s", view_case==SAME_SIDE_VIEW ? "SAME-SIDE" : (view_case==GRAZING_VIEW ? "GRAZING" : "OPPO-SIDE") );
                printf("::: tsdf_prev1, tsdf_curr: %f, %f\n", tsdf_prev1, tsdf_curr);
            }

            //1, weighting ����
            //float weight_curr = 1; //AVG, FIX, IGN, ������, ��Ȩ�ؾ���һ�� @2017-12-14 10:53:54
            float weight_curr = 0; //���� view_case ������֮��, Ĭ��Ȩ������
            float tsdf_new1 = SLIGHT_POSITIVE; //����º�� tsdf & w
            float weight_new = WEIGHT_RESET_FLAG; //v15 ���� reset-flag ��? �ǲ�ס��
            int weight_new_scaled;
            bool grazing_reset = false;

            if(SAME_SIDE_VIEW == view_case){
                weight_curr = 1;
            }
            else if(GRAZING_VIEW == view_case){
                //weight_curr = 1;    //v15.0: graz ʱ��Ȼ w=1, graz ������???  @2018-1-9 14:53:21
                //��-����, б�ӱ���ʱ, e.g., -0.1 �� 1 ������ʴ, 

                //v15.1: ���� v13.9, ��������, �޸ķֶκ�����ʽ, ��Ҫ���� th, TH; Ҫ���� confid ��̬�仯�� sigma
                float dpc = abs(tsdf_curr - tsdf_prev1);
                float sigma = 1 - 1.f * weight_prev1 / Tsdf::MAX_WEIGHT_V13; //confid~(0,127) --> sigma~(1,0)
                sigma = 0.2 * sigma + 0.1; //(0,1)--> (0.1, 0.3)

                weight_curr = 1 - 1.f * weight_prev1 / Tsdf::MAX_WEIGHT_V13 * (dpc - sigma) / (2 * sigma); //��ĸ�� 3��-��=2��
                weight_curr = max(0.f, min(1.f, weight_curr));

            }
            else if(OPPOSITE_VIEW == view_case){ //֮ǰ if-isNewFace 
                //weight_curr = 0; //OLD, �ĳ�: ������ w, ��Ϊ�ܻ���� bias  
                if(tsdf_prev1 > 0){ //������ wc, ����Ҫô 0, Ҫô -wp (���������� w_new = 0, ���νض�)
                    weight_curr = 0; //��ֵ������
                }
                else if(tsdf_prev1 < 0)
                    //&& weight_prev1 > 50) //����ֵ
                {
                    //���� v14 ��ѵ, ��˼·: ���жϸ�ֵ��; ���ҽ���: �� p<0 ��ֵ����; �� w����, ��˵��֮ǰ�۲�"����"; �� cos-vray-n_p >cos75��, �����桾oppo���۲�, ��grazing; �� ������ n_p ����, ����ȷ�����ڹ����

                    int sx = snorm_prev_g.x > 0 ? 1 : -1, //sign, ������
                        sy = snorm_prev_g.y > 0 ? 1 : -1,
                        sz = snorm_prev_g.z > 0 ? 1 : -1;
                    bool doBreak = false;
                    int nbr_x = -1,
                        nbr_y = -1,
                        nbr_z = -1;
                    float nbr_tsdf;
                    int nbr_weight;
                    for(int ix=0; ix<=1 && !doBreak; ix++){
                        for(int iy=0; iy<=1 && !doBreak; iy++){
                            for(int iz=0; iz<=1 && !doBreak; iz++){
                                if(0==ix && 0==iy && 0==iz)
                                    continue;

                                nbr_x = min(VOLUME_X-1, max(0, x + ix*sx));
                                nbr_y = min(VOLUME_Y-1, max(0, y + iy*sy));
                                nbr_z = min(VOLUME_Z-1, max(0, z + iz*sz));

                                short2 *nbr_pos = volume1.ptr(nbr_y) + nbr_x;
                                nbr_pos += nbr_z * elem_step;

                                //float nbr_tsdf;
                                //int nbr_weight;
                                unpack_tsdf(*nbr_pos, nbr_tsdf, nbr_weight);
                                //if(WEIGHT_RESET_FLAG != nbr_weight && nbr_tsdf > 0){
                                if(0 != nbr_weight && nbr_tsdf > 0){ //v15.0: w_new ������ WEIGHT_RESET_FLAG, ����ֱ������
                                    doBreak = true;
                                    break; //����ʽ�ж���ʵҲ����ν����
                                }
                            }
                        }
                    }//for-ix

                    if(doDbgPrint){
                        printf("\tdoBreak: %s\n", doBreak ? "doBreakTTT=����" : "doBreakFFF-����reset");
                        printf("\tNBR-XYZ: %d, %d, %d; NBR-TSDF/w: %f, %d\n", nbr_x, nbr_y, nbr_z, nbr_tsdf, nbr_weight);
                    }

                    if(false == doBreak){
                        weight_curr = -weight_prev1;
                    }
                }//if=p<0 & w> th
            }//if-OPPOSITE_VIEW

            if(doDbgPrint){
                printf("\tweight_prev1, weight_curr:: %f, %f\n", weight_prev1, weight_curr);
            }

            //2, ���� tsdf, weight, snorm
            weight_new = min(weight_prev1 + weight_curr, (float)Tsdf::MAX_WEIGHT_V13);
            if(0 == weight_new){
                tsdf_new1 = 0;
            }
            else{ //��ĸ��Ϊ��
                tsdf_new1 = (tsdf_prev1 * weight_prev1 + tsdf_curr * weight_curr) / weight_new;
            }
            weight_new_scaled = (int)nearbyintf(weight_new * WEIGHT_SCALE);
            pack_tsdf(tsdf_new1, weight_new_scaled, *pos1);

            //2.2 ���� snorm
            if(SAME_SIDE_VIEW == view_case){
                //�𲽡���΢���·�����
                if(0 != weight_new){
                    snorm_curr_g = (snorm_prev_g * weight_prev1 + snorm_curr_g * weight_curr) 
                        * (1./weight_new ); //float3 û���س���
                    snorm_curr_g = normalized(snorm_curr_g);
                }
                (*snorm_pos).x = (int)nearbyintf(snorm_curr_g.x * CHAR_MAX); //float2char
                (*snorm_pos).y = (int)nearbyintf(snorm_curr_g.y * CHAR_MAX);
                (*snorm_pos).z = (int)nearbyintf(snorm_curr_g.z * CHAR_MAX);
            }
            else if(GRAZING_VIEW == view_case){
                //DO-NOTHING
            }
            else if(OPPOSITE_VIEW == view_case){
                (*snorm_pos).x = 0;
                (*snorm_pos).y = 0;
                (*snorm_pos).z = 0;
            }

            if(doDbgPrint){
                printf("\ttsdf_new1, weight_new:: %f, %f\n", tsdf_new1, weight_new);
                printf("\tnew-snorm(*snorm_pos): [%d, %d, %d]\n", snorm_pos->x, snorm_pos->y, snorm_pos->z);
                printf("\tnew-snorm(*snorm_pos): [%f, %f, %f]\n", 1.f * (*snorm_pos).x / CHAR_MAX, 1.f * (*snorm_pos).y / CHAR_MAX, 1.f * (*snorm_pos).z / CHAR_MAX);
            }

          }//if-(Dp_scaled != 0 && sdf >= -tranc_dist) 
          else{
              if(doDbgPrint)
                  printf("NOT (Dp_scaled != 0 && sdf >= -tranc_dist)\n");
          }
        }//if- 0 < (x,y) < (cols,rows)
      }// for(int z = 0; z < VOLUME_Z; ++z)

    }//tsdf23_v15

    //v16: ���԰�, ���Խ��� tranc_dist_real ����, ���� tdist �ϴ�, ��ԵʲôЧ�� @2018-1-18 10:31:39
    __global__ void
    tsdf23_v16 (const PtrStepSz<float> depthScaled, PtrStep<short2> volume1, 
        PtrStep<short2> volume2nd, PtrStep<bool> flagVolume, PtrStep<char4> surfNormVolume, PtrStep<char4> vrayPrevVolume, const PtrStepSz<unsigned char> incidAngleMask,
        const PtrStep<float> nmap_curr_g, const PtrStep<float> nmap_model_g,
        /*��--ʵ��˳��: volume2nd, flagVolume, surfNormVolume, incidAngleMask, nmap_g,*/
        const PtrStep<float> weight_map, //v11.4
        const PtrStepSz<short> diff_dmap, //v12.1
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
      float pendingFixThresh = cell_size.x * tranc_dist_inv * 3; //v13.4+ �õ�: �ݶ� 3*vox ���

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

          float tranc_dist_real = max(2*cell_size.x, tranc_dist * weiFactor); //�ضϲ���̫��, v11.8
          //float tranc_dist_real = max(cell_size.x, tranc_dist * weiFactor); //�ضϲ���̫��, v11.8

          if(doDbgPrint) printf("\ttranc_dist_real, weiFactor: %f, %f\n", tranc_dist_real, weiFactor);

          //if (Dp_scaled != 0 && sdf >= -tranc_dist) //meters
          if (Dp_scaled != 0 && sdf >= -tranc_dist_real) //meters
          {
            float sdf_normed = sdf * tranc_dist_inv;
            float tsdf_curr = fmin (1.0f, sdf_normed);

            //read and unpack
            float tsdf_prev;
            int weight_prev;
            unpack_tsdf (*pos1, tsdf_prev, weight_prev);

            const int Wrk = 1;

            float tsdf_new = (tsdf_prev * weight_prev + Wrk * tsdf_curr) / (weight_prev + Wrk);
            int weight_new = min (weight_prev + Wrk, Tsdf::MAX_WEIGHT);

            if(doDbgPrint){
                printf("tsdf_prev, tsdf, tsdf_new: %f, %f, %f\n", tsdf_prev, tsdf_curr, tsdf_new);
            }

            pack_tsdf (tsdf_new, weight_new, *pos1);
          }
        }
        else{ //NOT (coo.x >= 0 && coo.y >= 0 && coo.x < depthScaled.cols && coo.y < depthScaled.rows)
            if(doDbgPrint){
                printf("vxlDbg.xyz:= (%d, %d, %d), coo.xy:= (%d, %d)\n", vxlDbg.x, vxlDbg.y, vxlDbg.z, coo.x, coo.y);
            }
        }
      }       // for(int z = 0; z < VOLUME_Z; ++z)
    }      // __global__ tsdf23_v16

    //v13~v15 ʧ��, ��ѵ: ����ֱ�� reset, ������ƫ��, ��������³��, �����׵��� bias
    //v17 ���Բ���: ˫ tsdf, ���� tdist, ��̬ѡ��, �ĸ��������ĸ�; ��ȱ�㡿�� �� ����Ч����Ȼ��, �����ֹ�; �� raycast, march-cubes ������Ҫ��֮��Ķ� @2018-1-18 15:26:21
    __global__ void
    tsdf23_v17 (const PtrStepSz<float> depthScaled, PtrStep<short2> volume1, 
        PtrStep<short2> volume2nd, PtrStep<bool> flagVolume, PtrStep<char4> surfNormVolume, PtrStep<char4> vrayPrevVolume, const PtrStepSz<unsigned char> incidAngleMask,
        const PtrStep<float> nmap_curr_g, const PtrStep<float> nmap_model_g,
        /*��--ʵ��˳��: volume2nd, flagVolume, surfNormVolume, incidAngleMask, nmap_g,*/
        const PtrStep<float> weight_map, //v11.4
        const PtrStepSz<short> diff_dmap, //v12.1
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
      float pendingFixThresh = cell_size.x * tranc_dist_inv * 3; //v13.4+ �õ�: �ݶ� 3*vox ���; //ֵ������� tranc_dist ��һ������

      short2* pos1 = volume1.ptr (y) + x;
      int elem_step = volume1.step * VOLUME_Y / sizeof(short2);

      //�ҵĿ�������:
      short2 *pos2nd = volume2nd.ptr(y) + x;
      const float tdist2nd_m = TDIST_MIN_MM / 1e3; //v17

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
        if(doDbgPrint)
            printf("inv_z:= %f\n", inv_z);

        if (inv_z < 0)
            continue;

        // project to current cam
        int2 coo =
        {
          __float2int_rn (v_x * inv_z + intr.cx),
          __float2int_rn (v_y * inv_z + intr.cy)
        };

        if(doDbgPrint)
            printf("coo.xy:(%d, %d)\n", coo.x, coo.y);

        if (coo.x >= 0 && coo.y >= 0 && coo.x < depthScaled.cols && coo.y < depthScaled.rows)         //6
        {
          float Dp_scaled = depthScaled.ptr (coo.y)[coo.x]; //meters

          float sdf = Dp_scaled - sqrtf (v_g_z * v_g_z + v_g_part_norm);

          if(doDbgPrint){
              printf("Dp_scaled, sdf, tranc_dist, %f, %f, %f\n", Dp_scaled, sdf, tranc_dist);
          }

          float weiFactor = weight_map.ptr(coo.y)[coo.x];

          float tranc_dist_real = max(2*cell_size.x, tranc_dist * weiFactor); //�ضϲ���̫��, v11.8
          if(doDbgPrint) printf("\ttranc_dist_real, weiFactor: %f, %f\n", tranc_dist_real, weiFactor);

          //if (Dp_scaled != 0 && sdf >= -tranc_dist) //meters
          if (Dp_scaled != 0 && sdf >= -tranc_dist_real) //meters
          {
            //v17.3 ��� cos-vray-snorm_c ���ڴ˿���ǰ��, ����������� sdf ��ʼ��λ�� @2018-1-30 17:15:23
            float3 snorm_curr_g;
            snorm_curr_g.x = nmap_curr_g.ptr(coo.y)[coo.x];
            if(isnan(snorm_curr_g.x)){
                if(doDbgPrint)
                    printf("+++++++++++++++isnan(snorm_curr_g.x), weiFactor: %f\n", weiFactor);

                //return; //��, v18.x ʱ�ŷ��� @2018-3-8 15:29:28
                continue;
            }

            snorm_curr_g.y = nmap_curr_g.ptr(coo.y + depthScaled.rows)[coo.x];
            snorm_curr_g.z = nmap_curr_g.ptr(coo.y + 2 * depthScaled.rows)[coo.x];

            float3 vray;
            vray.x = v_g_x;
            vray.y = v_g_y;
            vray.z = v_g_z;
            //float vray_norm = norm(vray);
            float3 vray_normed = normalized(vray); //��λ��������

            float cos_vray_norm_curr = dot(snorm_curr_g, vray_normed);
            if(cos_vray_norm_curr > 0){ //����assert, Ҫ�����: �н�>90��, ��������볯�������ͷ
                //printf("ERROR+++++++++++++++cos_vray_norm > 0");

                //���費��֤�ⲿ����ȷԤ����
                snorm_curr_g.x *= -1;
                snorm_curr_g.y *= -1;
                snorm_curr_g.z *= -1;
            }

            //v17.3: sdf ���� cos-vray-snorm_c ͶӰ, �ݲ��� snorm_p //����֤: Ч������, �ڱ���(��ֵ��)����, ȷʵ��Ҫ�˷�, ȷ����ȷ, ���������νض�(neg_near_zero) ����
            float sdf_cos = abs(cos_vray_norm_curr) * sdf;
            if(doDbgPrint){
                printf("snorm_curr_g, vray_normed: [%f, %f, %f], [%f, %f, %f]\n", snorm_curr_g.x, snorm_curr_g.y, snorm_curr_g.z, vray_normed.x, vray_normed.y, vray_normed.z);
                printf("sdf-orig: %f,, cos_vray_norm_curr: %f,, sdf_cos: %f\n", sdf, cos_vray_norm_curr, sdf_cos);
            }

            sdf = sdf_cos;
            float sdf_normed = sdf * tranc_dist_inv;
            float tsdf_curr = fmin (1.0f, sdf_normed);
            float sdf_normed_mm = sdf_normed * 1e3;


            float3 snorm_prev_g;
            snorm_prev_g.x = 1.f * (*snorm_pos).x / CHAR_MAX; //char2float
            snorm_prev_g.y = 1.f * (*snorm_pos).y / CHAR_MAX;
            snorm_prev_g.z = 1.f * (*snorm_pos).z / CHAR_MAX;

            //read and unpack
            float tsdf_prev1;
            int weight_prev1;
            unpack_tsdf (*pos1, tsdf_prev1, weight_prev1);
            bool use_tdist2nd = weight_prev1 % 2; //v17.1: �� w������ĩλ=1, ���ñ��� tdist (Ŀǰ�����Ǽ�С�ض�)
            weight_prev1 = weight_prev1 >> 1; //ȥ��ĩλ, ������
            if(doDbgPrint)
                printf("use_tdist2nd-prev: %d,, tsdf_prev1: %f,, weight_prev1: %d\n", use_tdist2nd, tsdf_prev1, weight_prev1);


            float tsdf_prev1_real_m = tsdf_prev1 * (use_tdist2nd ? tdist2nd_m : tranc_dist); //

            int Wrk = 1; //Ĭ��1

            if(use_tdist2nd){
                //�˿��ڽ��޸� tsdf_curr
                tsdf_curr = fmin (1.0f, sdf / tdist2nd_m);
                if(sdf < -tdist2nd_m)
                    Wrk = 0;
            }

#if 0   //v17.0, �� volume-2nd, ����δ���; ���Ƿ�����һ�� vol �͹��� (��Ϊֻ��Ҫһ���ء�����tdist���λ��), ���Դ��߼��������ݷ���������
            float tsdf_prev2nd = -123;
            int weight_prev2nd = -233;
            unpack_tsdf (*pos2nd, tsdf_prev2nd, weight_prev2nd);

            //volume-2nd ֱ�� pack, ��������
            if(sdf >= -tdist2nd_m){
                const int Wrk = 1;
                float tsdf_curr2nd = fmin (1.0f, sdf / tdist2nd_m); //volume-2nd �趨���� tdist=5mm 
                float tsdf_new2nd = (tsdf_prev2nd * weight_prev2nd + tsdf_curr2nd * Wrk) / (weight_prev2nd + Wrk);
                int weight_new2nd = min (weight_prev2nd + Wrk, Tsdf::MAX_WEIGHT);
                pack_tsdf(tsdf_new2nd, weight_new2nd, *pos2nd);
            }

            //v17.0: �� snorm_pos->w ��¼ tdist, ÿ�� vox ����, ���� mm ����
            signed char *trunc_dist_mm = &snorm_pos->w;
            if(0 == *trunc_dist_mm) //�����λ ��û��ʼ��, ���ú���������ʼ��; ����, ���Ѵ�ı��ֵ
                *trunc_dist_mm = int(tranc_dist * 1e3 + 0.5);
            float trunc_dist_m = trunc_dist_mm / 1e3;
#endif

            //v17.2: ��֮ǰ"���濴��ֵvox, ������ǰ�������, ���vox ����" 
            //��Ϊ: ���濴��ֵ vox, �� w �ﵽĳ��ֵ, ���� "���������", ����, �ٵ����濴ʱ, ���б��, �򲻶�
            //���� snorm_pos->w �����λ, �ݲ����� w(short) @2018-1-29 00:46:48
            //signed char *neg_near_zero = &snorm_pos->w;
            bool neg_near_zero = snorm_pos->w; //��ʼ 0->false
            const int weight_neg_th = 30; 
            if(tsdf_prev1 < 0 && weight_prev1 > weight_neg_th && !neg_near_zero)//��: ��ֵ, ��Ȩ�شﵽ��ֵ, �ұ��λ��δ��ʼ��
            {
                //��ԵҪ��Ҫ�ж�, �Ա����Ե��ƽ��? ��ȷ��, �ݲ�, 
                //weiFactor

                if(tsdf_prev1_real_m > 1.1 * cell_size.x){ //�为, ������������ (��ֵ��) //���� max(x,y,z); �ж���ֵ�� csz.x, ����� //�� projTSDF ��������, ���Ը��� sdf_cos
                    neg_near_zero = true;
                    snorm_pos->w = 1; //neg_near_zero=true
                }
            }

            const float COS30 = 0.8660254f
                ,COS45 = 0.7071f
                ,COS60 = 0.5f
                ,COS75 = 0.258819f
                ;

            float cos_snorm_p_c = dot(snorm_prev_g, snorm_curr_g);

            //v17.X: snorm-p-c �н� >60��, ��Ϊ����, �����, ���ܵĲ���: 
            //�� Զ�˸���, ��Ҫ��; 
            //�� ������: a, ������, ��; b, ���帺, ??? ���������ܻᵼ�� bias, Ҫ��������!��

            if(doDbgPrint){
                printf("snorm_prev_g.xyz: (%f, %f, %f)\n", snorm_prev_g.x, snorm_prev_g.y, snorm_prev_g.z);
                printf("snorm_curr_g.xyz: (%f, %f, %f); cos_snorm_p_c: %f\n", snorm_curr_g.x, snorm_curr_g.y, snorm_curr_g.z, cos_snorm_p_c);
            }

            bool isSnormPrevInit = (norm(snorm_prev_g) > 1e-8);
            if(!isSnormPrevInit && sdf < tranc_dist){ //ֻ���ڽ����� (���� tdist ����Ǹ��ж�), �ų�ʼ�� snorm
                (*snorm_pos).x = (int)nearbyintf(snorm_curr_g.x * CHAR_MAX); //float2char
                (*snorm_pos).y = (int)nearbyintf(snorm_curr_g.y * CHAR_MAX);
                (*snorm_pos).z = (int)nearbyintf(snorm_curr_g.z * CHAR_MAX);
            }
            else if(isSnormPrevInit && cos_snorm_p_c < COS60){ //�� norm-p ��ʼ����, �� cos-n-p-c ��������
                //v17.0: ����������, ������������ tdist, �Ȱѻ������̡�������Ūͨ �����ԡ�
                //sdf //m, ��ǰ֡
                //tranc_dist, tranc_dist_inv //m, ��ǰ��������
                //tsdf_prev1 //0~1, 

                if(!use_tdist2nd){ //��2nd ���λû������, ˵����һ�ν���, Ҫ: 1, ����λ; 2, w_p=0
                    use_tdist2nd = true;

                    //float tsdf_prev1_real_m = tsdf_prev1 * tranc_dist; //֮ǰӦ�ö��õĺ������� tranc_dist //����Ҫ��, ���Էŵ�����
                    tsdf_prev1 = tsdf_prev1_real_m / tdist2nd_m; //�ݲ��� fmin(1, ..), ������ w=0
                    //if(tsdf_prev1_real_m < -tdist2nd_m){ //�� ��� tdist2nd, ̫��, ������, ��Ϊ���� -tdist2nd ��������Ҳ��δ��ʼ��״̬
                    if(tsdf_prev1_real_m < -tdist2nd_m && !neg_near_zero){ 
                        weight_prev1 = 0;
                        tsdf_prev1 = 0; //��ʵ����, ��ʽд��, �����Ķ�

                        snorm_pos->x = snorm_pos->y = snorm_pos->z = 0;
                    }
                }
                //���� use_tdist2nd T/F, t_curr �϶�Ҫ�� td-2nd ����:
                tsdf_curr = fmin (1.0f, sdf / tdist2nd_m);
                if(sdf < -tdist2nd_m){
                    Wrk = 0;
                    tsdf_curr = 0; //��ʵ����, ��ʽд��, �����Ķ�
                }
                else{
                    ////v17.5
                    //if(sdf > tdist2nd_m //��: �۲쵽Զ�˱���
                    //    && 0 != weight_prev1) //�Ҵ� vox ����֮���ֱ�Զ�˸��¹� //use_tdist2nd �Ѿ� true, �������ж�ָ��; �� weight_prev1 �ж�
                    //    Wrk = 0; //�Ͳ��ٸ���, 
                    
                    //v17.6.1: �򵥴ֱ�: �� w >th, ��Ϊ t_p �㹻�ȶ�, ��������߼� cos(n-p-c)<COS60, ����ֱ��������ǰ: w_c = 0
                    if(tsdf_curr < tsdf_prev1 && weight_prev1 > weight_neg_th) //��: c<p
                        Wrk = 0;
                }

                //v17.2: ��
                if(neg_near_zero)
                    Wrk = 0;

                //v17.7: 17.5 �Ƶ����, ������ isSnormPrevInit / cos_snorm_p_c ɶ��, ֻҪ w_c !=0, Զ��һ�ɲ����� w @2018-2-4 11:30:27
                if(sdf > (use_tdist2nd ? tdist2nd_m : tranc_dist) //��: �۲쵽Զ�˱���
                    && 0 != weight_prev1) //�Ҵ� vox ����֮���ֱ�Զ�˸��¹� //use_tdist2nd �Ѿ� true, �������ж�ָ��; �� weight_prev1 �ж�
                    Wrk = 0; //�Ͳ��ٸ���, 

                //v17.x: Զ�˸���(���帺), һ�ɲ�Ҫ��
                //v17.x: Զ�˸���(���帺), �������ж�, ����"����"�ӽ�ʱ, ������ tdist
            }//cos-norm-p-c < COS60

            //v17.4
            if(!neg_near_zero){ //��֮ǰ��̫��������ʱ, ���� t_c ����Ȩ��
                //��--��: wrk ����; �� {t_c} < {t_p}
                if(abs(Wrk) > 1e-5 && abs(tsdf_curr) < abs(tsdf_prev1) )
                {
                    float tpc_ratio = abs(tsdf_prev1) / (abs(tsdf_curr) + 1e-2); //�˿��ڽ����Ȼ >1; ��ĸtrickΪ�˱������
                    //v17.4.1: ֱ���� ratio ��Ȩ��:
                    Wrk = (int)fmin(10.f, tpc_ratio);

                    //v17.4.2: �� ratio^2, Ŀ��: �� t_c ����̫Сʱ, ��Ȼ���� t_c Ӱ����
                    Wrk = (int)fmin(10.f, tpc_ratio * tpc_ratio);
                }
            }

            float tsdf_new1 = (tsdf_prev1 * weight_prev1 + tsdf_curr * Wrk) / (weight_prev1 + Wrk);
            int weight_new1 = min (weight_prev1 + Wrk, Tsdf::MAX_WEIGHT);
            
            if(doDbgPrint){
                printf("����tsdf_prev1: %f,, weight_prev1: %d; tsdf_prev1_real_m: %f, neg_near_zero: %s\n", tsdf_prev1, weight_prev1, tsdf_prev1_real_m, neg_near_zero ? "TTT":"FFF");
                printf("����tsdf_curr: %f,, Wrk: %d; \n", tsdf_curr, Wrk);
                printf("tsdf_new1: %f,, weight_new1: %d;;; use_tdist2nd: %d\n", tsdf_new1, weight_new1, use_tdist2nd);
            }
            //pack ǰ, ��� w_new Ҫ���ϱ��λ:
            weight_new1 = (weight_new1 << 1) + use_tdist2nd;

            pack_tsdf (tsdf_new1, weight_new1, *pos1);

          }//if-(Dp_scaled != 0 && sdf >= -tranc_dist) 
          else{
              if(doDbgPrint)
                  printf("NOT (Dp_scaled != 0 && sdf >= -tranc_dist)\n");
          }
        }//if- 0 < (x,y) < (cols,rows)
      }// for(int z = 0; z < VOLUME_Z; ++z)
    }//tsdf23_v17

    //for v18, Ϊ�˲��� krnl �Ƿ� thread, block ��ʵ����, ���: OK
    __global__ void
    test_kernel (int3 vxlDbg){
        int x = threadIdx.x + blockIdx.x * blockDim.x;
        int y = threadIdx.y + blockIdx.y * blockDim.y;
        if(vxlDbg.x == x && vxlDbg.y == y)
            printf("dbg@test_kernel>>>xy: %d, %d\n", x, y);

    }//test_kernel

    __global__ void
    tsdf23_v18 (const PtrStepSz<float> depthScaled, PtrStep<short2> volume1, 
        PtrStep<short2> volume2nd, PtrStep<bool> flagVolume, PtrStep<char4> surfNormVolume, PtrStep<char4> vrayPrevVolume, const PtrStepSz<unsigned char> incidAngleMask,
        const PtrStep<float> nmap_curr_g, const PtrStep<float> nmap_model_g,
        /*��--ʵ��˳��: volume2nd, flagVolume, surfNormVolume, incidAngleMask, nmap_g,*/
        const PtrStep<float> weight_map, //v11.4
        const PtrStepSz<ushort> depthModel,
        const PtrStepSz<short> diff_dmap, //v12.1
        const float tranc_dist, const Mat33 Rcurr_inv, const float3 tcurr, const Intr intr, const float3 cell_size
        , int3 vxlDbg)
    {
      int x = threadIdx.x + blockIdx.x * blockDim.x;
      int y = threadIdx.y + blockIdx.y * blockDim.y;
      //printf("tsdf23_v18, xy: %d, %d\n", x, y);
      //if(vxlDbg.x == x && vxlDbg.y == y)
      //    printf("dbg@tsdf23_v18>>>xy: %d, %d\n", x, y);

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
      float pendingFixThresh = cell_size.x * tranc_dist_inv * 3; //v13.4+ �õ�: �ݶ� 3*vox ���; //ֵ������� tranc_dist ��һ������

      short2* pos1 = volume1.ptr (y) + x;
      int elem_step = volume1.step * VOLUME_Y / sizeof(short2);

      //�ҵĿ�������:
      short2 *pos2nd = volume2nd.ptr(y) + x;
      const float tdist2nd_m = TDIST_MIN_MM / 1e3; //v17

      //hadSeen-flag:
      bool *flag_pos = flagVolume.ptr(y) + x;
      int flag_elem_step = flagVolume.step * VOLUME_Y / sizeof(bool);

      //vray.prev
      char4 *vrayPrev_pos = vrayPrevVolume.ptr(y) + x;
      int vrayPrev_elem_step = vrayPrevVolume.step * VOLUME_Y / sizeof(char4);

      //surface-norm.prev
      char4 *snorm_pos = surfNormVolume.ptr(y) + x;
      int snorm_elem_step = surfNormVolume.step * VOLUME_Y / sizeof(char4);

      //if(vxlDbg.x == x && vxlDbg.y == y)
      //    printf("dbg@tsdf23_v18-before-for-loop>>>xy: %d, %d\n", x, y);

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
        //v18.2 ���ѽ��, ��ѭ���ڲ����� return��
        //if(x > 0 && y > 0 && z > 0 //����Ĭ�� 000, ����Чֵ, �������Ӵ˼��
        //    && vxlDbg.x == x && vxlDbg.y == y)// && vxlDbg.z == z)
        //{   //��ʱ����: ����Щ vox �޷���λ��, �ƺ�������������߼���; @2018-3-1 22:47:15
        //    printf("dbg@for-loop>>>xyz: %d, %d, %d\n", x, y, z);
        //}
        bool doDbgPrint = false;
        if(x > 0 && y > 0 && z > 0 //����Ĭ�� 000, ����Чֵ, �������Ӵ˼��
            && vxlDbg.x == x && vxlDbg.y == y && vxlDbg.z == z)
            doDbgPrint = true;

        float inv_z = 1.0f / (v_z + Rcurr_inv.data[2].z * z_scaled);
        if(doDbgPrint)
            printf("inv_z:= %f\n", inv_z);

        if (inv_z < 0)
            continue;

        // project to current cam
        int2 coo =
        {
          __float2int_rn (v_x * inv_z + intr.cx),
          __float2int_rn (v_y * inv_z + intr.cy)
        };

        if(doDbgPrint)
            printf("coo.xy:(%d, %d)\n", coo.x, coo.y);

        if (coo.x >= 0 && coo.y >= 0 && coo.x < depthScaled.cols && coo.y < depthScaled.rows)         //6
        {
          float Dp_scaled = depthScaled.ptr (coo.y)[coo.x]; //meters

          float sdf = Dp_scaled - sqrtf (v_g_z * v_g_z + v_g_part_norm);

          if(doDbgPrint){
              printf("Dp_scaled, sdf, tranc_dist, %f, %f, %f\n", Dp_scaled, sdf, tranc_dist);
          }

          float weiFactor = weight_map.ptr(coo.y)[coo.x];
          //float tranc_dist_real = max(2*cell_size.x, tranc_dist * weiFactor); //�ضϲ���̫��, v11.8
          float tranc_dist_real = max(0.3, weiFactor) * tranc_dist; //v18.4: ��Ե���� w_factor=0, 

          float3 snorm_curr_g;
          snorm_curr_g.x = nmap_curr_g.ptr(coo.y)[coo.x];

           if(isnan(snorm_curr_g.x)){
               if(doDbgPrint)
                   printf("+++++++++++++++isnan(snorm_curr_g.x), weiFactor: %f\n", weiFactor);
 
               //return;    //��ѭ��, ÿ�ζ�Ҫ�߱� z��, ���� ����
               continue;    //v18.2
           }

          snorm_curr_g.y = nmap_curr_g.ptr(coo.y + depthScaled.rows)[coo.x];
          snorm_curr_g.z = nmap_curr_g.ptr(coo.y + 2 * depthScaled.rows)[coo.x];

          float3 vray;
          vray.x = v_g_x;
          vray.y = v_g_y;
          vray.z = v_g_z;
          //float vray_norm = norm(vray);
          float3 vray_normed = normalized(vray); //��λ��������

          float cos_vray_norm_curr = dot(snorm_curr_g, vray_normed);
          if(cos_vray_norm_curr > 0){ //����assert, Ҫ�����: �н�>90��, ��������볯�������ͷ
              //printf("ERROR+++++++++++++++cos_vray_norm > 0");

              //���費��֤�ⲿ����ȷԤ����
              snorm_curr_g.x *= -1;
              snorm_curr_g.y *= -1;
              snorm_curr_g.z *= -1;
          }

          //float sdf_cos = abs(cos_vray_norm_curr) * sdf;
          float sdf_cos = max(COS75, abs(cos_vray_norm_curr)) * sdf; //v18.3: �������Ӳ���С�� COS75

          if(doDbgPrint){
              printf("snorm_curr_g, vray_normed: [%f, %f, %f], [%f, %f, %f]\n", snorm_curr_g.x, snorm_curr_g.y, snorm_curr_g.z, vray_normed.x, vray_normed.y, vray_normed.z);
              printf("sdf-orig: %f,, cos_vray_norm_curr: %f,, sdf_cos: %f\n", sdf, cos_vray_norm_curr, sdf_cos);
              printf("\ttranc_dist_real, weiFactor: %f, %f\n", tranc_dist_real, weiFactor);
          }

          sdf = sdf_cos;

          //��--v18.17: unpack Ų������
          //read and unpack
          float tsdf_prev1;
          int weight_prev1;
          unpack_tsdf (*pos1, tsdf_prev1, weight_prev1);
          bool prev_always_edge = weight_prev1 % 2; //��DEL v17.1�� //v18.15: �����Ϊ: �Ƿ�һֱ���ڱ�Ե (��ֵ:=0:=false) @2018-3-28 15:56:33
          weight_prev1 = weight_prev1 >> 1; //ȥ��ĩλ, ֻ��Ϊ���� v17 ����һ��, ������� ������Ϊ tsdf23 �� w*2 ��
          if(doDbgPrint)
              printf("prev_always_edge-prev: %d,, tsdf_prev1: %f,, weight_prev1: %d\n", prev_always_edge, tsdf_prev1, weight_prev1);

          //if (Dp_scaled != 0 && sdf >= -tranc_dist) //meters
          if (Dp_scaled != 0 && sdf >= -tranc_dist_real) //meters //v18.4
          //if (Dp_scaled != 0 && tranc_dist_real >= sdf && sdf >= -tranc_dist_real) //meters //v18.6: ������ֵԶ�˽ض�; ����������ڲ�����, �ⲿ(�����Ե)����; �ķ��ں���, �� v18.7
          {
            float tsdf_curr = fmin (1.0f, sdf * tranc_dist_inv);

            //��--�������, Ų�������� v18.17
            ////read and unpack
            //float tsdf_prev1;
            //int weight_prev1;
            //unpack_tsdf (*pos1, tsdf_prev1, weight_prev1);
            //bool prev_always_edge = weight_prev1 % 2; //��DEL v17.1�� //v18.15: �����Ϊ: �Ƿ�һֱ���ڱ�Ե (��ֵ:=0:=false) @2018-3-28 15:56:33
            //weight_prev1 = weight_prev1 >> 1; //ȥ��ĩλ, ֻ��Ϊ���� v17 ����һ��, ������� ������Ϊ tsdf23 �� w*2 ��
            //if(doDbgPrint)
            //    printf("prev_always_edge-prev: %d,, tsdf_prev1: %f,, weight_prev1: %d\n", prev_always_edge, tsdf_prev1, weight_prev1);

            //const int Wrk = 1;
            int Wrk = 1; //v18.5: ����ȫ����: diff_dmap + ������� (�� nmap_model_g, ���� nmap-curr �ж�) @2018-3-11 11:58:55
            short diff_c_p = diff_dmap.ptr(coo.y)[coo.x]; //mm, curr-prev, +��ֵΪ��ǰ����
            ushort depth_prev = depthModel.ptr(coo.y)[coo.x];

            const int diff_c_p_thresh = 20; //20mm
            if(doDbgPrint)
                printf("depth_prev: %u; diff_c_p: %d\n", depth_prev, diff_c_p);

            if(depth_prev > 0 //����Ҫ model �� px ��Ч���ѳ�ʼ����
                && diff_c_p > diff_c_p_thresh){
                float3 snorm_prev_g;
                snorm_prev_g.x = nmap_model_g.ptr(coo.y)[coo.x];
                if(isnan(snorm_prev_g.x)){
                    if(doDbgPrint)
                        printf("\t+++++isnan(snorm_prev_g.x)\n");

                    Wrk = 0;
                }
                else{
                    snorm_prev_g.y = nmap_model_g.ptr(coo.y + depthScaled.rows)[coo.x];
                    snorm_prev_g.z = nmap_model_g.ptr(coo.y + 2 * depthScaled.rows)[coo.x];

                    float cos_vray_norm_prev = dot(snorm_prev_g, vray_normed);
                    if(doDbgPrint)
                        printf("\tsnorm_prev_g.xyz: (%f, %f, %f), cos_vray_norm_prev: %f\n", 
                            snorm_prev_g.x, snorm_prev_g.y, snorm_prev_g.z, cos_vray_norm_prev);

                    if(abs(cos_vray_norm_prev) < COS75)
                        Wrk = 0;
                }
            }//if-(diff_c_p > diff_c_p_thresh)

            //v18.7: ��Ϊ: ��һ��(w=0)�۲⵽Զ��, ��ֹ��ʼ��; 
            //�����1, ��/������� v18.6, �ڲ����� v18.5, 2, �����ⲿ���в�����Ƭ����; 3, ����ͼ(raycast���)���ѿ�!    ���ݴ桿
//             if(0 == weight_prev1 && sdf > tranc_dist_real){
//                 Wrk = 0;
//             }

            const float W_FACTOR_EDGE_THRESH = 0.99f;
            bool is_curr_edge = weiFactor < W_FACTOR_EDGE_THRESH;

            if(Wrk != 0){
                //if(0 == weight_prev1 && is_curr_edge){ //�� w-prev��δ��ʼ������ curr �ڱ�Ե
                if(weight_prev1 <= 1 && is_curr_edge){ //v18.18: �Ը�, ����, �� global_time =0 ʱ�õ� tsdf23 ֱ�� w+1 @2018-4-10 17:27:08
                    prev_always_edge = true;
                }
                else if(!is_curr_edge && prev_always_edge){
                    prev_always_edge = false;

                    //weight_prev1 = min(weight_prev1, 30); //����1: w-p ֱ�ӽ�Ȩ�� 30��1s; //����, ��t-p=1, �� 1*30 �����Ժܴ�, ������
                    weight_prev1 = min(weight_prev1, 5);
                }
            }

            float tsdf_new1 = tsdf_prev1;
            int weight_new1 = weight_prev1;
            if(Wrk > 0)
                //&& !(!prev_always_edge && is_curr_edge && tsdf_curr > 0.99) ) //��: prevȷ�ϷǱ�Ե, curr�Ǳ�Ե, �� t-cȷʵ��, �򲻸��� t, w
                //&& (prev_always_edge || !is_curr_edge || tsdf_curr <= 0.99) ) //ͬ��, 
            {
                tsdf_new1 = (tsdf_prev1 * weight_prev1 + tsdf_curr * Wrk) / (weight_prev1 + Wrk);
                weight_new1 = min (weight_prev1 + Wrk, Tsdf::MAX_WEIGHT);
            }

            if(doDbgPrint){
                //printf("����tsdf_prev1: %f,, weight_prev1: %d; tsdf_prev1_real_m: %f, neg_near_zero: %s\n", tsdf_prev1, weight_prev1, tsdf_prev1_real_m, neg_near_zero ? "TTT":"FFF");
                printf("����tsdf_prev1: %f,, weight_prev1: %d;\n", tsdf_prev1, weight_prev1);
                printf("����tsdf_curr: %f,, Wrk: %d; \n", tsdf_curr, Wrk);
                printf("tsdf_new1: %f,, weight_new1: %d;;; prev_always_edge: %d\n", tsdf_new1, weight_new1, prev_always_edge);
            }

            if(weight_new1 == 0)
                tsdf_new1 = 0; //�Ͻ���, ������Ի��ơ�marching cubes����

            //pack ǰ, ��� w_new Ҫ���ϱ��λ:
            weight_new1 = (weight_new1 << 1) + prev_always_edge;

            pack_tsdf (tsdf_new1, weight_new1, *pos1);

          }//if-(Dp_scaled != 0 && sdf >= -tranc_dist) 
//           else{
//               if(doDbgPrint)
//                   printf("NOT (Dp_scaled != 0 && sdf >= -tranc_dist)\n");
//           }
          //else if(Dp_scaled != 0 && sdf < -tranc_dist) { //v18.12: �˴�+v18.8; ��ĳvox����������һ�ۣ���������ȫ���䣬����ʱ��̣�, 
                                                            //�����ʱ�䲻�ɼ�, ��������Ȩ(����); ��������ܺ�, ���� v18.11, ����ʱ�򿴼�һ��δ��������, Ҫ��
          else if(Dp_scaled != 0 
              && sdf < -tranc_dist &&  sdf > -4*tranc_dist   //v18.13: ��-2*tdist +v18.8, �ų� v18.12 ������ //v18.14 ��-4*tdist, ��ȥ�� v18.8, ����ԭ�� marching cubes
              && !prev_always_edge  //v18.17: ���ԷǱ�Եִ�� "-1 ����", �����Ǳ�Ե(��, ϸ����), �� -1 @2018-4-8 02:32:39
            )
          {
              //��-v18.17: Ų�� if ������
              //float tsdf_prev1;
              //int weight_prev1;
              //unpack_tsdf (*pos1, tsdf_prev1, weight_prev1);
              //bool prev_always_edge = weight_prev1 % 2;
              //weight_prev1 = weight_prev1 >> 1; //ȥ��ĩλ, 

              const int POS_VALID_WEIGHT_TH = 0; //30֡��һ��
              if(/*tsdf_prev1 >= 0.999 ||*/ //�� t_p ֮ǰ��"Զ��", �ǽ�����
                  tsdf_prev1 > 0 && weight_prev1 < POS_VALID_WEIGHT_TH) //��, �� t_p ��ֵ�����в��ȶ�
              {
                  weight_prev1 = max(0, weight_prev1-1);

                  if(doDbgPrint){
                      printf("����tsdf_prev1: %f,, weight_prev1-=1: %d;\n", tsdf_prev1, weight_prev1);
                  }
              }

              if(weight_prev1 == 0)
                  tsdf_prev1 = 0; //�Ͻ���, ������Ի��ơ�marching cubes����
              weight_prev1 = (weight_prev1 << 1) + prev_always_edge;

              pack_tsdf (tsdf_prev1, weight_prev1, *pos1);
          }
        }//if- 0 < (x,y) < (cols,rows)
      }// for(int z = 0; z < VOLUME_Z; ++z)
    }//tsdf23_v18

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
    }      // tsdf23normal_hack
  }//namespace device

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

void
pcl::device::integrateTsdfVolume_s2s (/*const PtrStepSz<ushort>& depth,*/ const Intr& intr,
    const float3& volume_size, const Mat33& Rcurr_inv, const float3& tcurr, float tranc_dist, float eta,
    PtrStep<short2> volume, DeviceArray2D<float>& depthScaled, int3 vxlDbg) //zc: ����
{
    //depthScaled.create (depth.rows, depth.cols);

    //dim3 block_scale (32, 8);
    //dim3 grid_scale (divUp (depth.cols, block_scale.x), divUp (depth.rows, block_scale.y));

    ////scales depth along ray and converts mm -> meters. 
    //scaleDepth<<<grid_scale, block_scale>>>(depth, depthScaled, intr);
    //cudaSafeCall ( cudaGetLastError () );

    float3 cell_size;
    cell_size.x = volume_size.x / VOLUME_X;
    cell_size.y = volume_size.y / VOLUME_Y;
    cell_size.z = volume_size.z / VOLUME_Z;

    //dim3 block(Tsdf::CTA_SIZE_X, Tsdf::CTA_SIZE_Y);
    dim3 block (16, 16);
    dim3 grid (divUp (VOLUME_X, block.x), divUp (VOLUME_Y, block.y));

    //tsdf23<<<grid, block>>>(depthScaled, volume, tranc_dist, Rcurr_inv, tcurr, intr, cell_size, *buffer);    
    tsdf23_s2s<<<grid, block>>>(depthScaled, volume, tranc_dist, eta,
        Rcurr_inv, tcurr, intr, cell_size, vxlDbg);    

    //  for ( int i = 0; i < 100; i++ )
    //    tsdf23test<<<grid, block>>>(depthScaled, volume, tranc_dist, Rcurr_inv, tcurr, intr, cell_size, *buffer);    

    //tsdf23normal_hack<<<grid, block>>>(depthScaled, volume, tranc_dist, Rcurr_inv, tcurr, intr, cell_size);

    cudaSafeCall ( cudaGetLastError () );
    cudaSafeCall (cudaDeviceSynchronize ());
}//integrateTsdfVolume_s2s

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
pcl::device::integrateTsdfVolume_v12 (const PtrStepSz<ushort>& depth, const Intr& intr, const float3& volume_size, 
    const Mat33& Rcurr_inv, const float3& tcurr, float tranc_dist, PtrStep<short2> volume, 
    PtrStep<short2> volume2nd, PtrStep<bool> flagVolume, PtrStep<char4> surfNormVolume, PtrStep<char4> vrayPrevVolume, DeviceArray2D<unsigned char> incidAngleMask, 
    const MapArr& nmap_curr_g, const MapArr &nmap_model_g,
    const MapArr &weight_map, //v11.4
    const PtrStepSz<ushort>& depth_model,
    DeviceArray2D<short>& diffDmap,
    DeviceArray2D<float>& depthScaled, int3 vxlDbg)
{
    depthScaled.create (depth.rows, depth.cols);

    dim3 block_scale (32, 8);
    dim3 grid_scale (divUp (depth.cols, block_scale.x), divUp (depth.rows, block_scale.y));

    //scales depth along ray and converts mm -> meters. 
    scaleDepth<<<grid_scale, block_scale>>>(depth, depthScaled, intr);
    cudaSafeCall ( cudaGetLastError () );

    //v12 ��һ��: �� diffDmap = depth(raw)-depth_model @2017-12-3 22:06:24
    //DeviceArray2D<short> diffDmap; //short, ���� ushort
    //��--�ֲ������ᵼ��: Error: unspecified launch failure       ..\..\..\gpu\containers\src\device_memory.cpp:276 //��: DeviceMemory2D::release() ����
    diffDmap.create(depth.rows, depth.cols);
    diffDmaps(depth, depth_model, diffDmap); //�� mm


    float3 cell_size;
    cell_size.x = volume_size.x / VOLUME_X;
    cell_size.y = volume_size.y / VOLUME_Y;
    cell_size.z = volume_size.z / VOLUME_Z;

    //dim3 block(Tsdf::CTA_SIZE_X, Tsdf::CTA_SIZE_Y);
    dim3 block (16, 16);
    dim3 grid (divUp (VOLUME_X, block.x), divUp (VOLUME_Y, block.y));

    printf("vxlDbg@integrateTsdfVolume_v12: [%d, %d, %d]\n", vxlDbg.x, vxlDbg.y, vxlDbg.z);

    //tsdf23<<<grid, block>>>(depthScaled, volume, tranc_dist, Rcurr_inv, tcurr, intr, cell_size);    
    //tsdf23_v11<<<grid, block>>>(depthScaled, volume, 
    //tsdf23_v11_remake<<<grid, block>>>(depthScaled, volume, 
    tsdf23_v12<<<grid, block>>>(depthScaled, volume, 
         volume2nd, flagVolume, surfNormVolume, vrayPrevVolume, incidAngleMask, 
         nmap_curr_g, nmap_model_g,
         weight_map,
         diffDmap,
         tranc_dist, Rcurr_inv, tcurr, intr, cell_size, vxlDbg);    
}//integrateTsdfVolume_v12


/////////////////////////////////////////////////////////////////////////////////////////////////////////////////
void 
pcl::device::integrateTsdfVolume_v13 (const PtrStepSz<ushort>& depth, const Intr& intr, const float3& volume_size, 
    const Mat33& Rcurr_inv, const float3& tcurr, float tranc_dist, PtrStep<short2> volume, 
    PtrStep<short2> volume2nd, PtrStep<bool> flagVolume, PtrStep<char4> surfNormVolume, PtrStep<char4> vrayPrevVolume, DeviceArray2D<unsigned char> incidAngleMask, 
    const MapArr& nmap_curr_g, const MapArr &nmap_model_g,
    const MapArr &weight_map, //v11.4
    const PtrStepSz<ushort>& depth_model,
    DeviceArray2D<short>& diffDmap,
    DeviceArray2D<float>& depthScaled, int3 vxlDbg)
{
    depthScaled.create (depth.rows, depth.cols);

    dim3 block_scale (32, 8);
    dim3 grid_scale (divUp (depth.cols, block_scale.x), divUp (depth.rows, block_scale.y));

    //scales depth along ray and converts mm -> meters. 
    scaleDepth<<<grid_scale, block_scale>>>(depth, depthScaled, intr);
    cudaSafeCall ( cudaGetLastError () );

    //v12 ��һ��: �� diffDmap = depth(raw)-depth_model @2017-12-3 22:06:24
    //DeviceArray2D<short> diffDmap; //short, ���� ushort
    //��--�ֲ������ᵼ��: Error: unspecified launch failure       ..\..\..\gpu\containers\src\device_memory.cpp:276 //��: DeviceMemory2D::release() ����
    diffDmap.create(depth.rows, depth.cols);
    diffDmaps(depth, depth_model, diffDmap); //�� mm

    float3 cell_size;
    cell_size.x = volume_size.x / VOLUME_X;
    cell_size.y = volume_size.y / VOLUME_Y;
    cell_size.z = volume_size.z / VOLUME_Z;

    //dim3 block(Tsdf::CTA_SIZE_X, Tsdf::CTA_SIZE_Y);
    dim3 block (16, 16);
    dim3 grid (divUp (VOLUME_X, block.x), divUp (VOLUME_Y, block.y));

    printf("vxlDbg@integrateTsdfVolume_v13: [%d, %d, %d]\n", vxlDbg.x, vxlDbg.y, vxlDbg.z);

    //tsdf23<<<grid, block>>>(depthScaled, volume, tranc_dist, Rcurr_inv, tcurr, intr, cell_size);    
    //tsdf23_v11<<<grid, block>>>(depthScaled, volume, 
    //tsdf23_v13<<<grid, block>>>(depthScaled, volume, 
    //tsdf23_v14<<<grid, block>>>(depthScaled, volume, 
    //tsdf23_v15<<<grid, block>>>(depthScaled, volume, 
    //tsdf23_v16<<<grid, block>>>(depthScaled, volume,  //���� tranc_dist_real �õ�
    tsdf23_v17<<<grid, block>>>(depthScaled, volume,  //���� tdist, ��������� tdist
        volume2nd, flagVolume, surfNormVolume, vrayPrevVolume, incidAngleMask, 
        nmap_curr_g, nmap_model_g,
        weight_map,
        diffDmap,
        tranc_dist, Rcurr_inv, tcurr, intr, cell_size, vxlDbg);    
}//integrateTsdfVolume_v13

/////////////////////////////////////////////////////////////////////////////////////////////////////////////////
void 
pcl::device::integrateTsdfVolume_v18 (const PtrStepSz<ushort>& depth, const Intr& intr, const float3& volume_size, 
    const Mat33& Rcurr_inv, const float3& tcurr, float tranc_dist, PtrStep<short2> volume, 
    PtrStep<short2> volume2nd, PtrStep<bool> flagVolume, PtrStep<char4> surfNormVolume, PtrStep<char4> vrayPrevVolume, DeviceArray2D<unsigned char> incidAngleMask, 
    const MapArr& nmap_curr_g, const MapArr &nmap_model_g,
    const MapArr &weight_map, //v11.4
    const PtrStepSz<ushort>& depth_model,
    DeviceArray2D<short>& diffDmap,
    DeviceArray2D<float>& depthScaled, int3 vxlDbg)
{
    depthScaled.create (depth.rows, depth.cols);

    dim3 block_scale (32, 8);
    dim3 grid_scale (divUp (depth.cols, block_scale.x), divUp (depth.rows, block_scale.y));

    //scales depth along ray and converts mm -> meters. 
    scaleDepth<<<grid_scale, block_scale>>>(depth, depthScaled, intr);
    cudaSafeCall ( cudaGetLastError () );

    //v12 ��һ��: �� diffDmap = depth(raw)-depth_model @2017-12-3 22:06:24
    //DeviceArray2D<short> diffDmap; //short, ���� ushort
    //��--�ֲ������ᵼ��: Error: unspecified launch failure       ..\..\..\gpu\containers\src\device_memory.cpp:276 //��: DeviceMemory2D::release() ����
    diffDmap.create(depth.rows, depth.cols);
    diffDmaps(depth, depth_model, diffDmap); //�� mm

    float3 cell_size;
    cell_size.x = volume_size.x / VOLUME_X;
    cell_size.y = volume_size.y / VOLUME_Y;
    cell_size.z = volume_size.z / VOLUME_Z;

    //dim3 block(Tsdf::CTA_SIZE_X, Tsdf::CTA_SIZE_Y);
    dim3 block (16, 16);
    dim3 grid (divUp (VOLUME_X, block.x), divUp (VOLUME_Y, block.y));

    printf("vxlDbg@integrateTsdfVolume_v18: [%d, %d, %d]\n", vxlDbg.x, vxlDbg.y, vxlDbg.z);

    //tsdf23<<<grid, block>>>(depthScaled, volume, tranc_dist, Rcurr_inv, tcurr, intr, cell_size);    
    //tsdf23_v11<<<grid, block>>>(depthScaled, volume, 
    //tsdf23_v13<<<grid, block>>>(depthScaled, volume, 
    //tsdf23_v14<<<grid, block>>>(depthScaled, volume, 
    //tsdf23_v15<<<grid, block>>>(depthScaled, volume, 
    //tsdf23_v16<<<grid, block>>>(depthScaled, volume,  //���� tranc_dist_real �õ�
    //tsdf23_v17<<<grid, block>>>(depthScaled, volume,  //���� tdist, ��������� tdist
    //test_kernel<<<grid, block>>>(vxlDbg); //v18.2
    tsdf23_v18<<<grid, block>>>(depthScaled, volume,  
        volume2nd, flagVolume, surfNormVolume, vrayPrevVolume, incidAngleMask, 
        nmap_curr_g, nmap_model_g,
        weight_map,
        depth_model, //v18.5, �����β�, ��Ҫ�ж� isnan
        diffDmap,
        tranc_dist, Rcurr_inv, tcurr, intr, cell_size, vxlDbg);    
}//integrateTsdfVolume_v18


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

    cudaSafeCall(cudaGetLastError());
    //cudaSafeCall(cudaDeviceSynchronize()); //tmp, ��ʱ��ͼ�������� @2017-12-6 22:03:13
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

//@param[in] vmapLocal, ��ʵֻҪ�� dmap ����, �ݲ���, ��֮ǰ calcWmapKernel ����һ��
__global__ void
edge2wmapKernel(int rows, int cols, const PtrStep<float> vmapLocal, const PtrStepSz<float> edgeDistMap, float fxy, PtrStepSz<float> wmap_out){
    int x = threadIdx.x + blockIdx.x * blockDim.x,
        y = threadIdx.y + blockIdx.y * blockDim.y;

    const float qnan = pcl::device::numeric_limits<float>::quiet_NaN();
    if(!(x < cols && y < rows))
        return;

    wmap_out.ptr(y)[x] = 0; //Ĭ�ϳ�ʼȨ��=0

    float3 vray; //local
    vray.x = vmapLocal.ptr(y)[x];
    if(isnan(vray.x))
        return;

    vray.y = vmapLocal.ptr(y + rows)[x];
    vray.z = vmapLocal.ptr(y + 2 * rows)[x]; //meters

    const float maxEdgeDist = 10; //in mm //30mm ̫��
    float edgeDistMm = edgeDistMap.ptr(y)[x] / fxy * vray.z * 1e3; //in mm

    float edgeDistFactor = min(1.f, edgeDistMm / maxEdgeDist);
    wmap_out.ptr(y)[x] = edgeDistFactor;
}//edge2wmapKernel

void calcWmap(const MapArr &vmapLocal, const MapArr &nmapLocal, const pcl::device::MaskMap &contMask, MapArr &wmap_out){
    int cols = vmapLocal.cols(),
        rows = vmapLocal.rows() / 3;

    wmap_out.create(rows, cols);

    dim3 block(32, 8);
    dim3 grid(divUp(cols, block.x), divUp(rows, block.y));

    calcWmapKernel<<<grid, block>>>(rows, cols, vmapLocal, nmapLocal, contMask, wmap_out);
    
    cudaSafeCall(cudaGetLastError());
    //cudaSafeCall(cudaDeviceSynchronize()); //tmp, ��ʱ��ͼ�������� @2017-12-6 22:03:13
}//calcWmap

void calcWmap(const MapArr &vmapLocal, const MapArr &nmapLocal, const DeviceArray2D<float> &edgeDistMap, const float fxy, MapArr &wmap_out){
    int cols = vmapLocal.cols(),
        rows = vmapLocal.rows() / 3;

    wmap_out.create(rows, cols);

    dim3 block(32, 8);
    dim3 grid(divUp(cols, block.x), divUp(rows, block.y));

    calcWmapKernel<<<grid, block>>>(rows, cols, vmapLocal, nmapLocal, edgeDistMap, fxy, wmap_out);
    
    cudaSafeCall(cudaGetLastError());
    //cudaSafeCall(cudaDeviceSynchronize()); //tmp, ��ʱ��ͼ�������� @2017-12-6 22:03:13
}//calcWmap

void edge2wmap(const MapArr &vmapLocal, const DeviceArray2D<float> &edgeDistMap, const float fxy, MapArr &wmap_out){
    int cols = vmapLocal.cols(),
        rows = vmapLocal.rows() / 3;

    wmap_out.create(rows, cols);

    dim3 block(32, 8);
    dim3 grid(divUp(cols, block.x), divUp(rows, block.y));

    edge2wmapKernel<<<grid, block>>>(rows, cols, vmapLocal, edgeDistMap, fxy, wmap_out);

    cudaSafeCall(cudaGetLastError());

}//edge2wmap

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
    //cudaSafeCall(cudaDeviceSynchronize()); //tmp, ��ʱ��ͼ�������� @2017-12-6 22:03:13
}//transformVmap

}//namespace zc