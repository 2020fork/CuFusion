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

/*__global__ */__device__
    const float COS30 = 0.8660254f
    ,COS45 = 0.7071f
    ,COS60 = 0.5f
    ,COS75 = 0.258819f
    ,COS80 = 0.173649f
    ,COS120 = -0.5f
    ,COS150 = -0.8660254f
    ;

namespace pcl
{
  namespace device
  {
    __device__ __forceinline__ float
    getMinTime (const float3& volume_max, const float3& origin, const float3& dir)
    {
      float txmin = ( (dir.x > 0 ? 0.f : volume_max.x) - origin.x) / dir.x;
      float tymin = ( (dir.y > 0 ? 0.f : volume_max.y) - origin.y) / dir.y;
      float tzmin = ( (dir.z > 0 ? 0.f : volume_max.z) - origin.z) / dir.z;

      return fmax ( fmax (txmin, tymin), tzmin);
    }

    __device__ __forceinline__ float
    getMaxTime (const float3& volume_max, const float3& origin, const float3& dir)
    {
      float txmax = ( (dir.x > 0 ? volume_max.x : 0.f) - origin.x) / dir.x;
      float tymax = ( (dir.y > 0 ? volume_max.y : 0.f) - origin.y) / dir.y;
      float tzmax = ( (dir.z > 0 ? volume_max.z : 0.f) - origin.z) / dir.z;

      return fmin (fmin (txmax, tymax), tzmax);
    }

    struct RayCaster
    {
      enum { CTA_SIZE_X = 32, CTA_SIZE_Y = 8 };

      Mat33 Rcurr;
      float3 tcurr;

      float time_step;
      float3 volume_size;

      float3 cell_size;
      int cols, rows;

      PtrStep<short2> volume;

      Intr intr;

      mutable PtrStep<float> nmap;
      mutable PtrStep<float> vmap;

      mutable PtrStep<float> edge_wmap;
      //mutable PtrStep<unsigned short> rcFlag; //zc:
      mutable PtrStep<short> rcFlag; //zc: ushort>short, ��������ֵ, ��ֵΪ+>-�����, ��ֵΪ ->+�����  @2018-10-9 10:50:58
      int3 vxlDbg;
      float3 R_inv_row3;
      float tranc_dist;

      __device__ __forceinline__ float3
      get_ray_next (int x, int y) const
      {
        float3 ray_next;
        ray_next.x = (x - intr.cx) / intr.fx;
        ray_next.y = (y - intr.cy) / intr.fy;
        ray_next.z = 1;
        return ray_next;
      }

      __device__ __forceinline__ bool
      checkInds (const int3& g) const
      {
        return (g.x >= 0 && g.y >= 0 && g.z >= 0 && g.x < VOLUME_X && g.y < VOLUME_Y && g.z < VOLUME_Z);
      }

      __device__ __forceinline__ float
      readTsdf (int x, int y, int z, pcl::gpu::tsdf_buffer buffer) const
      {
        const short2* tmp_pos = &(volume.ptr (buffer.voxels_size.y * z + y)[x]);
        short2* pos = const_cast<short2*> (tmp_pos);
        shift_tsdf_pointer(&pos, buffer);
        return unpack_tsdf (*pos);
      }

      //zc: ����, Ҳ��ȡ w, ��������     @2018-9-30 13:29:59
      __device__ __forceinline__ float
      readTsdf (int x, int y, int z, pcl::gpu::tsdf_buffer buffer, int& weight) const
      {
        const short2* tmp_pos = &(volume.ptr (buffer.voxels_size.y * z + y)[x]);
        short2* pos = const_cast<short2*> (tmp_pos);
        shift_tsdf_pointer(&pos, buffer);
        //return unpack_tsdf (*pos);
        float tsdf;
        unpack_tsdf(*pos, tsdf, weight);
        return tsdf;
      }

      __device__ __forceinline__ int3
      getVoxel (float3 point) const
      {
        int vx = __float2int_rd (point.x / cell_size.x);        // round to negative infinity
        int vy = __float2int_rd (point.y / cell_size.y);
        int vz = __float2int_rd (point.z / cell_size.z);

        return make_int3 (vx, vy, vz);
      }

      __device__ __forceinline__ float
      interpolateTrilineary (const float3& origin, const float3& dir, float time, pcl::gpu::tsdf_buffer buffer) const
      {
        return interpolateTrilineary (origin + dir * time, buffer);
      }

