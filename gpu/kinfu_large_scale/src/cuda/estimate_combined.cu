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

//#include <pcl/gpu/utils/device/block.hpp>
//#include <pcl/gpu/utils/device/funcattrib.hpp>
#include "device.hpp"

namespace pcl
{
  namespace device
  {
    //typedef double float_type;
	typedef float float_type;

    struct Combined
    {
      enum
      {
        CTA_SIZE_X = 32,
        CTA_SIZE_Y = 8,
        CTA_SIZE = CTA_SIZE_X * CTA_SIZE_Y
      };

      struct plus
      {
        __forceinline__ __device__ float
        operator () (const float_type &lhs, const volatile float_type& rhs) const 
        {
          return (lhs + rhs);
        }
      };

      Mat33 Rcurr;
      float3 tcurr;

      PtrStep<float> vmap_curr;
      PtrStep<float> nmap_curr;

      Mat33 Rprev_inv;
      float3 tprev;

      Intr intr;

      PtrStep<float> vmap_g_prev;
      PtrStep<float> nmap_g_prev;

      float distThres;
      float angleThres;

      int cols;
      int rows;

      mutable PtrStep<float_type> gbuf;

      __device__ __forceinline__ bool
      search (int x, int y, float3& n, float3& d, float3& s) const
      {
        float3 ncurr;
        ncurr.x = nmap_curr.ptr (y)[x];

        if (isnan (ncurr.x))
          return (false);

        float3 vcurr;
        vcurr.x = vmap_curr.ptr (y       )[x];
        vcurr.y = vmap_curr.ptr (y + rows)[x];
        vcurr.z = vmap_curr.ptr (y + 2 * rows)[x];

        float3 vcurr_g = Rcurr * vcurr + tcurr;

        float3 vcurr_cp = Rprev_inv * (vcurr_g - tprev);         // prev camera coo space

        int2 ukr;         //projection
        ukr.x = __float2int_rn (vcurr_cp.x * intr.fx / vcurr_cp.z + intr.cx);      //4
        ukr.y = __float2int_rn (vcurr_cp.y * intr.fy / vcurr_cp.z + intr.cy);                      //4

        if (ukr.x < 0 || ukr.y < 0 || ukr.x >= cols || ukr.y >= rows || vcurr_cp.z < 0)
          return (false);

        float3 nprev_g;
        nprev_g.x = nmap_g_prev.ptr (ukr.y)[ukr.x];

        if (isnan (nprev_g.x))
          return (false);

        float3 vprev_g;
        vprev_g.x = vmap_g_prev.ptr (ukr.y       )[ukr.x];
        vprev_g.y = vmap_g_prev.ptr (ukr.y + rows)[ukr.x];
        vprev_g.z = vmap_g_prev.ptr (ukr.y + 2 * rows)[ukr.x];

        float dist = norm (vprev_g - vcurr_g);
        if (dist > distThres)
          return (false);

        ncurr.y = nmap_curr.ptr (y + rows)[x];
        ncurr.z = nmap_curr.ptr (y + 2 * rows)[x];

        float3 ncurr_g = Rcurr * ncurr;

        nprev_g.y = nmap_g_prev.ptr (ukr.y + rows)[ukr.x];
        nprev_g.z = nmap_g_prev.ptr (ukr.y + 2 * rows)[ukr.x];

        float sine = norm (cross (ncurr_g, nprev_g));

        if (sine >= angleThres)
          return (false);
        n = nprev_g;
        d = vprev_g;
        s = vcurr_g;
        return (true);
      }

      __device__ __forceinline__ void
      operator () () const
      {
        int x = threadIdx.x + blockIdx.x * CTA_SIZE_X;
        int y = threadIdx.y + blockIdx.y * CTA_SIZE_Y;

        float3 n, d, s;
        bool found_coresp = false;

        if (x < cols && y < rows)
          found_coresp = search (x, y, n, d, s);

        float row[7];

        if (found_coresp)
        {
          *(float3*)&row[0] = cross (s, n);
          *(float3*)&row[3] = n;
          row[6] = dot (n, d - s);
        }
        else
          row[0] = row[1] = row[2] = row[3] = row[4] = row[5] = row[6] = 0.f;

        __shared__ float_type smem[CTA_SIZE];
        int tid = Block::flattenedThreadId ();

        int shift = 0;
        #pragma unroll
        for (int i = 0; i < 6; ++i)        //rows
        {
          #pragma unroll
          for (int j = i; j < 7; ++j)          // cols + b
          {
            __syncthreads ();
            smem[tid] = row[i] * row[j];
            __syncthreads ();

            Block::reduce<CTA_SIZE>(smem, plus ());

            if (tid == 0)
              gbuf.ptr (shift++)[blockIdx.x + gridDim.x * blockIdx.y] = smem[0];
          }
        }
      }
    };

    __global__ void
    combinedKernel (const Combined cs) 
    {
      cs ();
    }

    struct TranformReduction
    {
      enum
      {
        CTA_SIZE = 512,
        STRIDE = CTA_SIZE,

