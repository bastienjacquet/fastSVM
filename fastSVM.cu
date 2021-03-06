#include <cufft.h>
#include "cutil_math.h"

#include <FreeImagePlus.h>

#include <vector>
#include <cassert>
#include <cstdlib>
#include <iostream>
#include <fstream>

#include <boost/iostreams/filtering_stream.hpp>
#include <boost/iostreams/device/file.hpp>
#include <boost/iostreams/filtering_streambuf.hpp>
#include <boost/iostreams/filter/gzip.hpp>
#include <boost/timer.hpp>

static __global__ void PointwiseMulConj(cufftComplex*, const cufftComplex*, int);
static __global__ void CropScaleAccum(const cufftReal*, int, int, int, int, cufftReal*);
static __global__ void Zero(int, float *);
static __global__ void Init(float, int, float *);
static __global__ void Threshold(float, int, float *);

static __global__ void FormatImage(const unsigned char *, float3 *, int, int, int, bool);
static __global__ void ComputeHistograms(const float3 *, int, int, int, int, int, int, float *);
static __global__ void ComputeEnergy(const float *, int, int, float *);
static __global__ void ComputeFeatures(const float *, const float *, int, int, int, int, float *);
static __global__ void PadFeatures(const float *, int, int, int, int, cufftReal *);

#define cudaSafeCall(x) _cudaSafeCall((x), __LINE__)
#define cufftSafeCall(x) _cufftSafeCall((x), __LINE__)

void _cudaSafeCall (cudaError_t error, int line)
{
    if (cudaSuccess != error)
    {
        printf("%d: %s\n", line, cudaGetErrorString(cudaGetLastError()));
        exit(error);
    }
}

void _cufftSafeCall (cufftResult error, int line)
{
    if (CUFFT_SUCCESS != error)
    {
        const char * msg;
        switch (error)
        {
        case CUFFT_INVALID_PLAN:
            msg = "CUFFT_INVALID_PLAN";
            break;
        case CUFFT_INVALID_VALUE:
            msg = "CUFFT_INVALID_VALUE";
            break;
        case CUFFT_INTERNAL_ERROR:
            msg = "CUFFT_INTERNAL_ERROR";
            break;
        case CUFFT_EXEC_FAILED:
            msg = "CUFFT_EXEC_FAILED";
            break;
        case CUFFT_SETUP_FAILED:
            msg = "CUFFT_SETUP_FAILED";
            break;
        case CUFFT_UNALIGNED_DATA:
            msg = "CUFFT_UNALIGNED_DATA";
            break;
        default:
            msg = "unknown";
            break;
        }
        printf("%d: %s\n", line, msg);
        exit(error);
    }
}

struct SVM
{
    uint16_t exemplar_id;
    uint16_t width;
    uint16_t height;
    uint16_t bins;
    std::vector<float> w;
    float b;
};