      __device__ __forceinline__ float
      interpolateTrilineary (const float3& point, pcl::gpu::tsdf_buffer buffer) const
      {
        int3 g = getVoxel (point);

        if (g.x <= 0 || g.x >= buffer.voxels_size.x - 1)
          return numeric_limits<float>::quiet_NaN ();

        if (g.y <= 0 || g.y >= buffer.voxels_size.y - 1)
          return numeric_limits<float>::quiet_NaN ();

        if (g.z <= 0 || g.z >= buffer.voxels_size.z - 1)
          return numeric_limits<float>::quiet_NaN ();

/*      //OLD CODE
        float vx = (g.x + 0.5f) * cell_size.x;
        float vy = (g.y + 0.5f) * cell_size.y;
        float vz = (g.z + 0.5f) * cell_size.z;

        g.x = (point.x < vx) ? (g.x - 1) : g.x;
        g.y = (point.y < vy) ? (g.y - 1) : g.y;
        g.z = (point.z < vz) ? (g.z - 1) : g.z;

        float a = (point.x - (g.x + 0.5f) * cell_size.x) / cell_size.x;
        float b = (point.y - (g.y + 0.5f) * cell_size.y) / cell_size.y;
        float c = (point.z - (g.z + 0.5f) * cell_size.z) / cell_size.z;

        float res = readTsdf (g.x + 0, g.y + 0, g.z + 0, buffer) * (1 - a) * (1 - b) * (1 - c) +
                    readTsdf (g.x + 0, g.y + 0, g.z + 1, buffer) * (1 - a) * (1 - b) * c +
                    readTsdf (g.x + 0, g.y + 1, g.z + 0, buffer) * (1 - a) * b * (1 - c) +
                    readTsdf (g.x + 0, g.y + 1, g.z + 1, buffer) * (1 - a) * b * c +
                    readTsdf (g.x + 1, g.y + 0, g.z + 0, buffer) * a * (1 - b) * (1 - c) +
                    readTsdf (g.x + 1, g.y + 0, g.z + 1, buffer) * a * (1 - b) * c +
                    readTsdf (g.x + 1, g.y + 1, g.z + 0, buffer) * a * b * (1 - c) +
                    readTsdf (g.x + 1, g.y + 1, g.z + 1, buffer) * a * b * c;
*/
        //NEW CODE
		float a = point.x/ cell_size.x - (g.x + 0.5f); if (a<0) { g.x--; a+=1.0f; };
        float b = point.y/ cell_size.y - (g.y + 0.5f); if (b<0) { g.y--; b+=1.0f; };
        float c = point.z/ cell_size.z - (g.z + 0.5f); if (c<0) { g.z--; c+=1.0f; };

        float res = (1 - a) * (
						(1 - b) * (
							readTsdf (g.x + 0, g.y + 0, g.z + 0, buffer) * (1 - c) +
							readTsdf (g.x + 0, g.y + 0, g.z + 1, buffer) *      c 
							)
						+ b * (
							readTsdf (g.x + 0, g.y + 1, g.z + 0, buffer) * (1 - c) +
							readTsdf (g.x + 0, g.y + 1, g.z + 1, buffer) *      c  
							)
						)
					+ a * (
						(1 - b) * (
							readTsdf (g.x + 1, g.y + 0, g.z + 0, buffer) * (1 - c) +
							readTsdf (g.x + 1, g.y + 0, g.z + 1, buffer) *      c 
							)
						+ b * (
							readTsdf (g.x + 1, g.y + 1, g.z + 0, buffer) * (1 - c) +
							readTsdf (g.x + 1, g.y + 1, g.z + 1, buffer) *      c 
							)
						)
					;
        return res;
      }

#if 1
      __device__ __forceinline__ void
      operator () (pcl::gpu::tsdf_buffer buffer) const
      {
        int x = threadIdx.x + blockIdx.x * CTA_SIZE_X;
        int y = threadIdx.y + blockIdx.y * CTA_SIZE_Y;

        if (x >= cols || y >= rows)
          return;

        vmap.ptr (y)[x] = numeric_limits<float>::quiet_NaN ();
        nmap.ptr (y)[x] = numeric_limits<float>::quiet_NaN ();

        float3 ray_start = tcurr;
        float3 ray_next = Rcurr * get_ray_next (x, y) + tcurr;

        float3 ray_dir = normalized (ray_next - ray_start);

        //ensure that it isn't a degenerate case
        ray_dir.x = (ray_dir.x == 0.f) ? 1e-15 : ray_dir.x;
        ray_dir.y = (ray_dir.y == 0.f) ? 1e-15 : ray_dir.y;
        ray_dir.z = (ray_dir.z == 0.f) ? 1e-15 : ray_dir.z;

        // computer time when entry and exit volume
        float time_start_volume = getMinTime (volume_size, ray_start, ray_dir);
        float time_exit_volume = getMaxTime (volume_size, ray_start, ray_dir);

        const float min_dist = 0.f;         //in meters
        time_start_volume = fmax (time_start_volume, min_dist);
        if (time_start_volume >= time_exit_volume)
          return;

        float time_curr = time_start_volume;
        int3 g = getVoxel (ray_start + ray_dir * time_curr);
        g.x = max (0, min (g.x, buffer.voxels_size.x - 1));
        g.y = max (0, min (g.y, buffer.voxels_size.y - 1));
        g.z = max (0, min (g.z, buffer.voxels_size.z - 1));

        float tsdf = readTsdf (g.x, g.y, g.z, buffer);

        //infinite loop guard
        const float max_time = 3 * (volume_size.x + volume_size.y + volume_size.z);

        for (; time_curr < max_time; time_curr += time_step)
        {
          float tsdf_prev = tsdf;

          int3 g = getVoxel (  ray_start + ray_dir * (time_curr + time_step)  );
          if (!checkInds (g))
            break;

          tsdf = readTsdf (g.x, g.y, g.z, buffer);

          if (tsdf_prev < 0.f && tsdf >= 0.f)
            break;

          if (tsdf_prev >= 0.f && tsdf < 0.f)           //zero crossing
          {
            float Ftdt = interpolateTrilineary (ray_start, ray_dir, time_curr + time_step, buffer);
            if (isnan (Ftdt))
              break;

            float Ft = interpolateTrilineary (ray_start, ray_dir, time_curr, buffer);
            if (isnan (Ft))
              break;

            //float Ts = time_curr - time_step * Ft/(Ftdt - Ft);
            float Ts = time_curr - time_step * Ft / (Ftdt - Ft);

            float3 vetex_found = ray_start + ray_dir * Ts;

            vmap.ptr (y       )[x] = vetex_found.x;
            vmap.ptr (y + rows)[x] = vetex_found.y;
            vmap.ptr (y + 2 * rows)[x] = vetex_found.z;

            int3 g = getVoxel ( ray_start + ray_dir * time_curr );
            if (g.x > 1 && g.y > 1 && g.z > 1 && g.x < buffer.voxels_size.x - 2 && g.y < buffer.voxels_size.y - 2 && g.z < buffer.voxels_size.z - 2)
            {
              float3 t;
              float3 n;

              t = vetex_found;
              t.x += cell_size.x;
              float Fx1 = interpolateTrilineary (t, buffer);

              t = vetex_found;
              t.x -= cell_size.x;
              float Fx2 = interpolateTrilineary (t, buffer);

              n.x = (Fx1 - Fx2);

              t = vetex_found;
              t.y += cell_size.y;
              float Fy1 = interpolateTrilineary (t, buffer);

              t = vetex_found;
              t.y -= cell_size.y;
              float Fy2 = interpolateTrilineary (t, buffer);

              n.y = (Fy1 - Fy2);

              t = vetex_found;
              t.z += cell_size.z;
              float Fz1 = interpolateTrilineary (t, buffer);

              t = vetex_found;
              t.z -= cell_size.z;
              float Fz2 = interpolateTrilineary (t, buffer);

              n.z = (Fz1 - Fz2);

              n = normalized (n);

              nmap.ptr (y       )[x] = n.x;
              nmap.ptr (y + rows)[x] = n.y;
              nmap.ptr (y + 2 * rows)[x] = n.z;
            }
            break;
          }

        }          /* for(;;)  */
      }//operator()(buffer).orig, //NO rcFlag

#elif 1 //rcFlag ���ڰ汾, ����, long2-jibei-c Ŀǰ ~f135 �ж�, ԭ����  @2018-12-4 17:39:11
      __device__ __forceinline__ void
      operator () (pcl::gpu::tsdf_buffer buffer) const
      {
        int x = threadIdx.x + blockIdx.x * CTA_SIZE_X;
        int y = threadIdx.y + blockIdx.y * CTA_SIZE_Y;

        if (x >= cols || y >= rows)
          return;

//         bool doDbgPrint = false;
//         if(x > 0 && y > 0 /*&& z > 0*/ //����Ĭ�� 000, ����Чֵ, �������Ӵ˼��
//             && 320 == x && 140 == y /*&& vxlDbg.z == z*/)
//         {
//             doDbgPrint = true;
//             printf("raycast@doDbgPrint: %d\n", doDbgPrint);
//         }
        if(rcFlag.data != nullptr)
            rcFlag.ptr(y)[x] = 0; //ע��ÿ�ζ�Ҫ����������0

        vmap.ptr (y)[x] = numeric_limits<float>::quiet_NaN ();
        nmap.ptr (y)[x] = numeric_limits<float>::quiet_NaN ();

        float3 ray_start = tcurr;
        float3 ray_next = Rcurr * get_ray_next (x, y) + tcurr;

        float3 ray_dir = normalized (ray_next - ray_start);

        //ensure that it isn't a degenerate case
        ray_dir.x = (ray_dir.x == 0.f) ? 1e-15 : ray_dir.x;
        ray_dir.y = (ray_dir.y == 0.f) ? 1e-15 : ray_dir.y;
        ray_dir.z = (ray_dir.z == 0.f) ? 1e-15 : ray_dir.z;

        // computer time when entry and exit volume
        float time_start_volume = getMinTime (volume_size, ray_start, ray_dir);
        float time_exit_volume = getMaxTime (volume_size, ray_start, ray_dir);

        const float min_dist = 0.f;         //in meters
        time_start_volume = fmax (time_start_volume, min_dist);
        if (time_start_volume >= time_exit_volume)
          return;

        float time_curr = time_start_volume;
        int3 g = getVoxel (ray_start + ray_dir * time_curr);
        g.x = max (0, min (g.x, buffer.voxels_size.x - 1));
        g.y = max (0, min (g.y, buffer.voxels_size.y - 1));
        g.z = max (0, min (g.z, buffer.voxels_size.z - 1));

        bool doDbgPrint = false;
        if(g == vxlDbg) //һ������������ vox, �ͳ������, ֱ�� break  //����ѭ������ʵ��Զ���� true  @2018-10-8 11:20:14
            doDbgPrint = true;

        //float tsdf = readTsdf (g.x, g.y, g.z, buffer);
        int weight;
        float tsdf = readTsdf (g.x, g.y, g.z, buffer, weight); //zc: ͬʱ��ȡ weight
        weight = (weight >> VOL1_FLAG_BIT_CNT);

        //infinite loop guard
        const float max_time = 3 * (volume_size.x + volume_size.y + volume_size.z);
//         if(doDbgPrint)
//             printf("px_xy: %d, %d; ggg_xyz: %d, %d, %d; tsdf-g: %f, max_time: %f; time_step: %f\n", x, y, g.x, g.y, g.z, tsdf, max_time, time_step);

        for (; time_curr < max_time; time_curr += time_step)
        {
          float tsdf_prev = tsdf;
          int weight_prev = weight;

          int3 g = getVoxel (  ray_start + ray_dir * (time_curr + time_step)  );
          if (!checkInds (g))
            break;

          int3 g_prev = getVoxel (  ray_start + ray_dir * time_curr  ); //dbg ��

          if(g == vxlDbg)
              doDbgPrint = true;

          //tsdf = readTsdf (g.x, g.y, g.z, buffer);
          //int weight; //���涨��
          tsdf = readTsdf (g.x, g.y, g.z, buffer, weight); //zc: ͬʱ��ȡ weight
          weight = (weight >> VOL1_FLAG_BIT_CNT);
          //if(doDbgPrint)
          //    printf("AFTER-checkInds, px_xy: %d, %d,; ggg_xyz: %d, %d, %d; tsdf-g: %f \n", x, y, g.x, g.y, g.z, tsdf);

          if (tsdf_prev < 0.f && tsdf >= 0.f)
          //  break;
          //if (tsdf_prev < 0.f && tsdf > 0.f) //">=" -> ">"; ��̫Ӱ�� icp ʱ������
          {
              if(rcFlag.data != nullptr && tsdf > 0 && weight > WEIGHT_CONFID_TH) //�ȶԵ��� t-curr, +��ֵ����
                  rcFlag.ptr(y)[x] = 127; //zc: ��� p-c+ ����Ϊ 127(0x7f), �����ж��������� @2018-9-30 09:50:24
              if(rcFlag.data != nullptr && tsdf == 0)
                  if(rcFlag.ptr(y)[x] == 0)
                      rcFlag.ptr(y)[x] = 129; //->0, �������
                  else if(rcFlag.ptr(y)[x] == 128)
                      rcFlag.ptr(y)[x] = 130; //0>->0, �������

              if(doDbgPrint){
                  printf("tp: %f, wp: %d; tc: %f, wc: %d; rcFlag: %d; g_prev_xyz: (%d, %d, %d), ggg_xyz: (%d, %d, %d), px_xy: (%d, %d)\n", tsdf_prev, weight_prev, tsdf, weight, rcFlag.ptr(y)[x], g_prev.x, g_prev.y, g_prev.z, g.x, g.y, g.z, x, y);
              }

              break;

          }
//           if(doDbgPrint)
//               printf("AFTER::P-C+; BEFORE::P+C-\n");

          if (tsdf_prev >= 0.f && tsdf < 0.f)           //zero crossing
          //if (tsdf_prev >= 0.f && weight_prev > 0 && tsdf < 0.f)           //���� wp>0 �޶�, ȷ�� tp=0 ������, ��Ȼû��Ӱ�� icp ʱ��, ������ ��ΪɶӰ��? ����δ���   @2018-10-1 22:41:10
          //if (tsdf_prev > 0.f && tsdf < 0.f) //zc: ȥ���Ⱥ�, ǿ�� P+, �ų���nan�������й����; �����ǡ��ǳ�Ӱ�� icp ʱ������ @2018-9-29 17:31:54
                                                            //�ֲ�Ӱ��icpʱ����, ����֮ǰ cpu/gpu ��ռ��? @2018-10-2 13:26:13
          {
//               if(rcFlag.data != nullptr && tsdf_prev == 0)
//                   printf("tsdf_prev == 0 @ray_caster.cu: px_xy: %d, %d,; ggg_xyz: %d, %d, %d; tp,wp: %f, %d, tc,wc: %f, %d;\n", x, y, g.x, g.y, g.z, tsdf_prev, weight_prev, tsdf, weight);

            //if(rcFlag.data != nullptr && tsdf_prev > 0)
            //    rcFlag.ptr(y)[x] = 255; //zc: �����ȷ���������Ϊ 255(0xff), �����ж�ͬ��۲� @2018-9-30 09:53:05

            if(rcFlag.data != nullptr){
#if 0   //�߼�����, Ҫ��
                if(tsdf_prev > 0) //P+ ���������ж�
                    rcFlag.ptr(y)[x] = 255; //zc: �����ȷ���������Ϊ 255(0xff), �����ж�ͬ��۲� @2018-9-30 09:53:05
                //else if(tsdf_prev == 0){
                else if(tsdf_prev == 0 && weight_prev == 0){ //�򾫶����� t=0 ���ܴ���, ���Ըĳ�ͬʱ�ж� wp, tp @2018-10-8 17:33:00
                    rcFlag.ptr(y)[x] = 128; //0>-, �������
                }
#elif 1 //�ĺ�
                if(tsdf_prev == 0 && weight_prev == 0){ //ͬʱ wp, tp=0, ���㡰����zcross��
                    rcFlag.ptr(y)[x] = 128; //0>-, �������
                }
                else{ //ֻҪ wp, tp ��ȫ��, �������� zcross
                    rcFlag.ptr(y)[x] = 255; //zc: �����ȷ���������Ϊ 255(0xff), �����ж�ͬ��۲� @2018-9-30 09:53:05
                }
#endif
            }

            if(doDbgPrint)
                printf("P+C-zero_crossing; px_xy: %d, %d,; ggg_xyz: %d, %d, %d; tsdf-p-c: %f, %f\n", x, y, g.x, g.y, g.z, tsdf_prev, tsdf);

//             if(doDbgPrint)
//                 printf("tp: %f, wp: %d; tc: %f, wc: %d; rcFlag: %d; g_prev_xyz: (%d, %d, %d), ggg_xyz: (%d, %d, %d), px_xy: (%d, %d)\n", tsdf_prev, weight_prev, tsdf, weight, rcFlag.ptr(y)[x], g_prev.x, g_prev.y, g_prev.z, g.x, g.y, g.z, x, y);

            float Ftdt = interpolateTrilineary (ray_start, ray_dir, time_curr + time_step, buffer);
            if (isnan (Ftdt))
              break;

            float Ft = interpolateTrilineary (ray_start, ray_dir, time_curr, buffer);
            if (isnan (Ft))
              break;

            //float Ts = time_curr - time_step * Ft/(Ftdt - Ft);
            float Ts = time_curr - time_step * Ft / (Ftdt - Ft);

            float3 vetex_found = ray_start + ray_dir * Ts;

            vmap.ptr (y       )[x] = vetex_found.x;
            vmap.ptr (y + rows)[x] = vetex_found.y;
            vmap.ptr (y + 2 * rows)[x] = vetex_found.z;

            int3 g = getVoxel ( ray_start + ray_dir * time_curr );
            if (g.x > 1 && g.y > 1 && g.z > 1 && g.x < buffer.voxels_size.x - 2 && g.y < buffer.voxels_size.y - 2 && g.z < buffer.voxels_size.z - 2)
            {
              float3 t;
              float3 n;

              t = vetex_found;
              t.x += cell_size.x;
              float Fx1 = interpolateTrilineary (t, buffer);

              t = vetex_found;
              t.x -= cell_size.x;
              float Fx2 = interpolateTrilineary (t, buffer);

              n.x = (Fx1 - Fx2);

              t = vetex_found;
              t.y += cell_size.y;
              float Fy1 = interpolateTrilineary (t, buffer);

              t = vetex_found;
              t.y -= cell_size.y;
              float Fy2 = interpolateTrilineary (t, buffer);

              n.y = (Fy1 - Fy2);

              t = vetex_found;
              t.z += cell_size.z;
              float Fz1 = interpolateTrilineary (t, buffer);

              t = vetex_found;
              t.z -= cell_size.z;
              float Fz2 = interpolateTrilineary (t, buffer);

              n.z = (Fz1 - Fz2);

              n = normalized (n);

              nmap.ptr (y       )[x] = n.x;
              nmap.ptr (y + rows)[x] = n.y;
              nmap.ptr (y + 2 * rows)[x] = n.z;
            }
            //break;
            //zc: ��: ���� tp>0, �� break; �� tp=0ʱ, ������, �����ߵ� ->+ ������
            if(tsdf_prev > 0)
                break;
          }

        }          /* for(;;)  */
      }//operator()(buffer), & rcFlag �汾
#endif

