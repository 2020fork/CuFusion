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

#ifndef PCL_KINFU_TSDF_VOLUME_H_
#define PCL_KINFU_TSDF_VOLUME_H_

#include <pcl/pcl_macros.h>
#include <pcl/gpu/containers/device_array.h>
#include <pcl/point_types.h>
#include <pcl/point_cloud.h>
#include <Eigen/Core>
#include <vector>

#include <pcl/gpu/kinfu_large_scale/tsdf_buffer.h>

#include <pcl/gpu/kinfu_large_scale/point_intensity.h>

namespace pcl
{
  namespace gpu
  {
    /** \brief TsdfVolume class
      * \author Anatoly Baskeheev, Itseez Ltd, (myname.mysurname@mycompany.com)
      */
    class PCL_EXPORTS TsdfVolume 
    {
    public:
      typedef boost::shared_ptr<TsdfVolume> Ptr;

      /** \brief Supported Point Types */
      typedef PointXYZ PointType;
      typedef Normal  NormalType;

      /** \brief Default buffer size for fetching cloud. It limits max number of points that can be extracted */
      enum { DEFAULT_CLOUD_BUFFER_SIZE = 10 * 1000 * 1000 };
            
      /** \brief Constructor
        * \param[in] resolution volume resolution
        */
      TsdfVolume(const Eigen::Vector3i& resolution);           
            
      /** \brief Sets Tsdf volume size for each dimention
        * \param[in] size size of tsdf volume in meters
        */
      void
      setSize(const Eigen::Vector3f& size);
      
      /** \brief Sets Tsdf truncation distance. Must be greater than 2 * volume_voxel_size
        * \param[in] distance TSDF truncation distance 
        */
      void
      setTsdfTruncDist (float distance);

      /** \brief Returns tsdf volume container that point to data in GPU memroy */
      DeviceArray2D<int> 
      data() const;

      /** \brief Returns volume size in meters */
      const Eigen::Vector3f&
      getSize() const;
            
      /** \brief Returns volume resolution */
      const Eigen::Vector3i&
      getResolution() const;

      /** \brief Returns volume voxel size in meters */
      const Eigen::Vector3f
      getVoxelSize() const;
      
      /** \brief Returns tsdf truncation distance in meters */
      float
      getTsdfTruncDist () const;
     
      /** \brief Resets tsdf volume data to uninitialized state */
      void 
      reset();

      /** \brief Generates cloud using CPU (downloads volumetric representation to CPU memory)
        * \param[out] cloud output array for cloud
        * \param[in] connected26 If false point cloud is extracted using 6 neighbor, otherwise 26.
        */
      void
      fetchCloudHost (PointCloud<PointType>& cloud, bool connected26 = false) const;
      
      /** \brief Generates cloud using CPU (downloads volumetric representation to CPU memory)
        * \param[out] cloud output array for cloud
        * \param[in] connected26 If false point cloud is extracted using 6 neighbor, otherwise 26.
        */
      void
      fetchCloudHost (PointCloud<PointXYZI>& cloud, bool connected26 = false) const;

      /** \brief Generates cloud using GPU in connected6 mode only
        * \param[out] cloud_buffer buffer to store point cloud
        * \return DeviceArray with disabled reference counting that points to filled part of cloud_buffer.
        */
      DeviceArray<PointType>
      fetchCloud (DeviceArray<PointType>& cloud_buffer, const pcl::gpu::tsdf_buffer* buffer) const;

        /** \brief Push a point cloud of previously scanned tsdf slice to the TSDF volume
          * \param[in] existingCloud point cloud pointer to the existing data. This data will be pushed to the TSDf volume. The points with indices outside the range [0 ... VOLUME_X - 1][0 ... VOLUME_Y - 1][0 ... VOLUME_Z - 1] will not be added.
          */
      void 
      pushSlice (const PointCloud<PointXYZI>::Ptr existing_data_cloud, const pcl::gpu::tsdf_buffer* buffer) const;