        B = 6, COLS = 6, ROWS = 6, DIAG = 6,
        UPPER_DIAG_MAT = (COLS * ROWS - DIAG) / 2 + DIAG,
        TOTAL = UPPER_DIAG_MAT + B,

        GRID_X = TOTAL
      };

      PtrStep<float_type> gbuf;
      int length;
      mutable float_type* output;

      __device__ __forceinline__ void
      operator () () const
      {
        const float_type *beg = gbuf.ptr (blockIdx.x);
        const float_type *end = beg + length;

        int tid = threadIdx.x;

        float_type sum = 0.f;
        for (const float_type *t = beg + tid; t < end; t += STRIDE)
          sum += *t;

        __shared__ float_type smem[CTA_SIZE];

        smem[tid] = sum;
        __syncthreads ();

		Block::reduce<CTA_SIZE>(smem, Combined::plus ());

        if (tid == 0)
          output[blockIdx.x] = smem[0];
      }
    };

    __global__ void
    TransformEstimatorKernel2 (const TranformReduction tr) 
    {
      tr ();
    }

    struct Combined2
    {
      enum
      {
        CTA_SIZE_X = 32,
        CTA_SIZE_Y = 8,
        CTA_SIZE = CTA_SIZE_X * CTA_SIZE_Y
      };

      struct plus
      {
        __forceinline__ __device__ float
        operator () (const float_type &lhs, const volatile float_type& rhs) const 
        {
          return (lhs + rhs);
        }
      };

      Mat33 Rcurr;
      float3 tcurr;

      PtrStep<float> vmap_curr;
      PtrStep<float> nmap_curr;

      Mat33 Rprev_inv;
      float3 tprev;

      Intr intr;

      PtrStep<float> vmap_g_prev;
      PtrStep<float> nmap_g_prev;

      float distThres;
      float angleThres;

      int cols;
      int rows;

      mutable PtrStep<float_type> gbuf;

      __device__ __forceinline__ bool
      search (int x, int y, float3& n, float3& d, float3& s) const
      {
        float3 ncurr;
        ncurr.x = nmap_curr.ptr (y)[x];

        if (isnan (ncurr.x))
          return (false);

        float3 vcurr;
        vcurr.x = vmap_curr.ptr (y       )[x];
        vcurr.y = vmap_curr.ptr (y + rows)[x];
        vcurr.z = vmap_curr.ptr (y + 2 * rows)[x];

        float3 vcurr_g = Rcurr * vcurr + tcurr;

        float3 vcurr_cp = Rprev_inv * (vcurr_g - tprev);         // prev camera coo space

        int2 ukr;         //projection
        ukr.x = __float2int_rn (vcurr_cp.x * intr.fx / vcurr_cp.z + intr.cx);      //4
        ukr.y = __float2int_rn (vcurr_cp.y * intr.fy / vcurr_cp.z + intr.cy);                      //4

        if (ukr.x < 0 || ukr.y < 0 || ukr.x >= cols || ukr.y >= rows || vcurr_cp.z < 0)
          return (false);

        float3 nprev_g;
        nprev_g.x = nmap_g_prev.ptr (ukr.y)[ukr.x];

        if (isnan (nprev_g.x))
          return (false);

        float3 vprev_g;
        vprev_g.x = vmap_g_prev.ptr (ukr.y       )[ukr.x];

        //zc: fix @2017-4-13 16:20:12
        if (isnan (vprev_g.x))
          return (false);

        vprev_g.y = vmap_g_prev.ptr (ukr.y + rows)[ukr.x];
        vprev_g.z = vmap_g_prev.ptr (ukr.y + 2 * rows)[ukr.x];

        float dist = norm (vprev_g - vcurr_g);
        if (dist > distThres)
          return (false);

        ncurr.y = nmap_curr.ptr (y + rows)[x];
        ncurr.z = nmap_curr.ptr (y + 2 * rows)[x];

        float3 ncurr_g = Rcurr * ncurr;

        nprev_g.y = nmap_g_prev.ptr (ukr.y + rows)[ukr.x];
        nprev_g.z = nmap_g_prev.ptr (ukr.y + 2 * rows)[ukr.x];

        float sine = norm (cross (ncurr_g, nprev_g));

        if (sine >= angleThres)
          return (false);
        n = nprev_g;
        d = vprev_g;
        s = vcurr_g;
        return (true);
      }