      //zc: ����, rcFlag������ֵ(depth mm), ���� FLAG 
      __device__ __forceinline__ void
      operator () (pcl::gpu::tsdf_buffer buffer, int dummy) const
      {
        int x = threadIdx.x + blockIdx.x * CTA_SIZE_X;
        int y = threadIdx.y + blockIdx.y * CTA_SIZE_Y;

        if (x >= cols || y >= rows)
          return;

//         bool doDbgPrint = false;
//         if(x > 0 && y > 0 /*&& z > 0*/ //����Ĭ�� 000, ����Чֵ, �������Ӵ˼��
//             && 320 == x && 140 == y /*&& vxlDbg.z == z*/)
//         {
//             doDbgPrint = true;
//             printf("raycast@doDbgPrint: %d\n", doDbgPrint);
//         }
        if(rcFlag.data != nullptr)
            rcFlag.ptr(y)[x] = 0; //ע��ÿ�ζ�Ҫ����������0

        vmap.ptr (y)[x] = numeric_limits<float>::quiet_NaN ();
        nmap.ptr (y)[x] = numeric_limits<float>::quiet_NaN ();

        float3 ray_start = tcurr;
        float3 ray_next = Rcurr * get_ray_next (x, y) + tcurr;

        float3 ray_dir = normalized (ray_next - ray_start);

        //ensure that it isn't a degenerate case
        ray_dir.x = (ray_dir.x == 0.f) ? 1e-15 : ray_dir.x;
        ray_dir.y = (ray_dir.y == 0.f) ? 1e-15 : ray_dir.y;
        ray_dir.z = (ray_dir.z == 0.f) ? 1e-15 : ray_dir.z;

        // computer time when entry and exit volume
        float time_start_volume = getMinTime (volume_size, ray_start, ray_dir);
        float time_exit_volume = getMaxTime (volume_size, ray_start, ray_dir);

        const float min_dist = 0.f;         //in meters
        time_start_volume = fmax (time_start_volume, min_dist);
        if (time_start_volume >= time_exit_volume)
          return;

        float time_curr = time_start_volume;
        int3 g = getVoxel (ray_start + ray_dir * time_curr);
        g.x = max (0, min (g.x, buffer.voxels_size.x - 1));
        g.y = max (0, min (g.y, buffer.voxels_size.y - 1));
        g.z = max (0, min (g.z, buffer.voxels_size.z - 1));

        bool doDbgPrint = false;
        if(g == vxlDbg) //һ������������ vox, �ͳ������, ֱ�� break  //����ѭ������ʵ��Զ���� true  @2018-10-8 11:20:14
            doDbgPrint = true;
        bool doDbgPrint2 = false; //���� ray_dir ������ԣ��� doDbgPrint ��������޹� @2018-10-10 10:23:31

        //float tsdf = readTsdf (g.x, g.y, g.z, buffer);
        int weight;
        float tsdf = readTsdf (g.x, g.y, g.z, buffer, weight); //zc: ͬʱ��ȡ weight
        weight = (weight >> VOL1_FLAG_BIT_CNT);

        //infinite loop guard
        const float max_time = 3 * (volume_size.x + volume_size.y + volume_size.z);

        float time_step_local = time_step; //��Ϊ�ֲ�����, ѭ����, ���ߵ���ֵ, ������(continue), ����ϣ�����󲽳�, �����ߵ����������, ���� "->+"������	@2018-10-9 23:55:32
//         if(doDbgPrint)
//             printf("px_xy: %d, %d; ggg_xyz: %d, %d, %d; tsdf-g: %f, max_time: %f; time_step_local: %f\n", x, y, g.x, g.y, g.z, tsdf, max_time, time_step_local);

        for (; time_curr < max_time; time_curr += time_step_local)
        {
          float tsdf_prev = tsdf;
          int weight_prev = weight;

          int3 g = getVoxel (  ray_start + ray_dir * (time_curr + time_step_local)  );
          if (!checkInds (g))
            break;

          int3 g_prev = getVoxel (  ray_start + ray_dir * time_curr  ); //dbg ��

          if(g == vxlDbg)
              doDbgPrint = true;

          if(doDbgPrint2)
              printf("FOR_HEAD:=px_xy: (%d, %d), ray_start: (%f, %f, %f), ray_dir: (%f, %f, %f), time_curr: %f; g_prev_xyz: (%d, %d, %d), ggg_xyz: (%d, %d, %d); vxlDbg: (%d, %d, %d)\n", 
              x, y, ray_start.x, ray_start.y, ray_start.z, ray_dir.x, ray_dir.y, ray_dir.z, time_curr, g_prev.x, g_prev.y, g_prev.z, g.x, g.y, g.z, vxlDbg.x, vxlDbg.y, vxlDbg.z);
          //tsdf = readTsdf (g.x, g.y, g.z, buffer);
          //int weight; //���涨��
          tsdf = readTsdf (g.x, g.y, g.z, buffer, weight); //zc: ͬʱ��ȡ weight
          weight = (weight >> VOL1_FLAG_BIT_CNT);
//           if(doDbgPrint)
//               printf("AFTER-checkInds, px_xy: %d, %d,; ggg_xyz: %d, %d, %d; tsdf-g: %f \n", x, y, g.x, g.y, g.z, tsdf);

          if (tsdf_prev < 0.f && tsdf >= 0.f)
          //  break;
          //if (tsdf_prev < 0.f && tsdf > 0.f) //">=" -> ">"; ��̫Ӱ�� icp ʱ������
          {
#if 0
              if(rcFlag.data != nullptr && tsdf > 0 && weight > WEIGHT_CONFID_TH) //�ȶԵ��� t-curr, +��ֵ����
                  rcFlag.ptr(y)[x] = 127; //zc: ��� p-c+ ����Ϊ 127(0x7f), �����ж��������� @2018-9-30 09:50:24
              if(rcFlag.data != nullptr && tsdf == 0)
                  if(rcFlag.ptr(y)[x] == 0)
                      rcFlag.ptr(y)[x] = 129; //->0, �������
                  else if(rcFlag.ptr(y)[x] == 128)
                      rcFlag.ptr(y)[x] = 130; //0>->0, �������

#elif 1 //v21.3:
              //if(rcFlag.data != nullptr){
              //if(rcFlag.data != nullptr && weight > 0){
              if(rcFlag.data != nullptr && weight > WEIGHT_CONFID_TH){ //��: �ֵ����, w>th ֮�����
                  float Ftdt = interpolateTrilineary (ray_start, ray_dir, time_curr + time_step_local, buffer);
                  if (isnan (Ftdt))
                      break;

                  float Ft = interpolateTrilineary (ray_start, ray_dir, time_curr, buffer);
                  if (isnan (Ft))
                      break;

                  //float Ts = time_curr - time_step_local * Ft/(Ftdt - Ft);
                  float Ts = time_curr - time_step_local * Ft / (Ftdt - Ft);

                  float3 vetex_found = ray_start + ray_dir * Ts;

                  float v_z = dot(R_inv_row3, vetex_found - tcurr); //in meters
                  rcFlag.ptr(y)[x] = static_cast<unsigned short>(v_z * 1000) * -1; //mm, ��ֵ�洢, ���� ->+
              }
#endif

              break;

          }
//           if(doDbgPrint)
//               printf("AFTER::P-C+; BEFORE::P+C-\n");

          if (tsdf_prev >= 0.f && tsdf < 0.f)           //zero crossing
          //if (tsdf_prev >= 0.f && weight_prev > 0 && tsdf < 0.f)           //���� wp>0 �޶�, ȷ�� tp=0 ������, ��Ȼû��Ӱ�� icp ʱ��, ������ ��ΪɶӰ��? ����δ���   @2018-10-1 22:41:10
          //if (tsdf_prev > 0.f && tsdf < 0.f) //zc: ȥ���Ⱥ�, ǿ�� P+, �ų���nan�������й����; �����ǡ��ǳ�Ӱ�� icp ʱ������ @2018-9-29 17:31:54
                                                            //�ֲ�Ӱ��icpʱ����, ����֮ǰ cpu/gpu ��ռ��? @2018-10-2 13:26:13
          {
            //if(rcFlag.data != nullptr && tsdf_prev > 0)
            //    rcFlag.ptr(y)[x] = 255; //zc: �����ȷ���������Ϊ 255(0xff), �����ж�ͬ��۲� @2018-9-30 09:53:05

            float Ftdt = interpolateTrilineary (ray_start, ray_dir, time_curr + time_step_local, buffer);
            if (isnan (Ftdt))
              break;

            float Ft = interpolateTrilineary (ray_start, ray_dir, time_curr, buffer);
            if (isnan (Ft))
              break;

            //float Ts = time_curr - time_step_local * Ft/(Ftdt - Ft);
            float Ts = time_curr - time_step_local * Ft / (Ftdt - Ft);

            float3 vetex_found = ray_start + ray_dir * Ts;

            //zc: @2018-10-9 15:29:32
            if(rcFlag.data != nullptr){
#if 0   //�߼�����, Ҫ��
                if(tsdf_prev > 0) //P+ ���������ж�
                    rcFlag.ptr(y)[x] = 255; //zc: �����ȷ���������Ϊ 255(0xff), �����ж�ͬ��۲� @2018-9-30 09:53:05
                //else if(tsdf_prev == 0){
                else if(tsdf_prev == 0 && weight_prev == 0){ //�򾫶����� t=0 ���ܴ���, ���Ըĳ�ͬʱ�ж� wp, tp @2018-10-8 17:33:00
                    rcFlag.ptr(y)[x] = 128; //0>-, �������
                }
#elif 0 //�ĺ�
                if(tsdf_prev == 0 && weight_prev == 0){ //ͬʱ wp, tp=0, ���㡰����zcross��
                    rcFlag.ptr(y)[x] = 128; //0>-, �������
                }
                else{ //ֻҪ wp, tp ��ȫ��, �������� zcross
                    rcFlag.ptr(y)[x] = 255; //zc: �����ȷ���������Ϊ 255(0xff), �����ж�ͬ��۲� @2018-9-30 09:53:05
                }
#elif 1 //v21.3
                float v_z = dot(R_inv_row3, vetex_found - tcurr); //in meters
                rcFlag.ptr(y)[x] = static_cast<unsigned short>(v_z * 1000); //mm
#endif

            }

            vmap.ptr (y       )[x] = vetex_found.x;
            vmap.ptr (y + rows)[x] = vetex_found.y;
            vmap.ptr (y + 2 * rows)[x] = vetex_found.z;

            const float qnan = numeric_limits<float>::quiet_NaN();
            float3 n_f3 = make_float3(qnan, qnan, qnan); //�������ݶ�������

            int3 g = getVoxel ( ray_start + ray_dir * time_curr );
            if (g.x > 1 && g.y > 1 && g.z > 1 && g.x < buffer.voxels_size.x - 2 && g.y < buffer.voxels_size.y - 2 && g.z < buffer.voxels_size.z - 2)
            {
              float3 t;
              float3 n;

              t = vetex_found;
              t.x += cell_size.x;
              float Fx1 = interpolateTrilineary (t, buffer);

              t = vetex_found;
              t.x -= cell_size.x;
              float Fx2 = interpolateTrilineary (t, buffer);

              n.x = (Fx1 - Fx2);

              t = vetex_found;
              t.y += cell_size.y;
              float Fy1 = interpolateTrilineary (t, buffer);

              t = vetex_found;
              t.y -= cell_size.y;
              float Fy2 = interpolateTrilineary (t, buffer);

              n.y = (Fy1 - Fy2);

              t = vetex_found;
              t.z += cell_size.z;
              float Fz1 = interpolateTrilineary (t, buffer);

              t = vetex_found;
              t.z -= cell_size.z;
              float Fz2 = interpolateTrilineary (t, buffer);

              n.z = (Fz1 - Fz2);

              n = normalized (n);

              nmap.ptr (y       )[x] = n.x;
              nmap.ptr (y + rows)[x] = n.y;
              nmap.ptr (y + 2 * rows)[x] = n.z;

              n_f3 = n;
            }
            //break;
            //zc: ��: ���� tp>0, �� break; �� tp=0ʱ, ������, �����ߵ� ->+ ������
//             if(tsdf_prev > 0)
//                 break;
            //zc: v21.3 ��:   @2018-10-9 15:07:17
            //1, +(0)>- ���� break, �� continue; ���� ->+(0) ʱ�� break; ��Ϊ��ֵ�ض�, ���õ���̫��ʱ
            //2, ->+(0) ������ +(0)>-, ��"��"��������"��"
            //3, ����������ǽϴ�, ����Ϊƽ���ڱ���, Ϊ��������"��"����, ��rcast ����Ϊ�ط��߸�����
            //3.2, ���ٸ�Ϊ�� ����+������ ��ƽ���߷���, ������������  //�ݲ���һ��, ��Ϊ���� & �����߻������, �����߲���С
            //4, ���� {{OVER}}
            time_step_local = tranc_dist * 0.8; //+(0)>- ֮��, �� ���󲽳�; 
            //�� ray_dir ����������, ���ط��߸����������ʲ���

            //��-v21.3.4: ��Եֱ�Ӳ�����, ����̫��Ե�����޷���� ->+, ��������� @2018-10-15 16:36:28
            //������������Ϊֱ��Ҳ������ȫ100%��� ->+, ��������������, ��Ӧ�ô˲��Խ�� @2018-10-18 10:15:24
//             float weiFactor = edge_wmap.ptr(y)[x];
//             const float W_FACTOR_EDGE_THRESH = 0.99f;
//             bool is_curr_edge_wide = weiFactor < W_FACTOR_EDGE_THRESH;
//             is_curr_edge_wide = weiFactor < 0.3;//W_FACTOR_EDGE_THRESH;
//             if(doDbgPrint){
//                 printf("is_curr_edge_wide@raycast: %d\n", is_curr_edge_wide);
//                 //printf("weiFactor@raycast: %d\n", weiFactor); //һ���þͱ���, ����: Error: unspecified launch failure	..\..\..\gpu\containers\src\device_memory.cpp:307
//                 //Ϊɶ���� float weiFactor ʱ������?
//                 printf("edge_wmap.ptr(y)[x]@raycast: %f\n", edge_wmap.ptr(y)[x]); //Ҳ��
//             }
// 
//             if(!is_curr_edge_wide && !isnan(n_f3.x)){ //v21.3.4
            if(!isnan(n_f3.x)){
                if(doDbgPrint)
                    printf("ray_dir, n_f3: (%f, %f, %f), (%f, %f, %f); px_xy: (%d, %d)\n", ray_dir.x, ray_dir.y, ray_dir.z, n_f3.x, n_f3.y, n_f3.z, x, y);
                //ray_start + ray_dir * time_curr ������Ҫ��
                ray_start = vetex_found;
                //ray_dir = n_f3 * -1;
                //ray_dir = (ray_dir + n_f3 * -1) *0.5f; //v21.3.1: ��1: ��ƽ����, //δ��һ��
                //v21.3.2: ��2: �������Ľ�ƽ����, ��������Ǵ��� 60��,������, ����ֱ��
                float cos_vray_neg_norm = dot(ray_dir, n_f3 * -1); //����߶� normalized ����
                if(cos_vray_neg_norm < COS60)
                    //ray_dir = (ray_dir + n_f3 * -1) *0.5f;
                    ray_dir = ray_dir * 0.67f + n_f3 * -0.33f; //v21.3.3: ��С�������ʡ������ؽ�ƽ���ߣ���΢(0.33)���伴��   ����ʱ���š�@2018-10-10 18:03:53

                time_curr = 0;
                if(doDbgPrint)
                    printf("\tcos_vray_neg_norm: %f\n", cos_vray_neg_norm);

                //doDbgPrint2 = true; //�� doDbgPrint ��������޹�
            }
            continue;
          }//if(+>-)

//           if(doDbgPrint)
//               printf("tp: %f, wp: %d; tc: %f, wc: %d; rcFlag: %d; g_prev_xyz: (%d, %d, %d), ggg_xyz: (%d, %d, %d), px_xy: (%d, %d)\n", tsdf_prev, weight_prev, tsdf, weight, rcFlag.ptr(y)[x], g_prev.x, g_prev.y, g_prev.z, g.x, g.y, g.z, x, y);

          if(doDbgPrint2)
              printf("px_xy: (%d, %d), ray_start: (%f, %f, %f), ray_dir: (%f, %f, %f), time_curr: %f; g_prev_xyz: (%d, %d, %d), ggg_xyz: (%d, %d, %d); vxlDbg: (%d, %d, %d)\n", 
              x, y, ray_start.x, ray_start.y, ray_start.z, ray_dir.x, ray_dir.y, ray_dir.z, time_curr, g_prev.x, g_prev.y, g_prev.z, g.x, g.y, g.z, vxlDbg.x, vxlDbg.y, vxlDbg.z);
        }          /* for(;;)  */
      }//operator()(dummy, buffer)

    };

