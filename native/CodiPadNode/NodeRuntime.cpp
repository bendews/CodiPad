#include "NodeRuntime.h"

#include "CodeRegion.h"
#include "PageAllocator.h"
#include "cppgc/platform.h"
#include "node.h"
#include "uv.h"

#include <atomic>
#include <algorithm>
#include <chrono>
#include <condition_variable>
#include <cstdio>
#include <cstring>
#include <memory>
#include <mutex>
#include <string>
#include <thread>
#include <vector>

// Standalone lifecycle probes can omit the process adapter. The app supplies it.
extern "C" bool codipad_node_process_begin(void) __attribute__((weak_import));
extern "C" bool codipad_node_process_end(void) __attribute__((weak_import));

namespace {

constexpr int kStartTimeoutSeconds = 30;
constexpr int kStopTimeoutSeconds = 10;
constexpr size_t kEnvironmentJsonLimit = 1024 * 1024;
// The address space already holds the app when the runtime is created, so one
// region size can fail where a fresh process succeeds. Order is a heuristic; a
// failure to place any size is reported, never retried silently forever.
constexpr size_t kRegionSizesMiB[] = {96, 128, 64, 32, 48, 80, 112, 16};

struct Runtime {
  std::shared_ptr<codipadnode::CodeRegion> region;
  std::unique_ptr<codipadnode::NodePageAllocator> pages;
  std::unique_ptr<node::MultiIsolatePlatform> platform;
  std::shared_ptr<node::InitializationResult> init;
  codipadnode::ExecutablePages pagesPolicy = codipadnode::ExecutablePages::Platform;
};

std::mutex runtimeMutex;
Runtime *runtimeSingleton = nullptr;
bool runtimeAttempted = false;
std::string runtimeError;
void SetError(char *error, size_t size, const std::string &text) {
  if (!error || !size) return;
  std::snprintf(error, size, "%s", text.c_str());
}

std::string JoinErrors(const std::vector<std::string> &errors) {
  std::string text;
  for (size_t i = 0; i < errors.size() && i < 3; ++i) {
    if (!text.empty()) text += "; ";
    text += errors[i];
  }
  return text;
}

// Creates the process-wide runtime on first use. A failed attempt is remembered:
// retrying V8 initialization in the same process is not supported.
Runtime *EnsureRuntime(codipadnode::ExecutablePages policy, std::string *error) {
  std::lock_guard<std::mutex> lock(runtimeMutex);
  if (runtimeSingleton) {
    if (runtimeSingleton->pagesPolicy != policy) {
      if (error)
        *error =
            "process-wide runtime is already initialized with a different executable-page policy; "
            "one process cannot mix them";
      return nullptr;
    }
    return runtimeSingleton;
  }
  if (runtimeAttempted) {
    if (error) *error = runtimeError;
    return nullptr;
  }
  runtimeAttempted = true;

  auto runtime = std::make_unique<Runtime>();
  runtime->pagesPolicy = policy;
  std::string lastError = "no code region fits this process address space";
  for (size_t mib : kRegionSizesMiB) {
    std::string failure;
    auto region = codipadnode::CodeRegion::Create(mib * 1024 * 1024, policy, &failure);
    if (!region) {
      lastError = failure;
      continue;
    }
    // Leave headroom in the region for V8's own reservations.
    auto pages = codipadnode::NodePageAllocator::Create(region, (mib - 16) * 1024 * 1024, &failure);
    if (!pages) {
      lastError = failure;
      continue;
    }
    runtime->region = std::move(region);
    runtime->pages = std::move(pages);
    break;
  }
  if (!runtime->pages) {
    runtimeError = lastError;
    if (error) *error = runtimeError;
    return nullptr;
  }

  std::vector<std::string> args = {"codipadnode", "--max-old-space-size=256"};
  runtime->init = node::InitializeOncePerProcess(
      args, {node::ProcessInitializationFlags::kNoInitializeV8,
             node::ProcessInitializationFlags::kNoInitializeNodeV8Platform,
             node::ProcessInitializationFlags::kNoInitializeCppgc,
             node::ProcessInitializationFlags::kNoDefaultSignalHandling,
             node::ProcessInitializationFlags::kNoStdioInitialization,
             node::ProcessInitializationFlags::kNoAdjustResourceLimits,
             node::ProcessInitializationFlags::kDisableNodeOptionsEnv});
  auto initErrors = JoinErrors(runtime->init->errors());
  if (runtime->init->early_return()) {
    runtimeError = initErrors.empty() ? "Node initialization returned early"
                                      : "Node initialization failed: " + initErrors;
    if (error) *error = runtimeError;
    return nullptr;
  }
  runtime->platform = node::MultiIsolatePlatform::Create(2, nullptr, runtime->pages.get());
  v8::V8::InitializePlatform(runtime->platform.get());
  cppgc::InitializeProcess(runtime->pages.get());
  if (!v8::V8::Initialize()) {
    runtimeError = "V8 initialization failed";
    if (error) *error = runtimeError;
    return nullptr;
  }
  // Deliberately never torn down: V8 is process-wide, generations are not.
  runtimeSingleton = runtime.release();
  return runtimeSingleton;
}

}  // namespace

