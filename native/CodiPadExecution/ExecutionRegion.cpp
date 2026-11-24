#include "ExecutionRegion.h"

#include "../CodiPadNode/CodeRegion.h"

#include <TargetConditionals.h>
#if TARGET_OS_IPHONE && !TARGET_OS_SIMULATOR
#include <CoreFoundation/CoreFoundation.h>
#include <sys/sysctl.h>
#include <unistd.h>
extern "C" void *SecTaskCreateFromSelf(CFAllocatorRef) __attribute__((weak_import));
extern "C" CFTypeRef SecTaskCopyValueForEntitlement(void *, CFStringRef, CFErrorRef *)
    __attribute__((weak_import));
extern "C" int csops(pid_t, unsigned int, void *, size_t) __attribute__((weak_import));
#endif

#include <atomic>
#include <cstdlib>
#include <cstring>
#include <cstdio>
#include <memory>
#include <string>

struct CodiPadExecutionRegion {
  std::shared_ptr<codipadnode::CodeRegion> backing;
};

struct CodiPadExecutionLease {
  std::unique_ptr<codipadnode::CodeRegion::Lease> allocation;
};

namespace {

alignas(16) std::atomic<uint64_t> debuggerHandshake[2]{};

void setError(char *buffer, size_t size, const std::string &message) {
  if (buffer && size) std::snprintf(buffer, size, "%s", message.c_str());
}

}  // namespace

extern "C" bool CodiPadExecutionDebuggerAttached(void) { return codipadnode::DebuggerAttached(); }

extern "C" bool CodiPadExecutionJITEnabled(void) {
#if TARGET_OS_IPHONE && !TARGET_OS_SIMULATOR
  uint32_t flags = 0;
  return csops && csops(getpid(), 0, &flags, sizeof(flags)) == 0 && (flags & 0x10000000u);
#else
  return false;
#endif
}

extern "C" uintptr_t CodiPadExecutionDebuggerHandshakeAddress(void) {
  static_assert(sizeof(debuggerHandshake) == 16, "unexpected atomic storage layout");
  return reinterpret_cast<uintptr_t>(debuggerHandshake);
}

extern "C" void CodiPadExecutionDebuggerHandshakeReset(void) {
  debuggerHandshake[0].store(0);
  debuggerHandshake[1].store(0);
}

extern "C" void CodiPadExecutionDebuggerHandshakeBegin(uint64_t first, uint64_t second) {
  debuggerHandshake[0].store(first);
  debuggerHandshake[1].store(second);
}

extern "C" bool CodiPadExecutionDebuggerHandshakeMatches(uint64_t first, uint64_t second) {
  return (first || second) && debuggerHandshake[0].load() == ~first &&
         debuggerHandshake[1].load() == ~second;
}

extern "C" bool CodiPadExecutionDebuggerCancelPreparation(void) {
  return codipadnode::CancelDebuggerPreparation();
}

extern "C" int CodiPadExecutionTXMState(void) {
#if TARGET_OS_IPHONE && !TARGET_OS_SIMULATOR
  char os[32] = {}, hw[64] = {};
  size_t length = sizeof(os);
  if (sysctlbyname("kern.osproductversion", os, &length, nullptr, 0) ||
      length == 0 || length > sizeof(os) || os[length - 1] != '\0') return -1;
  length = sizeof(hw);
  if (sysctlbyname("hw.machine", hw, &length, nullptr, 0) ||
      length == 0 || length > sizeof(hw) || hw[length - 1] != '\0') return -1;
  char *end = nullptr;
  long major = std::strtol(os, &end, 10);
  if (end == os || (*end && *end != '.') || major <= 0) return -1;
  const char *number = nullptr;
  bool ipad = false;
  if (std::strncmp(hw, "iPad", 4) == 0) { number = hw + 4; ipad = true; }
  else if (std::strncmp(hw, "iPhone", 6) == 0) number = hw + 6;
  else return -1;
  char *separator = nullptr;
  long model = std::strtol(number, &separator, 10);
  if (separator == number || *separator != ',' || model <= 0) return -1;
  const char *minorStart = separator + 1;
  long minor = std::strtol(minorStart, &end, 10);
  if (end == minorStart || *end || minor < 0) return -1;
  if (major >= 27) return std::strcmp(hw, "iPad8,11") && std::strcmp(hw, "iPad8,12") ? 1 : 0;
  if (major < 26) return 0;
  double divisor = 1;
  for (long n = minor; n; n /= 10) divisor *= 10;
  return model + minor / divisor >= (ipad ? 14.5 : 14.2) ? 1 : 0;
#else
  return -1;
#endif
}

extern "C" bool CodiPadExecutionHasDebugEntitlement(void) {
#if TARGET_OS_IPHONE && !TARGET_OS_SIMULATOR
  if (!SecTaskCreateFromSelf || !SecTaskCopyValueForEntitlement) return false;
  void *task = SecTaskCreateFromSelf(nullptr);
  if (!task) return false;
  CFTypeRef value = SecTaskCopyValueForEntitlement(task, CFSTR("get-task-allow"), nullptr);
  const bool result = value == kCFBooleanTrue;
  if (value) CFRelease(value);
  CFRelease(task);
  return result;
#else
  return false;
#endif
}

extern "C" CodiPadExecutionRegion *CodiPadExecutionRegionCreate(size_t capacity,
                                                              bool debugger_prepared,
                                                              char *error, size_t error_size) {
  std::string detail;
  auto policy = debugger_prepared ? codipadnode::ExecutablePages::DebuggerPrepared
                                 : codipadnode::ExecutablePages::Platform;
  auto backing = codipadnode::CodeRegion::Create(capacity, policy, &detail, true);
  if (!backing) {
    setError(error, error_size, detail);
    return nullptr;
  }
  return new CodiPadExecutionRegion{std::move(backing)};
}

extern "C" void CodiPadExecutionRegionDestroy(CodiPadExecutionRegion *region) { delete region; }

extern "C" size_t CodiPadExecutionRegionCapacity(const CodiPadExecutionRegion *region) {
  return region && region->backing ? region->backing->capacityBytes() : 0;
}

extern "C" CodiPadExecutionLease *CodiPadExecutionRegionAcquire(CodiPadExecutionRegion *region,
                                                              size_t capacity, char *error,
                                                              size_t error_size) {
  if (!region || !region->backing) {
    setError(error, error_size, "execution region handle is null");
    return nullptr;
  }
  std::string detail;
  // The translator installs and publishes each block before exposing its entry.
  auto allocation = region->backing->Allocate(capacity, &detail, false);
  if (!allocation) {
    setError(error, error_size, detail);
    return nullptr;
  }
  return new CodiPadExecutionLease{std::move(allocation)};
}

extern "C" void CodiPadExecutionLeaseDestroy(CodiPadExecutionLease *lease) { delete lease; }

extern "C" void *CodiPadExecutionLeaseExecutable(const CodiPadExecutionLease *lease) {
  return lease && lease->allocation ? lease->allocation->executable() : nullptr;
}

extern "C" void *CodiPadExecutionLeaseWritable(const CodiPadExecutionLease *lease) {
  return lease && lease->allocation ? lease->allocation->writable() : nullptr;
}

extern "C" size_t CodiPadExecutionLeaseCapacity(const CodiPadExecutionLease *lease) {
  return lease && lease->allocation ? lease->allocation->size : 0;
}

extern "C" void CodiPadExecutionLeasePublish(const CodiPadExecutionLease *lease) {
  if (lease && lease->allocation) lease->allocation->publish();
}