    __global__ void
    rayCastKernel (const RayCaster rc, pcl::gpu::tsdf_buffer buffer) {
      rc (buffer);
    }

    //����
    __global__ void
    rayCastKernel (const RayCaster rc, pcl::gpu::tsdf_buffer buffer, int dummy) {
      rc (buffer, dummy);
    }

  }
}


//////////////////////////////////////////////////////////////////////////////////////////////////////////////////
void
pcl::device::raycast (const Intr& intr, const Mat33& Rcurr, const float3& tcurr, 
                      float tranc_dist, const float3& volume_size,
                      const PtrStep<short2>& volume, const pcl::gpu::tsdf_buffer* buffer, MapArr& vmap, MapArr& nmap)
{
//     static int cnt_tmp = 0;
//     if(cnt_tmp !=0) //���� cyclical2_ & volume2nd_ ��   @2018-12-4 10:37:30

  RayCaster rc;

  rc.Rcurr = Rcurr;
  rc.tcurr = tcurr;

  rc.time_step = tranc_dist * 0.8f;
  //rc.time_step = tranc_dist * 0.1f; //zc:
  //rc.time_step = tranc_dist * 0.4f; //zc: �� td~5mm csz~2mm ����, ϣ��ÿ step ���һ��cell, ���󲽳������ߵ�̫��,���������ܱߴ���cell    @2018-10-9 01:03:26

  rc.volume_size = volume_size;

  rc.cell_size.x = volume_size.x / buffer->voxels_size.x;
  rc.cell_size.y = volume_size.y / buffer->voxels_size.y;
  rc.cell_size.z = volume_size.z / buffer->voxels_size.z;

  rc.cols = vmap.cols ();
  rc.rows = vmap.rows () / 3;

  rc.intr = intr;

  rc.volume = volume;
  rc.vmap = vmap;
  rc.nmap = nmap;

  printf("rc.cell_size.xyz: %f, %f, %f; rc.cc_rr: %d, %d\n", rc.cell_size.x, rc.cell_size.y, rc.cell_size.z, rc.cols, rc.rows);

  //zc: @2018-9-30 09:38:48
//   DepthMap rcFlag; //�ֲ�����, ������Զû�õ�, ��Ϊ�˼��������ذ汾
//   rcFlag.create(rc.rows, rc.cols);
//   rc.rcFlag = rcFlag;

  dim3 block (RayCaster::CTA_SIZE_X, RayCaster::CTA_SIZE_Y);
  dim3 grid (divUp (rc.cols, block.x), divUp (rc.rows, block.y));

  rayCastKernel<<<grid, block>>>(rc, *buffer);
  cudaSafeCall (cudaGetLastError ());
  cudaSafeCall(cudaDeviceSynchronize());
}

