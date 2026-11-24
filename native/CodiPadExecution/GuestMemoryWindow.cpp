#include "GuestMemoryWindow.h"

#include <cerrno>
#include <chrono>
#include <cstring>
#include <mach/mach.h>
#include <memory>
#include <new>
#include <sys/mman.h>
#include <unistd.h>

namespace {
constexpr uint64_t kWindowBytes = UINT64_C(1) << 32;
constexpr size_t kGuestPageBytes = 4096;
constexpr uint8_t kMapped = CodiPadGuestPageMapped;
constexpr uint8_t kDirectRead = CodiPadGuestPageDirectRead;
constexpr uint8_t kDirectWrite = CodiPadGuestPageDirectWrite;

void setError(int *out, int value) { if (out) *out = value; }
bool validPermissions(unsigned permissions) {
  return (permissions & ~(CodiPadGuestMemoryRead | CodiPadGuestMemoryWrite)) == 0;
}
int protection(unsigned permissions) {
  return ((permissions & CodiPadGuestMemoryRead) ? PROT_READ : 0) |
         ((permissions & CodiPadGuestMemoryWrite) ? PROT_WRITE : 0);
}
}  // namespace

struct CodiPadGuestMemoryWindow {
  void *base = MAP_FAILED;
  size_t page = 0;
  bool usable = true;
  uint64_t generation = 1;
  std::unique_ptr<uint8_t[]> pages;
  std::unique_ptr<void *[]> backing;
  std::unique_ptr<bool[]> owned;

  ~CodiPadGuestMemoryWindow() {
    if (base != MAP_FAILED) munmap(base, kWindowBytes);
    if (backing && owned) {
      for (size_t index = 0; index < kWindowBytes / page; ++index)
        if (backing[index] && owned[index]) munmap(backing[index], page);
    }
  }

  CodiPadGuestMemoryResult range(uint64_t address, size_t length) const {
    if (!usable || generation == UINT64_MAX) return CodiPadGuestMemoryHostFailure;
    if (!length || address % kGuestPageBytes || length % kGuestPageBytes)
      return CodiPadGuestMemoryInvalidRange;
    if (address >= kWindowBytes || length > kWindowBytes - address)
      return CodiPadGuestMemoryRequiresSoftwareMMU;
    return CodiPadGuestMemoryOK;
  }

  uint8_t *at(uint64_t address) const {
    return static_cast<uint8_t *>(base) + address;
  }

  bool all(uint64_t address, size_t length, unsigned required, bool mapped) const {
    const size_t end = (address + length - 1) / kGuestPageBytes;
    for (size_t index = address / kGuestPageBytes; index <= end; ++index) {
      if (((pages[index] & kMapped) != 0) != mapped ||
          (pages[index] & required) != required) return false;
    }
    return true;
  }

  void mark(uint64_t address, size_t length, uint8_t value) {
    const size_t end = (address + length) / kGuestPageBytes;
    for (size_t index = address / kGuestPageBytes; index < end; ++index) pages[index] = value;
  }

  bool aliasBacking(size_t group, void *data, bool takeOwnership) {
    vm_address_t target = reinterpret_cast<vm_address_t>(at(group * page));
    vm_prot_t current = 0, maximum = 0;
    const kern_return_t status = vm_remap(mach_task_self(), &target, page, 0,
        VM_FLAGS_FIXED | VM_FLAGS_OVERWRITE, mach_task_self(),
        reinterpret_cast<vm_address_t>(data), false, &current, &maximum, VM_INHERIT_NONE);
    if (status != KERN_SUCCESS) {
      errno = status == KERN_NO_SPACE ? ENOMEM : EIO;
      return false;
    }
    backing[group] = data;
    owned[group] = takeOwnership;
    return true;
  }

  bool ensureBacking(size_t group) {
    if (backing[group]) return true;
    void *data = mmap(nullptr, page, PROT_READ | PROT_WRITE, MAP_PRIVATE | MAP_ANON, -1, 0);
    if (data == MAP_FAILED) return false;
    if (!aliasBacking(group, data, true)) { munmap(data, page); return false; }
    return true;
  }

