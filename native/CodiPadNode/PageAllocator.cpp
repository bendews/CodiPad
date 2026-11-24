#include "PageAllocator.h"

#include <sys/mman.h>
#include <unistd.h>

#include <cstring>
#include <limits>

// These three symbols are the seam the pinned V8 archive is patched against
// (node/patches/v8-alias-writes.patch at 51b56d5 rewrites code writes to
// codipad_v8_rw_begin + (address - codipad_v8_rx_begin)). The names are part of the
// runtime artifact contract, not an internal detail: do not rename them without
// rebuilding the runtime.
extern "C" {
uintptr_t codipad_v8_rx_begin = 0;
uintptr_t codipad_v8_rx_end = 0;
uintptr_t codipad_v8_rw_begin = 0;
}

namespace codipadnode {
namespace {

std::mutex registration;
constexpr size_t codeAlignment = 256 * 1024;  // Pinned V8 ARM64 heap page.

bool fail(std::string *error, const char *what) {
  if (error) *error = what ? what : "unknown error";
  return false;
}

bool contains(const std::map<uintptr_t, size_t> &map, uintptr_t p, size_t n) {
  auto it = map.upper_bound(p);
  if (it == map.begin()) return false;
  --it;
  return p - it->first <= it->second && n <= it->second - (p - it->first);
}

int protection(v8::PageAllocator::Permission p) {
  switch (p) {
    case v8::PageAllocator::kRead:
      return PROT_READ;
    case v8::PageAllocator::kReadWrite:
      return PROT_READ | PROT_WRITE;
    case v8::PageAllocator::kReadExecute:
    case v8::PageAllocator::kReadWriteExecute:
      return PROT_READ | PROT_EXEC;
    default:
      return PROT_NONE;
  }
}

}  // namespace

std::unique_ptr<NodePageAllocator> NodePageAllocator::Create(
    const std::shared_ptr<CodeRegion> &region, size_t bytes, std::string *error) {
  std::lock_guard<std::mutex> lock(registration);
  if (!region || codipad_v8_rx_begin || !bytes || bytes % codeAlignment ||
      bytes > SIZE_MAX - codeAlignment) {
    fail(error, "invalid or duplicate Node code pool");
    return nullptr;
  }
  auto allocation = region->Allocate(bytes + codeAlignment, error);
  if (!allocation) return nullptr;
  auto result = std::unique_ptr<NodePageAllocator>(new NodePageAllocator);
  result->lease = std::move(allocation);
  auto base = reinterpret_cast<uintptr_t>(result->lease->executable());
  result->rx = (base + codeAlignment - 1) & ~(codeAlignment - 1);
  result->rw = reinterpret_cast<uintptr_t>(result->lease->writable()) + result->rx - base;
  result->page = region->pageSize();
  result->capacity = bytes;
  result->freeCode.emplace(0, bytes);
  if (mprotect(reinterpret_cast<void *>(result->rx), bytes, PROT_NONE)) {
    fail(error, "Node code pool could not be guarded");
    return nullptr;
  }
  codipad_v8_rw_begin = result->rw;
  codipad_v8_rx_end = result->rx + bytes;
  codipad_v8_rx_begin = result->rx;
  return result;
}

NodePageAllocator::~NodePageAllocator() {
  std::lock_guard<std::mutex> lock(registration);
  // The caller has already joined workers and disposed V8. Restore CodeRegion's
  // original protections before returning its lease to the shared allocator.
  for (auto [address, size] : dataAllocations) munmap(reinterpret_cast<void *>(address), size);
  if (rx) mprotect(reinterpret_cast<void *>(rx), capacity, PROT_READ | PROT_EXEC);
  if (rw) mprotect(reinterpret_cast<void *>(rw), capacity, PROT_READ | PROT_WRITE);
  if (codipad_v8_rx_begin == rx) codipad_v8_rx_begin = codipad_v8_rx_end = codipad_v8_rw_begin = 0;
}

void *NodePageAllocator::GetRandomMmapAddr() {
  // A hint only; mmap still applies ASLR and selects the actual reservation.
  std::lock_guard<std::mutex> lock(mutex);
  randomSeed = randomSeed * 6364136223846793005ULL + 1442695040888963407ULL;
  return reinterpret_cast<void *>((randomSeed & 0x00000007ffffffffULL) & ~(page - 1));
}

bool NodePageAllocator::owned(void *p, size_t n, bool &code) const {
  auto address = reinterpret_cast<uintptr_t>(p);
  if (!n || address % page || n % page) return false;
  code = contains(codeAllocations, address, n);
  return code || contains(dataAllocations, address, n);
}

bool NodePageAllocator::apply(void *p, size_t n, Permission perm, bool code) {
  if (!code && (perm == kReadWriteExecute || perm == kReadExecute || perm == kNoAccessWillJitLater))
    return false;
  int prot = protection(perm);
  if (mprotect(p, n, prot)) return false;
  // Match Darwin's reusable-page accounting when V8 recommits discarded data.
  if (!code && prot != PROT_NONE && madvise(p, n, MADV_FREE_REUSE)) return false;
  if (code) {
    auto alias = rw + reinterpret_cast<uintptr_t>(p) - rx;
    if (mprotect(reinterpret_cast<void *>(alias), n,
                 prot == PROT_NONE ? PROT_NONE : PROT_READ | PROT_WRITE))
      return false;
  }
  return true;
}

void *NodePageAllocator::AllocatePages(void *hint, size_t n, size_t alignment, Permission perm) {
  if (!n || n % page || alignment < page || (alignment & (alignment - 1)) ||
      n > SIZE_MAX - alignment)
    return nullptr;
  std::lock_guard<std::mutex> lock(mutex);
  bool code = perm == kNoAccessWillJitLater || perm == kReadWriteExecute || perm == kReadExecute;
  if (code) {
    for (auto it = freeCode.begin(); it != freeCode.end(); ++it) {
      size_t offset = ((rx + it->first + alignment - 1) & ~(alignment - 1)) - rx;
      size_t padding = offset - it->first;
      if (padding > it->second || n > it->second - padding) continue;
      auto start = it->first, remaining = it->second;
      void *result = reinterpret_cast<void *>(rx + offset);
      // Zero on reuse, including reservations whose first requested state is guarded.
      if (mprotect(reinterpret_cast<void *>(rw + offset), n, PROT_READ | PROT_WRITE)) return nullptr;
      memset(reinterpret_cast<void *>(rw + offset), 0, n);
      if (!apply(result, n, perm, true)) return nullptr;
      freeCode.erase(it);
      if (padding) freeCode.emplace(start, padding);
      if (remaining - padding > n) freeCode.emplace(offset + n, remaining - padding - n);
      codeAllocations.emplace(rx + offset, n);
      return result;
    }
    return nullptr;
  }
  size_t reserved = n + alignment;
  void *block = mmap(hint, reserved, PROT_NONE, MAP_PRIVATE | MAP_ANON, -1, 0);
  if (block == MAP_FAILED) return nullptr;
  auto original = reinterpret_cast<uintptr_t>(block);
  auto address = (original + alignment - 1) & ~(alignment - 1);
  if (address > original) munmap(block, address - original);
  if (reserved > address - original + n)
    munmap(reinterpret_cast<void *>(address + n), reserved - (address - original) - n);
  void *result = reinterpret_cast<void *>(address);
  if (!apply(result, n, perm, false)) {
    munmap(result, n);
    return nullptr;
  }
  dataAllocations.emplace(address, n);
  return result;
}

void NodePageAllocator::releaseCode(uintptr_t address, size_t n) {
  size_t offset = address - rx;
  auto after = freeCode.lower_bound(offset);
  if (after != freeCode.end() && offset + n == after->first) {
    n += after->second;
    after = freeCode.erase(after);
  }
  if (after != freeCode.begin()) {
    auto before = std::prev(after);
    if (before->first + before->second == offset) {
      offset = before->first;
      n += before->second;
      freeCode.erase(before);
    }
  }
  freeCode.emplace(offset, n);
}

bool NodePageAllocator::FreePages(void *p, size_t n) {
  std::lock_guard<std::mutex> lock(mutex);
  auto address = reinterpret_cast<uintptr_t>(p);
  auto code = codeAllocations.find(address);
  if (code != codeAllocations.end() && code->second == n) {
    if (!apply(p, n, kNoAccess, true)) return false;
    codeAllocations.erase(code);
    releaseCode(address, n);
    return true;
  }
  auto data = dataAllocations.find(address);
  if (data == dataAllocations.end() || data->second != n || munmap(p, n)) return false;
  dataAllocations.erase(data);
  return true;
}

bool NodePageAllocator::ReleasePages(void *p, size_t n, size_t remaining) {
  if (!remaining || remaining >= n || remaining % page) return false;
  std::lock_guard<std::mutex> lock(mutex);
  auto address = reinterpret_cast<uintptr_t>(p);
  auto code = codeAllocations.find(address);
  if (code != codeAllocations.end() && code->second == n) {
    if (!apply(reinterpret_cast<void *>(address + remaining), n - remaining, kNoAccess, true))
      return false;
    code->second = remaining;
    releaseCode(address + remaining, n - remaining);
    return true;
  }
  auto data = dataAllocations.find(address);
  if (data == dataAllocations.end() || data->second != n ||
      munmap(reinterpret_cast<void *>(address + remaining), n - remaining))
    return false;
  data->second = remaining;
  return true;
}

bool NodePageAllocator::SetPermissions(void *p, size_t n, Permission perm) {
  std::lock_guard<std::mutex> lock(mutex);
  bool code;
  return owned(p, n, code) && apply(p, n, perm, code);
}

bool NodePageAllocator::DiscardSystemPages(void *p, size_t n) {
  std::lock_guard<std::mutex> lock(mutex);
  bool code;
  if (!owned(p, n, code)) return false;
  // Retain the bounded debugger-prepared code backing; never discard its tags.
  return code || !madvise(p, n, MADV_FREE_REUSABLE);
}

bool NodePageAllocator::DecommitPages(void *p, size_t n) {
  std::lock_guard<std::mutex> lock(mutex);
  bool code;
  if (!owned(p, n, code)) return false;
  if (code) {
    auto alias = reinterpret_cast<void *>(rw + reinterpret_cast<uintptr_t>(p) - rx);
    if (mprotect(alias, n, PROT_READ | PROT_WRITE)) return false;
    memset(alias, 0, n);
    return apply(p, n, kNoAccess, true);
  }
  return mmap(p, n, PROT_NONE, MAP_FIXED | MAP_PRIVATE | MAP_ANON, -1, 0) != MAP_FAILED;
}

}  // namespace codipadnode