void
pcl::device::raycast (const Intr& intr, const Mat33& Rcurr, const float3& tcurr, 
                      float tranc_dist, const float3& volume_size,
                      const PtrStep<short2>& volume, const pcl::gpu::tsdf_buffer* buffer, MapArr& vmap, MapArr& nmap, 
                      /*MapArr& edge_wmap,*/ /*DepthMap*/ DeviceArray2D<short>& rcFlagMap, int3 vxlDbg /*= int3()*/)
{
  RayCaster rc;

  rc.Rcurr = Rcurr;
  rc.tcurr = tcurr;

  //rc.time_step = tranc_dist * 0.8f;
  //rc.time_step = tranc_dist * 0.1f; //zc:
  rc.time_step = tranc_dist * 0.4f; //zc: �� td~5mm csz~2mm ����, ϣ��ÿ step ���һ��cell, ���󲽳������ߵ�̫��,���������ܱߴ���cell    @2018-10-9 01:03:26

  rc.volume_size = volume_size;

  rc.cell_size.x = volume_size.x / buffer->voxels_size.x;
  rc.cell_size.y = volume_size.y / buffer->voxels_size.y;
  rc.cell_size.z = volume_size.z / buffer->voxels_size.z;

  rc.cols = vmap.cols ();
  rc.rows = vmap.rows () / 3;

  rc.intr = intr;

  rc.volume = volume;
  rc.vmap = vmap;
  rc.nmap = nmap;

  //zc: @2018-9-30 09:38:48
  //rcFlagMap_.create(rows_, cols_); //kinfu.cpp ��ԭ����, �����ο��� @2018-11-29 16:57:10
  rcFlagMap.create(rc.rows, rc.cols); //�ŵ� rcast �ڲ�

  rc.rcFlag = rcFlagMap;
  rc.vxlDbg = vxlDbg;

  //operator()�ڸ� rcFlag ������ֵ��������, ��ҪԤ�ȼ���Rת��, ������õ�����(ת�õ�����)    @2018-10-9 15:13:17
  float3 R_inv_row3;
  R_inv_row3.x = Rcurr.data[0].z;
  R_inv_row3.y = Rcurr.data[1].z;
  R_inv_row3.z = Rcurr.data[2].z;
  rc.R_inv_row3 = R_inv_row3;

  rc.tranc_dist = tranc_dist;

  //rc.edge_wmap = edge_wmap; //�����Եʱ, ��Ҫ����   @2018-10-15 05:52:39

  dim3 block (RayCaster::CTA_SIZE_X, RayCaster::CTA_SIZE_Y);
  dim3 grid (divUp (rc.cols, block.x), divUp (rc.rows, block.y));

  int dummy = 0;
  rayCastKernel<<<grid, block>>>(rc, *buffer, dummy);
  cudaSafeCall (cudaGetLastError ());
  //cudaSafeCall(cudaDeviceSynchronize());
}