  bool protectGroups(uint64_t address, size_t length) {
    const size_t last = (address + length - 1) / page;
    for (size_t group = address / page; group <= last; ++group) {
      const size_t begin = group * page / kGuestPageBytes;
      const size_t end = begin + page / kGuestPageBytes;
      unsigned common = CodiPadGuestMemoryRead | CodiPadGuestMemoryWrite;
      bool anyMapped = false;
      for (size_t index = begin; index < end; ++index) {
        anyMapped |= (pages[index] & kMapped) != 0;
        common &= (pages[index] & kMapped) ? pages[index] : 0;
      }
      // Do not grant host write-only access where the CPU also permits reads.
      if (!(common & CodiPadGuestMemoryRead)) common = 0;
      if (!anyMapped && backing[group]) {
        if (mmap(at(group * page), page, PROT_NONE, MAP_FIXED | MAP_PRIVATE | MAP_ANON,
                 -1, 0) == MAP_FAILED) return false;
        if (owned[group]) munmap(backing[group], page);
        backing[group] = nullptr;
        owned[group] = false;
      } else if (backing[group] && mprotect(at(group * page), page, protection(common))) return false;
      for (size_t index = begin; index < end; ++index) {
        pages[index] &= ~(kDirectRead | kDirectWrite);
        if (common & CodiPadGuestMemoryRead) pages[index] |= kDirectRead;
        if (common & CodiPadGuestMemoryWrite) pages[index] |= kDirectWrite;
      }
    }
    return true;
  }

  CodiPadGuestMemoryResult failed(int *host_error) {
    setError(host_error, errno);
    usable = false;
    return CodiPadGuestMemoryHostFailure;
  }
};

extern "C" CodiPadGuestMemoryWindow *CodiPadGuestMemoryWindowCreate(int *host_error) {
  setError(host_error, 0);
  const long page = sysconf(_SC_PAGESIZE);
  if (sizeof(size_t) < 8 || page <= 0 || page % kGuestPageBytes ||
      kWindowBytes % static_cast<size_t>(page)) {
    setError(host_error, ENOTSUP);
    return nullptr;
  }
  auto window = std::unique_ptr<CodiPadGuestMemoryWindow>(new (std::nothrow) CodiPadGuestMemoryWindow);
  if (!window) { setError(host_error, ENOMEM); return nullptr; }
  window->page = static_cast<size_t>(page);
  window->pages.reset(new (std::nothrow) uint8_t[kWindowBytes / kGuestPageBytes]());
  window->backing.reset(new (std::nothrow) void *[kWindowBytes / window->page]());
  window->owned.reset(new (std::nothrow) bool[kWindowBytes / window->page]());
  if (!window->pages || !window->backing || !window->owned) { setError(host_error, ENOMEM); return nullptr; }
  window->base = mmap(nullptr, kWindowBytes, PROT_NONE, MAP_PRIVATE | MAP_ANON, -1, 0);
  if (window->base == MAP_FAILED) { setError(host_error, errno); return nullptr; }
  return window.release();
}

extern "C" CodiPadGuestMemoryResult CodiPadGuestMemoryWindowRelease(CodiPadGuestMemoryWindow *window,
                                                                int *host_error) {
  setError(host_error, 0);
  if (!window) return CodiPadGuestMemoryOK;
  window->usable = false;
  // Borrowed backing must remain pinned until the entire alias reservation is
  // gone. Keep the object and its ownership records intact on any host error.
  if (window->base != MAP_FAILED && munmap(window->base, kWindowBytes))
    return window->failed(host_error);
  window->base = MAP_FAILED;
  delete window;
  return CodiPadGuestMemoryOK;
}

extern "C" void CodiPadGuestMemoryWindowDestroy(CodiPadGuestMemoryWindow *window) {
  (void)CodiPadGuestMemoryWindowRelease(window, nullptr);
}
extern "C" size_t CodiPadGuestMemoryWindowHostPageSize(const CodiPadGuestMemoryWindow *window) {
  return window ? window->page : 0;
}

