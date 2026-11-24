#ifndef CODIPADNODE_NODE_RUNTIME_H
#define CODIPADNODE_NODE_RUNTIME_H

#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>

// C API for a managed in-process Node host. Safe to include from Swift through
// an Objective-C bridging header: no C++ types cross this boundary.
//
// Ownership rules:
//   * one process-wide V8 runtime, created by the first successful Start and
//     never torn down (V8, its platform and the code pool outlive every host);
//   * each Start creates a new generation with its own environment, isolate and
//     event loop; Stop disposes that generation's environment;
//   * Start rejects while a generation is starting, running or stopping, and
//     there is no implicit restart. The owner decides when to start the next one;
//   * Destroy stops synchronously and joins the host thread. It never detaches
//     and never reports a running host as stopped;
//   * Start and Destroy are single-owner calls and must not race each other.
//     RequestStop is safe concurrently with Start.
//
// Callbacks run on the host thread (state events) or the calling thread
// (Stopping). A callback must not call Start, RequestStop or Destroy.

#ifdef __cplusplus
extern "C" {
#endif

typedef enum {
  CodiPadNodeStateIdle = 0,
  CodiPadNodeStateStarting = 1,
  CodiPadNodeStateRunning = 2,
  CodiPadNodeStateStopping = 3,
  CodiPadNodeStateExited = 4,
  CodiPadNodeStateFailed = 5,
} CodiPadNodeState;

typedef struct {
  int32_t generation;          // 0 before the first Start
  int32_t state;               // CodiPadNodeState
  int32_t exit_code;           // environment exit code, 0 when none requested
  int32_t runtime_initialized; // 1 once the process-wide V8 runtime exists
  char message[192];           // last transition or failure detail
} CodiPadNodeSnapshot;

typedef struct CodiPadNodeRuntime CodiPadNodeRuntime;

typedef void (*CodiPadNodeEventCallback)(void *context, const CodiPadNodeSnapshot *snapshot);

// Creation options. Zero-initialising this struct selects the fail-closed
// default: executable pages come from the platform mapping only.
typedef struct {
  // Opt-in: ask the attached debugger for executable pages via the breakpoint
  // protocol. Fails unless a debugger is already attached.
  int32_t use_debugger_prepared_pages;
} CodiPadNodeRuntimeOptions;

// Returns null on allocation failure. `callback` may be null.
CodiPadNodeRuntime *CodiPadNodeRuntimeCreate(CodiPadNodeEventCallback callback, void *context);

// Same, with explicit options. `options` may be null (defaults). The process-wide
// runtime is created by the first successful Start; a later Start asking for a
// different page policy is rejected rather than mixing policies in one process.
CodiPadNodeRuntime *CodiPadNodeRuntimeCreateWithOptions(const CodiPadNodeRuntimeOptions *options,
                                                    CodiPadNodeEventCallback callback,
                                                    void *context);

// Starts one generation. `script_utf8` is the CommonJS entry source evaluated in
// the new environment (not a file path). Returns false and fills `error` when a
// generation is already active, the runtime cannot be created, or the script
// fails to evaluate. A script that exits synchronously during evaluation is an
// early exit, not a failure: the generation ends in StateExited with its code,
// and Start still returns false because no running generation was produced.
bool CodiPadNodeRuntimeStart(CodiPadNodeRuntime *runtime, const char *script_utf8,
                           size_t script_length, char *error, size_t error_size);

// Starts a generation with an Environment-local string environment. The UTF-8
// JSON value must be an object whose values are strings. Unlike Start(), this
// creates a private Node environment map before LoadEnvironment() and enables
// environment-based POSIX os.homedir() lookup. The existing Start() behavior
// remains unchanged for standalone probes.
bool CodiPadNodeRuntimeStartWithEnvironment(CodiPadNodeRuntime *runtime,
                                          const char *script_utf8,
                                          size_t script_length,
                                          const char *environment_json_utf8,
                                          size_t environment_json_length,
                                          char *error, size_t error_size);

// Asks the running generation to stop and returns immediately. It ends a JS busy
// loop as well as an idle loop: node::Stop is the thread-safe entry point
// (Environment::ExitEnv terminates the isolate and stops the loop). The host
// thread disposes the environment afterwards; the owner observes StateExited.
// Idempotent while stopping, and safe while Start is still waiting.
bool CodiPadNodeRuntimeRequestStop(CodiPadNodeRuntime *runtime, char *error, size_t error_size);

CodiPadNodeSnapshot CodiPadNodeRuntimeGetSnapshot(const CodiPadNodeRuntime *runtime);

// Stops and joins, then frees. Returns false with the handle left allocated if
// the host thread does not finish in time. The owner must not be inside any other
// call on this handle when Destroy runs; start the next generation on a new
// handle or wait for this one to return.
bool CodiPadNodeRuntimeDestroy(CodiPadNodeRuntime *runtime, char *error, size_t error_size);

const char *CodiPadNodeStateName(int32_t state);

#ifdef __cplusplus
}
#endif

#endif  // CODIPADNODE_NODE_RUNTIME_H
