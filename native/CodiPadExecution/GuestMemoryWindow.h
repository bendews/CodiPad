#pragma once

#include <stddef.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

typedef struct CodiPadGuestMemoryWindow CodiPadGuestMemoryWindow;

typedef enum {
  CodiPadGuestMemoryOK = 0,
  CodiPadGuestMemoryInvalidRange = 1,
  CodiPadGuestMemoryRequiresSoftwareMMU = 2,
  CodiPadGuestMemoryHostFailure = 3,
  CodiPadGuestMemoryMappingConflict = 4,
} CodiPadGuestMemoryResult;

enum { CodiPadGuestMemoryRead = 1, CodiPadGuestMemoryWrite = 2 };

// Stable metadata layout consumed by generated scalar memory accesses. These
// are eligibility cache bits; kernel mapping/permission/COW state stays authoritative.
enum {
  CodiPadGuestPageRead = 1,
  CodiPadGuestPageWrite = 2,
  CodiPadGuestPageMapped = 4,
  CodiPadGuestPageDirectRead = 8,
  CodiPadGuestPageDirectWrite = 16,
  CodiPadGuestPageIndirect = 32,
};

typedef struct {
  void *base;
  const uint8_t *pages;  // one byte per 4 KiB guest page
  uint64_t length;
  uint64_t generation;
} CodiPadGuestMemoryView;

typedef enum {
  CodiPadGuestMemoryDirect = 0,
  CodiPadGuestMemoryMMU = 1,
  CodiPadGuestMemoryGuestFault = 2,
} CodiPadGuestMemoryAccess;

// Experimental data-memory representation, not a registered execution backend.
// Reserves a sparse 4 GiB host window. Guest pointers remain unchanged; a proven
// low guest address is accessed at base + address. No executable permission is
// requested, and this does not change the current iSH memory representation.
CodiPadGuestMemoryWindow *CodiPadGuestMemoryWindowCreate(int *host_error);
// Revoke every window alias synchronously, then delete the object. All workers
// and borrowed buffers must already be stopped. On HostFailure the object stays
// allocated and unusable: retain the original backing pins and retry Release.
// Success never clears or frees borrowed backing. NULL is already released.
CodiPadGuestMemoryResult CodiPadGuestMemoryWindowRelease(CodiPadGuestMemoryWindow *window,
    int *host_error);
// Convenience for standalone diagnostics. On revocation failure this retains
// the unusable object. Kernel owners must use checked Release before dropping pins.
void CodiPadGuestMemoryWindowDestroy(CodiPadGuestMemoryWindow *window);
size_t CodiPadGuestMemoryWindowHostPageSize(const CodiPadGuestMemoryWindow *window);

// Single owner, only while all users of this address space are stopped and no
// syscall borrows its buffers. There is no implicit thread suspension, fork/COW,
// guest shared mapping, executable mapping, or transition from an existing engine.
//
// Guest alignment is 4 KiB. Host mappings use the intersection of guest-page
// permissions, treating holes as inaccessible. Per-guest-page metadata selects
// direct access or an MMU helper without weakening guest permissions.
// High mappings require the existing MMU and never wrap/mask into the window.
// A host VM error makes this candidate unusable; callers must not resume it.
CodiPadGuestMemoryResult CodiPadGuestMemoryWindowMap(CodiPadGuestMemoryWindow *window,
    uint64_t address, size_t length, unsigned permissions, int *host_error);
CodiPadGuestMemoryResult CodiPadGuestMemoryWindowProtect(CodiPadGuestMemoryWindow *window,
    uint64_t address, size_t length, unsigned permissions, int *host_error);
CodiPadGuestMemoryResult CodiPadGuestMemoryWindowDiscard(CodiPadGuestMemoryWindow *window,
    uint64_t address, size_t length, int *host_error);

// A checked, borrowed pointer for this stopped-owner prototype. Every page in
// the requested range must exist and allow the requested access. The pointer
// expires at the next mapping change or destruction. Future generated code
// needs its own fault/checkpoint protocol before it can use an unchecked base.
void *CodiPadGuestMemoryWindowAddress(CodiPadGuestMemoryWindow *window,
    uint64_t address, size_t length, unsigned access);

// Full-range bounds and one flat guest-page lookup. Cross-4-KiB operations stay
// with the existing instruction-aware helper, including pairs and atomics.
// Mapping changes require stopped workers, as above; this table is not a second
// process or mapping authority. The prototype owns anonymous backing only.
CodiPadGuestMemoryAccess CodiPadGuestMemoryWindowClassify(const CodiPadGuestMemoryWindow *window,
    uint64_t address, size_t length, unsigned access);

// Checked access for a future MMU helper into the SAME backing as the window.
// A borrowed span cannot cross a host-page backing object. No copy/sync layer.
// Does not implement atomic, instruction-restart, COW, or borrowed-buffer rules.
void *CodiPadGuestMemoryWindowBacking(CodiPadGuestMemoryWindow *window,
    uint64_t address, size_t length, unsigned access);

// Alias existing, RW, host-page-aligned anonymous kernel backing without a copy
// or ownership transfer. Address/length must also be host-page aligned. The
// kernel retains its source backing until Unbind or checked Release succeeds.
// Unrepresentable alignment returns RequiresSoftwareMMU before effects.
CodiPadGuestMemoryResult CodiPadGuestMemoryWindowBind(CodiPadGuestMemoryWindow *window,
    uint64_t address, size_t length, void *backing, unsigned permissions, int *host_error);

// Revoke whole host groups touched by a 4 KiB-aligned range. Neighbour pages in
// those groups become indirect too. Never zero or free borrowed kernel backing.
// The ordinary MMU retains every guest mapping and decides its access semantics.
CodiPadGuestMemoryResult CodiPadGuestMemoryWindowUnbind(CodiPadGuestMemoryWindow *window,
    uint64_t address, size_t length, int *host_error);

// Borrowed only while the owner holds its memory lock and pins this mapping
// generation. Mutations require quiescent users and invalidate previous views.
// Kernel integration must also invalidate its existing TLB/code assumptions.
int CodiPadGuestMemoryWindowGetView(const CodiPadGuestMemoryWindow *window, CodiPadGuestMemoryView *view);

typedef struct {
  uint64_t window_bytes;
  uint64_t host_page_bytes;
  int32_t windows_created;
  int32_t host_error;
  int32_t independent_memory;
  int32_t high_address_rejected;
  int32_t subpage_protect_result;
  int32_t subpage_discard_result;
  int32_t rejected_operations_preserved_memory;
  int32_t whole_page_protection;
  int32_t discarded_page_zeroed;
  int32_t checksum_matches;
  int32_t mixed_page_classification;
  int32_t shared_backing_coherent;
  uint64_t iterations;
  uint64_t native_nanoseconds;
  uint64_t offset_nanoseconds;
} CodiPadGuestMemoryProbeResult;

// Bounded mechanism diagnostic; callers record whether Node was initialized.
// Tiny compiled loops are not Python/uv or end-to-end performance evidence.
CodiPadGuestMemoryProbeResult CodiPadGuestMemoryWindowProbe(void);

#ifdef __cplusplus
}
#endif