extern "C" CodiPadGuestMemoryResult CodiPadGuestMemoryWindowMap(CodiPadGuestMemoryWindow *window,
    uint64_t address, size_t length, unsigned permissions, int *host_error) {
  setError(host_error, 0);
  if (!window || !validPermissions(permissions)) return CodiPadGuestMemoryInvalidRange;
  const auto result = window->range(address, length);
  if (result != CodiPadGuestMemoryOK) return result;
  if (!window->all(address, length, 0, false)) return CodiPadGuestMemoryMappingConflict;
  const size_t last = (address + length - 1) / window->page;
  for (size_t group = address / window->page; group <= last; ++group)
    if (window->backing[group] && !window->owned[group]) return CodiPadGuestMemoryRequiresSoftwareMMU;
  for (size_t group = address / window->page; group <= last; ++group)
    if (!window->ensureBacking(group)) return window->failed(host_error);
  for (uint64_t current = address; current < address + length; current += kGuestPageBytes)
    std::memset(static_cast<uint8_t *>(window->backing[current / window->page]) + current % window->page,
                0, kGuestPageBytes);
  window->mark(address, length, kMapped | permissions);
  if (!window->protectGroups(address, length)) return window->failed(host_error);
  ++window->generation;
  return CodiPadGuestMemoryOK;
}

extern "C" CodiPadGuestMemoryResult CodiPadGuestMemoryWindowProtect(CodiPadGuestMemoryWindow *window,
    uint64_t address, size_t length, unsigned permissions, int *host_error) {
  setError(host_error, 0);
  if (!window || !validPermissions(permissions)) return CodiPadGuestMemoryInvalidRange;
  const auto result = window->range(address, length);
  if (result != CodiPadGuestMemoryOK) return result;
  if (!window->all(address, length, 0, true)) return CodiPadGuestMemoryMappingConflict;
  window->mark(address, length, kMapped | permissions);
  if (!window->protectGroups(address, length)) return window->failed(host_error);
  ++window->generation;
  return CodiPadGuestMemoryOK;
}

extern "C" CodiPadGuestMemoryResult CodiPadGuestMemoryWindowDiscard(CodiPadGuestMemoryWindow *window,
    uint64_t address, size_t length, int *host_error) {
  setError(host_error, 0);
  if (!window) return CodiPadGuestMemoryInvalidRange;
  const auto result = window->range(address, length);
  if (result != CodiPadGuestMemoryOK) return result;
  // Zero only removed anonymous guest pages through the helper alias. Other
  // subpages retain their exact backing and bytes; a later Map starts zeroed.
  for (uint64_t current = address; current < address + length; current += kGuestPageBytes)
    if ((window->pages[current / kGuestPageBytes] & kMapped) && window->owned[current / window->page])
      std::memset(static_cast<uint8_t *>(window->backing[current / window->page]) + current % window->page,
                  0, kGuestPageBytes);
  window->mark(address, length, 0);
  if (!window->protectGroups(address, length)) return window->failed(host_error);
  ++window->generation;
  return CodiPadGuestMemoryOK;
}

extern "C" void *CodiPadGuestMemoryWindowAddress(CodiPadGuestMemoryWindow *window,
    uint64_t address, size_t length, unsigned access) {
  if (!window || !window->usable || !length || !access || !validPermissions(access) ||
      address >= kWindowBytes || length > kWindowBytes - address) return nullptr;
  const unsigned direct = ((access & CodiPadGuestMemoryRead) ? kDirectRead : 0) |
                          ((access & CodiPadGuestMemoryWrite) ? kDirectWrite : 0);
  if (!window->all(address, length, access | direct, true)) return nullptr;
  return window->at(address);
}