struct CodiPadNodeRuntime {
  mutable std::mutex mutex;
  std::condition_variable cv;
  // Serializes Start/Destroy only. Never held while waiting for a generation to
  // settle, so RequestStop can enter during a start.
  std::mutex api;

  CodiPadNodeEventCallback callback = nullptr;
  void *context = nullptr;
  codipadnode::ExecutablePages pagesPolicy = codipadnode::ExecutablePages::Platform;

  int32_t generation = 0;
  int32_t state = CodiPadNodeStateIdle;
  int32_t exitCode = 0;
  std::string message = "created";

  std::thread thread;
  int32_t threadGeneration = 0;
  bool joinable = false;
  bool settled = false;   // start finished: Running, or finished with a failure
  bool finished = false;  // host thread about to exit
  bool stopRequested = false;

  // Both guarded by `mutex`. The environment pointer stays valid until the host
  // thread has disposed it, so a concurrent RequestStop can call node::Stop.
  uv_async_t *stopHandle = nullptr;
  node::Environment *environment = nullptr;
};

namespace {

// Snapshot must be built with `mutex` held.
CodiPadNodeSnapshot SnapshotLocked(CodiPadNodeRuntime *runtime) {
  CodiPadNodeSnapshot snapshot{};
  snapshot.generation = runtime->generation;
  snapshot.state = runtime->state;
  snapshot.exit_code = runtime->exitCode;
  {
    std::lock_guard<std::mutex> lock(runtimeMutex);
    snapshot.runtime_initialized = runtimeSingleton ? 1 : 0;
  }
  std::snprintf(snapshot.message, sizeof(snapshot.message), "%s", runtime->message.c_str());
  return snapshot;
}

// State change plus owner notification, without holding the lock across the
// callback: a callback may read a snapshot.
void Publish(CodiPadNodeRuntime *runtime, int32_t state, int32_t exitCode,
             const std::string &message) {
  CodiPadNodeSnapshot snapshot{};
  {
    std::lock_guard<std::mutex> lock(runtime->mutex);
    runtime->state = state;
    runtime->exitCode = exitCode;
    if (!message.empty()) runtime->message = message;
    snapshot = SnapshotLocked(runtime);
  }
  runtime->cv.notify_all();
  if (runtime->callback) runtime->callback(runtime->context, &snapshot);
}

void Finish(CodiPadNodeRuntime *runtime) {
  {
    std::lock_guard<std::mutex> lock(runtime->mutex);
    runtime->finished = true;
  }
  runtime->cv.notify_all();
}

struct LoopState {
  node::Environment *environment = nullptr;  // loop thread only
  std::atomic<int32_t> exitCode{0};
  std::atomic<bool> exitRequested{false};
  std::atomic<bool> stopped{false};
};

struct StopSignal {
  uv_async_t async;
  LoopState *loop = nullptr;
  std::atomic<bool> closed{false};
};

void RunGeneration(CodiPadNodeRuntime *runtime,
                   const std::shared_ptr<const std::string> &source,
                   const std::shared_ptr<const std::string> &environmentJson) {
  Runtime *v8 = nullptr;
  {
    std::lock_guard<std::mutex> lock(runtimeMutex);
    v8 = runtimeSingleton;
  }
  if (!v8) {
    Publish(runtime, CodiPadNodeStateFailed, 0, "process-wide runtime is not initialized");
    Finish(runtime);
    return;
  }

  LoopState loop;
  std::vector<std::string> errors;
  node::EnvironmentFlags::Flags environmentFlags =
      static_cast<node::EnvironmentFlags::Flags>(node::EnvironmentFlags::kTrackUnmanagedFds |
                                                 node::EnvironmentFlags::kNoNativeAddons |
                                                 node::EnvironmentFlags::kNoStartDebugSignalHandler);
  if (environmentJson) environmentFlags = static_cast<node::EnvironmentFlags::Flags>(
      environmentFlags | node::EnvironmentFlags::kUseEnvironmentHome);
  auto setup = node::CommonEnvironmentSetup::Create(
      v8->platform.get(), &errors, v8->init->args(), v8->init->exec_args(), environmentFlags);
  if (!setup) {
    std::string detail = "environment setup failed";
    auto joined = JoinErrors(errors);
    if (!joined.empty()) detail += ": " + joined;
    Publish(runtime, CodiPadNodeStateFailed, 0, detail);
    Finish(runtime);
    return;
  }

  int32_t finalCode = 0;
  int32_t finalState = CodiPadNodeStateExited;
  std::string outcome;
  if (environmentJson) {
    v8::Isolate *isolate = setup->isolate();
    bool configured = false;
    {
      v8::Locker locker(isolate);
      v8::Isolate::Scope isolateScope(isolate);
      v8::HandleScope handles(isolate);
      v8::Context::Scope contextScope(setup->context());
      v8::TryCatch tryCatch(isolate);
      v8::Local<v8::String> json;
      v8::Local<v8::Value> parsed;
      bool valid = v8::String::NewFromUtf8(
                             isolate, environmentJson->data(), v8::NewStringType::kNormal,
                             static_cast<int>(environmentJson->size()))
                             .ToLocal(&json) &&
                         v8::JSON::Parse(setup->context(), json).ToLocal(&parsed) &&
                         parsed->IsObject() && !parsed->IsArray();
      // KVStore's generic API performs JavaScript string coercion. This C
      // launch contract accepts only POSIX-compatible string entries, matching
      // what descendants receive through the process authority.
      v8::Local<v8::Array> keys;
      if (valid) valid = parsed.As<v8::Object>()->GetOwnPropertyNames(setup->context()).ToLocal(&keys);
      for (uint32_t i = 0; valid && i < keys->Length(); ++i) {
        v8::Local<v8::Value> key, value;
        valid = keys->Get(setup->context(), i).ToLocal(&key) && key->IsString() &&
                parsed.As<v8::Object>()->Get(setup->context(), key).ToLocal(&value) && value->IsString();
        if (!valid) break;
        v8::String::Utf8Value name(isolate, key), text(isolate, value);
        valid = *name && *text && name.length() > 0 &&
                std::strlen(*name) == static_cast<size_t>(name.length()) &&
                std::strchr(*name, '=') == nullptr &&
                std::strlen(*text) == static_cast<size_t>(text.length());
      }
      if (valid) {
        configured = node::SetEnvironmentVariables(
                         setup->env(), setup->context(), parsed.As<v8::Object>())
                         .IsJust();
      }
    }
    if (!configured) {
      setup.reset();
      Publish(runtime, CodiPadNodeStateFailed, 0,
              "extension environment must be a JSON object of string values");
      Finish(runtime);
      return;
    }
  }

  if (codipad_node_process_begin && !codipad_node_process_begin()) {
    setup.reset();
    Publish(runtime, CodiPadNodeStateFailed, 0, "previous process generation has incomplete cleanup");
    Finish(runtime);
    return;
  }

  {
    v8::Isolate *isolate = setup->isolate();
    v8::Locker locker(isolate);
    v8::Isolate::Scope isolateScope(isolate);
    v8::HandleScope handles(isolate);
    v8::Context::Scope contextScope(setup->context());

    node::Environment *environment = setup->env();
    {
      std::lock_guard<std::mutex> lock(runtime->mutex);
      runtime->environment = environment;
    }

    // process.exit ends this environment, not the app. Node reports the code and
    // the environment is disposed; the exit itself is not suppressed.
    node::SetProcessExitHandler(environment, [&loop](node::Environment *env, int exitCode) {
      loop.exitCode.store(exitCode);
      loop.exitRequested.store(true);
      if (!loop.stopped.exchange(true)) node::Stop(env);
    });

    // Idle loops are woken here; running JS is stopped by RequestStop calling
    // node::Stop directly, which terminates the isolate. The handle exists for
    // the window where no environment is available yet.
    loop.environment = environment;
    auto *signal = new (std::nothrow) StopSignal();
    if (signal) {
      signal->loop = &loop;
      signal->async.data = signal;
      uv_async_init(setup->event_loop(), &signal->async, [](uv_async_t *handle) {
        auto *state = static_cast<StopSignal *>(handle->data);
        if (!state->loop->stopped.exchange(true)) node::Stop(state->loop->environment);
      });
      uv_unref(reinterpret_cast<uv_handle_t *>(&signal->async));
      std::lock_guard<std::mutex> lock(runtime->mutex);
      runtime->stopHandle = &signal->async;
      if (runtime->stopRequested) uv_async_send(&signal->async);
    }

    v8::MaybeLocal<v8::Value> loaded = node::LoadEnvironment(environment, source->c_str());
    if (loaded.IsEmpty()) {
      if (loop.exitRequested.load()) {
        finalCode = loop.exitCode.load();
        outcome = "environment exited while loading";
      } else if (loop.stopped.load()) {
        outcome = "stopped before the script loaded";
      } else {
        finalState = CodiPadNodeStateFailed;
        finalCode = 1;
        outcome = "script failed to evaluate";
      }
    } else {
      {
        std::lock_guard<std::mutex> lock(runtime->mutex);
        runtime->settled = true;
        runtime->state = CodiPadNodeStateRunning;
        runtime->message = "script loaded";
      }
      runtime->cv.notify_all();
      if (runtime->callback) {
        CodiPadNodeSnapshot snapshot{};
        {
          std::lock_guard<std::mutex> lock(runtime->mutex);
          snapshot = SnapshotLocked(runtime);
        }
        runtime->callback(runtime->context, &snapshot);
      }

      v8::Maybe<int> spin = node::SpinEventLoop(environment);
      if (loop.exitRequested.load()) {
        finalCode = loop.exitCode.load();
        outcome = finalCode != 0 ? "environment exited" : "environment disposed";
      } else if (spin.IsNothing()) {
        finalCode = 0;
        outcome = "loop terminated by stop request";
      } else {
        finalCode = spin.FromJust();
        outcome = finalCode != 0 ? "environment exited from the event loop"
                                 : "environment disposed";
      }
    }

    // Loop-thread ownership: unhook the handle under the mutex, then close it
    // here. RequestStop signals under the same mutex, so it never touches a
    // closed handle.
    StopSignal *pending = nullptr;
    {
      std::lock_guard<std::mutex> lock(runtime->mutex);
      pending = reinterpret_cast<StopSignal *>(runtime->stopHandle);
      runtime->stopHandle = nullptr;
    }
    if (pending) {
      uv_close(reinterpret_cast<uv_handle_t *>(&pending->async), [](uv_handle_t *h) {
        static_cast<StopSignal *>(h->data)->closed.store(true);
      });
      for (int i = 0; i < 100 && !pending->closed.load(); ++i)
        uv_run(setup->event_loop(), UV_RUN_NOWAIT);
      // If the loop never completed the close it still owns the handle, so only
      // free it once the callback has run.
      if (pending->closed.load()) delete pending;
    }

    if (!loop.stopped.exchange(true)) node::Stop(environment);
    if (codipad_node_process_end && !codipad_node_process_end()) {
      finalState = CodiPadNodeStateFailed;
      outcome = "extension subprocess cleanup is incomplete; restart is refused";
    }
    // The environment is stopped and about to be disposed: clear the pointer
    // under the mutex so a concurrent RequestStop cannot reach a freed object.
    {
      std::lock_guard<std::mutex> lock(runtime->mutex);
      runtime->environment = nullptr;
    }
  }

  // ~CommonEnvironmentSetup disposes the environment, isolate and loop. The
  // process-wide V8 runtime stays up for the next generation.
  setup.reset();

  Publish(runtime, finalState, finalCode, outcome);
  Finish(runtime);
}

bool RequestStopLocked(CodiPadNodeRuntime *runtime, char *error, size_t errorSize) {
  CodiPadNodeSnapshot snapshot{};
  {
    std::lock_guard<std::mutex> lock(runtime->mutex);
    if (runtime->state == CodiPadNodeStateStopping) return true;
    if (runtime->state == CodiPadNodeStateIdle || runtime->state == CodiPadNodeStateExited ||
        runtime->state == CodiPadNodeStateFailed) {
      SetError(error, errorSize,
               std::string("no generation to stop (state ") +
                   CodiPadNodeStateName(runtime->state) + ")");
      return false;
    }
    runtime->stopRequested = true;
    runtime->state = CodiPadNodeStateStopping;
    runtime->message = "stop requested";
    // node::Stop -> Environment::ExitEnv is the documented thread-safe entry
    // point: it flags the environment, terminates the isolate (which aborts a
    // running JS busy loop) and posts uv_stop for an idle loop. Serialised
    // against the host thread's teardown by `mutex` and the environment pointer
    // stays valid until that thread has disposed it.
    if (runtime->environment) {
      node::Stop(runtime->environment);
    } else if (runtime->stopHandle) {
      uv_async_send(runtime->stopHandle);
    }
    snapshot = SnapshotLocked(runtime);
  }
  runtime->cv.notify_all();
  if (runtime->callback) runtime->callback(runtime->context, &snapshot);
  return true;
}

// Joins a generation's thread, which must already have reported finished.
void JoinFinishedLocked(CodiPadNodeRuntime *runtime, int32_t generation) {
  if (runtime->joinable && runtime->threadGeneration == generation) {
    runtime->thread.join();
    runtime->joinable = false;
  }
}

}  // namespace

