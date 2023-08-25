#include "debug_utils.cuh"
#include "gaussian.cuh"
#include "read_utils.cuh"
#include <ATen/cuda/CUDAContext.h>
#include <c10/cuda/CUDAGuard.h>
#include <exception>
#include <thread>

GaussianModel::GaussianModel(int sh_degree) : _max_sh_degree(sh_degree) {
    cudaStreamCreate(&_stream1);
    cudaStreamCreate(&_stream2);
    cudaStreamCreate(&_stream3);
    cudaStreamCreate(&_stream4);
    cudaStreamCreate(&_stream5);
    cudaStreamCreate(&_stream6);
}

GaussianModel::~GaussianModel() {
    std::cout << "GaussianModel::~GaussianModel()" << std::endl;
    cudaStreamDestroy(_stream1);
    cudaStreamDestroy(_stream2);
    cudaStreamDestroy(_stream3);
    cudaStreamDestroy(_stream4);
    cudaStreamDestroy(_stream5);
    cudaStreamDestroy(_stream6);
}
torch::Tensor GaussianModel::Get_covariance(float scaling_modifier) {
    auto L = build_scaling_rotation(scaling_modifier * Get_scaling(), _rotation);
    auto actual_covariance = torch::mm(L, L.transpose(1, 2));
    auto symm = strip_symmetric(actual_covariance);
    return symm;
}

/**
 * @brief Fetches the features of the Gaussian model
 *
 * This function concatenates _features_dc and _features_rest along the second dimension.
 *
 * @return Tensor of the concatenated features
 */
torch::Tensor GaussianModel::Get_features() const {
    auto features_dc = _features_dc;
    auto features_rest = _features_rest;
    return torch::cat({features_dc, features_rest}, 1);
}

/**
 * @brief Increment the SH degree by 1
 *
 * This function increments the active_sh_degree by 1, up to a maximum of max_sh_degree.
 */
void GaussianModel::One_up_sh_degree() {
    if (_active_sh_degree < _max_sh_degree) {
        _active_sh_degree++;
    }
}

/**
 * @brief Initialize Gaussian Model from a Point Cloud.
 *
 * This function creates a Gaussian model from a given PointCloud object. It also sets
 * the spatial learning rate scale. The model's features, scales, rotations, and opacities
 * are initialized based on the input point cloud.
 *
 * @param pcd The input point cloud
 * @param spatial_lr_scale The spatial learning rate scale
 */
void GaussianModel::Create_from_pcd(PointCloud& pcd, float spatial_lr_scale) {
    _spatial_lr_scale = spatial_lr_scale;

    const auto pointType = torch::TensorOptions().dtype(torch::kFloat32);
    _xyz = torch::from_blob(pcd._points.data(), {static_cast<long>(pcd._points.size()), 3}, pointType).to(torch::kCUDA).set_requires_grad(true);
    auto dist2 = torch::clamp_min(distCUDA2(_xyz), 0.0000001);
    _scaling = torch::log(torch::sqrt(dist2)).unsqueeze(-1).repeat({1, 3}).to(torch::kCUDA, true).set_requires_grad(true);
    _rotation = torch::zeros({_xyz.size(0), 4}).index_put_({torch::indexing::Slice(), 0}, 1).to(torch::kCUDA, true).set_requires_grad(true);
    _opacity = inverse_sigmoid(0.5 * torch::ones({_xyz.size(0), 1})).to(torch::kCUDA, true).set_requires_grad(true);
    _max_radii2D = torch::zeros({_xyz.size(0)}).to(torch::kCUDA, true);

    // colors
    auto colorType = torch::TensorOptions().dtype(torch::kUInt8);
    auto fused_color = RGB2SH(torch::from_blob(pcd._colors.data(), {static_cast<long>(pcd._colors.size()), 3}, colorType).to(pointType) / 255.f).to(torch::kCUDA);

    // features
    auto features = torch::zeros({fused_color.size(0), 3, static_cast<long>(std::pow((_max_sh_degree + 1), 2))}).to(torch::kCUDA);
    features.index_put_({torch::indexing::Slice(), torch::indexing::Slice(torch::indexing::None, 3), 0}, fused_color);
    features.index_put_({torch::indexing::Slice(), torch::indexing::Slice(3, torch::indexing::None), torch::indexing::Slice(1, torch::indexing::None)}, 0.0);
    _features_dc = features.index({torch::indexing::Slice(), torch::indexing::Slice(), torch::indexing::Slice(0, 1)}).transpose(1, 2).contiguous().set_requires_grad(true);
    _features_rest = features.index({torch::indexing::Slice(), torch::indexing::Slice(), torch::indexing::Slice(1, torch::indexing::None)}).transpose(1, 2).contiguous().set_requires_grad(true);
}

/**
 * @brief Setup the Gaussian Model for training
 *
 * This function sets up the Gaussian model for training by initializing several
 * parameters and settings based on the provided OptimizationParameters object.
 *
 * @param params The OptimizationParameters object providing the settings for training
 */
