#pragma once
#include <cstddef>
#include <cstdint>
#include <map>
#include <memory>
#include <mutex>
#include <string>

// Bounded executable code pool with a writable alias (GPL-3.0-only; see NOTICE).

namespace codipadnode {

// This is a point-in-time observation, not a guarantee that the tracer stays attached.
bool DebuggerAttached();
// Only call after verifying the active StikDebug script's fresh handshake.
bool CancelDebuggerPreparation();

// Where executable pages come from.
//
// Platform never issues the debugger breakpoint protocol: a process whose pages
// cannot be made executable gets an error and the caller reports it.
// DebuggerPrepared is opt-in and fails unless a debugger is already attached
// to prepare executable pages via the breakpoint protocol.
enum class ExecutablePages {
  Platform,
  DebuggerPrepared,
};

class CodeRegion : public std::enable_shared_from_this<CodeRegion> {
 public:
  struct Lease {
    std::shared_ptr<CodeRegion> owner;
    size_t offset = 0, size = 0;
    ~Lease();
    char *writable() const;
    char *executable() const;
    void publish() const;
  };

  // Returns null and fills *error on failure. `error` may be null.
  static std::shared_ptr<CodeRegion> Create(size_t capacity, ExecutablePages pages,
                                            std::string *error, bool allow_debugger_fallback = false);
  ~CodeRegion();

  // Callers skipping initialization must write every instruction before it can run.
  std::unique_ptr<Lease> Allocate(size_t bytes, std::string *error, bool initialize = true);

  size_t capacityBytes() const { return capacity; }
  size_t pageSize() const { return page; }

 private:
  CodeRegion() = default;
  static std::shared_ptr<CodeRegion> CreateUnshared(size_t capacity, ExecutablePages pages,
                                                    std::string *error, bool allow_debugger_fallback);
  void release(size_t offset, size_t bytes);

  char *rx = nullptr, *rw = nullptr;
  size_t capacity = 0, page = 0;
  bool debugger = false;
  mutable std::mutex mutex;
  std::map<size_t, size_t> free;
};

}  // namespace codipadnode
