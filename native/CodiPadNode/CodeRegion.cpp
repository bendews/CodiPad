#include "CodeRegion.h"

#include <TargetConditionals.h>
#include <libkern/OSCacheControl.h>
#include <mach/mach.h>
#include <sys/mman.h>
#include <sys/sysctl.h>
#include <unistd.h>

#include <algorithm>
#include <cstring>

namespace codipadnode {
namespace {

bool fail(std::string *error, const char *what) {
  if (error) *error = what ? what : "unknown error";
  return false;
}

#if TARGET_OS_IPHONE && !TARGET_OS_SIMULATOR
// Device: pages are only executable when a tracer prepared them. The path stays
// opt-in through ExecutablePages::DebuggerPrepared and is never taken silently.
#endif

// Public KERN_PROC_PID status, not csops. Issuing the breakpoint without an
// attached handler is fatal, so the path is opt-in and refuses to run untraced.
bool traced() {
  int mib[] = {CTL_KERN, KERN_PROC, KERN_PROC_PID, getpid()};
  kinfo_proc info{};
  size_t size = sizeof(info);
  return !sysctl(mib, 4, &info, &size, nullptr, 0) && size == sizeof(info) &&
         (info.kp_proc.p_flag & P_TRACED);
}

struct DebuggerAllocation { void *address; size_t capacity; };

__attribute__((naked, noinline)) DebuggerAllocation requestPages(void *, size_t) {
  __asm__("mov x16, #1\n brk #0xf00d\n ret");
}

__attribute__((naked, noinline)) void releaseDebugger(bool, const char *, size_t) {
  __asm__("mov x16, #0\n brk #0xf00d\n ret");
}

__attribute__((naked, noinline)) void cancelDebugger() {
  __asm__("mov x16, #2\n brk #0xf00d\n ret");
}

// Debugger preparation can split a contiguous pool into several VM entries.
// Validate every entry and reject gaps or writable executable pages.
bool readableExecutable(char *address, size_t length) {
  auto pointer = reinterpret_cast<vm_address_t>(address);
  while (length) {
    vm_address_t start = pointer;
    vm_size_t size = 0;
    vm_region_basic_info_data_64_t info{};
    mach_msg_type_number_t count = VM_REGION_BASIC_INFO_COUNT_64;
    mach_port_t object = MACH_PORT_NULL;
    auto status = vm_region_64(mach_task_self(), &start, &size, VM_REGION_BASIC_INFO_64,
                               reinterpret_cast<vm_region_info_t>(&info), &count, &object);
    if (object != MACH_PORT_NULL) mach_port_deallocate(mach_task_self(), object);
    if (status != KERN_SUCCESS || start > pointer || pointer - start >= size ||
        !(info.protection & VM_PROT_READ) || !(info.protection & VM_PROT_EXECUTE) ||
        (info.protection & VM_PROT_WRITE))
      return false;
    auto covered = std::min<size_t>(length, size - (pointer - start));
    if (pointer > UINTPTR_MAX - covered) return false;
    pointer += covered;
    length -= covered;
  }
  return true;
}

// A successful munmap can leave a permanent PROT_NONE entry behind. Query
// the map itself and treat any intervening entry or query failure as occupied.
bool unmappedRange(char *address, size_t length) {
  auto start = reinterpret_cast<vm_address_t>(address);
  if (!length || start > UINTPTR_MAX - length) return false;
  const auto end = start + length;
  vm_address_t next = start;
  vm_size_t size = 0;
  vm_region_basic_info_data_64_t info{};
  mach_msg_type_number_t count = VM_REGION_BASIC_INFO_COUNT_64;
  mach_port_t object = MACH_PORT_NULL;
  const auto status = vm_region_64(mach_task_self(), &next, &size, VM_REGION_BASIC_INFO_64,
                                   reinterpret_cast<vm_region_info_t>(&info), &count, &object);
  if (object != MACH_PORT_NULL && mach_port_deallocate(mach_task_self(), object) != KERN_SUCCESS)
    return false;
  if (status == KERN_INVALID_ADDRESS) return true;
  return status == KERN_SUCCESS && next >= end;
}

bool executableUnavailable(std::string *error) {
  return fail(error,
              "executable code pages unavailable: this process kept the mapping writable or "
              "non-executable. The debugger-prepared path is opt-in and needs a tracer already "
              "attached; no distribution entitlement is assumed or asserted here");
}

// Extended virtual addressing can place an unconstrained alias far from the
// executable pool. Both emitters use ARM64 page-relative references, so search
// from the lowest eligible address and validate the result before publishing it.
// ANYWHERE never overwrites an existing mapping; an out-of-range result is ours
// to discard. Large guest data windows do not have this code-alias constraint.
bool aliasNearby(char *source, size_t bytes, size_t page, char **destination,
                 std::string *error, bool *rangeUnavailable = nullptr) {
  if (rangeUnavailable) *rangeUnavailable = false;
  const uintptr_t origin = reinterpret_cast<uintptr_t>(source);
  const uintptr_t reach = (UINT64_C(1) << 32) - bytes - page;
  vm_address_t alias = origin > reach ? origin - reach : page;
  vm_prot_t current = 0, maximum = 0;
  auto status = vm_remap(mach_task_self(), &alias, bytes, 0, VM_FLAGS_ANYWHERE,
      mach_task_self(), origin, false, &current, &maximum, VM_INHERIT_NONE);
  const auto anywhereStatus = status;
  kern_return_t firstOtherStatus = KERN_SUCCESS;
  size_t fixedAttempts = 0;
  size_t noSpaceFailures = 0;
  if (status == KERN_SUCCESS) {
    const uintptr_t distance = alias > origin ? alias - origin : origin - alias;
    if (distance < (UINT64_C(1) << 32) - bytes) {
      *destination = reinterpret_cast<char *>(alias);
      return true;
    }
    if (vm_deallocate(mach_task_self(), alias, bytes) != KERN_SUCCESS)
      return fail(error, "could not release the out-of-range code alias");
  }

  // ANYWHERE may ignore the hint and choose an address beyond ADRP's reach.
  // FIXED without OVERWRITE fails on occupied ranges, so probing cannot
  // replace existing mappings. Do not probe ranges overlapping the source.
  constexpr size_t stride = 64u * 1024 * 1024;
  for (size_t offset = bytes + page; offset < reach; offset += stride) {
    for (int direction : {1, -1}) {
      if ((direction > 0 && origin > UINTPTR_MAX - offset) ||
          (direction < 0 && origin <= offset)) continue;
      alias = direction > 0 ? origin + offset : origin - offset;
      status = vm_remap(mach_task_self(), &alias, bytes, 0, VM_FLAGS_FIXED,
          mach_task_self(), origin, false, &current, &maximum, VM_INHERIT_NONE);
      ++fixedAttempts;
      if (status == KERN_SUCCESS) {
        *destination = reinterpret_cast<char *>(alias);
        return true;
      }
      if (status == KERN_NO_SPACE) ++noSpaceFailures;
      else if (firstOtherStatus == KERN_SUCCESS) firstOtherStatus = status;
    }
  }
  // Coarse probes may miss a usable hole. Walk VM entries without overwriting
  // them, then make one fixed attempt per observed gap. The walk is bounded
  // because a changing map or a very fragmented process need not converge.
  uintptr_t cursor = origin > reach ? origin - reach : page;
  const uintptr_t last = origin <= UINTPTR_MAX - reach ? origin + reach : UINTPTR_MAX - page;
  size_t gapQueries = 0;
  kern_return_t gapStatus = KERN_SUCCESS;
  while (cursor <= last && gapQueries < 4096) {
    if (cursor > UINTPTR_MAX - bytes) break;
    ++gapQueries;
    vm_address_t next = cursor;
    vm_size_t regionSize = 0;
    vm_region_basic_info_data_64_t info{};
    mach_msg_type_number_t count = VM_REGION_BASIC_INFO_COUNT_64;
    mach_port_t object = MACH_PORT_NULL;
    const auto query = vm_region_64(mach_task_self(), &next, &regionSize, VM_REGION_BASIC_INFO_64,
                                    reinterpret_cast<vm_region_info_t>(&info), &count, &object);
    if (object != MACH_PORT_NULL && mach_port_deallocate(mach_task_self(), object) != KERN_SUCCESS) {
      gapStatus = KERN_FAILURE;
      break;
    }
    if (query != KERN_SUCCESS && query != KERN_INVALID_ADDRESS) { gapStatus = query; break; }
    const bool noNext = query == KERN_INVALID_ADDRESS;
    if (noNext || (next > cursor && next - cursor >= bytes)) {
      alias = cursor;
      status = vm_remap(mach_task_self(), &alias, bytes, 0, VM_FLAGS_FIXED,
          mach_task_self(), origin, false, &current, &maximum, VM_INHERIT_NONE);
      ++fixedAttempts;
      if (status == KERN_SUCCESS) {
        *destination = reinterpret_cast<char *>(alias);
        return true;
      }
      if (status == KERN_NO_SPACE) ++noSpaceFailures;
      else if (firstOtherStatus == KERN_SUCCESS) firstOtherStatus = status;
    }
    if (noNext) break;
    if (!regionSize || next > UINTPTR_MAX - regionSize || next + regionSize <= cursor) {
      gapStatus = KERN_FAILURE;
      break;
    }
    cursor = next + regionSize;
  }
  if (rangeUnavailable) *rangeUnavailable = true;
  if (error) {
    *error = "code alias remap failed (anywhere status " + std::to_string(anywhereStatus) +
        ", fixed attempts " + std::to_string(fixedAttempts) +
        ", fixed no-space " + std::to_string(noSpaceFailures) +
        ", first other fixed status " + std::to_string(firstOtherStatus) +
        ", gap queries " + std::to_string(gapQueries) +
        ", gap query status " + std::to_string(gapStatus) + ")";
  }
  return false;
}

}  // namespace

bool DebuggerAttached() { return traced(); }

bool CancelDebuggerPreparation() {
  if (!traced()) return false;
  cancelDebugger();
  return !traced();
}

std::shared_ptr<CodeRegion> CodeRegion::Create(size_t bytes, ExecutablePages pages,
                                               std::string *error, bool allow_debugger_fallback) {
  const size_t pageSize = static_cast<size_t>(getpagesize());
  if (!bytes || bytes > 1280u * 1024 * 1024 || bytes % pageSize) {
    fail(error, "JIT capacity must be page aligned and between one page and 1280 MiB");
    return nullptr;
  }
  // Node and the translated ARM64 engine share one process-wide dual mapping.
  // The first caller must reserve the complete pool before either runtime
  // starts; later callers may request a smaller view of that same pool.
  static std::mutex processMutex;
  static std::weak_ptr<CodeRegion> processRegion;
  std::lock_guard<std::mutex> lock(processMutex);
  if (auto existing = processRegion.lock()) {
    if (existing->capacity < bytes || existing->debugger !=
                                          (pages == ExecutablePages::DebuggerPrepared)) {
      fail(error, "process code pool already exists with a different capacity or page policy");
      return nullptr;
    }
    return existing;
  }
  auto region = CreateUnshared(bytes, pages, error, allow_debugger_fallback);
  if (region) processRegion = region;
  return region;
}

std::shared_ptr<CodeRegion> CodeRegion::CreateUnshared(size_t bytes, ExecutablePages pages,
                                                       std::string *error, bool allow_debugger_fallback) {
  auto region = std::shared_ptr<CodeRegion>(new CodeRegion);
  region->page = static_cast<size_t>(getpagesize());
  if (!bytes || bytes > 1280u * 1024 * 1024 || bytes % region->page) {
    fail(error, "JIT capacity must be page aligned and between one page and 1280 MiB");
    return nullptr;
  }
  region->capacity = bytes;
  struct DetachOnReturn {
    bool active = false;
    bool prepared = false;
    std::string *error = nullptr;
    size_t capacity = 0;
    ~DetachOnReturn() { if (active) releaseDebugger(prepared, error ? error->c_str() : nullptr, capacity); }
  } detacher{false, false, error, 0};

  if (pages == ExecutablePages::DebuggerPrepared) {
    if (!traced()) {
      fail(error,
           "debugger-prepared pages requested but no tracer is attached; the JIT handler must be "
           "arranged before creating the region");
      return nullptr;
    }
    auto allocation = requestPages(nullptr, bytes);
    region->rx = static_cast<char *>(allocation.address);
    // The debugger may retry a large shared-pool request at the original size.
    // No other size reduction is accepted, and the caller must repartition it.
    if (region->rx && allocation.capacity != bytes) {
      if (!allow_debugger_fallback || bytes <= 512u * 1024 * 1024 ||
          allocation.capacity != 512u * 1024 * 1024) {
        if (allocation.capacity && allocation.capacity <= bytes &&
            allocation.capacity % region->page == 0)
          munmap(region->rx, allocation.capacity);
        region->rx = nullptr;
        releaseDebugger(false, "debugger returned an unexpected executable pool capacity", 0);
        fail(error, "debugger returned an unexpected executable pool capacity");
        return nullptr;
      }
      bytes = allocation.capacity;
      region->capacity = bytes;
    }
    // Keep the debugger until the complete pool, including both protections,
    // has passed validation. Failure also releases the connection once.
    detacher.active = true;
    if (!region->rx || reinterpret_cast<uintptr_t>(region->rx) % region->page) {
      region->rx = nullptr;
      fail(error, "debugger did not supply a page-aligned executable region");
      return nullptr;
    }
    if (!readableExecutable(region->rx, bytes)) {
      region->rx = nullptr;
      executableUnavailable(error);
      return nullptr;
    }
    region->debugger = true;
    bool rangeUnavailable = false;
    if (!aliasNearby(region->rx, bytes, region->page, &region->rw, error, &rangeUnavailable)) {
      constexpr size_t fallbackBytes = 512u * 1024 * 1024;
      if (!allow_debugger_fallback || !rangeUnavailable || bytes <= fallbackBytes)
        return nullptr;
      // Never unmap this suffix twice: after the attempt, even part of it may
      // be occupied by another thread. Treat an uncertain release as fatal.
      char *tail = region->rx + fallbackBytes;
      size_t tailBytes = bytes - fallbackBytes;
      int unmapResult = munmap(tail, tailBytes);
      bytes = fallbackBytes;
      region->capacity = bytes;
      if (unmapResult || !unmappedRange(tail, tailBytes)) {
        fail(error, "debugger executable tail could not be confirmed released; restart required");
        return nullptr;
      }
      if (error) error->clear();
      if (!aliasNearby(region->rx, bytes, region->page, &region->rw, error))
        return nullptr;
    }
    if (mprotect(region->rw, bytes, PROT_READ | PROT_WRITE)) {
      fail(error, "debugger alias could not be made writable");
      return nullptr;
    }
  } else {
    region->rw = static_cast<char *>(
        mmap(nullptr, bytes, PROT_READ | PROT_WRITE, MAP_PRIVATE | MAP_ANON, -1, 0));
    if (region->rw == MAP_FAILED) {
      region->rw = nullptr;
      fail(error, "platform working-memory allocation failed");
      return nullptr;
    }
    if (!aliasNearby(region->rw, bytes, region->page, &region->rx, error)) return nullptr;
    if (mprotect(region->rx, bytes, PROT_READ | PROT_EXEC)) {
      executableUnavailable(error);
      return nullptr;
    }
  }

  if (!readableExecutable(region->rx, bytes)) {
    executableUnavailable(error);
    return nullptr;
  }
  // Keep direct ADRP-relative data references within ARM64's ±4 GiB window.
  auto distance = uintptr_t(region->rx) > uintptr_t(region->rw)
                      ? uintptr_t(region->rx) - uintptr_t(region->rw)
                      : uintptr_t(region->rw) - uintptr_t(region->rx);
  if (distance + bytes >= uint64_t(1) << 32) {
    fail(error, "RX/RW aliases exceed ARM64 page-relative addressing range");
    return nullptr;
  }
  region->free.emplace(0, bytes);
  detacher.capacity = region->capacity;
  detacher.prepared = true;
  return region;
}

CodeRegion::~CodeRegion() {
  if (rx) munmap(rx, capacity);
  if (rw) munmap(rw, capacity);
}

std::unique_ptr<CodeRegion::Lease> CodeRegion::Allocate(size_t bytes, std::string *error,
                                                        bool initialize) {
  if (!bytes || bytes > capacity) {
    fail(error, "native allocation exceeds the bounded JIT pool");
    return nullptr;
  }
  bytes = (bytes + page - 1) / page * page;
  std::lock_guard<std::mutex> lock(mutex);
  for (auto i = free.begin(); i != free.end(); ++i) {
    if (i->second < bytes) continue;
    size_t start = i->first, remaining = i->second - bytes;
    free.erase(i);
    if (remaining) free.emplace(start + bytes, remaining);
    auto lease = std::unique_ptr<Lease>(new Lease{shared_from_this(), start, bytes});
    if (initialize) memset(lease->writable(), 0, bytes);
    return lease;
  }
  fail(error, "native JIT pool exhausted; live code cannot be recycled");
  return nullptr;
}

void CodeRegion::release(size_t offset, size_t bytes) {
  std::lock_guard<std::mutex> lock(mutex);
  auto next = free.lower_bound(offset);
  if (next != free.end() && offset + bytes == next->first) {
    bytes += next->second;
    free.erase(next);
  }
  next = free.lower_bound(offset);
  if (next != free.begin()) {
    auto prev = std::prev(next);
    if (prev->first + prev->second == offset) {
      offset = prev->first;
      bytes += prev->second;
      free.erase(prev);
    }
  }
  free.emplace(offset, bytes);
}

CodeRegion::Lease::~Lease() { owner->release(offset, size); }
char *CodeRegion::Lease::writable() const { return owner->rw + offset; }
char *CodeRegion::Lease::executable() const { return owner->rx + offset; }
void CodeRegion::Lease::publish() const {
  sys_dcache_flush(writable(), size);
  sys_icache_invalidate(executable(), size);
}

}  // namespace codipadnode