int main (int argc, char ** argv)
{
    boost::timer timer;

    if (argc < 4)
    {
        std::cout << "Usage: " << argv[0] << " [image] [svms].gz [result].gz" << std::endl;
        exit (0);
    }

    std::string imageFilename (argv[1]);
    std::string svmFilename (argv[2]);
    std::string outputFilename (argv[3]);

    /***** Load image *****/
    std::cout << "Load image: " << std::flush;
    timer.restart();
    fipImage originalImage;
    originalImage.load(imageFilename.c_str());
    std::cout << timer.elapsed() << std::endl;
    /**********/

    /***** Load SVMs *****/
    std::cout << "Load SVMs: " << std::flush;
    timer.restart();
    std::ifstream file(svmFilename.c_str(), std::ios_base::in | std::ios_base::binary);
    boost::iostreams::filtering_streambuf<boost::iostreams::input> in;
    in.push(boost::iostreams::gzip_decompressor());
    in.push(file);
    std::istream incoming(&in);
    std::vector<SVM> svms;
    int total_coeff = 0;
    uint16_t largest_filter_width = 0;
    uint16_t largest_filter_height = 0;
    while (true)
    {
        SVM svm;
        incoming.read((char*)&svm.exemplar_id, sizeof(uint16_t));
        if (!incoming) break;
        incoming.read((char*)&svm.width, sizeof(uint16_t));
        assert(incoming);
        incoming.read((char*)&svm.height, sizeof(uint16_t));
        assert(incoming);
        incoming.read((char*)&svm.bins, sizeof(uint16_t));
        assert(incoming);
        assert(svm.bins == 31);
        largest_filter_width = std::max(largest_filter_width, svm.width);
        largest_filter_height = std::max(largest_filter_height, svm.height);
        
        svm.w.resize(svm.width*svm.height*svm.bins);
        total_coeff += svm.w.size();
        incoming.read((char*)&svm.w[0], svm.width*svm.height*svm.bins*sizeof(float));
        assert(incoming);
        incoming.read((char*)&svm.b, sizeof(float));
        assert(incoming);
        svms.push_back (svm);

        #if 0
        if (svms.size() == 20)
            break;
        #endif
        #if 0
        std::cout << svm.exemplar_id << " " << svm.width << " " << svm.height << " " << svm.bins << std::endl;
        #endif
    }
    file.close();
    std::cout << timer.elapsed() << " seconds" << std::endl;
    /**********/
    
    /***** Prepare output *****/
    boost::iostreams::filtering_ostream out;
    out.push(boost::iostreams::gzip_compressor());
    out.push(boost::iostreams::file_sink(outputFilename.c_str(), std::ios_base::binary));

    /***** Copy filters to GPU *****/
    std::cout << "Copy filters to GPU: " << std::flush;
    timer.restart();
    float * d_filter_big;
    cudaSafeCall(cudaMalloc((void**)&d_filter_big, sizeof(float)*total_coeff));

    float * h_filter_big;
    cudaSafeCall(cudaMallocHost((void**)&h_filter_big, sizeof(float)*total_coeff));
    int index = 0;
    for (std::vector<SVM>::const_iterator j = svms.begin(); j != svms.end(); ++j)
    {
        int size = j->w.size();
        memcpy(h_filter_big + index, &j->w[0], size*sizeof(float));
        index += size;
    }
    cudaSafeCall(cudaMemcpy(d_filter_big, h_filter_big, sizeof(float)*total_coeff, cudaMemcpyHostToDevice));
    cudaSafeCall(cudaFreeHost(h_filter_big));
    std::cout << timer.elapsed() << " seconds" << std::endl;
    /*********/

    /***** FOREACH scale *****/
    for (int i = 0; i < 200; ++i)
    {
        float scaler = 1.f/pow(pow(2.f, 1.f/10.f), i);
        if (scaler < 0.01f) break;
        fipImage image(originalImage);
        std::cout << "Scale: " << scaler << std::endl;
        timer.restart();
        std::cout << "Rescale image: " << std::flush;
        image.rescale(originalImage.getWidth()*scaler, originalImage.getHeight()*scaler, FILTER_BILINEAR);
        std::cout << timer.elapsed() << std::endl;
        std::cout << image.getWidth() << " " << image.getHeight() << " " << image.getScanWidth() << " " << (image.isGrayscale() ? "Grayscale" : "Color" ) << std::endl;

        /***** Convert to floating point color *****/
        timer.restart();
        std::cout << "Convert image: " << std::flush;
        unsigned char * d_byte_image;
        float3 * d_color_float_image;
        int srcImageSize = image.getScanWidth()*image.getHeight();
        cudaSafeCall(cudaMalloc((void**)&d_byte_image, srcImageSize));
        int dstImageSize = image.getWidth()*image.getHeight();
        cudaSafeCall(cudaMalloc((void**)&d_color_float_image, dstImageSize*sizeof(float3)));
        cudaSafeCall(cudaMemcpy(d_byte_image, image.accessPixels(), srcImageSize, cudaMemcpyHostToDevice));

        FormatImage<<<32, 256>>>(
            d_byte_image, 
            d_color_float_image,
            image.getWidth(), 
            image.getHeight(),
            image.getScanWidth(),
            image.isGrayscale());
        cudaSafeCall(cudaThreadSynchronize());
        cudaSafeCall(cudaGetLastError());
        cudaSafeCall(cudaFree(d_byte_image));
        std::cout << timer.elapsed() << std::endl;

        #if 0
        std::vector<float3> h_color_float_image (dstImageSize);
        cudaSafeCall(cudaMemcpy(&h_color_float_image[0], d_color_float_image, h_color_float_image.size()*sizeof(float3), cudaMemcpyDeviceToHost));
        std::ofstream outImage ("color_float_dump");
        std::cout << h_color_float_image.size() << std::endl;
        outImage.write((const char *)&h_color_float_image[0], h_color_float_image.size()*sizeof(float3));
        exit(0);
        #endif
        /**********/

        /***** Compute Pedro features *****/
        timer.restart();
        std::cout << "Compute features: " << std::flush;
        const int sbin = 8;

        // memory for caching orientation histograms & their norms
        int blocks_x = (int)round((float)image.getWidth()/sbin);
        int blocks_y = (int)round((float)image.getHeight()/sbin);
        float *d_hist, *d_norm;
        cudaSafeCall(cudaMalloc((void**)&d_hist, blocks_x*blocks_y*18*sizeof(float)));

        Zero<<<32, 256>>>(blocks_x*blocks_y*18, d_hist);
        cudaSafeCall(cudaThreadSynchronize());
        cudaSafeCall(cudaGetLastError());

        cudaSafeCall(cudaMalloc((void**)&d_norm, blocks_x*blocks_y*sizeof(float)));

        Zero<<<32, 256>>>(blocks_x*blocks_y, d_norm);
        cudaSafeCall(cudaThreadSynchronize());
        cudaSafeCall(cudaGetLastError());

        // memory for HOG features
        int feat_x = std::max(blocks_x-2, 0);
        int feat_y = std::max(blocks_y-2, 0);
        int feat_bins = 27+4;
        float *d_feat;
        cudaSafeCall(cudaMalloc((void**)&d_feat, feat_x*feat_y*feat_bins*sizeof(float)));

        Zero<<<32, 256>>>(feat_x*feat_y*feat_bins, d_feat);
        cudaSafeCall(cudaThreadSynchronize());
        cudaSafeCall(cudaGetLastError());


        int visible_x = blocks_x*sbin;
        int visible_y = blocks_y*sbin;

        ComputeHistograms<<<32, 256>>>(
            d_color_float_image,
            image.getWidth(),
            image.getHeight(), 
            visible_x,
            visible_y,
            blocks_x,
            blocks_y,
            d_hist);
        cudaSafeCall(cudaThreadSynchronize());
        cudaSafeCall(cudaGetLastError());
        cudaSafeCall(cudaFree(d_color_float_image));

        #if 0
        std::vector<float> h_hist (blocks_x*blocks_y*18);
        cudaSafeCall(cudaMemcpy(&h_hist[0], d_hist, h_hist.size()*sizeof(float), cudaMemcpyDeviceToHost));
        std::ofstream histDump ("hist_dump");
        std::cout << blocks_x << " " << blocks_y << " 18" << std::endl;
        histDump.write((const char *)&h_hist[0], h_hist.size()*sizeof(float));
        exit(0);
        #endif

        ComputeEnergy<<<32, 256>>>(
            d_hist,
            blocks_x,
            blocks_y,
            d_norm);
        cudaSafeCall(cudaThreadSynchronize());
        cudaSafeCall(cudaGetLastError());

        #if 0
        std::vector<float> h_norm (blocks_x*blocks_y);
        cudaSafeCall(cudaMemcpy(&h_norm[0], d_norm, h_norm.size()*sizeof(float), cudaMemcpyDeviceToHost));
        std::ofstream normDump ("norm_dump");
        std::cout << blocks_x << " " << blocks_y << std::endl;
        normDump.write((const char *)&h_norm[0], h_norm.size()*sizeof(float));
        exit(0);
        #endif

        ComputeFeatures<<<32, 256>>>(
            d_hist,
            d_norm,
            blocks_x,
            blocks_y,
            feat_x,
            feat_y,
            d_feat);
        cudaSafeCall(cudaThreadSynchronize());
        cudaSafeCall(cudaGetLastError());
        cudaSafeCall(cudaFree(d_hist));
        cudaSafeCall(cudaFree(d_norm));
        std::cout << timer.elapsed() << std::endl;

        #if 0
        std::vector<float> h_feat (feat_x*feat_y*feat_bins);
        cudaSafeCall(cudaMemcpy(&h_feat[0], d_feat, h_feat.size()*sizeof(float), cudaMemcpyDeviceToHost));
        std::ofstream featDump ("feat_dump");
        std::cout << feat_x << " " << feat_y << " " << feat_bins << std::endl;
        featDump.write((const char *)&h_feat[0], h_feat.size()*sizeof(float));
        exit(0);
        #endif
        /**********/

        std::cout << "Features: (" << feat_x << ", " << feat_y << ")" << std::endl;

        int pad_x = 1;
        while (feat_x+largest_filter_width > pad_x) pad_x <<= 1;
        int pad_y = 1;
        while (feat_y+largest_filter_height > pad_y) pad_y <<= 1;

        std::cout << "Padded features: (" << pad_x << ", " << pad_y << ")" << std::endl;
        
        cufftReal * d_feat_pad;
        cudaSafeCall(cudaMalloc((void**)&d_feat_pad, pad_x*pad_y*feat_bins*sizeof(cufftReal)));

        dim3 pad_block;
        pad_block.x = 16;
        pad_block.y = 16;
        pad_block.z = 1;
        dim3 pad_grid;
        pad_grid.x = ceil((float)pad_x/pad_block.x);
        pad_grid.y = ceil((float)pad_y/pad_block.y);
        pad_grid.z = ceil((float)feat_bins/pad_block.z);
        PadFeatures<<<pad_grid, pad_block>>>(
            d_feat,
            feat_x,
            feat_y,
            pad_x,
            pad_y,
            d_feat_pad);
        cudaSafeCall(cudaThreadSynchronize());
        cudaSafeCall(cudaGetLastError());
        cudaSafeCall(cudaFree(d_feat));

        #if 0
        std::vector<cufftReal> h_feat_pad (pad_x*pad_y*feat_bins);
        cudaSafeCall(cudaMemcpy(&h_feat_pad[0], d_feat_pad, h_feat_pad.size()*sizeof(cufftReal), cudaMemcpyDeviceToHost));
        std::ofstream featPadDump ("feat_pad_dump");
        std::cout << pad_x << " " << pad_y << " " << feat_bins << std::endl;
        featPadDump.write((const char *)&h_feat_pad[0], h_feat_pad.size()*sizeof(cufftReal));
        exit(0);
        #endif

        /***** Apply FFT to input image *****/
        cufftHandle planForward, planInverse;
        int n[2] = {pad_x, pad_y};
        timer.restart();
        std::cout << "FFT on input image features: " << std::flush;
        cufftSafeCall(cufftPlanMany(&planForward, 2, n, NULL, 1, 0, NULL, 1, 0, CUFFT_R2C, feat_bins));
        cufftSafeCall(cufftSetCompatibilityMode(planForward, CUFFT_COMPATIBILITY_NATIVE));
        cufftSafeCall(cufftPlanMany(&planInverse, 2, n, NULL, 1, 0, NULL, 1, 0, CUFFT_C2R, feat_bins));
        cufftSafeCall(cufftSetCompatibilityMode(planInverse, CUFFT_COMPATIBILITY_NATIVE));
        cufftComplex * d_feat_freq;
        // Note: for R2C CUFFT only stores non-redundant complex coefficients
        cudaSafeCall(cudaMalloc((void**)&d_feat_freq, sizeof(cufftComplex)*pad_x*(pad_y/2+1)*feat_bins));
        cufftSafeCall(cufftExecR2C(planForward, d_feat_pad, d_feat_freq));
        cudaSafeCall(cudaThreadSynchronize());
        cudaSafeCall(cudaGetLastError());
        cudaSafeCall(cudaFree(d_feat_pad));
        std::cout << timer.elapsed() << " seconds" << std::endl;

        #if 0
        std::vector<cufftComplex> h_feat_freq (pad_x*(pad_y/2+1)*feat_bins);
        cudaSafeCall(cudaMemcpy(&h_feat_freq[0], d_feat_freq, h_feat_freq.size()*sizeof(cufftComplex), cudaMemcpyDeviceToHost));
        std::ofstream featFreqDump ("feat_freq_dump");
        std::cout << pad_x << " " << pad_y << " " << feat_bins << std::endl;
        featFreqDump.write((const char *)&h_feat_freq[0], h_feat_freq.size()*sizeof(cufftComplex));
        exit(0);
        #endif
        /**********/

        /***** FOREACH SVM *****/
        cufftComplex * d_filter_freq;
        cudaSafeCall(cudaMalloc((void**)&d_filter_freq, sizeof(cufftComplex)*pad_x*(pad_y/2+1)*feat_bins));

        cufftReal * d_filter_padded;
        cudaSafeCall(cudaMalloc((void**)&d_filter_padded, sizeof(cufftReal)*feat_bins*pad_x*pad_y));

        cufftReal * d_result;
        cudaSafeCall(cudaMalloc((void**)&d_result, sizeof(cufftReal)*pad_x*pad_y));

        uint8_t * h_result;
        cudaSafeCall(cudaMallocHost(&h_result, (feat_x*feat_y*sizeof(float) + sizeof(uint16_t) + sizeof(float) + 2*sizeof(uint16_t))*svms.size()));
        int result_index = 0;

        float * d_filter = d_filter_big;
        for (std::vector<SVM>::const_iterator j = svms.begin(); j != svms.end(); ++j)
        {
            int size = j->w.size();
            int crop_x = feat_x - j->width + 1;
            int crop_y = feat_y - j->height + 1;
 
            // Image too small for filter
            if (crop_x <= 0 || crop_y <= 0)
            {
                return 0;
            }
        //    std::cout << j - svms.begin() << std::endl;
            //cudaSafeCall(cudaMemcpy(d_filter, &j->w[0], sizeof(float)*j->w.size(), cudaMemcpyHostToDevice));

            PadFeatures<<<pad_grid, pad_block>>>(
                d_filter,
                j->width,
                j->height,
                pad_x,
                pad_y,
                d_filter_padded);

            #if 0
            std::vector<cufftReal> h_filter_pad (pad_x*pad_y*feat_bins);
            cudaSafeCall(cudaMemcpy(&h_filter_pad[0], d_filter_padded, h_filter_pad.size()*sizeof(cufftReal), cudaMemcpyDeviceToHost));
            std::ofstream filterPadDump ("filter_pad_dump");
            std::cout << pad_x << " " << pad_y << " " << feat_bins << std::endl;
            filterPadDump.write((const char *)&h_filter_pad[0], h_filter_pad.size()*sizeof(cufftReal));
            exit(0);
            #endif

            int init_block;
            init_block = 512;
            int init_grid;
            init_grid = ceil((float)crop_x*crop_y/init_block);
            Init<<<init_grid, init_block>>>(
                -j->b,
                crop_x*crop_y,
                d_result);
          
            cufftSafeCall(cufftExecR2C(planForward, d_filter_padded, d_filter_freq));

            #if 0
            std::vector<cufftComplex> h_filter_freq (pad_x*(pad_y/2+1)*feat_bins);
            cudaSafeCall(cudaMemcpy(&h_filter_freq[0], d_filter_freq, h_filter_freq.size()*sizeof(cufftComplex), cudaMemcpyDeviceToHost));
            std::ofstream filterFreqDump ("filter_freq_dump");
            std::cout << pad_x << " " << pad_y << " " << feat_bins << std::endl;
            filterFreqDump.write((const char *)&h_filter_freq[0], h_filter_freq.size()*sizeof(cufftComplex));
            exit(0);
            #endif

            int pointwise_block;
            pointwise_block = 512; 
            int pointwise_grid;
            pointwise_grid = ceil((float)(pad_x*(pad_y/2+1)*feat_bins)/pointwise_block);
            PointwiseMulConj<<<pointwise_grid, pointwise_block>>>(
                d_filter_freq, 
                d_feat_freq, 
                pad_x*(pad_y/2+1)*feat_bins);

            #if 0
            std::vector<cufftComplex> h_pointwise (pad_x*(pad_y/2+1)*feat_bins);
            cudaSafeCall(cudaMemcpy(&h_pointwise[0], d_filter_freq, h_pointwise.size()*sizeof(cufftComplex), cudaMemcpyDeviceToHost));
            std::ofstream pointwiseDump ("pointwise_dump");
            std::cout << pad_y/2+1 << " " << pad_x << " " << feat_bins << std::endl;
            pointwiseDump.write((const char *)&h_pointwise[0], h_pointwise.size()*sizeof(cufftComplex));
            exit(0);
            #endif

            cufftSafeCall(cufftExecC2R(planInverse, d_filter_freq, d_filter_padded));

            #if 0
            std::vector<cufftReal> h_conv (pad_x*pad_y*feat_bins);
            cudaSafeCall(cudaMemcpy(&h_conv[0], d_filter_padded, h_conv.size()*sizeof(cufftReal), cudaMemcpyDeviceToHost));
            std::ofstream convDump ("conv_dump");
            std::cout << pad_x << " " << pad_y << " " << feat_bins << std::endl;
            convDump.write((const char *)&h_conv[0], h_conv.size()*sizeof(cufftReal));
            exit(0);
            #endif

            // Result of IFFT in CUFFT needs to be divided by M*N
            dim3 accum_block;
            accum_block.x = 4;
            accum_block.y = 4;
            accum_block.z = 32;
            dim3 accum_grid;
            accum_grid.x = ceil((float)crop_x/accum_block.x);
            accum_grid.y = ceil((float)crop_y/accum_block.y);
            accum_grid.z = ceil((float)feat_bins/accum_block.z);
            CropScaleAccum<<<accum_grid, accum_block>>>(
                d_filter_padded,
                crop_x,
                crop_y,
                pad_x,
                pad_y,
                d_result);
   
            #if 0
            std::vector<cufftReal> h_result (crop_x*crop_y);
            cudaSafeCall(cudaMemcpy(&h_result[0], d_result, h_result.size()*sizeof(cufftReal), cudaMemcpyDeviceToHost));
            std::ofstream resultDump ("result_dump");
            std::cout << crop_x << " " << crop_y << std::endl;
            resultDump.write((const char *)&h_result[0], h_result.size()*sizeof(cufftReal));
            exit(0);
            #endif

            int threshold_block;
            threshold_block = 512;
            int threshold_grid;
            threshold_grid = ceil((float)crop_x*crop_y/threshold_block);
            Threshold<<<threshold_grid, threshold_block>>>(
                -1,
                crop_x*crop_y,
                d_result);
      
            uint16_t crop_x_out = crop_x;
            uint16_t crop_y_out = crop_y;
            memcpy(h_result+result_index, &j->exemplar_id, sizeof(uint16_t));
            result_index += sizeof(uint16_t);
            memcpy(h_result+result_index, &scaler, sizeof(float));
            result_index += sizeof(float);
            memcpy(h_result+result_index, &crop_y_out, sizeof(uint16_t));
            result_index += sizeof(uint16_t);
            memcpy(h_result+result_index, &crop_x_out, sizeof(uint16_t));
            result_index += sizeof(uint16_t);
            cudaSafeCall(cudaMemcpyAsync(h_result+result_index, d_result, crop_x*crop_y*sizeof(cufftReal), cudaMemcpyDeviceToHost));
            result_index += crop_x*crop_y*sizeof(cufftReal);

            #if 0
            out.write((const char*)&scaler, sizeof(float));
            out.write((const char*)&crop_y_out, sizeof(uint16_t));
            out.write((const char*)&crop_x_out, sizeof(uint16_t));
            out.write((const char*)&h_result[0], h_result.size()*sizeof(cufftReal));
            #endif

            d_filter += size;

        }
        /***** Free memory for image features and freq transform *****/ 
        cudaSafeCall(cudaFree(d_filter_padded));
        cudaSafeCall(cudaFree(d_filter_freq));
        cufftSafeCall(cufftDestroy(planForward));
        cufftSafeCall(cufftDestroy(planInverse));
        cudaSafeCall(cudaFree(d_feat_freq));

        cudaSafeCall(cudaDeviceSynchronize());
        out.write((const char*)h_result, result_index);
        cudaSafeCall(cudaFreeHost(h_result));
        #if 0
        break;
        #endif
    }
    cudaSafeCall(cudaFree(d_filter_big));

    return 0;
}