      /** \brief Generates cloud using GPU in connected6 mode only
        * \param[out] cloud_buffer buffer_xyz to store point cloud
        * \param[in] buffer Pointer to the buffer struct that contains information about memory addresses of the tsdf volume memory block, which are used for the cyclic buffer.
        * \param[in] shiftX Offset in indices.
        * \param[in] shiftY Offset in indices.
        * \param[in] shiftZ Offset in indices.
        * \return DeviceArray with disabled reference counting that points to filled part of cloud_buffer.
        */
      size_t
      fetchSliceAsCloud (DeviceArray<PointType>& cloud_buffer_xyz, DeviceArray<float>& cloud_buffer_intensity, const pcl::gpu::tsdf_buffer* buffer, int shiftX, int shiftY, int shiftZ ) const;

      /** \brief Computes normals as gradient of tsdf for given points
        * \param[in] cloud Points where normals are computed.
        * \param[out] normals array for normals
        */

      void
      fetchNormals (const DeviceArray<PointType>& cloud, DeviceArray<PointType>& normals) const;

  	  void
	  fetchNormalsInSpace (const DeviceArray<PointType>& cloud, const pcl::gpu::tsdf_buffer* buffer) const;

      /** \brief Computes normals as gradient of tsdf for given points
        * \param[in] cloud Points where normals are computed.
        * \param[out] normals array for normals
        */
      void
      fetchNormals(const DeviceArray<PointType>& cloud, DeviceArray<NormalType>& normals) const;

      /** \brief Downloads tsdf volume from GPU memory.           
        * \param[out] tsdf Array with tsdf values. if volume resolution is 512x512x512, so for voxel (x,y,z) tsdf value can be retrieved as volume[512*512*z + 512*y + x];
        */
      void
      downloadTsdf (std::vector<float>& tsdf) const;

      /** \brief Downloads TSDF volume and according voxel weights from GPU memory
        * \param[out] tsdf Array with tsdf values. if volume resolution is 512x512x512, so for voxel (x,y,z) tsdf value can be retrieved as volume[512*512*z + 512*y + x];
        * \param[out] weights Array with tsdf voxel weights. Same size and access index as for tsdf. A weight of 0 indicates the voxel was never used.
        */
      void
      downloadTsdfAndWeighs(std::vector<float>& tsdf, std::vector<short>& weights) const;
      
      /** \brief Releases tsdf buffer on GPU */
      void releaseVolume() {volume_.release();}

    private:
      /** \brief tsdf volume size in meters */
      Eigen::Vector3f size_;
      
      /** \brief tsdf volume resolution */
      Eigen::Vector3i resolution_;      

      /** \brief tsdf volume data container */
      DeviceArray2D<int> volume_;

      /** \brief tsdf truncation distance */
      float tranc_dist_;

public: //zc:
	//用作 pcTSDF 的 flag, 启用单独变量, 不改写原 volume为 short3 //2017-1-27 23:29:13
	//false=纯预测, true=确实看见过, 即 seen-flag
	DeviceArray2D<bool> flagVolume_; //增加消耗 256MB 显存, (getting mesh 耗费约 120MB 显存, 目前已到 1850MB 左右的极限)

	//tsdf-v10 中, 用于存储"混合均值滤波" 的[第二中心]
	DeviceArray2D<int> volume2nd_;

	//zc: 用作 tsdf-v8, 对每个晶格, 存储其上一次 视线=(晶格-视点) 向量
	DeviceArray2D<int> vrayPrevVolume_;

	//tsdf-v11, 启用 vray+ surfNorm 双判定, 
	DeviceArray2D<int> surfNormPrev_;

	//存储基座按水平面分割后的上方扫描物 //对应控制量 segPlaneParam_
	//DeviceArray2D<int> volumeUpper_; //暂放弃
    };
  }
}

#endif /* PCL_KINFU_TSDF_VOLUME_H_ */