      __device__ __forceinline__ bool
      searchDbg (int x, int y, float3& n, float3& d, float3& s) const
      {
        float3 ncurr;
        ncurr.x = nmap_curr.ptr (y)[x];

        if (isnan (ncurr.x))
          return (false);

        float3 vcurr;
        vcurr.x = vmap_curr.ptr (y       )[x];
        vcurr.y = vmap_curr.ptr (y + rows)[x];
        vcurr.z = vmap_curr.ptr (y + 2 * rows)[x];

        float3 vcurr_g = Rcurr * vcurr + tcurr;

        float3 vcurr_cp = Rprev_inv * (vcurr_g - tprev);         // prev camera coo space

        int2 ukr;         //projection
        ukr.x = __float2int_rn (vcurr_cp.x * intr.fx / vcurr_cp.z + intr.cx);      //4
        ukr.y = __float2int_rn (vcurr_cp.y * intr.fy / vcurr_cp.z + intr.cy);                      //4

        if (ukr.x < 0 || ukr.y < 0 || ukr.x >= cols || ukr.y >= rows || vcurr_cp.z < 0)
          return (false);

        float3 nprev_g;
        nprev_g.x = nmap_g_prev.ptr (ukr.y)[ukr.x];

        if (isnan (nprev_g.x))
          return (false);

        float3 vprev_g;
        vprev_g.x = vmap_g_prev.ptr (ukr.y       )[ukr.x];
        vprev_g.y = vmap_g_prev.ptr (ukr.y + rows)[ukr.x];
        vprev_g.z = vmap_g_prev.ptr (ukr.y + 2 * rows)[ukr.x];

		//zc: dbg
		printf("\t@searchDbg: ukr.xy=(%d, %d); isnan(nprev_g.x): %d; isnan (vprev_g.x): %d\n", ukr.x, ukr.y, isnan(nprev_g.x), isnan(vprev_g.x));

        float dist = norm (vprev_g - vcurr_g);
        if (dist > distThres)
          return (false);

        ncurr.y = nmap_curr.ptr (y + rows)[x];
        ncurr.z = nmap_curr.ptr (y + 2 * rows)[x];

        float3 ncurr_g = Rcurr * ncurr;

        nprev_g.y = nmap_g_prev.ptr (ukr.y + rows)[ukr.x];
        nprev_g.z = nmap_g_prev.ptr (ukr.y + 2 * rows)[ukr.x];

        float sine = norm (cross (ncurr_g, nprev_g));

        if (sine >= angleThres)
          return (false);
        n = nprev_g;
        d = vprev_g;
        s = vcurr_g;
        return (true);
      }//searchDbg

      __device__ __forceinline__ void
      operator () () const
      {
        int x = threadIdx.x + blockIdx.x * CTA_SIZE_X;
        int y = threadIdx.y + blockIdx.y * CTA_SIZE_Y;

        float3 n, d, s;
        bool found_coresp = false;

        if (x < cols && y < rows)
          found_coresp = search (x, y, n, d, s);

#if 0	//zc: dbg
		//if(x == 320 && y == 240){ //��
		if(x == cols/2 && y == rows/2){
			printf("@operator():: (x, y)=(%d, %d), found_coresp= %d; n=(%f, %f, %f), d=(%f, %f, %f), s=(%f, %f, %f)\n", x, y, 
				found_coresp, n.x, n.y, n.z, d.x, d.y, d.z, s.x, s.y, s.z);
		}
#endif

        float row[7];

        if (found_coresp)
        {
          *(float3*)&row[0] = cross (s, n);
          *(float3*)&row[3] = n;
          row[6] = dot (n, d - s);
		  //zc: dbg
		  if(isnan(row[6])){ //��������ȫ��Ӧ�÷�������
			  printf("isnan(row[6]), (x,y)=(%d, %d); (rows, cols)=(%d, %d); n=(%f, %f, %f), d=(%f, %f, %f), s=(%f, %f, %f)\n", x, y, rows, cols,
				  n.x, n.y, n.z, d.x, d.y, d.z, s.x, s.y, s.z);
			  searchDbg(x, y, n, d, s);
		  }

#if 0	//����, ���ܼӵ�һ��, ��Ϊ��ͷ�������� ������С���� ��ʽ, �Ƿ������� @2017-6-1 11:06:13
		  //zc: ������ʦҪ��, ���� nmap ���ͷ���, //��ֻ�ܳͷ� R, ���� t @2017-5-31 11:16:49
		  //Ӱ�� row[0~2, 6], ��Ӱ�� row[3~5]
		  float3 ncurr;
		  ncurr.x = nmap_curr.ptr (y)[x];
		  ncurr.y = nmap_curr.ptr (y + rows)[x];
		  ncurr.z = nmap_curr.ptr (y + 2 * rows)[x];
		  
		  float3 ncurr_g = Rcurr * ncurr;
		  if(dot(ncurr_g, n) < 0) //�жϷ���, ϣ���� nprev_g ����һ��
			  ncurr_g *= -1;

		  //ע��: n �� nprev_g 
		  float3 tmpv = ncurr_g - n;
		  *(float3*)&row[0] = *(float3*)&row[0] + cross(ncurr_g, tmpv); //3x1 ����
		  row[6] = row[6] - dot(tmpv, tmpv); //�ٱ��� ��ע������ ��-=��, ��ԭ��, �Ƶ���
#endif

#if 0
		  {
			  float3 cross_ng_v = cross(ncurr_g, tmpv);
			  float3 row03 = *(float3*)&row[0];
			  float3 row03_new = row03 + cross_ng_v;
			  //printf("ncurr_g=(%f, %f, %f), nprev_g=(%f, %f, %f)\n", ncurr_g.x, ncurr_g.y, ncurr_g.z, n.x, n.y, n.z);
			  printf("ncurr_g=(%f, %f, %f), nprev_g=(%f, %f, %f)\
					 \ntmpv=(%f, %f, %f), row03=(%f, %f, %f), cross_ng_v=(%f, %f, %f), row03_new=(%f, %f, %f), row6=%f, row6_new=%f\n", 
					 ncurr_g.x, ncurr_g.y, ncurr_g.z, n.x, n.y, n.z,
				  tmpv.x, tmpv.y, tmpv.z, 
				  row03.x, row03.y, row03.z,
				  cross_ng_v.x, cross_ng_v.y, cross_ng_v.z, 
				  row03_new.x, row03_new.y, row03_new.z, 
				  row[6], row[6] - dot(tmpv, tmpv));

		  }
#endif
        }
        else
          row[0] = row[1] = row[2] = row[3] = row[4] = row[5] = row[6] = 0.f;

        int tid = Block::flattenedThreadId ();

        int shift = 0;
        #pragma unroll
        for (int i = 0; i < 6; ++i)        //rows
        {
          #pragma unroll
          for (int j = i; j < 7; ++j)          // cols + b
          {
              gbuf.ptr (shift++)[ (blockIdx.x + gridDim.x * blockIdx.y) * CTA_SIZE + tid ] = row[i]*row[j];
          }
        }
      }

