#include <optional>
#include "VecSim/vec_sim.h"
#include "VecSim/vec_sim_common.h"
#include "VecSim/vec_sim_index.h"
#include "VecSim/query_result_struct.h"
#include "VecSim/memory/vecsim_malloc.h"
#include "VecSim/algorithms/brute_force/bfs_batch_iterator.h"   // TODO: Temporary header to remove

#include "raft/core/device_resources.hpp"
#include "raft/neighbors/ivf_flat.cuh"
#include "raft/neighbors/ivf_flat_types.hpp"

#ifdef RAFT_COMPILED
#include <raft/neighbors/specializations.cuh>
#endif

raft::distance::DistanceType GetRaftDistanceType(VecSimMetric vsm){
    raft::distance::DistanceType result;
    switch (vsm) {
        case VecSimMetric::VecSimMetric_L2:
            result = raft::distance::DistanceType::L2Expanded;
            break;
        case VecSimMetric_IP:
            result = raft::distance::DistanceType::InnerProduct;
            break;
        case VecSimMetric_Cosine:
            result = raft::distance::DistanceType::CosineExpanded;
            break;
        default:
            throw std::runtime_error("Metric not supported");
    }
    return result;
}

class RaftFlatIndex : public VecSimIndexAbstract<float> {
public:
    using DataType = float;
    using DistType = float;
    using raftIvfFlatIndex = raft::neighbors::ivf_flat::index<DataType, std::int64_t>;

    RaftFlatIndex(const RaftFlatParams *params, std::shared_ptr<VecSimAllocator> allocator);
    int addVector(const void *vector_data, labelType label, bool overwrite_allowed = true) override;
    int deleteVector(labelType label) override { return 0;}
    double getDistanceFrom(labelType label, const void *vector_data) const override {
        assert(!"getDistanceFrom not implemented");
        return INVALID_SCORE;
    }
    size_t indexSize() const override {
        if (!flat_index_) {
            return 0;
        }
        return counts_;
    }
    size_t indexCapacity() const override {
        assert(!"indexCapacity not implemented");
        return 0;
    }
    void increaseCapacity() override {
        assert(!"increaseCapacity not implemented");
    }
    inline size_t indexLabelCount() const override {
        if (!flat_index_) {
            return 0;
        }
        return counts_; //TODO: Return unique counts
    }
    virtual VecSimQueryResult_List topKQuery(const void *queryBlob, size_t k, VecSimQueryParams *queryParams) override;
    virtual VecSimQueryResult_List rangeQuery(const void *queryBlob, double radius, VecSimQueryParams *queryParams) override
    {
        assert(!"RangeQuery not implemented");
    }
    virtual VecSimIndexInfo info() const override
    {
        VecSimIndexInfo info;
        info.algo = VecSimAlgo_RaftFlat;
        info.bfInfo.dim = this->dim;
        info.bfInfo.type = this->vecType;
        info.bfInfo.metric = this->metric;
        info.bfInfo.indexSize = this->counts_;
        info.bfInfo.indexLabelCount = this->indexLabelCount();
        info.bfInfo.blockSize = this->blockSize;
        info.bfInfo.memory = this->getAllocationSize();
        info.bfInfo.isMulti = false;
        info.bfInfo.last_mode = this->last_mode;
        return info;
    }
    virtual VecSimInfoIterator *infoIterator() const override
    {
        assert(!"infoIterator not implemented");
        size_t numberOfInfoFields = 12;
        VecSimInfoIterator *infoIterator = new VecSimInfoIterator(numberOfInfoFields);
        return infoIterator;
    }
    virtual VecSimBatchIterator *newBatchIterator(const void *queryBlob, VecSimQueryParams *queryParams) const override
    {
        assert(!"newBatchIterator not implemented");
        // TODO: Using BFS_Batch Iterator temporarily for the return type
        return new (this->allocator) BFS_BatchIterator<DataType, float>(const_cast<void*>(queryBlob), nullptr, queryParams, this->allocator);
    }
    bool preferAdHocSearch(size_t subsetSize, size_t k, bool initial_check) override
    {
        return true; // TODO: Implement this
    }


protected:
    raft::device_resources res_;
    std::unique_ptr<raftIvfFlatIndex> flat_index_;
    idType counts_;
    raft::neighbors::ivf_flat::index_params build_params_;
    raft::neighbors::ivf_flat::search_params search_params_;
};