static __global__ void PointwiseMulConj(cufftComplex* a, const cufftComplex* b, int size)
{
    const int threadID = blockIdx.x * blockDim.x + threadIdx.x;
    if (threadID >= size) return;
        
    cufftComplex a_local = a[threadID];
    cufftComplex b_local = b[threadID];
    a[threadID].x = a_local.x * b_local.x + a_local.y * b_local.y;
    a[threadID].y = a_local.x * b_local.y - a_local.y * b_local.x;
}

static __global__ void CropScaleAccum(const cufftReal* a, int crop_x, int crop_y, int pad_x, int pad_y, cufftReal * accum) 
{
    const int threadID_x = blockIdx.x * blockDim.x + threadIdx.x;
    const int threadID_y = blockIdx.y * blockDim.y + threadIdx.y;
    const int threadID_z = blockIdx.z * blockDim.z + threadIdx.z;

    int y = threadID_y;
    int x = threadID_x;
    int bin = threadID_z;

    if (y >= crop_y || x >= crop_x || bin >= 31) return;

    int i = bin*pad_x*pad_y + x*pad_y + y;
    int j = x*crop_y + y;
        
    atomicAdd(accum + j, a[i]/(pad_x*pad_y));
}

static __global__ void Zero(int size, float * buf)
{
    const int numThreads = blockDim.x * gridDim.x;
    const int threadID = blockIdx.x * blockDim.x + threadIdx.x;
    for (int i = threadID; i < size; i += numThreads)
    {
        buf[i] = 0.f;
    }
}