      __device__ __forceinline__ void
      operator () (int dummy) const
      {
        int x = threadIdx.x + blockIdx.x * CTA_SIZE_X;
        int y = threadIdx.y + blockIdx.y * CTA_SIZE_Y;

        float3 n, d, s;
        bool found_coresp = false;

        if (x < cols && y < rows)
          found_coresp = search (x, y, n, d, s);

#if 0	//zc: dbg
		//if(x == 320 && y == 240){ //��
		if(x == cols/2 && y == rows/2){
			printf("@operator():: (x, y)=(%d, %d), found_coresp= %d; n=(%f, %f, %f), d=(%f, %f, %f), s=(%f, %f, %f)\n", x, y, 
				found_coresp, n.x, n.y, n.z, d.x, d.y, d.z, s.x, s.y, s.z);
		}
#endif

        float row[7];

        if (found_coresp)
        {
#if 0	//��, ����Ҫ�� nmap �ͷ���, ���Ż� R, ���� t (ϵ������) @2017-6-1 14:47:31
          *(float3*)&row[0] = cross (s, n);
          *(float3*)&row[3] = n;
          row[6] = dot (n, d - s);
#elif 1
          float3 ncurr;
          ncurr.x = nmap_curr.ptr (y)[x];
          ncurr.y = nmap_curr.ptr (y + rows)[x];
          ncurr.z = nmap_curr.ptr (y + 2 * rows)[x];
          
          float3 ncurr_g = Rcurr * ncurr;
          if(dot(ncurr_g, n) < 0) //�жϷ���, ϣ���� nprev_g ����һ��
              ncurr_g *= -1;

          //ע��: n �� nprev_g 
#if 0	//�˴�˼·�� argmin(SUM(|(R*ng~-ng)*(ng~-ng)|))
          //������, ����, ���� @2017-6-2 17:48:13
          float3 tmpv = ncurr_g - n;
          *(float3*)&row[0] = cross(ncurr_g, tmpv); //3x1 ����
          row[3] = row[4] = row[5] = 0.f;
          row[6] = -dot(tmpv, tmpv); //�ٱ��� ��ע������ ��-=��, ��ԭ��, �Ƶ���

#elif 1	//������ʵ���� orthogonal-procrustes ����, ���ﳢ�Բ��л����� @2017-6-2 17:48:49
          //Ŀ��: argmin|RA-B| ==> R = svd(B*At), ���� A/B �� 3*N, �� BAt~3x3
          //row0~2 -> ncurr_g, 3~5-> nprev_g, [6]����, ������
          //֮�� gbuf[27] ֻ��ǰ 3x3=9 ��, 
          *(float3*)&row[0] = ncurr_g;
          *(float3*)&row[3] = n;
          row[6] = 0;
#endif

#endif
		  //zc: dbg
		  if(isnan(row[6])){ //��������ȫ��Ӧ�÷�������
			  printf("isnan(row[6]), (x,y)=(%d, %d); (rows, cols)=(%d, %d); n=(%f, %f, %f), d=(%f, %f, %f), s=(%f, %f, %f)\n", x, y, rows, cols,
				  n.x, n.y, n.z, d.x, d.y, d.z, s.x, s.y, s.z);
			  searchDbg(x, y, n, d, s);
		  }

#if 0	//����, ���ܼӵ�һ��, ��Ϊ��ͷ�������� ������С���� ��ʽ, �Ƿ������� @2017-6-1 11:06:13
		  //zc: ������ʦҪ��, ���� nmap ���ͷ���, //��ֻ�ܳͷ� R, ���� t @2017-5-31 11:16:49
		  //Ӱ�� row[0~2, 6], ��Ӱ�� row[3~5]
		  float3 ncurr;
		  ncurr.x = nmap_curr.ptr (y)[x];
		  ncurr.y = nmap_curr.ptr (y + rows)[x];
		  ncurr.z = nmap_curr.ptr (y + 2 * rows)[x];
		  
		  float3 ncurr_g = Rcurr * ncurr;
		  if(dot(ncurr_g, n) < 0) //�жϷ���, ϣ���� nprev_g ����һ��
			  ncurr_g *= -1;

		  //ע��: n �� nprev_g 
		  float3 tmpv = ncurr_g - n;
		  *(float3*)&row[0] = *(float3*)&row[0] + cross(ncurr_g, tmpv); //3x1 ����
		  row[6] = row[6] - dot(tmpv, tmpv); //�ٱ��� ��ע������ ��-=��, ��ԭ��, �Ƶ���
#endif

#if 0
		  {
			  float3 cross_ng_v = cross(ncurr_g, tmpv);
			  float3 row03 = *(float3*)&row[0];
			  float3 row03_new = row03 + cross_ng_v;
			  //printf("ncurr_g=(%f, %f, %f), nprev_g=(%f, %f, %f)\n", ncurr_g.x, ncurr_g.y, ncurr_g.z, n.x, n.y, n.z);
			  printf("ncurr_g=(%f, %f, %f), nprev_g=(%f, %f, %f)\
					 \ntmpv=(%f, %f, %f), row03=(%f, %f, %f), cross_ng_v=(%f, %f, %f), row03_new=(%f, %f, %f), row6=%f, row6_new=%f\n", 
					 ncurr_g.x, ncurr_g.y, ncurr_g.z, n.x, n.y, n.z,
				  tmpv.x, tmpv.y, tmpv.z, 
				  row03.x, row03.y, row03.z,
				  cross_ng_v.x, cross_ng_v.y, cross_ng_v.z, 
				  row03_new.x, row03_new.y, row03_new.z, 
				  row[6], row[6] - dot(tmpv, tmpv));

		  }
#endif
        }
        else
          row[0] = row[1] = row[2] = row[3] = row[4] = row[5] = row[6] = 0.f;

        int tid = Block::flattenedThreadId ();

        int shift = 0;
#if 0   //gbuf ���� 21������+6=27 ʱ
        #pragma unroll
        for (int i = 0; i < 6; ++i)        //rows
        {
          #pragma unroll
          for (int j = i; j < 7; ++j)          // cols + b
          {
              gbuf.ptr (shift++)[ (blockIdx.x + gridDim.x * blockIdx.y) * CTA_SIZE + tid ] = row[i]*row[j];
          }
        }
#elif 1 //gbuf ����ǰ 3x3=9, �� orthogonal-procrustes ����ʱ @2017-6-2 17:55:44
        #pragma unroll
        for(int j=3; j<6; ++j){ //RA-B ������, ���� 3~5��Ӧ B
            #pragma unroll
            for(int i=0; i<3; ++i){ //0~2 ��Ӧ A
                gbuf.ptr (shift++)[ (blockIdx.x + gridDim.x * blockIdx.y) * CTA_SIZE + tid ] = row[j] * row[i];
            }
        }
#endif
      }//operator () (int dummy) const


    };