extern "C" CodiPadGuestMemoryAccess CodiPadGuestMemoryWindowClassify(const CodiPadGuestMemoryWindow *window,
    uint64_t address, size_t length, unsigned access) {
  if (!window || !window->usable || !length || !access || !validPermissions(access) ||
      address >= kWindowBytes || length > kWindowBytes - address) return CodiPadGuestMemoryMMU;
  if (length > kGuestPageBytes - address % kGuestPageBytes) return CodiPadGuestMemoryMMU;
  const uint8_t entry = window->pages[address / kGuestPageBytes];
  if (entry & CodiPadGuestPageIndirect) return CodiPadGuestMemoryMMU;
  if ((entry & (kMapped | access)) != (kMapped | access)) return CodiPadGuestMemoryGuestFault;
  const unsigned direct = ((access & CodiPadGuestMemoryRead) ? kDirectRead : 0) |
                          ((access & CodiPadGuestMemoryWrite) ? kDirectWrite : 0);
  return (entry & direct) == direct ? CodiPadGuestMemoryDirect : CodiPadGuestMemoryMMU;
}

extern "C" void *CodiPadGuestMemoryWindowBacking(CodiPadGuestMemoryWindow *window,
    uint64_t address, size_t length, unsigned access) {
  if (!window || !window->usable || !length || !access || !validPermissions(access) ||
      address >= kWindowBytes || length > kWindowBytes - address ||
      length > window->page - address % window->page ||
      !window->all(address, length, access, true)) return nullptr;
  return static_cast<uint8_t *>(window->backing[address / window->page]) + address % window->page;
}

extern "C" CodiPadGuestMemoryResult CodiPadGuestMemoryWindowBind(CodiPadGuestMemoryWindow *window,
    uint64_t address, size_t length, void *source, unsigned permissions, int *host_error) {
  setError(host_error, 0);
  if (!window || !source || !validPermissions(permissions)) return CodiPadGuestMemoryInvalidRange;
  const auto result = window->range(address, length);
  if (result != CodiPadGuestMemoryOK) return result;
  const auto sourceAddress = reinterpret_cast<uintptr_t>(source);
  if (address % window->page || length % window->page || sourceAddress % window->page)
    return CodiPadGuestMemoryRequiresSoftwareMMU;
  if (length > UINTPTR_MAX - sourceAddress) return CodiPadGuestMemoryInvalidRange;
  const auto windowAddress = reinterpret_cast<uintptr_t>(window->base);
  if (sourceAddress < windowAddress + kWindowBytes && windowAddress < sourceAddress + length)
    return CodiPadGuestMemoryInvalidRange;
  if (!window->all(address, length, 0, false)) return CodiPadGuestMemoryMappingConflict;
  const size_t first = address / window->page;
  const size_t last = (address + length - 1) / window->page;
  for (size_t group = first; group <= last; ++group)
    if (window->backing[group]) return CodiPadGuestMemoryMappingConflict;
  for (size_t group = first; group <= last; ++group) {
    auto *data = static_cast<uint8_t *>(source) + (group - first) * window->page;
    if (!window->aliasBacking(group, data, false)) return window->failed(host_error);
  }
  window->mark(address, length, kMapped | permissions);
  if (!window->protectGroups(address, length)) return window->failed(host_error);
  ++window->generation;
  return CodiPadGuestMemoryOK;
}

extern "C" CodiPadGuestMemoryResult CodiPadGuestMemoryWindowUnbind(CodiPadGuestMemoryWindow *window,
    uint64_t address, size_t length, int *host_error) {
  setError(host_error, 0);
  if (!window) return CodiPadGuestMemoryInvalidRange;
  const auto result = window->range(address, length);
  if (result != CodiPadGuestMemoryOK) return result;
  const uint64_t first = address / window->page * window->page;
  const uint64_t end = (address + length + window->page - 1) / window->page * window->page;
  window->mark(first, end - first, CodiPadGuestPageIndirect);
  if (!window->protectGroups(first, end - first)) return window->failed(host_error);
  ++window->generation;
  return CodiPadGuestMemoryOK;
}