static __global__ void Init(float value, int size, float * buf)
{
    const int threadID = blockIdx.x * blockDim.x + threadIdx.x;
    if(threadID >= size) return;
    buf[threadID] = value;
}

static __global__ void Threshold(float value, int size, float * buf)
{
    const int threadID = blockIdx.x * blockDim.x + threadIdx.x;
    if(threadID >= size) return;
    float prev = buf[threadID];
    buf[threadID] = prev < value ? value : prev;
}

static __global__ void FormatImage(const unsigned char * byte_image, float3 * color_float_image, int width, int height, int line, bool grayscale)
{
    const int numThreads = blockDim.x * gridDim.x;
    const int threadID = blockIdx.x * blockDim.x + threadIdx.x;

    int size = height*line;
    for (int i = threadID; i < size; i += numThreads)
    {
        int x = i % line;
        int y = i / line;

        if (!grayscale && x%3) continue;

        if (!grayscale) x /= 3;

        if (x >= width) continue;;
        int j = x*height + (height - 1 - y);

        color_float_image[j].x = (grayscale ? byte_image[i] : byte_image[i])/255.f;
        color_float_image[j].y = (grayscale ? byte_image[i] : byte_image[i+1])/255.f;
        color_float_image[j].z = (grayscale ? byte_image[i] : byte_image[i+2])/255.f;
    }
}