    __global__ void
    combinedKernel2 (const Combined2 cs) 
    {
      cs ();
    }

    __global__ void
    combinedKernel2_nmap (const Combined2 cs) 
    {
      cs (1234567); //dummy ����
    }

    struct CombinedPrevSpace
    {
      enum
      {
        CTA_SIZE_X = 32,
        CTA_SIZE_Y = 8,
        CTA_SIZE = CTA_SIZE_X * CTA_SIZE_Y
      };

      struct plus
      {
        __forceinline__ __device__ float
        operator () (const float_type &lhs, const volatile float_type& rhs) const 
        {
          return (lhs + rhs);
        }
      };

      Mat33 Rcurr;
      float3 tcurr;

      PtrStep<float> vmap_curr;
      PtrStep<float> nmap_curr;

      Mat33 Rprev_inv;
      float3 tprev;

      Intr intr;

      PtrStep<float> vmap_g_prev;
      PtrStep<float> nmap_g_prev;

      float distThres;
      float angleThres;

      int cols;
      int rows;

      mutable PtrStep<float_type> gbuf;

      __device__ __forceinline__ bool
      search (int x, int y, float3& n, float3& d, float3& s) const
      {
        float3 ncurr;
        ncurr.x = nmap_curr.ptr (y)[x];

        if (isnan (ncurr.x))
          return (false);

        float3 vcurr;
        vcurr.x = vmap_curr.ptr (y       )[x];
        vcurr.y = vmap_curr.ptr (y + rows)[x];
        vcurr.z = vmap_curr.ptr (y + 2 * rows)[x];

        float3 vcurr_g = Rcurr * vcurr + tcurr;

        float3 vcurr_cp = Rprev_inv * (vcurr_g - tprev);         // prev camera coo space

        int2 ukr;         //projection
        ukr.x = __float2int_rn (vcurr_cp.x * intr.fx / vcurr_cp.z + intr.cx);      //4
        ukr.y = __float2int_rn (vcurr_cp.y * intr.fy / vcurr_cp.z + intr.cy);                      //4

        if (ukr.x < 0 || ukr.y < 0 || ukr.x >= cols || ukr.y >= rows || vcurr_cp.z < 0)
          return (false);

        float3 nprev_g;
        nprev_g.x = nmap_g_prev.ptr (ukr.y)[ukr.x];

        if (isnan (nprev_g.x))
          return (false);

        float3 vprev_g;
        vprev_g.x = vmap_g_prev.ptr (ukr.y       )[ukr.x];
        vprev_g.y = vmap_g_prev.ptr (ukr.y + rows)[ukr.x];
        vprev_g.z = vmap_g_prev.ptr (ukr.y + 2 * rows)[ukr.x];

        float dist = norm (vprev_g - vcurr_g);
        if (dist > distThres)
          return (false);

        ncurr.y = nmap_curr.ptr (y + rows)[x];
        ncurr.z = nmap_curr.ptr (y + 2 * rows)[x];

        float3 ncurr_g = Rcurr * ncurr;

        nprev_g.y = nmap_g_prev.ptr (ukr.y + rows)[ukr.x];
        nprev_g.z = nmap_g_prev.ptr (ukr.y + 2 * rows)[ukr.x];

        float sine = norm (cross (ncurr_g, nprev_g));

        if (sine >= angleThres)
          return (false);
        n = Rprev_inv * nprev_g;
        d = Rprev_inv * (vprev_g - tprev);
        s = vcurr_cp;
        return (true);
      }

