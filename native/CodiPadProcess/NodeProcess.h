// Native Node's libuv adapter. Sessions and lifecycle remain owned by IshKernel.
#ifndef CODIPAD_NODE_PROCESS_H
#define CODIPAD_NODE_PROCESS_H
#include <stdbool.h>
#include <stdint.h>
#include "IshKernel.h"
#ifdef __cplusplus
extern "C" {
#endif

// Metadata-only diagnostics emitted when a process spawn fails. Stage values are stable within
// this API. Backend values use the codipad_backend_t numeric values from IshKernel.h.
typedef enum codipad_node_spawn_stage {
    CODIPAD_NODE_SPAWN_CWD_ADMISSION = 1,
    CODIPAD_NODE_SPAWN_EXECUTABLE_ADMISSION = 2,
    CODIPAD_NODE_SPAWN_STDIO_SETUP = 3,
    CODIPAD_NODE_SPAWN_AUTHORITY = 4,
} codipad_node_spawn_stage;

typedef void (*codipad_node_spawn_diagnostic_callback)(int stage, int error, int backend,
                                                      void *context);

// Configure before starting an extension-host generation. Pass NULL to clear while inactive.
// The callback receives only stage, raw error, backend, and context; it runs synchronously
// outside NodeProcess and kernel locks. Its context must remain valid until the host stops.
int codipad_node_set_spawn_diagnostic_callback(codipad_node_spawn_diagnostic_callback callback,
                                              void *context);

// Configure the canonical native Node executable before starting a host generation. A spawn of
// this exact path routes to the guest Linux Node at /usr/local/bin/node. Pass NULL to clear while
// inactive; basename or suffix matches are never used.
int codipad_node_set_self_exec_identity(const char *canonical_native_path);

// Called after the shared filesystem has authorized and mounted the workspace.
// A different mount is refused while the process-wide kernel is alive.
int codipad_node_set_workspace(const char *native_workspace);

// One extension-host generation at a time. Bind on the Node thread before evaluation;
// finish on that same thread after node::Stop and before disposing its environment.
bool codipad_node_process_begin(void);
bool codipad_node_process_end(void);

// Metadata-only cleanup state for diagnostics. No paths, commands, or environment values.
typedef struct codipad_node_process_close_attempt {
    codipad_session_t session;
    int32_t signal_result, close_result;
    uint32_t close_calls;
    uint8_t final_info_valid;
    struct codipad_session_info final_info; // actual successful close status, or last retained info
} codipad_node_process_close_attempt;

typedef struct codipad_node_process_cleanup_snapshot {
    uint32_t version, size;
    uint64_t active_owner, cleanup_attempts, found_sessions, closed_sessions, remaining_sessions;
    uint64_t cleanup_owner;
    uint64_t last_session;
    int32_t last_error;
    uint8_t host_active, timed_out, over_capacity, session_info_valid;
    uint8_t running, exited, reaped, settled;
    uint32_t attempted_count;
    codipad_node_process_close_attempt attempted[64];
    uint32_t diagnostic_count;
    struct codipad_session_cleanup_diagnostic remaining[64];
} codipad_node_process_cleanup_snapshot;
void codipad_node_process_get_cleanup_snapshot(codipad_node_process_cleanup_snapshot *out);

#ifdef __cplusplus
}
#endif
#endif