RaftFlatIndex::RaftFlatIndex(const RaftFlatParams *params, std::shared_ptr<VecSimAllocator> allocator)
    : VecSimIndexAbstract<DistType>(allocator, params->dim, params->type, params->metric, params->blockSize, false),
      counts_(0)
{
    //auto build_params = raft::neighbors::ivf_flat::index_params{};
    build_params_.metric = GetRaftDistanceType(params->metric);
    build_params_.n_lists = params->nLists;
    build_params_.kmeans_n_iters = params->kmeans_nIters;
    build_params_.kmeans_trainset_fraction = params->kmeans_trainsetFraction;
    build_params_.adaptive_centers = params->adaptiveCenters;
    build_params_.add_data_on_build = true;
    search_params_.n_probes = params->nProbes;
    // TODO: Can't build flat_index here because there is no initial data;
    //flat_index_ = std::make_unique<raft::neighbors::ivf_flat::index<DataType, std::int64_t>>(raft::neighbors::ivf_flat::build<DataType, std::int64_t>(res_, build_params,
    //                                                                       nullptr, 0, this->dim));
}

int RaftFlatIndex::addVector(const void *vector_data, labelType label, bool overwrite_allowed)
{
    assert(label < static_cast<labelType>(std::numeric_limits<std::int64_t>::max()));
    auto vector_data_gpu = raft::make_device_matrix<DataType, std::int64_t>(res_, 1, this->dim);
    auto label_converted = static_cast<std::int64_t>(label);
    auto label_gpu = raft::make_device_vector<std::int64_t, std::int64_t>(res_, 1);
    raft::copy(vector_data_gpu.data_handle(), (DataType*)vector_data, this->dim, res_.get_stream());
    raft::copy(label_gpu.data_handle(), &label_converted, 1, res_.get_stream());

    if (!flat_index_) {
        flat_index_ = std::make_unique<raftIvfFlatIndex>(raft::neighbors::ivf_flat::build<DataType, std::int64_t>(
            res_, build_params_, raft::make_const_mdspan(vector_data_gpu.view())));
    } else {
        raft::neighbors::ivf_flat::extend(res_, raft::make_const_mdspan(vector_data_gpu.view()),
            std::make_optional(raft::make_const_mdspan(label_gpu.view())), flat_index_.get());
    }
    // TODO: Verify that label exists already?
    // TODO normalizeVector for cosine?
    this->counts_ += 1;
    return 1;
}

// Search for the k closest vectors to a given vector in the index.
VecSimQueryResult_List RaftFlatIndex::topKQuery(
    const void *queryBlob, size_t k, VecSimQueryParams *queryParams)
{
    VecSimQueryResult_List result_list = {0};
    if (!flat_index_) {
        result_list.results = array_new<VecSimQueryResult>(0);
        return result_list;
    }
    auto vector_data_gpu = raft::make_device_matrix<DataType, std::int64_t>(res_, queryParams->batchSize, this->dim);
    auto neighbors_gpu = raft::make_device_matrix<std::int64_t, std::int64_t>(res_, queryParams->batchSize, k);
    auto distances_gpu = raft::make_device_matrix<float, std::int64_t>(res_, queryParams->batchSize, k);
    raft::copy(vector_data_gpu.data_handle(), (const DataType*)queryBlob, this->dim * queryParams->batchSize, res_.get_stream());
    raft::neighbors::ivf_flat::search(res_, search_params_, *flat_index_, raft::make_const_mdspan(vector_data_gpu.view()), neighbors_gpu.view(), distances_gpu.view());

    auto result_size = queryParams->batchSize * k;
    auto neighbors = array_new_len<std::int64_t>(result_size, result_size);
    auto distances = array_new_len<float>(result_size, result_size);
    raft::copy(neighbors, neighbors_gpu.data_handle(), result_size, res_.get_stream());
    raft::copy(distances, distances_gpu.data_handle(), result_size, res_.get_stream());
    result_list.results = array_new_len<VecSimQueryResult>(k, k);
    for (size_t i = 0; i < k; ++i) {
        VecSimQueryResult_SetId(result_list.results[i], neighbors[i]);
        VecSimQueryResult_SetScore(result_list.results[i], distances[i]);
    }
    array_free(neighbors);
    array_free(distances);
    return result_list;
}