void GaussianModel::Training_setup(const OptimizationParameters& params) {
    this->_percent_dense = params.percent_dense;
    this->_xyz_gradient_accum = torch::zeros({this->_xyz.size(0), 1}).to(torch::kCUDA);
    this->_denom = torch::zeros({this->_xyz.size(0), 1}).to(torch::kCUDA);
    this->_xyz_scheduler_args = Expon_lr_func(params.position_lr_init * this->_spatial_lr_scale,
                                              params.position_lr_final * this->_spatial_lr_scale,
                                              params.position_lr_delay_mult,
                                              params.position_lr_max_steps);

    std::vector<torch::optim::OptimizerParamGroup> optimizer_params_groups;
    optimizer_params_groups.reserve(6);
    optimizer_params_groups.push_back(torch::optim::OptimizerParamGroup({_xyz}, std::make_unique<torch::optim::AdamOptions>(params.position_lr_init * this->_spatial_lr_scale)));
    optimizer_params_groups.push_back(torch::optim::OptimizerParamGroup({_features_dc}, std::make_unique<torch::optim::AdamOptions>(params.feature_lr)));
    optimizer_params_groups.push_back(torch::optim::OptimizerParamGroup({_features_rest}, std::make_unique<torch::optim::AdamOptions>(params.feature_lr / 20.)));
    optimizer_params_groups.push_back(torch::optim::OptimizerParamGroup({_scaling}, std::make_unique<torch::optim::AdamOptions>(params.scaling_lr * this->_spatial_lr_scale)));
    optimizer_params_groups.push_back(torch::optim::OptimizerParamGroup({_rotation}, std::make_unique<torch::optim::AdamOptions>(params.rotation_lr)));
    optimizer_params_groups.push_back(torch::optim::OptimizerParamGroup({_opacity}, std::make_unique<torch::optim::AdamOptions>(params.opacity_lr)));

    static_cast<torch::optim::AdamOptions&>(optimizer_params_groups[0].options()).eps(1e-15);
    static_cast<torch::optim::AdamOptions&>(optimizer_params_groups[1].options()).eps(1e-15);
    static_cast<torch::optim::AdamOptions&>(optimizer_params_groups[2].options()).eps(1e-15);
    static_cast<torch::optim::AdamOptions&>(optimizer_params_groups[3].options()).eps(1e-15);
    static_cast<torch::optim::AdamOptions&>(optimizer_params_groups[4].options()).eps(1e-15);
    static_cast<torch::optim::AdamOptions&>(optimizer_params_groups[5].options()).eps(1e-15);

    _optimizer = std::make_unique<torch::optim::Adam>(optimizer_params_groups, torch::optim::AdamOptions(0.f).eps(1e-15));
}

void GaussianModel::Update_learning_rate(float iteration) {
    // This is hacky because you cant change in libtorch individual parameter learning rate
    // xyz is added first, since _optimizer->param_groups() return a vector, we assume that xyz stays first
    auto lr = _xyz_scheduler_args(iteration);
    static_cast<torch::optim::AdamOptions&>(_optimizer->param_groups()[0].options()).set_lr(lr);
}

void GaussianModel::Reset_opacity() {
    // opacitiy activation
    auto new_opacity = inverse_sigmoid(torch::ones_like(_opacity, torch::TensorOptions().dtype(torch::kFloat32)) * 0.01f);

    auto adamParamStates = std::make_unique<torch::optim::AdamParamState>(static_cast<torch::optim::AdamParamState&>(
        *_optimizer->state()[c10::guts::to_string(_optimizer->param_groups()[5].params()[0].unsafeGetTensorImpl())]));

    _optimizer->state().erase(c10::guts::to_string(_optimizer->param_groups()[5].params()[0].unsafeGetTensorImpl()));

    adamParamStates->exp_avg(torch::zeros_like(new_opacity));
    adamParamStates->exp_avg_sq(torch::zeros_like(new_opacity));
    // replace tensor
    _optimizer->param_groups()[5].params()[0] = new_opacity.set_requires_grad(true);
    _opacity = _optimizer->param_groups()[5].params()[0];

    _optimizer->state()[c10::guts::to_string(_optimizer->param_groups()[5].params()[0].unsafeGetTensorImpl())] = std::move(adamParamStates);
}

void prune_optimizer(torch::optim::Adam* optimizer, const torch::Tensor& mask, torch::Tensor& old_tensor, int param_position) {
    auto adamParamStates = std::make_unique<torch::optim::AdamParamState>(static_cast<torch::optim::AdamParamState&>(
        *optimizer->state()[c10::guts::to_string(optimizer->param_groups()[param_position].params()[0].unsafeGetTensorImpl())]));
    optimizer->state().erase(c10::guts::to_string(optimizer->param_groups()[param_position].params()[0].unsafeGetTensorImpl()));

    adamParamStates->exp_avg(adamParamStates->exp_avg().index_select(0, mask));
    adamParamStates->exp_avg_sq(adamParamStates->exp_avg_sq().index_select(0, mask));

    optimizer->param_groups()[param_position].params()[0] = old_tensor.index_select(0, mask).set_requires_grad(true);
    old_tensor = optimizer->param_groups()[param_position].params()[0]; // update old tensor
    optimizer->state()[c10::guts::to_string(optimizer->param_groups()[param_position].params()[0].unsafeGetTensorImpl())] = std::move(adamParamStates);
}

void GaussianModel::prune_points(torch::Tensor mask) {
    // reverse to keep points
    auto valid_point_mask = ~mask;
    int true_count = valid_point_mask.sum().item<int>();
    auto indices = torch::nonzero(valid_point_mask == true).index({torch::indexing::Slice(torch::indexing::None, torch::indexing::None), torch::indexing::Slice(torch::indexing::None, 1)}).squeeze(-1);
    prune_optimizer(_optimizer.get(), indices, _xyz, 0);
    prune_optimizer(_optimizer.get(), indices, _features_dc, 1);
    prune_optimizer(_optimizer.get(), indices, _features_rest, 2);
    prune_optimizer(_optimizer.get(), indices, _scaling, 3);
    prune_optimizer(_optimizer.get(), indices, _rotation, 4);
    prune_optimizer(_optimizer.get(), indices, _opacity, 5);

    _xyz_gradient_accum = _xyz_gradient_accum.index_select(0, indices);
    _denom = _denom.index_select(0, indices);
    _max_radii2D = _max_radii2D.index_select(0, indices);
}