      __device__ __forceinline__ void
      operator () () const
      {
        int x = threadIdx.x + blockIdx.x * CTA_SIZE_X;
        int y = threadIdx.y + blockIdx.y * CTA_SIZE_Y;

        float3 n, d, s;
        bool found_coresp = false;

        if (x < cols && y < rows)
          found_coresp = search (x, y, n, d, s);

        float row[7];

        if (found_coresp)
        {
          *(float3*)&row[0] = cross (s, n);
          *(float3*)&row[3] = n;
          row[6] = dot (n, d - s);
        }
        else
          row[0] = row[1] = row[2] = row[3] = row[4] = row[5] = row[6] = 0.f;

        int tid = Block::flattenedThreadId ();

        int shift = 0;
        #pragma unroll
        for (int i = 0; i < 6; ++i)        //rows
        {
          #pragma unroll
          for (int j = i; j < 7; ++j)          // cols + b
          {
              gbuf.ptr (shift++)[ (blockIdx.x + gridDim.x * blockIdx.y) * CTA_SIZE + tid ] = row[i]*row[j];
          }
        }
      }
    };

    __global__ void
    combinedKernelPrevSpace (const CombinedPrevSpace cs) 
    {
      cs ();
    }

  }
}


//////////////////////////////////////////////////////////////////////////////////////////////////////////////////
void
pcl::device::estimateCombined (const Mat33& Rcurr, const float3& tcurr, 
                               const MapArr& vmap_curr, const MapArr& nmap_curr, 
                               const Mat33& Rprev_inv, const float3& tprev, const Intr& intr,
                               const MapArr& vmap_g_prev, const MapArr& nmap_g_prev, 
                               float distThres, float angleThres,
                               DeviceArray2D<float_type>& gbuf, DeviceArray<float_type>& mbuf, 
                               float_type* matrixA_host, float_type* vectorB_host)
{
  int cols = vmap_curr.cols ();
  int rows = vmap_curr.rows () / 3;
  dim3 block (Combined::CTA_SIZE_X, Combined::CTA_SIZE_Y);
  dim3 grid (1, 1, 1);
  grid.x = divUp (cols, block.x);
  grid.y = divUp (rows, block.y);

  /*
  Combined cs;

  cs.Rcurr = Rcurr;
  cs.tcurr = tcurr;

  cs.vmap_curr = vmap_curr;
  cs.nmap_curr = nmap_curr;

  cs.Rprev_inv = Rprev_inv;
  cs.tprev = tprev;

  cs.intr = intr;

  cs.vmap_g_prev = vmap_g_prev;
  cs.nmap_g_prev = nmap_g_prev;

  cs.distThres = distThres;
  cs.angleThres = angleThres;

  cs.cols = cols;
  cs.rows = rows;

//////////////////////////////

  mbuf.create (TranformReduction::TOTAL);
  if (gbuf.rows () != TranformReduction::TOTAL || gbuf.cols () < (int)(grid.x * grid.y))
    gbuf.create (TranformReduction::TOTAL, grid.x * grid.y);

  cs.gbuf = gbuf;

  combinedKernel<<<grid, block>>>(cs);
  cudaSafeCall ( cudaGetLastError () );
  //cudaSafeCall(cudaDeviceSynchronize());

  //printFuncAttrib(combinedKernel);

  TranformReduction tr;
  tr.gbuf = gbuf;
  tr.length = grid.x * grid.y;
  tr.output = mbuf;

  TransformEstimatorKernel2<<<TranformReduction::TOTAL, TranformReduction::CTA_SIZE>>>(tr);
  cudaSafeCall (cudaGetLastError ());
  cudaSafeCall (cudaDeviceSynchronize ());
  */
  Combined2 cs2;

  cs2.Rcurr = Rcurr;
  cs2.tcurr = tcurr;

  cs2.vmap_curr = vmap_curr;
  cs2.nmap_curr = nmap_curr;

  cs2.Rprev_inv = Rprev_inv;
  cs2.tprev = tprev;

  cs2.intr = intr;

  cs2.vmap_g_prev = vmap_g_prev;
  cs2.nmap_g_prev = nmap_g_prev;

  cs2.distThres = distThres;
  cs2.angleThres = angleThres;

  cs2.cols = cols;
  cs2.rows = rows;

  cs2.gbuf = gbuf;

  combinedKernel2<<<grid, block>>>(cs2);
  cudaSafeCall ( cudaGetLastError () );

  //zc: dbg *gbuf*
#if 0
  const int pxNUM = 640 * 480;
  //float_type gbuf_host[27];//*640*480]; //31MB ����ջ�ڴ����, ���� new
  float_type *gbuf_host = new float_type[27*pxNUM];
  gbuf.download(gbuf_host, pxNUM*sizeof(float_type));
  for(int i=0; i<27; i++){
	  float sum = 0;
	  for(int j=0; j<pxNUM; j++){
		  sum += gbuf_host[i*pxNUM + j];
	  }
	  printf("gbuf_host::sum(%d):=%f\n", i, sum);
  }
#endif

  TranformReduction tr2;
  tr2.gbuf = gbuf;
  tr2.length = cols * rows;
  tr2.output = mbuf;

  TransformEstimatorKernel2<<<TranformReduction::TOTAL, TranformReduction::CTA_SIZE>>>(tr2);
  cudaSafeCall (cudaGetLastError ());
  cudaSafeCall (cudaDeviceSynchronize ());

  float_type host_data[TranformReduction::TOTAL];
  mbuf.download (host_data);

  int shift = 0;
  for (int i = 0; i < 6; ++i)  //rows
    for (int j = i; j < 7; ++j)    // cols + b
    {
      float_type value = host_data[shift++];
      if (j == 6)       // vector b
        vectorB_host[i] = value;
      else
        matrixA_host[j * 6 + i] = matrixA_host[i * 6 + j] = value;
    }
}