static __global__ void ComputeHistograms(const float3 * color_float_image, int width, int height, int visible_x, int visible_y, int blocks_x, int blocks_y, float * hist)
{
    const int numThreads = blockDim.x * gridDim.x;
    const int threadID = blockIdx.x * blockDim.x + threadIdx.x;

    const float uu[9] = {1.0000f, 0.9397f, 0.7660f, 0.500f, 0.1736f, -0.1736f, -0.5000f, -0.7660f, -0.9397f};
    const float vv[9] = {0.0000f, 0.3420f, 0.6428f, 0.8660f, 0.9848f, 0.9848f, 0.8660f, 0.6428f, 0.3420f};

    const int sbin = 8;

    const int size = visible_x*visible_y;
    for (int i = threadID; i < size; i += numThreads)
    {
        int x = i / visible_y;
        int y = i % visible_y;

        if (x == 0 || y == 0 || x >= visible_x-1 || y >= visible_y-1)
            continue;

        const float3 * s = color_float_image + min(x,width-2)*height + min(y,height-2);
        float3 dy = *(s+1) - *(s-1);
        float3 dx = *(s+height) - *(s-height);
        float3 v = dx*dx + dy*dy;

        // pick channel with strongest gradient
        float v_max = v.x;
        float dx_max = dx.x;
        float dy_max = dy.x;
        if (v.y > v_max)
        {
            v_max = v.y;
            dx_max = dx.y;
            dy_max = dy.y;
        }
        if (v.z > v_max)
        {
            v_max = v.z;
            dx_max = dx.z;
            dy_max = dy.z;
        }

        // snap to one of 18 orientations
        float best_dot = 0.f;
        int best_o = 0;
        for (int o = 0; o < 9; ++o)
        {
            float dot = uu[o]*dx_max + vv[o]*dy_max;
            if (dot > best_dot)
            {
                best_dot = dot;
                best_o = o;
            }
            else if (-dot > best_dot)
            {
                best_dot = -dot;
                best_o = o+9;
            }
        }

        // snap to one of 18 orientations
        float xp = ((float)x+0.5f)/sbin - 0.5f;
        float yp = ((float)y+0.5f)/sbin - 0.5f;
        int ixp = (int)floor(xp);
        int iyp = (int)floor(yp);
        float vx0 = xp-ixp;
        float vy0 = yp-iyp;
        float vx1 = 1.f - vx0;
        float vy1 = 1.f - vy0;
        v_max = sqrt(v_max);

        if (ixp >= 0 && iyp >= 0)
            atomicAdd(hist + ixp*blocks_y + iyp + best_o*blocks_x*blocks_y, vx1*vy1*v_max);

        if (ixp+1 < blocks_x && iyp >= 0)
            atomicAdd(hist + (ixp+1)*blocks_y + iyp + best_o*blocks_x*blocks_y, vx0*vy1*v_max);

        if (ixp >= 0 && iyp+1 < blocks_y)
            atomicAdd(hist + ixp*blocks_y + (iyp+1) + best_o*blocks_x*blocks_y, vx1*vy0*v_max);

        if (ixp+1 < blocks_x && iyp+1 < blocks_y)
            atomicAdd(hist + (ixp+1)*blocks_y + (iyp+1) + best_o*blocks_x*blocks_y, vx0*vy0*v_max); 
    }
}