extern "C" {

CodiPadNodeRuntime *CodiPadNodeRuntimeCreateWithOptions(const CodiPadNodeRuntimeOptions *options,
                                                    CodiPadNodeEventCallback callback,
                                                    void *context) {
  auto *runtime = new (std::nothrow) CodiPadNodeRuntime();
  if (!runtime) return nullptr;
  runtime->callback = callback;
  runtime->context = context;
  runtime->pagesPolicy = (options && options->use_debugger_prepared_pages)
                             ? codipadnode::ExecutablePages::DebuggerPrepared
                             : codipadnode::ExecutablePages::Platform;
  return runtime;
}

CodiPadNodeRuntime *CodiPadNodeRuntimeCreate(CodiPadNodeEventCallback callback, void *context) {
  return CodiPadNodeRuntimeCreateWithOptions(nullptr, callback, context);
}

static bool StartRuntime(CodiPadNodeRuntime *runtime, const char *scriptUtf8, size_t scriptLength,
                         const char *environmentJsonUtf8, size_t environmentJsonLength,
                         char *error, size_t errorSize) {
  if (!runtime) {
    SetError(error, errorSize, "runtime is null");
    return false;
  }
  if (!scriptUtf8) {
    SetError(error, errorSize, "script source is null");
    return false;
  }
  if (environmentJsonUtf8 && environmentJsonLength > kEnvironmentJsonLimit) {
    SetError(error, errorSize, "environment JSON exceeds 1 MiB");
    return false;
  }
  auto source = std::make_shared<const std::string>(scriptUtf8, scriptLength);
  std::shared_ptr<const std::string> environmentJson;
  if (environmentJsonUtf8) {
    environmentJson = std::make_shared<const std::string>(environmentJsonUtf8,
                                                          environmentJsonLength);
  }
  int32_t generation = 0;
  {
    // Held only for validation and spawn. The wait below runs without it, so
    // RequestStop can enter while a generation is starting.
    std::lock_guard<std::mutex> api(runtime->api);
    {
      std::lock_guard<std::mutex> lock(runtime->mutex);
      if (runtime->state == CodiPadNodeStateStarting || runtime->state == CodiPadNodeStateRunning ||
          runtime->state == CodiPadNodeStateStopping) {
        SetError(error, errorSize,
                 std::string("generation ") + std::to_string(runtime->generation) + " is " +
                     CodiPadNodeStateName(runtime->state) +
                     "; stop it and wait for exit before starting another");
        return false;
      }
    }
    // Reap the previous generation's thread; it has already reported finished.
    if (runtime->joinable) {
      runtime->thread.join();
      runtime->joinable = false;
    }

    std::string runtimeFailure;
    if (!EnsureRuntime(runtime->pagesPolicy, &runtimeFailure)) {
      SetError(error, errorSize, runtimeFailure);
      Publish(runtime, CodiPadNodeStateFailed, 0, runtimeFailure);
      return false;
    }
    {
      std::lock_guard<std::mutex> lock(runtime->mutex);
      runtime->generation += 1;
      generation = runtime->generation;
      runtime->state = CodiPadNodeStateStarting;
      runtime->exitCode = 0;
      runtime->message = "starting generation " + std::to_string(generation);
      runtime->settled = false;
      runtime->finished = false;
      runtime->stopRequested = false;
    }
    Publish(runtime, CodiPadNodeStateStarting, 0, "starting generation " + std::to_string(generation));
    runtime->thread = std::thread(RunGeneration, runtime, source, environmentJson);
    runtime->threadGeneration = generation;
    runtime->joinable = true;
  }

  bool settled = false;
  bool ran = false;
  {
    std::unique_lock<std::mutex> lock(runtime->mutex);
    settled = runtime->cv.wait_for(lock, std::chrono::seconds(kStartTimeoutSeconds), [runtime] {
      return runtime->settled || runtime->finished;
    });
    ran = runtime->settled;
  }

  if (!settled) {
    // Bounded start failure. Ask the generation to stop and wait for the thread
    // to finish; never leave a detached host behind.
    std::printf("codipadnode: generation %d did not load within %d s; stopping\n", generation,
                kStartTimeoutSeconds);
    CodiPadNodeRuntimeRequestStop(runtime, nullptr, 0);
    bool finished = false;
    {
      std::unique_lock<std::mutex> lock(runtime->mutex);
      finished = runtime->cv.wait_for(lock, std::chrono::seconds(kStopTimeoutSeconds),
                                      [runtime] { return runtime->finished; });
    }
    if (!finished) {
      SetError(error, errorSize,
               "generation did not stop after a start timeout; handle left running");
      return false;
    }
    {
      std::lock_guard<std::mutex> api(runtime->api);
      JoinFinishedLocked(runtime, generation);
    }
    SetError(error, errorSize, "generation did not load within the start timeout");
    return false;
  }

  if (ran) {
    // The generation reached Running inside the start window. A script that
    // already drained or exited is still a started generation: the snapshot
    // carries the real state and exit code.
    return true;
  }

  CodiPadNodeSnapshot snapshot = CodiPadNodeRuntimeGetSnapshot(runtime);
  {
    std::lock_guard<std::mutex> api(runtime->api);
    JoinFinishedLocked(runtime, generation);
  }
  SetError(error, errorSize, snapshot.message[0] ? snapshot.message : "generation failed");
  return false;
}

bool CodiPadNodeRuntimeStart(CodiPadNodeRuntime *runtime, const char *scriptUtf8,
                           size_t scriptLength, char *error, size_t errorSize) {
  return StartRuntime(runtime, scriptUtf8, scriptLength, nullptr, 0, error, errorSize);
}

bool CodiPadNodeRuntimeStartWithEnvironment(CodiPadNodeRuntime *runtime,
                                          const char *scriptUtf8,
                                          size_t scriptLength,
                                          const char *environmentJsonUtf8,
                                          size_t environmentJsonLength,
                                          char *error, size_t errorSize) {
  if (!environmentJsonUtf8) {
    SetError(error, errorSize, "environment JSON is null");
    return false;
  }
  return StartRuntime(runtime, scriptUtf8, scriptLength, environmentJsonUtf8,
                      environmentJsonLength, error, errorSize);
}

bool CodiPadNodeRuntimeRequestStop(CodiPadNodeRuntime *runtime, char *error, size_t errorSize) {
  if (!runtime) {
    SetError(error, errorSize, "runtime is null");
    return false;
  }
  return RequestStopLocked(runtime, error, errorSize);
}

CodiPadNodeSnapshot CodiPadNodeRuntimeGetSnapshot(const CodiPadNodeRuntime *runtime) {
  CodiPadNodeSnapshot snapshot{};
  if (!runtime) {
    snapshot.state = CodiPadNodeStateFailed;
    std::snprintf(snapshot.message, sizeof(snapshot.message), "%s", "runtime is null");
    return snapshot;
  }
  std::lock_guard<std::mutex> lock(runtime->mutex);
  return SnapshotLocked(const_cast<CodiPadNodeRuntime *>(runtime));
}

bool CodiPadNodeRuntimeDestroy(CodiPadNodeRuntime *runtime, char *error, size_t errorSize) {
  if (!runtime) return true;
  std::unique_lock<std::mutex> api(runtime->api);
  bool active = false;
  {
    std::lock_guard<std::mutex> lock(runtime->mutex);
    active = runtime->state == CodiPadNodeStateStarting || runtime->state == CodiPadNodeStateRunning ||
             runtime->state == CodiPadNodeStateStopping;
  }
  if (active) RequestStopLocked(runtime, nullptr, 0);

  if (runtime->joinable) {
    bool finished = false;
    {
      std::unique_lock<std::mutex> lock(runtime->mutex);
      finished = runtime->cv.wait_for(lock, std::chrono::seconds(kStopTimeoutSeconds),
                                      [runtime] { return runtime->finished; });
    }
    if (!finished) {
      SetError(error, errorSize,
               "host thread did not finish; runtime handle left allocated rather than detached");
      return false;
    }
    runtime->thread.join();
    runtime->joinable = false;
  }
  api.unlock();
  delete runtime;
  return true;
}

const char *CodiPadNodeStateName(int32_t state) {
  switch (state) {
    case CodiPadNodeStateIdle:
      return "idle";
    case CodiPadNodeStateStarting:
      return "starting";
    case CodiPadNodeStateRunning:
      return "running";
    case CodiPadNodeStateStopping:
      return "stopping";
    case CodiPadNodeStateExited:
      return "exited";
    case CodiPadNodeStateFailed:
      return "failed";
    default:
      return "unknown";
  }
}

}  // extern "C"