void tensors_to_optimizer_new(torch::optim::Adam* optimizer,
                              torch::Tensor& extended_tensor,
                              torch::Tensor& old_tensor,
                              torch::Tensor& exp_avg,
                              torch::Tensor exp_avg_sq,
                              int param_position) {
    std::cout << "tensors_to_optimizer_new" << std::endl;
    auto adamParamStates = std::make_unique<torch::optim::AdamParamState>(static_cast<torch::optim::AdamParamState&>(
        *optimizer->state()[c10::guts::to_string(optimizer->param_groups()[param_position].params()[0].unsafeGetTensorImpl())]));
    std::cout << "optimizer->state().erase(c10::guts::to_string(optimizer->param_groups()[param_position].params()[0].unsafeGetTensorImpl()))";
    optimizer->state().erase(c10::guts::to_string(optimizer->param_groups()[param_position].params()[0].unsafeGetTensorImpl()));

    std::cout << "exp_avg";
    adamParamStates->exp_avg(exp_avg);
    std::cout << "exp_avg_sq";
    adamParamStates->exp_avg_sq(exp_avg_sq);

    std::cout << "optimizer->param_groups()[param_position].params()[0]";
    optimizer->param_groups()[param_position].params()[0] = extended_tensor.clone().set_requires_grad(true);
    std::cout << "old_tensor";
    old_tensor = optimizer->param_groups()[param_position].params()[0];

    std::cout << "optimizer->state()[c10::guts::to_string(optimizer->param_groups()[param_position].params()[0].unsafeGetTensorImpl())]";
    optimizer->state()[c10::guts::to_string(optimizer->param_groups()[param_position].params()[0].unsafeGetTensorImpl())] = std::move(adamParamStates);
}

void tensors_to_optimizer(torch::optim::Adam* optimizer,
                          torch::Tensor& extended_tensor,
                          torch::Tensor& old_tensor,
                          at::IntArrayRef extension_size,
                          int param_position) {
    auto adamParamStates = std::make_unique<torch::optim::AdamParamState>(static_cast<torch::optim::AdamParamState&>(
        *optimizer->state()[c10::guts::to_string(optimizer->param_groups()[param_position].params()[0].unsafeGetTensorImpl())]));
    optimizer->state().erase(c10::guts::to_string(optimizer->param_groups()[param_position].params()[0].unsafeGetTensorImpl()));

    const auto options = torch::TensorOptions().dtype(torch::kFloat32).device(torch::kCUDA);
    adamParamStates->exp_avg(torch::cat({adamParamStates->exp_avg(), torch::zeros(extension_size, options)}, 0));
    adamParamStates->exp_avg_sq(torch::cat({adamParamStates->exp_avg_sq(), torch::zeros(extension_size, options)}, 0));

    optimizer->param_groups()[param_position].params()[0] = extended_tensor.set_requires_grad(true);
    old_tensor = optimizer->param_groups()[param_position].params()[0];

    optimizer->state()[c10::guts::to_string(optimizer->param_groups()[param_position].params()[0].unsafeGetTensorImpl())] = std::move(adamParamStates);
}

void cat_tensors_to_optimizer(torch::optim::Adam* optimizer,
                              torch::Tensor& extension_tensor,
                              torch::Tensor& old_tensor,
                              int param_position) {
    auto adamParamStates = std::make_unique<torch::optim::AdamParamState>(static_cast<torch::optim::AdamParamState&>(
        *optimizer->state()[c10::guts::to_string(optimizer->param_groups()[param_position].params()[0].unsafeGetTensorImpl())]));
    optimizer->state().erase(c10::guts::to_string(optimizer->param_groups()[param_position].params()[0].unsafeGetTensorImpl()));

    adamParamStates->exp_avg(torch::cat({adamParamStates->exp_avg(), torch::zeros_like(extension_tensor)}, 0));
    adamParamStates->exp_avg_sq(torch::cat({adamParamStates->exp_avg_sq(), torch::zeros_like(extension_tensor)}, 0));

    optimizer->param_groups()[param_position].params()[0] = torch::cat({old_tensor, extension_tensor}, 0).set_requires_grad(true);
    old_tensor = optimizer->param_groups()[param_position].params()[0];

    optimizer->state()[c10::guts::to_string(optimizer->param_groups()[param_position].params()[0].unsafeGetTensorImpl())] = std::move(adamParamStates);
}

void GaussianModel::densification_postfix(torch::Tensor& new_xyz,
                                          torch::Tensor& new_features_dc,
                                          torch::Tensor& new_features_rest,
                                          torch::Tensor& new_scaling,
                                          torch::Tensor& new_rotation,
                                          torch::Tensor& new_opacity) {
    cat_tensors_to_optimizer(_optimizer.get(), new_xyz, _xyz, 0);
    cat_tensors_to_optimizer(_optimizer.get(), new_features_dc, _features_dc, 1);
    cat_tensors_to_optimizer(_optimizer.get(), new_features_rest, _features_rest, 2);
    cat_tensors_to_optimizer(_optimizer.get(), new_scaling, _scaling, 3);
    cat_tensors_to_optimizer(_optimizer.get(), new_rotation, _rotation, 4);
    cat_tensors_to_optimizer(_optimizer.get(), new_opacity, _opacity, 5);

    _xyz_gradient_accum = torch::zeros({_xyz.size(0), 1}).to(torch::kCUDA);
    _denom = torch::zeros({_xyz.size(0), 1}).to(torch::kCUDA);
    _max_radii2D = torch::zeros({_xyz.size(0)}).to(torch::kCUDA);
}