static __global__ void ComputeEnergy(const float * hist, int blocks_x, int blocks_y, float * norm)
{
    const int numThreads = blockDim.x * gridDim.x;
    const int threadID = blockIdx.x * blockDim.x + threadIdx.x;

    // compute energy in each block by summing over orientations
    for (int o = threadID; o < 9; o += numThreads)
    {
        const float * src1 = hist + o*blocks_x*blocks_y;
        const float * src2 = hist + (o+9)*blocks_x*blocks_y;
        float * dst = norm;
        float * end = norm + blocks_x*blocks_y;
        while (dst < end)
        {
            atomicAdd(dst, (*src1 + *src2) * (*src1 + *src2));
            ++dst;
            ++src1;
            ++src2;
        }
    }
}

static __global__ void ComputeFeatures(const float * hist, const float * norm, int blocks_x, int blocks_y, int feat_x, int feat_y, float * feat)
{
    const int numThreads = blockDim.x * gridDim.x;
    const int threadID = blockIdx.x * blockDim.x + threadIdx.x;

    const float eps = 0.0001f;

    const int feats = feat_x*feat_y;
    for (int i = threadID; i < feats; i += numThreads)
    {
        int x = i / feat_y;
        int y = i % feat_y;

        float * dst = feat + x*feat_y + y;
        const float *src, *p;
        float n1, n2, n3, n4;

        p = norm + (x+1)*blocks_y + y+1;
        n1 = 1.f / sqrt(*p + *(p+1) + *(p+blocks_y) + *(p + blocks_y+1) + eps);
        p = norm + (x+1)*blocks_y + y;
        n2 = 1.f / sqrt(*p + *(p+1) + *(p+blocks_y) + *(p + blocks_y+1) + eps);
        p = norm + x*blocks_y + y+1;
        n3 = 1.f / sqrt(*p + *(p+1) + *(p+blocks_y) + *(p + blocks_y+1) + eps);
        p = norm + x*blocks_y + y;
        n4 = 1.f / sqrt(*p + *(p+1) + *(p+blocks_y) + *(p + blocks_y+1) + eps);

        float t1 = 0.f;
        float t2 = 0.f;
        float t3 = 0.f;
        float t4 = 0.f;

        // contrast-sensitive features
        src = hist + (x+1)*blocks_y + (y+1);
        for (int o = 0; o < 18; ++o)
        {
            float h1 = min(*src * n1, 0.2f);
            float h2 = min(*src * n2, 0.2f);
            float h3 = min(*src * n3, 0.2f);
            float h4 = min(*src * n4, 0.2f);
            *dst = 0.5f * (h1 + h2 + h3 + h4);
            t1 += h1;
            t2 += h2;
            t3 += h3;
            t4 += h4;
            dst += feat_x*feat_y;
            src += blocks_x*blocks_y;
        }

        // contrast-insensitive features
        src = hist + (x+1)*blocks_y + (y+1);
        for (int o = 0; o < 9; ++o)
        {
            float sum = *src + *(src + 9*blocks_x*blocks_y);
            float h1 = min(sum * n1, 0.2f);
            float h2 = min(sum * n2, 0.2f);
            float h3 = min(sum * n3, 0.2f);
            float h4 = min(sum * n4, 0.2f);
            *dst = 0.5f * (h1 + h2 + h3 + h4);
            dst += feat_x*feat_y;
            src += blocks_x*blocks_y;
        }

        // texture features
        *dst = 0.2357f * t1;
        dst += feat_x*feat_y;
        *dst = 0.2357f * t2;
        dst += feat_x*feat_y;
        *dst = 0.2357f * t3;
        dst += feat_x*feat_y;
        *dst = 0.2357f * t4;
    }
}

static __global__ void PadFeatures(const float * feat, int feat_x, int feat_y, int pad_x, int pad_y, cufftReal * feat_pad)
{
    const int threadID_x = blockIdx.x * blockDim.x + threadIdx.x;
    const int threadID_y = blockIdx.y * blockDim.y + threadIdx.y;
    const int threadID_z = blockIdx.z * blockDim.z + threadIdx.z;

    int x = threadID_x;
    int y = threadID_y;
    int bin = threadID_z;

    int i = bin*pad_x*pad_y + x*pad_y + y;
    int j = bin*feat_x*feat_y + x*feat_y + y;

    feat_pad[i] = (x >= feat_x || y >= feat_y) ? 0.f : feat[j];
}