//zc: nmap �ͷ���ר��, �� estimateCombined ������ combinedKernel2 �������� operator() @2017-6-1 13:11:25
void
pcl::device::estimateCombined_nmap (const Mat33& Rcurr, const float3& tcurr, 
                               const MapArr& vmap_curr, const MapArr& nmap_curr, 
                               const Mat33& Rprev_inv, const float3& tprev, const Intr& intr,
                               const MapArr& vmap_g_prev, const MapArr& nmap_g_prev, 
                               float distThres, float angleThres,
                               DeviceArray2D<float_type>& gbuf, DeviceArray<float_type>& mbuf, 
                               float_type* matrixA_host, float_type* vectorB_host)
{
  int cols = vmap_curr.cols ();
  int rows = vmap_curr.rows () / 3;
  dim3 block (Combined::CTA_SIZE_X, Combined::CTA_SIZE_Y);
  dim3 grid (1, 1, 1);
  grid.x = divUp (cols, block.x);
  grid.y = divUp (rows, block.y);

  /*
  Combined cs;

  cs.Rcurr = Rcurr;
  cs.tcurr = tcurr;

  cs.vmap_curr = vmap_curr;
  cs.nmap_curr = nmap_curr;

  cs.Rprev_inv = Rprev_inv;
  cs.tprev = tprev;

  cs.intr = intr;

  cs.vmap_g_prev = vmap_g_prev;
  cs.nmap_g_prev = nmap_g_prev;

  cs.distThres = distThres;
  cs.angleThres = angleThres;

  cs.cols = cols;
  cs.rows = rows;

//////////////////////////////

  mbuf.create (TranformReduction::TOTAL);
  if (gbuf.rows () != TranformReduction::TOTAL || gbuf.cols () < (int)(grid.x * grid.y))
    gbuf.create (TranformReduction::TOTAL, grid.x * grid.y);

  cs.gbuf = gbuf;

  combinedKernel<<<grid, block>>>(cs);
  cudaSafeCall ( cudaGetLastError () );
  //cudaSafeCall(cudaDeviceSynchronize());

  //printFuncAttrib(combinedKernel);

  TranformReduction tr;
  tr.gbuf = gbuf;
  tr.length = grid.x * grid.y;
  tr.output = mbuf;

  TransformEstimatorKernel2<<<TranformReduction::TOTAL, TranformReduction::CTA_SIZE>>>(tr);
  cudaSafeCall (cudaGetLastError ());
  cudaSafeCall (cudaDeviceSynchronize ());
  */
  Combined2 cs2;

  cs2.Rcurr = Rcurr;
  cs2.tcurr = tcurr;

  cs2.vmap_curr = vmap_curr;
  cs2.nmap_curr = nmap_curr;

  cs2.Rprev_inv = Rprev_inv;
  cs2.tprev = tprev;

  cs2.intr = intr;

  cs2.vmap_g_prev = vmap_g_prev;
  cs2.nmap_g_prev = nmap_g_prev;

  cs2.distThres = distThres;
  cs2.angleThres = angleThres;

  cs2.cols = cols;
  cs2.rows = rows;

  cs2.gbuf = gbuf;

  //combinedKernel2<<<grid, block>>>(cs2);
  combinedKernel2_nmap<<<grid, block>>>(cs2); //zc
  
  cudaSafeCall ( cudaGetLastError () );

  //zc: dbg *gbuf*
#if 0
  const int pxNUM = 640 * 480;
  //float_type gbuf_host[27];//*640*480]; //31MB ����ջ�ڴ����, ���� new
  float_type *gbuf_host = new float_type[27*pxNUM];
  gbuf.download(gbuf_host, pxNUM*sizeof(float_type));
  for(int i=0; i<27; i++){
	  float sum = 0;
	  for(int j=0; j<pxNUM; j++){
		  sum += gbuf_host[i*pxNUM + j];
	  }
	  printf("gbuf_host::sum(%d):=%f\n", i, sum);
  }
#endif

  TranformReduction tr2;
  tr2.gbuf = gbuf;
  tr2.length = cols * rows;
  tr2.output = mbuf;

  //TransformEstimatorKernel2<<<TranformReduction::TOTAL, TranformReduction::CTA_SIZE>>>(tr2);
  TransformEstimatorKernel2<<<9, TranformReduction::CTA_SIZE>>>(tr2); //9=3x3, ԭ TranformReduction::TOTAL=27
  cudaSafeCall (cudaGetLastError ());
  cudaSafeCall (cudaDeviceSynchronize ());

  float_type host_data[TranformReduction::TOTAL];
  mbuf.download (host_data);

#if 0   //��ԭ TranformReduction::TOTAL=27
  int shift = 0;
  for (int i = 0; i < 6; ++i)  //rows
    for (int j = i; j < 7; ++j)    // cols + b
    {
      float_type value = host_data[shift++];
      if (j == 6)       // vector b
        vectorB_host[i] = value;
      else
        matrixA_host[j * 6 + i] = matrixA_host[i * 6 + j] = value;
    }
#elif 1 //�� matrixA_host ����ǰ 3x3 (���� 6x6) 
  int shift = 0;
  for(int i=0; i<3; ++i)  //rows
    for(int j=0; j<3; ++j){
      float_type value = host_data[shift++];
      matrixA_host[i * 6 + j] = value;
    }

    //��-������, ��Ϊ matrixA_host ���� 66 ����
//   for(int i=0; i<9; ++i)
//       matrixA_host[i] = host_data[i];
#endif
}//estimateCombined_nmap