void GaussianModel::densify_and_split(torch::Tensor& grads, float grad_threshold, float scene_extent, float min_opacity, float max_screen_size) {
    static const int N = 2;
    const int n_init_points = _xyz.size(0);
    // Extract points that satisfy the gradient condition
    torch::Tensor padded_grad = torch::zeros({n_init_points}).to(torch::kCUDA);
    padded_grad.slice(0, 0, grads.size(0)) = grads.squeeze();
    torch::Tensor selected_pts_mask = torch::where(padded_grad >= grad_threshold, torch::ones_like(padded_grad).to(torch::kBool), torch::zeros_like(padded_grad).to(torch::kBool));
    selected_pts_mask = torch::logical_and(selected_pts_mask, std::get<0>(Get_scaling().max(1)) > _percent_dense * scene_extent);
    auto indices = torch::nonzero(selected_pts_mask.squeeze(-1) == true).index({torch::indexing::Slice(torch::indexing::None, torch::indexing::None), torch::indexing::Slice(torch::indexing::None, 1)}).squeeze(-1);

    torch::Tensor stds = Get_scaling().index_select(0, indices).repeat({N, 1});
    torch::Tensor means = torch::zeros({stds.size(0), 3}).to(torch::kCUDA);
    torch::Tensor samples = torch::randn({stds.size(0), stds.size(1)}).to(torch::kCUDA) * stds + means;
    torch::Tensor rots = build_rotation(_rotation.index_select(0, indices)).repeat({N, 1, 1});

    torch::Tensor new_xyz = torch::bmm(rots, samples.unsqueeze(-1)).squeeze(-1) + _xyz.index_select(0, indices).repeat({N, 1});
    torch::Tensor new_scaling = torch::log(Get_scaling().index_select(0, indices).repeat({N, 1}) / (0.8 * N));
    torch::Tensor new_rotation = _rotation.index_select(0, indices).repeat({N, 1});
    torch::Tensor new_features_dc = _features_dc.index_select(0, indices).repeat({N, 1, 1});
    torch::Tensor new_features_rest = _features_rest.index_select(0, indices).repeat({N, 1, 1});
    torch::Tensor new_opacity = _opacity.index_select(0, indices).repeat({N, 1});

    densification_postfix(new_xyz, new_features_dc, new_features_rest, new_scaling, new_rotation, new_opacity);

    torch::Tensor prune_filter = torch::cat({selected_pts_mask.squeeze(-1), torch::zeros({N * selected_pts_mask.sum().item<int>()}).to(torch::kBool).to(torch::kCUDA)});
    // torch::Tensor prune_filter = torch::cat({selected_pts_mask.squeeze(-1), torch::zeros({N * selected_pts_mask.sum().item<int>()})}).to(torch::kBool).to(torch::kCUDA);
    prune_filter = torch::logical_or(prune_filter, (Get_opacity() < min_opacity).squeeze(-1));
    prune_points(prune_filter);
}

__global__ void concat_4dim_kernel(
    const float* __restrict__ xyz,
    const int64_t* __restrict__ indices,
    float* __restrict__ new_xyz,
    const size_t N,
    const size_t orig_N) {
    const int idx = blockIdx.x * blockDim.x + threadIdx.x;
    if (idx >= N) {
        return;
    }

    // Copy selected elements to new tensors, at positions after the original elements
    const int64_t index = indices[idx];
    const int64_t dest_idx = orig_N + idx;

    new_xyz[dest_idx * 3] = xyz[index * 3];
    new_xyz[dest_idx * 3 + 1] = xyz[index * 3 + 1];
    new_xyz[dest_idx * 3 + 2] = xyz[index * 3 + 2];
    new_xyz[dest_idx * 3 + 3] = xyz[index * 3 + 3];
}

__global__ void concat_2dim_kernel(
    const float* __restrict__ src,
    const int64_t* __restrict__ indices,
    float* __restrict__ dst,
    int64_t dim0,
    int64_t dim1,
    const long N,
    const long orig_N) {
    const long idx = blockIdx.x * blockDim.x + threadIdx.x;
    if (idx >= N) {
        return;
    }

    // Copy selected elements to new tensors, at positions after the original elements
    const int64_t index = indices[idx];
    const int64_t dest_idx = orig_N + idx;

    for (long i = 0; i < dim1; i++) {
        dst[dest_idx * dim1 + i] = src[index * dim1 + i];
    }
}

__global__ void concat_selection_float3_kernel(
    const float3* __restrict__ src,
    const int64_t* __restrict__ indices,
    float3* __restrict__ dst,
    const size_t extension_size,
    const size_t orig_size) {

    const int idx = blockIdx.x * blockDim.x + threadIdx.x;
    if (idx >= extension_size) {
        return;
    }

    const int64_t src_index = indices[idx];
    const int64_t dest_idx = orig_size + idx;

    // Single memory read operation for each 3D point
    dst[dest_idx] = src[src_index];
}

__global__ void concat_selection_float4_kernel(
    const float4* __restrict__ src,
    const int64_t* __restrict__ indices,
    float4* __restrict__ dst,
    const size_t extension_size,
    const size_t orig_size) {

    const int idx = blockIdx.x * blockDim.x + threadIdx.x;
    if (idx >= extension_size) {
        return;
    }

    const int64_t src_index = indices[idx];
    const int64_t dest_idx = orig_size + idx;

    // Single memory read operation for each 3D point
    dst[dest_idx] = src[src_index];
}

__global__ void concat_elements_kernel_opacity(
    const float* __restrict__ opacity,
    const int64_t* __restrict__ indices,
    float* __restrict__ new_opacity,
    const size_t N,
    const size_t orig_N) {
    const int idx = blockIdx.x * blockDim.x + threadIdx.x;
    if (idx >= N) {
        return;
    }

    const int64_t index = indices[idx];
    const int64_t dest_idx = orig_N + idx;
    new_opacity[dest_idx] = opacity[index];
}

__global__ void concat_elements_kernel_features_dc(
    const float3* __restrict__ features_dc,
    const int64_t* __restrict__ indices,
    float3* __restrict__ new_features_dc,
    const size_t N,
    const size_t orig_N,
    const size_t F1) {
    const int idx = blockIdx.x * blockDim.x + threadIdx.x;
    if (idx >= N) {
        return;
    }

    // Copy selected elements to new tensors, at positions after the original elements
    const int64_t index = indices[idx];
    const int64_t dest_idx = orig_N + idx;

    for (int j = 0; j < F1; j++) {
        new_features_dc[dest_idx * F1 + j] = features_dc[index * F1 + j];
    }
}

__global__ void concat_elements_kernel_features_rest(
    const float3* __restrict__ features_rest,
    const int64_t* __restrict__ indices,
    float3* __restrict__ new_features_rest,
    const size_t N,
    const size_t orig_N,
    const size_t F1,
    const size_t F3) {
    const int idx = blockIdx.x * blockDim.x + threadIdx.x;
    if (idx >= N) {
        return;
    }

    // Copy selected elements to new tensors, at positions after the original elements
    const int64_t index = indices[idx];
    const int64_t dest_idx = orig_N + idx;

    for (int j = 0; j < F1; j++) {
        for (int k = 0; k < F3; k++) {
            new_features_rest[dest_idx * F1 * F3 + j * F3 + k] = features_rest[index * F1 * F3 + j * F3 + k];
        }
    }
}

