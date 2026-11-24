#pragma once
#include <cstddef>
#include <map>
#include <memory>
#include <mutex>
#include <string>

#include "CodeRegion.h"
#include "v8-platform.h"

// V8 page allocator backed by a CodeRegion RX/RW alias pair (GPL-3.0-only; see NOTICE).

namespace codipadnode {

// One process-wide code alias pair, installed before V8 starts any workers.
// The allocator must outlive V8, its isolates, workers and platform teardown.
class NodePageAllocator final : public v8::PageAllocator {
 public:
  static std::unique_ptr<NodePageAllocator> Create(const std::shared_ptr<CodeRegion> &region,
                                                   size_t codeBytes, std::string *error);
  ~NodePageAllocator() override;

  size_t AllocatePageSize() override { return page; }
  size_t CommitPageSize() override { return page; }
  void SetRandomMmapSeed(int64_t seed) override { randomSeed = seed; }
  void *GetRandomMmapAddr() override;
  void *AllocatePages(void *, size_t, size_t, Permission) override;
  bool FreePages(void *, size_t) override;
  bool ReleasePages(void *, size_t, size_t) override;
  bool SetPermissions(void *, size_t, Permission) override;
  bool RecommitPages(void *p, size_t n, Permission perm) override {
    return SetPermissions(p, n, perm);
  }
  bool DiscardSystemPages(void *, size_t) override;
  bool DecommitPages(void *, size_t) override;

 private:
  NodePageAllocator() = default;
  bool apply(void *, size_t, Permission, bool code);
  bool owned(void *, size_t, bool &code) const;
  void releaseCode(uintptr_t, size_t);

  std::unique_ptr<CodeRegion::Lease> lease;
  uintptr_t rx = 0, rw = 0;
  size_t page = 0, capacity = 0;
  uint64_t randomSeed = 0;
  mutable std::mutex mutex;
  std::map<uintptr_t, size_t> codeAllocations, dataAllocations;
  std::map<size_t, size_t> freeCode;
};

}  // namespace codipadnode