extern "C" int CodiPadGuestMemoryWindowGetView(const CodiPadGuestMemoryWindow *window,
                                             CodiPadGuestMemoryView *view) {
  if (!view) return 0;
  *view = {};
  if (!window || !window->usable) return 0;
  *view = {window->base, window->pages.get(), kWindowBytes, window->generation};
  return 1;
}

namespace {
// The same compiled loop for both measurements. Offset mode adds the base to
// guest addresses; native mode starts with the actual pointer. No software TLB
// is involved. This intentionally measures only address calculation plus memory.
__attribute__((noinline)) uint64_t memoryLoop(uintptr_t base, uintptr_t address,
                                           uint64_t iterations) {
  uint64_t checksum = 0;
  for (uint64_t index = 0; index < iterations; ++index) {
    auto *value = reinterpret_cast<volatile uint64_t *>(base + address + (index % 512) * 8);
    const uint64_t next = *value + index;
    *value = next;
    checksum += next;
  }
  return checksum;
}

uint64_t timedLoop(uintptr_t base, uintptr_t address, uint64_t iterations, uint64_t *checksum) {
  const auto start = std::chrono::steady_clock::now();
  *checksum = memoryLoop(base, address, iterations);
  return std::chrono::duration_cast<std::chrono::nanoseconds>(
      std::chrono::steady_clock::now() - start).count();
}
}  // namespace