void copy3DAsync(const float* src,
                 const std::vector<long>& src_size,
                 float* dst,
                 const std::vector<long>& dst_size,
                 cudaStream_t stream) {
    cudaMemcpy3DParms copyParams = {0};
    copyParams.kind = cudaMemcpyDeviceToDevice;

    copyParams.srcPtr = make_cudaPitchedPtr(
        (void*)src,
        (size_t)src_size[2] * sizeof(float),
        (size_t)src_size[2],
        (size_t)src_size[1]);

    copyParams.dstPtr = make_cudaPitchedPtr(
        (void*)dst,
        (size_t)dst_size[2] * sizeof(float),
        (size_t)dst_size[2],
        (size_t)dst_size[1]);

    copyParams.extent = make_cudaExtent(
        (size_t)src_size[2] * sizeof(float),
        (size_t)src_size[1],
        (size_t)src_size[0]);
    CHECK_CUDA_ERROR(cudaMemcpy3DAsync(&copyParams, stream));
}

void copy2DAsync(const float* src, const std::vector<long>& src_size, float* dst, cudaStream_t stream) {
    //    float *new_dst;
    //    cudaMalloc(&new_dst, dst.size(0) * dst.size(1) * sizeof(float));
    if (src_size.size() != 2) {
        std::cout << "src_size.size() != 2" << std::endl;
        return;
    }
    std::cout << "src_size[0]: " << src_size[0] << std::endl;
    std::cout << "src_size[1]: " << src_size[1] << std::endl;
    size_t width_in_bytes = src_size[1] * sizeof(float);
    size_t height_in_elements = src_size[0];
    size_t src_pitch = src_size[1] * sizeof(float); // provide stride
    size_t dst_pitch = src_size[1] * sizeof(float); // make stride

    cudaMemcpy2DAsync(
        dst,                      // Destination pointer
        dst_pitch,                // Destination pitch
        src,                      // Source pointer
        src_pitch,                // Source pitch
        width_in_bytes,           // Width of the 2D region in bytes
        height_in_elements,       // Height of the 2D region in elements
        cudaMemcpyDeviceToDevice, // Specifies the kind of copy (Device to Device)
        stream                    // Stream to perform the copy
    );
    CHECK_LAST_CUDA_ERROR();
}

void copy1DAsync(const torch::Tensor& src, torch::Tensor& dst, cudaStream_t stream) {
    // assert(src.size(0) <= dst.size(0));

    size_t bytes_to_copy = src.size(0) * sizeof(float);

    CHECK_CUDA_ERROR(cudaMemcpyAsync(
        dst.data_ptr(),           // Destination pointer
        src.data_ptr(),           // Source pointer
        bytes_to_copy,            // Number of bytes to copy
        cudaMemcpyDeviceToDevice, // Specifies the kind of copy (Device to Device)
        stream                    // Stream to perform the copy
        ));
}