//////////////////////////////////////////////////////////////////////////////////////////////////////////////////
void
pcl::device::estimateCombinedPrevSpace (const Mat33& Rcurr, const float3& tcurr, 
                               const MapArr& vmap_curr, const MapArr& nmap_curr, 
                               const Mat33& Rprev_inv, const float3& tprev, const Intr& intr,
                               const MapArr& vmap_g_prev, const MapArr& nmap_g_prev, 
                               float distThres, float angleThres,
                               DeviceArray2D<float_type>& gbuf, DeviceArray<float_type>& mbuf, 
                               float_type* matrixA_host, float_type* vectorB_host)
{
  int cols = vmap_curr.cols ();
  int rows = vmap_curr.rows () / 3;
  dim3 block (Combined::CTA_SIZE_X, Combined::CTA_SIZE_Y);
  dim3 grid (1, 1, 1);
  grid.x = divUp (cols, block.x);
  grid.y = divUp (rows, block.y);

  CombinedPrevSpace cs3;

  cs3.Rcurr = Rcurr;
  cs3.tcurr = tcurr;

  cs3.vmap_curr = vmap_curr;
  cs3.nmap_curr = nmap_curr;

  cs3.Rprev_inv = Rprev_inv;
  cs3.tprev = tprev;

  cs3.intr = intr;

  cs3.vmap_g_prev = vmap_g_prev;
  cs3.nmap_g_prev = nmap_g_prev;

  cs3.distThres = distThres;
  cs3.angleThres = angleThres;

  cs3.cols = cols;
  cs3.rows = rows;

  cs3.gbuf = gbuf;

  combinedKernelPrevSpace<<<grid, block>>>(cs3);
  cudaSafeCall ( cudaGetLastError () );

  TranformReduction tr2;
  tr2.gbuf = gbuf;
  tr2.length = cols * rows;
  tr2.output = mbuf;

  TransformEstimatorKernel2<<<TranformReduction::TOTAL, TranformReduction::CTA_SIZE>>>(tr2);
  cudaSafeCall (cudaGetLastError ());
  cudaSafeCall (cudaDeviceSynchronize ());

  float_type host_data[TranformReduction::TOTAL];
  mbuf.download (host_data);

  int shift = 0;
  for (int i = 0; i < 6; ++i)  //rows
    for (int j = i; j < 7; ++j)    // cols + b
    {
      float_type value = host_data[shift++];
      if (j == 6)       // vector b
        vectorB_host[i] = value;
      else
        matrixA_host[j * 6 + i] = matrixA_host[i * 6 + j] = value;
    }
}