extern "C" CodiPadGuestMemoryProbeResult CodiPadGuestMemoryWindowProbe(void) {
  CodiPadGuestMemoryProbeResult result{};
  result.window_bytes = kWindowBytes;
  result.host_page_bytes = static_cast<uint64_t>(sysconf(_SC_PAGESIZE));
  using Window = std::unique_ptr<CodiPadGuestMemoryWindow, decltype(&CodiPadGuestMemoryWindowDestroy)>;
  Window first(CodiPadGuestMemoryWindowCreate(&result.host_error), CodiPadGuestMemoryWindowDestroy);
  if (!first) return result;
  result.windows_created = 1;
  result.host_page_bytes = first->page;
  Window second(CodiPadGuestMemoryWindowCreate(&result.host_error), CodiPadGuestMemoryWindowDestroy);
  if (!second) return result;
  result.windows_created = 2;
  const size_t page = first->page;
  const uint64_t address = page * 2;
  const unsigned rw = CodiPadGuestMemoryRead | CodiPadGuestMemoryWrite;
  if (CodiPadGuestMemoryWindowMap(first.get(), address, page * 2, rw, &result.host_error) ||
      CodiPadGuestMemoryWindowMap(second.get(), address, page, rw, &result.host_error)) return result;
  auto *a = static_cast<uint64_t *>(CodiPadGuestMemoryWindowAddress(first.get(), address, page, rw));
  auto *b = static_cast<uint64_t *>(CodiPadGuestMemoryWindowAddress(second.get(), address, page, rw));
  a[0] = 17;
  a[kGuestPageBytes / sizeof(uint64_t)] = 41;
  b[0] = 29;
  result.independent_memory = a[0] == 17 && b[0] == 29 && a != b;
  result.high_address_rejected =
      CodiPadGuestMemoryWindowMap(first.get(), kWindowBytes, page, rw, nullptr) == CodiPadGuestMemoryRequiresSoftwareMMU &&
      CodiPadGuestMemoryWindowAddress(first.get(), UINT64_MAX - 7, 16, rw) == nullptr;
  result.subpage_protect_result = CodiPadGuestMemoryWindowProtect(first.get(), address, kGuestPageBytes,
                                                               CodiPadGuestMemoryRead, &result.host_error);
  result.mixed_page_classification =
      CodiPadGuestMemoryWindowClassify(first.get(), address, 8, CodiPadGuestMemoryRead) == CodiPadGuestMemoryDirect &&
      CodiPadGuestMemoryWindowClassify(first.get(), address, 8, CodiPadGuestMemoryWrite) == CodiPadGuestMemoryGuestFault &&
      CodiPadGuestMemoryWindowClassify(first.get(), address + kGuestPageBytes, 8, CodiPadGuestMemoryWrite) ==
          (page == kGuestPageBytes ? CodiPadGuestMemoryDirect : CodiPadGuestMemoryMMU) &&
      CodiPadGuestMemoryWindowClassify(first.get(), address + kGuestPageBytes - 4, 8,
                                     CodiPadGuestMemoryRead) == CodiPadGuestMemoryMMU;
  auto *helper = static_cast<uint64_t *>(CodiPadGuestMemoryWindowBacking(first.get(), address + kGuestPageBytes, 8, rw));
  auto *reader = static_cast<uint64_t *>(CodiPadGuestMemoryWindowAddress(first.get(), address + kGuestPageBytes, 8, CodiPadGuestMemoryRead));
  if (helper && reader) {
    *helper = 43;
    result.shared_backing_coherent = *reader == 43 &&
        CodiPadGuestMemoryWindowBacking(first.get(), address, 8, CodiPadGuestMemoryWrite) == nullptr;
  }
  result.subpage_discard_result = CodiPadGuestMemoryWindowDiscard(first.get(), address + kGuestPageBytes,
                                                               kGuestPageBytes, &result.host_error);
  auto *retained = static_cast<uint64_t *>(CodiPadGuestMemoryWindowBacking(first.get(), address, 8, CodiPadGuestMemoryRead));
  result.rejected_operations_preserved_memory = retained && *retained == 17 &&
      CodiPadGuestMemoryWindowClassify(first.get(), address + kGuestPageBytes, 8,
                                     CodiPadGuestMemoryRead) == CodiPadGuestMemoryGuestFault;
  if (result.subpage_discard_result == CodiPadGuestMemoryOK &&
      CodiPadGuestMemoryWindowMap(first.get(), address + kGuestPageBytes, kGuestPageBytes,
                               rw, &result.host_error) != CodiPadGuestMemoryOK) return result;
  if (CodiPadGuestMemoryWindowProtect(first.get(), address, page, rw, &result.host_error) != CodiPadGuestMemoryOK) return result;
  result.whole_page_protection =
      CodiPadGuestMemoryWindowProtect(first.get(), address + page, page, CodiPadGuestMemoryRead, &result.host_error) == CodiPadGuestMemoryOK &&
      CodiPadGuestMemoryWindowAddress(first.get(), address + page, page, CodiPadGuestMemoryWrite) == nullptr &&
      CodiPadGuestMemoryWindowAddress(first.get(), address + page, page, CodiPadGuestMemoryRead) != nullptr;
  if (CodiPadGuestMemoryWindowDiscard(second.get(), address, page, &result.host_error) != CodiPadGuestMemoryOK ||
      CodiPadGuestMemoryWindowAddress(second.get(), address, page, CodiPadGuestMemoryRead) != nullptr ||
      CodiPadGuestMemoryWindowMap(second.get(), address, page, rw, &result.host_error) != CodiPadGuestMemoryOK) return result;
  a = static_cast<uint64_t *>(CodiPadGuestMemoryWindowAddress(first.get(), address, page, rw));
  b = static_cast<uint64_t *>(CodiPadGuestMemoryWindowAddress(second.get(), address, page, rw));
  result.discarded_page_zeroed = b[0] == 0;

  result.iterations = 2 * 1024 * 1024;
  uint64_t nativeChecksum = 0, offsetChecksum = 0;
  // Equal initial bytes; the tiny diagnostic supplies no application/native-tool
  // speed verdict. Both invocations use exactly the same compiled loop.
  for (size_t index = 0; index < 512; ++index) a[index] = b[index] = index;
  result.native_nanoseconds = timedLoop(0, reinterpret_cast<uintptr_t>(b), result.iterations, &nativeChecksum);
  result.offset_nanoseconds = timedLoop(reinterpret_cast<uintptr_t>(first->base), address,
                                         result.iterations, &offsetChecksum);
  result.checksum_matches = nativeChecksum == offsetChecksum;
  return result;
}