void GaussianModel::select_elements_and_cat(
    const float* xyz,
    const std::vector<long>& xyz_size,
    const float* features_dc,
    const std::vector<long>& features_dc_size,
    const float* features_rest,
    const std::vector<long>& features_rest_size,
    const float* opacity,
    const std::vector<long>& opacity_size,
    const float* scaling,
    const std::vector<long>& scaling_size,
    const float* rotation,
    const std::vector<long>& rotation_size,
    int64_t* indices,
    long F1,
    long F2,
    long F3,
    long original_size,
    long extension_size) {

    long threads = 512;
    long blocks = std::max(1L, (extension_size + threads - 1L) / threads);
    {

        const auto& xyz_paramstates = static_cast<torch::optim::AdamParamState&>(*_optimizer->state()[c10::guts::to_string(_optimizer->param_groups()[0].params()[0].unsafeGetTensorImpl())]);
        const auto& features_dc_paramstates = static_cast<torch::optim::AdamParamState&>(*_optimizer->state()[c10::guts::to_string(_optimizer->param_groups()[1].params()[0].unsafeGetTensorImpl())]);
        const auto& features_rest_paramstates = static_cast<torch::optim::AdamParamState&>(*_optimizer->state()[c10::guts::to_string(_optimizer->param_groups()[2].params()[0].unsafeGetTensorImpl())]);
        const auto& scaling_paramstates = static_cast<torch::optim::AdamParamState&>(*_optimizer->state()[c10::guts::to_string(_optimizer->param_groups()[3].params()[0].unsafeGetTensorImpl())]);
        const auto& rotation_paramstates = static_cast<torch::optim::AdamParamState&>(*_optimizer->state()[c10::guts::to_string(_optimizer->param_groups()[4].params()[0].unsafeGetTensorImpl())]);
        const auto& opacity_paramstates = static_cast<torch::optim::AdamParamState&>(*_optimizer->state()[c10::guts::to_string(_optimizer->param_groups()[5].params()[0].unsafeGetTensorImpl())]);

        const auto options = torch::TensorOptions().dtype(torch::kFloat32).device(torch::kCUDA);
        auto new_xyz = torch::zeros({_xyz.size(0) + extension_size, _xyz.size(0)}, options);
        ts::print_debug_info(new_xyz, "Before tensor_to_optimizer_new: new_xyz");
        auto new_features_dc = torch::zeros({original_size + extension_size, F1, F2}, options);
        auto new_features_rest = torch::zeros({original_size + extension_size, F1, F3}, options);
        auto new_opacity = torch::zeros({original_size + extension_size, 1}, options);
        auto new_scaling = torch::zeros({original_size + extension_size, 3}, options);
        auto new_rotation = torch::zeros({original_size + extension_size, 4}, options);

        const int total_extension_count = original_size + extension_size;
        auto xyz_exp_avg = torch::zeros({total_extension_count, 3}, options);
        auto xyz_exp_avg_sq = torch::zeros({total_extension_count, 3}, options);
        auto features_dc_avg = torch::zeros({total_extension_count, _features_dc.size(1), _features_dc.size(2)}, options);
        auto features_dc_avg_sq = torch::zeros({total_extension_count, _features_dc.size(1), _features_dc.size(2)}, options);
        auto features_rest_avg = torch::zeros({total_extension_count, _features_rest.size(1), _features_rest.size(2)}, options);
        auto features_rest_avg_sq = torch::zeros({total_extension_count, _features_rest.size(1), _features_rest.size(2)}, options);
        auto opacity_avg = torch::zeros({total_extension_count, 1}, options);
        auto opacity_avg_sq = torch::zeros({total_extension_count, 1}, options);
        auto scaling_avg = torch::zeros({total_extension_count, 3}, options);
        auto scaling_avg_sq = torch::zeros({total_extension_count, 3}, options);
        auto rotation_avg = torch::zeros({total_extension_count, 4}, options);
        auto rotation_avg_sq = torch::zeros({total_extension_count, 4}, options);

        //        std::cout << "async xyz_paramstates.exp_avg()" << std::endl;
        //        copy2DAsync(xyz_paramstates.exp_avg().data_ptr<float>(), {original_size, 3}, xyz_exp_avg.data_ptr<float>(), _stream1);
        //        CHECK_LAST_CUDA_ERROR();
        //        std::cout << "async xyz_paramstates.exp_avg_sq()" << std::endl;
        //        copy2DAsync(xyz_paramstates.exp_avg_sq().data_ptr<float>(), {original_size, 3}, xyz_exp_avg_sq.data_ptr<float>(), _stream1);
        //        CHECK_LAST_CUDA_ERROR();

        std::cout << "async features_dc_paramstates.exp_avg()" << std::endl;
        copy3DAsync(features_dc_paramstates.exp_avg().data_ptr<float>(), features_dc_size, features_dc_avg.data_ptr<float>(), {original_size + extension_size, F1, F2}, _stream3);
        CHECK_LAST_CUDA_ERROR();
        std::cout << "async features_dc_paramstates.exp_avg_sq()" << std::endl;
        copy3DAsync(features_dc_paramstates.exp_avg_sq().data_ptr<float>(), features_dc_size, features_dc_avg_sq.data_ptr<float>(), {original_size + extension_size, F1, F2}, _stream4);
        CHECK_LAST_CUDA_ERROR();

        std::cout << "async features_rest_paramstates.exp_avg()" << std::endl;
        copy3DAsync(features_rest_paramstates.exp_avg().data_ptr<float>(), features_rest_size, features_rest_avg.data_ptr<float>(), {original_size + extension_size, F1, F3}, _stream5);
        CHECK_LAST_CUDA_ERROR();
        std::cout << "async features_rest_paramstates.exp_avg_sq()" << std::endl;
        copy3DAsync(features_rest_paramstates.exp_avg_sq().data_ptr<float>(), features_rest_size, features_rest_avg_sq.data_ptr<float>(), {original_size + extension_size, F1, F3}, _stream6);
        CHECK_LAST_CUDA_ERROR();

        std::cout << "async opacity_paramstates.exp_avg()" << std::endl;
        copy2DAsync(opacity_paramstates.exp_avg().data_ptr<float>(), {original_size, 1}, opacity_avg.data_ptr<float>(), _stream1);
        CHECK_LAST_CUDA_ERROR();
        std::cout << "async opacity_paramstates.exp_avg_sq()" << std::endl;
        copy2DAsync(opacity_paramstates.exp_avg_sq().data_ptr<float>(), {original_size, 1}, opacity_avg_sq.data_ptr<float>(), _stream2);
        CHECK_LAST_CUDA_ERROR();

        std::cout << "async scaling_paramstates.exp_avg()" << std::endl;
        copy2DAsync(scaling_paramstates.exp_avg().data_ptr<float>(), {original_size, 3}, scaling_avg.data_ptr<float>(), _stream3);
        CHECK_LAST_CUDA_ERROR();
        std::cout << "async scaling_paramstates.exp_avg_sq()" << std::endl;
        copy2DAsync(scaling_paramstates.exp_avg_sq().data_ptr<float>(), {original_size, 3}, scaling_avg_sq.data_ptr<float>(), _stream4);
        CHECK_LAST_CUDA_ERROR();

        std::cout << "async rotation_paramstates.exp_avg()" << std::endl;
        copy2DAsync(rotation_paramstates.exp_avg().data_ptr<float>(), {original_size, 4}, rotation_avg.data_ptr<float>(), _stream5);
        CHECK_LAST_CUDA_ERROR();
        std::cout << "async rotation_paramstates.exp_avg_sq()" << std::endl;
        copy2DAsync(rotation_paramstates.exp_avg_sq().data_ptr<float>(), {original_size, 4}, rotation_avg_sq.data_ptr<float>(), _stream6);
        CHECK_LAST_CUDA_ERROR();

        copy2DAsync(xyz, xyz_size, new_xyz.data_ptr<float>(), _stream1);
        ts::print_debug_info(new_xyz, "Before concat_selection_float3_kernel: new_xyz");
        CHECK_LAST_CUDA_ERROR();
        const auto* xyz3_ptr = reinterpret_cast<const float3*>(xyz);
        auto* new_xyz3_ptr = reinterpret_cast<float3*>(new_xyz.data_ptr<float>());
        concat_selection_float3_kernel<<<blocks, threads, 0, _stream1>>>(
            xyz3_ptr,
            indices,
            new_xyz3_ptr,
            extension_size,
            xyz_size[0]);
        CHECK_LAST_CUDA_ERROR();
        ts::print_debug_info(new_xyz, "After concat_selection_float3_kernel: new_xyz");

        copy2DAsync(scaling, scaling_size, new_scaling.data_ptr<float>(), _stream2);
        CHECK_LAST_CUDA_ERROR();
        const auto* scaling3_ptr = reinterpret_cast<const float3*>(scaling);
        auto* new_scaling3_ptr = reinterpret_cast<float3*>(new_scaling.data_ptr<float>());
        concat_selection_float3_kernel<<<blocks, threads, 0, _stream2>>>(
            scaling3_ptr,
            indices,
            new_scaling3_ptr,
            extension_size,
            scaling_size[0]);
        CHECK_LAST_CUDA_ERROR();

        copy3DAsync(features_dc, features_dc_size, new_features_dc.data_ptr<float>(), {original_size + extension_size, F1, F2}, _stream3);
        CHECK_LAST_CUDA_ERROR();
        const auto* features_dc_ptr = reinterpret_cast<const float3*>(features_dc);
        auto* new_features_dc_ptr = reinterpret_cast<float3*>(new_features_dc.data_ptr<float>());
        concat_elements_kernel_features_dc<<<blocks, threads, 0, _stream3>>>(
            features_dc_ptr,
            indices,
            new_features_dc_ptr,
            extension_size,
            xyz_size[0], F1);
        CHECK_LAST_CUDA_ERROR();

        copy2DAsync(opacity, opacity_size, new_opacity.data_ptr<float>(), _stream4);
        CHECK_LAST_CUDA_ERROR();
        concat_elements_kernel_opacity<<<blocks, threads, 0, _stream4>>>(
            opacity,
            indices,
            new_opacity.data_ptr<float>(),
            extension_size,
            xyz_size[0]);
        CHECK_LAST_CUDA_ERROR();

        copy3DAsync(features_rest, features_rest_size, new_features_rest.data_ptr<float>(), {original_size + extension_size, F1, F3}, _stream5);
        CHECK_LAST_CUDA_ERROR();
        const auto* features_rest_ptr = reinterpret_cast<const float3*>(features_rest);
        auto* new_features_rest_ptr = reinterpret_cast<float3*>(new_features_rest.data_ptr<float>());
        concat_elements_kernel_features_rest<<<blocks, threads, 0, _stream5>>>(
            features_rest_ptr,
            indices,
            new_features_rest_ptr,
            extension_size,
            xyz_size[0],
            F1, F3);
        CHECK_LAST_CUDA_ERROR();

        copy2DAsync(rotation, rotation_size, new_rotation.data_ptr<float>(), _stream6);
        CHECK_LAST_CUDA_ERROR();
        auto* rotation_ptr = reinterpret_cast<const float4*>(rotation);
        auto* new_rotation_ptr = reinterpret_cast<float4*>(new_rotation.data_ptr<float>());
        concat_selection_float4_kernel<<<blocks, threads, 0, _stream6>>>(
            rotation_ptr,
            indices,
            new_rotation_ptr,
            extension_size,
            rotation_size[0]);
        CHECK_LAST_CUDA_ERROR();

        //        cudaStreamSynchronize(_stream1);
        //        CHECK_LAST_CUDA_ERROR();
        //        cudaStreamSynchronize(_stream2);
        //        CHECK_LAST_CUDA_ERROR();
        //        cudaStreamSynchronize(_stream3);
        //        CHECK_LAST_CUDA_ERROR();
        //        cudaStreamSynchronize(_stream4);
        //        CHECK_LAST_CUDA_ERROR();
        //        cudaStreamSynchronize(_stream5);
        //        CHECK_LAST_CUDA_ERROR();
        //        cudaStreamSynchronize(_stream6);
        cudaDeviceSynchronize();
        CHECK_LAST_CUDA_ERROR();
        std::cout << "After cudaStreamSynchronize" << std::endl;
        std::cout << "xyz_exp_avg" << std::endl;
        ts::print_debug_info(_xyz, "Before tensor_to_optimizer_new: xyz");
        ts::print_debug_info(new_xyz, "Before tensor_to_optimizer_new: new_xyz");
        tensors_to_optimizer_new(_optimizer.get(), new_xyz, _xyz, xyz_exp_avg, xyz_exp_avg_sq, 0);
        ts::print_debug_info(_xyz, "\nAfter tensor_to_optimizer_new: xyz");
        ts::print_debug_info(new_xyz, "After tensor_to_optimizer_new: new_xyz");
        CHECK_LAST_CUDA_ERROR();
        std::cout << "features_dc_exp_avg" << std::endl;
        tensors_to_optimizer_new(_optimizer.get(), new_features_dc, _features_dc, features_dc_avg, features_dc_avg_sq, 1);
        CHECK_LAST_CUDA_ERROR();
        std::cout << "features_rest_exp_avg" << std::endl;
        tensors_to_optimizer_new(_optimizer.get(), new_features_rest, _features_rest, features_rest_avg, features_rest_avg_sq, 2);
        CHECK_LAST_CUDA_ERROR();
        std::cout << "opacity_exp_avg" << std::endl;
        tensors_to_optimizer_new(_optimizer.get(), new_opacity, _opacity, opacity_avg, opacity_avg_sq, 5);
        CHECK_LAST_CUDA_ERROR();
        std::cout << "scaling_exp_avg" << std::endl;
        tensors_to_optimizer_new(_optimizer.get(), new_scaling, _scaling, scaling_avg, scaling_avg_sq, 3);
        CHECK_LAST_CUDA_ERROR();
        std::cout << "rotation_exp_avg" << std::endl;
        tensors_to_optimizer_new(_optimizer.get(), new_rotation, _rotation, rotation_avg, rotation_avg_sq, 4);
        CHECK_LAST_CUDA_ERROR();
        std::cout << "done!" << std::endl;
    }

    std::cout << "After cudaStreamDestory" << std::endl;
    CHECK_LAST_CUDA_ERROR();
}

