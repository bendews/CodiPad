#pragma once

#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

typedef struct CodiPadExecutionRegion CodiPadExecutionRegion;
typedef struct CodiPadExecutionLease CodiPadExecutionLease;

// Point-in-time tracer observation; the tracer can detach immediately afterward.
bool CodiPadExecutionDebuggerAttached(void);
// Runtime check of this process, false when unavailable or in the simulator.
bool CodiPadExecutionHasDebugEntitlement(void);
// True only if the process currently has CS_DEBUGGED.
bool CodiPadExecutionJITEnabled(void);
// -1 when unknown, 0 when absent, 1 when present; reflects the pinned device table.
int CodiPadExecutionTXMState(void);
// Begin with fresh nonzero challenge words before every attempt. The script
// reads these bytes, verifies identity, then writes their bitwise inverse.
// The script token is the original 16 bytes in memory order as 32 hex digits;
// begin/match arguments are the first and second eight bytes read little-endian.
uintptr_t CodiPadExecutionDebuggerHandshakeAddress(void);
void CodiPadExecutionDebuggerHandshakeBegin(uint64_t first, uint64_t second);
void CodiPadExecutionDebuggerHandshakeReset(void);
bool CodiPadExecutionDebuggerHandshakeMatches(uint64_t first, uint64_t second);
// Only before allocation starts and after matching the active script handshake.
bool CodiPadExecutionDebuggerCancelPreparation(void);

// Create the one process-wide pool before starting Node or the ARM64 engine.
// Reserve the translated cache plus at least 256 MiB for Node. The first
// call performs the optional debugger-prepared request; subsequent CodeRegion
// users receive this same backing mapping. A conflicting second policy/size
// fails closed.
CodiPadExecutionRegion *CodiPadExecutionRegionCreate(size_t capacity, bool debugger_prepared,
                                                 char *error, size_t error_size);
void CodiPadExecutionRegionDestroy(CodiPadExecutionRegion *region);
// May be smaller than requested when debugger preparation uses its bounded fallback.
size_t CodiPadExecutionRegionCapacity(const CodiPadExecutionRegion *region);

// Reserve a page-rounded contiguous lease from the shared pool. Keep the lease
// alive until all generated code and worker tasks have stopped. Contents are
// unspecified, including on reuse; initialize and publish code before execution.
CodiPadExecutionLease *CodiPadExecutionRegionAcquire(CodiPadExecutionRegion *region, size_t capacity,
                                                 char *error, size_t error_size);
void CodiPadExecutionLeaseDestroy(CodiPadExecutionLease *lease);
void *CodiPadExecutionLeaseExecutable(const CodiPadExecutionLease *lease);
void *CodiPadExecutionLeaseWritable(const CodiPadExecutionLease *lease);
size_t CodiPadExecutionLeaseCapacity(const CodiPadExecutionLease *lease);
void CodiPadExecutionLeasePublish(const CodiPadExecutionLease *lease);

// Exported by patches/ish/native-execution-region.patch. Installs the lease
// into the existing ARM64 translator; it does not map, chmod, or detach pages.
// Query the exact cache capacity before engine startup; zero means startup has
// begun or the emitter is unavailable. Install before startup and keep the
// lease alive through all task joins.
size_t ish_jit_region_capacity(void);
// Restrict the selected power-of-two capacity before installing the region.
bool ish_jit_limit_region_capacity(size_t maximum);
bool ish_jit_install_region(void *executable, void *writable, size_t capacity);

#ifdef __cplusplus
}
#endif