void GaussianModel::densify_and_clone(torch::Tensor& grads, float grad_threshold, float scene_extent) {
    // Extract points that satisfy the gradient condition
    torch::Tensor selected_pts_mask = torch::where(torch::linalg::vector_norm(grads, {2}, 1, true, torch::kFloat32) >= grad_threshold,
                                                   torch::ones_like(grads.index({torch::indexing::Slice()})).to(torch::kBool),
                                                   torch::zeros_like(grads.index({torch::indexing::Slice()})).to(torch::kBool))
                                          .to(torch::kLong);

    selected_pts_mask = torch::logical_and(selected_pts_mask, std::get<0>(Get_scaling().max(1)).unsqueeze(-1) <= _percent_dense * scene_extent);

    auto indices = torch::nonzero(selected_pts_mask.squeeze(-1) == true).index({torch::indexing::Slice(torch::indexing::None, torch::indexing::None), torch::indexing::Slice(torch::indexing::None, 1)}).squeeze(-1);
    const auto extension_count = torch::sum(selected_pts_mask).item<int>();
    //    const auto total_extension_count = _xyz.size(0) + extension_count;
    //    const auto options = torch::TensorOptions().dtype(torch::kFloat32).device(torch::kCUDA);
    //    torch::Tensor new_xyz = torch::zeros({total_extension_count, 3}, options);
    //    torch::Tensor new_features_dc = torch::zeros({total_extension_count, _features_dc.size(1), _features_dc.size(2)}, options);
    //    torch::Tensor new_features_rest = torch::zeros({total_extension_count, _features_rest.size(1), _features_rest.size(2)}, options);
    //    torch::Tensor new_opacity = torch::zeros({total_extension_count, 1}, options);
    //    torch::Tensor new_scaling = torch::zeros({total_extension_count, 3}, options);
    //    torch::Tensor new_rotation = torch::zeros({total_extension_count, 4}, options);
    std::cout << "Print extension size: " << extension_count << std::endl;
    const auto F1 = _features_dc.size(1);
    const auto F2 = _features_dc.size(2);
    const auto F3 = _features_rest.size(2);
    select_elements_and_cat(_xyz.data_ptr<float>(),
                            {_xyz.size(0), _xyz.size(1)},
                            _features_dc.data_ptr<float>(),
                            {_features_dc.size(0), _features_dc.size(1), _features_dc.size(2)},
                            _features_rest.data_ptr<float>(),
                            {_features_rest.size(0), _features_rest.size(1), _features_rest.size(2)},
                            _opacity.data_ptr<float>(),
                            {_opacity.size(0), _opacity.size(1)},
                            _scaling.data_ptr<float>(),
                            {_scaling.size(0), _scaling.size(1)},
                            _rotation.data_ptr<float>(),
                            {_rotation.size(0), _rotation.size(1)},
                            indices.data_ptr<int64_t>(),
                            F1, F2, F3,
                            _xyz.size(0),
                            extension_count);
    std::cout << "After select_elements_and_cat" << std::endl;
    ts::print_debug_info(_xyz, "xyz");
    _xyz_gradient_accum = torch::zeros({_xyz.size(0), 1}).to(torch::kCUDA);
    std::cout << "After _xyz_gradient_accum" << std::endl;
    ts::print_debug_info(_xyz, "xyz");
    _denom = torch::zeros({_xyz.size(0), 1}).to(torch::kCUDA);
    std::cout << "After _denom" << std::endl;
    ts::print_debug_info(_denom, "xyz");
    _max_radii2D = torch::zeros({_xyz.size(0)}).to(torch::kCUDA);
    std::cout << "After _max_radii2D" << std::endl;
    ts::print_debug_info(_max_radii2D, "max_radii2D");
}

void GaussianModel::Densify_and_prune(float max_grad, float min_opacity, float extent, float max_screen_size) {
    torch::Tensor grads = _xyz_gradient_accum / _denom;
    grads.index_put_({grads.isnan()}, 0.0);

    densify_and_clone(grads, max_grad, extent);
    densify_and_split(grads, max_grad, extent, min_opacity, max_screen_size);
}

void GaussianModel::Add_densification_stats(torch::Tensor& viewspace_point_tensor, torch::Tensor& update_filter) {
    _xyz_gradient_accum.index_put_({update_filter}, _xyz_gradient_accum.index_select(0, update_filter.nonzero().squeeze()) + viewspace_point_tensor.grad().index_select(0, update_filter.nonzero().squeeze()).slice(1, 0, 2).norm(2, -1, true));
    _denom.index_put_({update_filter}, _denom.index_select(0, update_filter.nonzero().squeeze()) + 1);
}

std::vector<std::string> GaussianModel::construct_list_of_attributes() {
    std::vector<std::string> attributes = {"x", "y", "z", "nx", "ny", "nz"};

    for (int i = 0; i < _features_dc.size(1) * _features_dc.size(2); ++i)
        attributes.push_back("f_dc_" + std::to_string(i));

    for (int i = 0; i < _features_rest.size(1) * _features_rest.size(2); ++i)
        attributes.push_back("f_rest_" + std::to_string(i));

    attributes.emplace_back("opacity");

    for (int i = 0; i < _scaling.size(1); ++i)
        attributes.push_back("scale_" + std::to_string(i));

    for (int i = 0; i < _rotation.size(1); ++i)
        attributes.push_back("rot_" + std::to_string(i));

    return attributes;
}

void GaussianModel::Save_ply(const std::filesystem::path& file_path, int iteration, bool isLastIteration) {
    std::cout << "Saving at " << std::to_string(iteration) << " iterations\n";
    auto folder = file_path / ("point_cloud/iteration_" + std::to_string(iteration));
    std::filesystem::create_directories(folder);

    auto xyz = _xyz.cpu().contiguous();
    auto normals = torch::zeros_like(xyz);
    auto f_dc = _features_dc.transpose(1, 2).flatten(1).cpu().contiguous();
    auto f_rest = _features_rest.transpose(1, 2).flatten(1).cpu().contiguous();
    auto opacities = _opacity.cpu();
    auto scale = _scaling.cpu();
    auto rotation = _rotation.cpu();

    std::vector<torch::Tensor> tensor_attributes = {xyz.clone(),
                                                    normals.clone(),
                                                    f_dc.clone(),
                                                    f_rest.clone(),
                                                    opacities.clone(),
                                                    scale.clone(),
                                                    rotation.clone()};
    auto attributes = construct_list_of_attributes();
    std::thread t = std::thread([folder, tensor_attributes, attributes]() {
        Write_output_ply(folder / "point_cloud.ply", tensor_attributes, attributes);
    });

    if (isLastIteration) {
        t.join();
    } else {
        t.detach();
    }
}