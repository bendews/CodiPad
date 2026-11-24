// CodiPadProcess/IshKernel.h — one app-owned process authority on the pinned iSH virtual kernel.
//
// Scope of this module
//   * owns the kernel boot, the session registry, and the per-PTY table;
//   * is the *only* authority: terminals, tasks, extension children, language servers and debug
//     adapters all come through codipad_kernel_spawn();
//   * executes guest ELF and supported scripts in iSH, without native tool offloads.
//
// Where the boundaries are, and what is never faked:
//   * exit is observed by the kernel's exit_hook (pids_lock held), which publishes the root's real
//     wait status into a bounded generation-tagged table and appends a dispatcher wakeup. The
//     dispatcher reaps with wait4 (borrowing init as `current`, since wait4 is parent-group scoped)
//     and only then calls the session's callback, with no lock held.
//   * ownership is the group's opaque fs_context (kernel/task.h:244), set to the session id before
//     exec and inherited verbatim on fork. Scans, signals and reaping all key on it, so a child is
//     not lost when its parent exits or reparents, and setsid() does not hide it. Zombies stay owned
//     until wait4 reaps them.
//   * cancellation stays strict: signal() returns CODIPAD_EINCOMPLETE unless every owned member was
//     reachable, and close() reports completion only with the whole context reaped.
//   * streams are not tracked separately: output is delivered by the pty driver before the exit is
//     reported, and close() does not claim completion without the reap.
//   * an interactive Bash PTY passed Ctrl-Z, bg, fg, and foreground Ctrl-C in the pinned host
//     probe. This is host evidence only; device behavior and terminal UI integration remain open.
//
// Concurrency: spawn() is served by one launcher thread, because the kernel's `current` is thread-
// local and become_new_init_child() rewrites it. Launch requests are serialized; only the launch is
// serialized, the guest tasks then run independently.

#ifndef CODIPAD_ISH_KERNEL_H
#define CODIPAD_ISH_KERNEL_H

#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

// Select before kernel boot or executable-region installation. The default permits JIT.
// Gadget-only prevents translator initialization and executable-region acquisition even when
// ISH_JIT is set. Repeating the selected mode is safe; changing it after boot starts or a
// region is installed returns -EBUSY. Returns 0 or a negative errno.
int codipad_kernel_configure_execution_mode(bool gadget_only);

struct task;

typedef uint64_t codipad_session_t;

// Not an errno: signal delivered, but not every descendant could be confirmed. Distinct so a caller
// cannot read it as success or as "nothing happened".
#define CODIPAD_EINCOMPLETE 2001
#define CODIPAD_SESSION_NONE ((codipad_session_t) 0)

// Terminal output remains charged until the workbench acknowledges decoded output events.
#define CODIPAD_TERMINAL_OUTPUT_MAX_BYTES 4194304
// Upstream buffers ACKs until >5000 UTF-16 chars. A BMP character may take
// three one-byte UTF-8 callbacks, so leave room for that first ACK to occur.
#define CODIPAD_TERMINAL_OUTPUT_MAX_EVENTS 32768
// Bounded indexed child stdio map; index N becomes guest fd N.
#define CODIPAD_SPAWN_MAX_STDIO_FDS 16
#define CODIPAD_HOST_FD_READ 0
#define CODIPAD_HOST_FD_WRITE 1
#define CODIPAD_HOST_FD_READ_WRITE 2
#define CODIPAD_HOST_STATUS_NONBLOCK (1u << 0)

// How the executable would be run. GUEST_MACHO is the declared restricted ARM64 Mach-O/Darwin
// personality in iSH; it does not claim host-native speed. Arbitrary/unsupported Mach-O images are
// classified UNKNOWN by the read-only loader preflight.
typedef enum {
    CODIPAD_BACKEND_GUEST_ELF = 1,    // guest ELF, emulated by the iSH CPU loop
    CODIPAD_BACKEND_GUEST_SCRIPT = 2, // #! script; the interpreter is classified again
    CODIPAD_BACKEND_NATIVE = 3,       // Arbitrary Mach-O — rejected in this build
    CODIPAD_BACKEND_UNKNOWN = 4,      // unrecognised; rejected
    // Values 5 and 6 are reserved for retired backends in earlier diagnostics.
    CODIPAD_BACKEND_GUEST_MACHO = 7,   // validated ARM64 Mach-O subset, executed by iSH task engine
} codipad_backend_t;

typedef enum {
    // Output arrives on the guest thread that wrote to the pty. Do not block, do not re-enter the
    // kernel, and copy the bytes before returning.
    CODIPAD_SPAWN_APPEND_NEWLINE = 1u << 0, // reserved; unused
} codipad_spawn_flags;

// Input readiness is one-shot and may arrive with tty->lock held. Only enqueue work;
// do not call back into the kernel. Uses the spawn callback context and close fence.
typedef void (*codipad_input_ready_cb)(codipad_session_t session, void *ctx);
typedef void (*codipad_output_cb)(codipad_session_t session, const void *bytes, size_t len, void *ctx);
// Called once per session. all_members_reaped=false means the leader exited but the session still
// has unreaped members (or its pty writers are still open): the caller must treat this as leaderExit
// only, never as completion. Invoked with no kernel or registry lock held.
typedef void (*codipad_exit_cb)(codipad_session_t session, int code, int terminating_signal,
                              bool all_members_reaped, void *ctx);

typedef enum {
    CODIPAD_STDIO_PTY = 0,
    CODIPAD_STDIO_HOST_FDS = 1,
} codipad_stdio_mode;

struct codipad_spawn_opts {
    const char *exe;                  // guest command or path; bare names use cwd/env PATH
    const char *const *argv;          // NULL-terminated; argv[0] is the program name
    const char *const *envp;          // NULL-terminated "K=V"; copied before spawn returns
    const char *cwd;                  // guest absolute path; NULL keeps the session default
    unsigned cols, rows;              // initial pty size, 0 = 80x24
    uint32_t flags;                   // codipad_spawn_flags
    codipad_output_cb on_output;
    codipad_exit_cb on_exit;            // called on the dispatcher, never under pids_lock
    void *ctx;
    codipad_stdio_mode stdio_mode;      // zero preserves terminal behavior
    int stdin_fd, stdout_fd, stderr_fd; // HOST_FDS: duplicated, originals remain caller-owned
    // Optional indexed borrowed host descriptors for HOST_FDS. Each array index is the child
    // descriptor number; -1 leaves descriptors >= 3 closed (0..2 become /dev/null). The authority
    // duplicates nonnegative descriptors before returning and never changes their OFD flags. The
    // fd and optional metadata arrays, and each nonnegative fd, must remain stable until return.
    // Safe types are regular files, /dev/null, connected AF_UNIX SOCK_STREAM sockets, and FIFOs
    // already O_NONBLOCK (writable FIFOs must also have F_GETNOSIGPIPE set). Blocking FIFOs,
    // terminals, and other special files reject pre-spawn; borrowed host flags are never changed.
    // NULL preserves the legacy stdio trio, subject to the same safe borrowing checks.
    const int *stdio_host_fds;
    size_t stdio_host_fd_count;
    // Optional access mode per indexed descriptor, using CODIPAD_HOST_FD_* values above. NULL uses
    // conventional stdin/stdout/stderr modes and read/write for descriptors >= 3.
    const unsigned char *stdio_host_modes;
    // Optional inherited status bits. NONBLOCK is virtualized in the guest and never changes the
    // borrowed host open-file description. NULL preserves legacy derivation from host F_GETFL.
    const unsigned char *stdio_host_status_flags;
    // Optional completion notification, once the leader status and all owned exits are observed.
    // Parent reads can still have buffered bytes; native pipes provide their own real EOF.
    codipad_exit_cb on_settled;
    uint64_t owner;                   // supervisor generation, zero for independent terminals
    codipad_session_t parent_session;   // optional parent in the same authority; zero for roots
};

struct codipad_session_info {
    codipad_session_t session;
    codipad_session_t parent_session;   // zero for roots; otherwise the authority parent record
    uint64_t guest_pid;               // 0 until the task exists
    uint64_t guest_pgid;
    int pty_num;                      // /dev/pts/<n>
    codipad_backend_t backend;
    bool running;
    bool exited;
    bool reaped;                      // wait4 actually freed the zombie
    bool all_descendants_reaped;      // every session-owned member reaped (fs_context scan)
    bool has_status;
    // Derived from the observed wait status (kernel/exit.c: sys_exit passes code<<8, signal death
    // passes the bare signal). Normal exit: code = (status >> 8) & 0xff, terminating_signal = 0.
    // Signalled: terminating_signal = the signal, code = 128 + signal (shell convention).
    // Valid only when has_status is true; nothing here is synthesised when no status was observed.
    int code;
    int terminating_signal;
};

// Last incomplete close return site, not a priority inferred from a later snapshot.
enum codipad_close_wait_reason {
    CODIPAD_CLOSE_WAIT_NONE = 0, CODIPAD_CLOSE_WAIT_SETTLEMENT = 1,
    CODIPAD_CLOSE_WAIT_ROOT_STATUS = 2, CODIPAD_CLOSE_WAIT_TTY_RELEASE = 3,
    CODIPAD_CLOSE_WAIT_RECORD_DROP = 4, CODIPAD_CLOSE_WAIT_CHILD = 5,
    // Values 6 through 9 were used by retired native tool sessions.
};
// Read-only, sequential observations; counts may change between domains. A disappearing record
// returns ENOENT with session preserved and record_valid=false. Reserved fields preserve v2 layout.
struct codipad_session_cleanup_diagnostic {
    uint32_t version, size;
    codipad_session_t session, parent_session;
    uint64_t owner, root_pid, root_pgid, waiting_child, reserved_native_waiter_pid;
    int32_t root_code, root_signal, close_result, reserved_native_join_error;
    uint32_t backend, live_tasks, zombie_tasks, unreaped_tasks;
    uint32_t users, callback_users, borrowed_users, reserved_native_ops;
    uint32_t pty_open_fds, reserved_native_stream_open_mask;
    uint8_t record_valid, guest_tasks_valid, reserved_native_valid;
    uint8_t root_running, root_exited, root_status_valid, root_status_published, root_reaped;
    uint8_t descendants_reaped, close_requested, writers_valid, writers_closed, has_tty, wait_reason;
    uint8_t reserved_native_state[6];
};
int codipad_kernel_cleanup_diagnostic(codipad_session_t session, struct codipad_session_cleanup_diagnostic *out);

// Boots the guest kernel exactly once. fakefs_root is the guest rootfs directory (may be separate
// from the workspace). native_workspace_dir is the canonical native directory to expose at its
// native absolute guest path and at the /workspace compatibility alias; pass NULL to boot without
// a workspace (fd -1). A workspace requires its already-authorized borrowed directory fd.
// The mount duplicates the fd; the caller must keep it live through the call.
// Returns 0 or a negative errno. Repeated workspace calls revalidate mounted fd identity.
int codipad_kernel_boot(const char *fakefs_root, const char *native_workspace_dir, int borrowed_workspace_fd);

// Startup state is authority, unlike diagnostic phase strings. INCOMPLETE may own published
// resources and must never be retried as a pristine bootstrap. INITIALIZED means the core can
// accept mounts; a requested workspace/alias may still have failed. Query under caller startup lock.
enum codipad_kernel_initialization_state {
    CODIPAD_KERNEL_PRISTINE = 0,
    CODIPAD_KERNEL_INCOMPLETE = 1,
    CODIPAD_KERNEL_INITIALIZED = 2,
};
enum codipad_kernel_initialization_state codipad_kernel_initialization_state(void);
// 1: matching canonical/covering/legacy-alias mount; 0: no related mount; negative: no absence proof.
// Borrowed fd stays caller-owned. Requires the same startup serialization as mount calls.
int codipad_kernel_authorized_root_status(const char *canonical_native_dir, int borrowed_directory_fd);

// Diagnostic name of the most recent boot operation. Read after boot returns, under the same
// caller-side startup serialization. The returned string is static and contains no paths.
const char *codipad_kernel_boot_phase(void);

// Mount an already-authorized native directory at its canonical absolute path in the guest with
// realfs: guest paths resolve to the host directory itself, so there is one backing file, one
// st_ino and no copy. The caller must validate authorization and retain its access lease through
// kernel shutdown, including partial publication failures. The path is an explicit canonical guest
// identity label; it is never reopened. The borrowed directory fd is duplicated into the mount.
// Same-path repeats require matching dev/ino; invalid or conflicting mounts fail before spawn.
int codipad_kernel_mount_authorized_root(const char *canonical_native_dir, int borrowed_directory_fd);

// Diagnostic substep of the most recent workspace mount attempt. Read after the operation
// returns, under the same caller-side startup serialization. The returned string is static and
// contains no paths.
const char *codipad_kernel_workspace_mount_stage(void);

// Read-only path membership check against the kernel's existing direct realfs mounts. Returns
// true only for a path equal to or beneath a canonical native mount point.
bool codipad_kernel_native_path_is_mounted(const char *canonical_native_path);

// Refresh guest /etc/resolv.conf from the host's configured DNS servers. Returns a negative errno
// without replacing the existing configuration when no host resolver is available.
int codipad_kernel_refresh_dns(void);

// Mount the workspace at its canonical native path and at /workspace for older fixtures. The
// native path is the primary guest identity and is also the path returned by getcwd().
// read_only is NOT implemented: do_mount() stores the flag but no kernel path reads it, and realfs
// has no read-only mode. Passing read_only=true returns -EOPNOTSUPP before any mount is attempted
// rather than pretending to enforce it. Alias failure can leave the canonical mount published;
// retain its original adapter/lease even on error. Returns 0 or negative errno. Requires boot.
int codipad_kernel_mount_workspace(const char *native_workspace_dir, int borrowed_directory_fd, bool read_only);

// Required by the pinned iSH offload hook; retired native images are always rejected.
int codipad_kernel_native_image_validate(const char *guest_path);

// Classify guest executable contents without running them. Missing or unsupported images,
// including retired native descriptors, are unknown. ARM64 Mach-O support is restricted.
codipad_backend_t codipad_kernel_backend_for(const char *guest_path);

// Read-only regular-file existence in the already booted guest namespace. Follows symlinks;
// does not require execute permission, inspect executable contents, open a file, or create a task.
// Matches upstream profile existsFile: a directory, dangling link or failed stat yields false.
// Host callers must serialize with boot/mount setup and retain the existing authorized runtime
// and mount leases. This does not prepare a runtime or authorize/mount the supplied path.
// Normal boot captures an independent metadata-only root context before starting init. Its fs and
// root/pwd descriptor references live with the mounted kernel, so init exit cannot invalidate an
// admitted lookup. Calls after init begins exit fail; no PID lock is held across filesystem lookup.
// Requires an absolute guest path shorter than MAX_PATH. Returns -EINVAL/-ENAMETOOLONG for
// invalid input and -EBUSY without a live initialized authority. Missing paths and non-regular
// files return 0 with *is_file false. Other guest lookup errors propagate to the caller.
int codipad_kernel_path_is_file(const char *absolute_guest_path, bool *is_file);

// Reads the guest /etc/shells using the independent lookup context. Missing means empty.
int codipad_kernel_read_shells(char *buffer, size_t capacity, size_t *length);

// Resolves, validates and classifies a command in the guest namespace without allocating a session
// or creating a task. Returns the canonical guest executable path and its backend on success.
int codipad_kernel_preflight_executable(const char *command, const char *cwd,
                                      const char *const *envp, char *resolved,
                                      size_t capacity, codipad_backend_t *backend);

// Reserve a nonzero identity from the same namespace as session records. Supervisors must use
// this rather than a private counter or clock, since independent-terminal children use their
// parent's session id as owner. Reservations are never reused, including after failed starts.
// Available before kernel boot; no task, session record or additional registry is created.
// Returns 0, -EINVAL for NULL output, or -EOVERFLOW when exhausted (output cleared to zero).
// UINT64_MAX is the permanent exhausted sentinel and is never issued.
int codipad_kernel_reserve_owner_generation(uint64_t *out_owner);

// Creates a session: pty, cwd, environment, argv, then execve. Serialized through the launcher.
// Returns 0 and a session id, or a negative errno. A rejected request has no side effects: preflight
// (argument checks, executable probe, format classification) runs before any kernel task is created.
// A launch that fails after the task is constructed exits through do_exit_group(127) on its own
// launcher thread, so the kernel tears it down instead of leaking it.
//   -ENOENT   no such executable
//   -ENOEXEC  wrong format for this build (e.g. a native tool, or a script whose interpreter is one)
//   -EACCES   workspace authorization / not readable
//   -EINVAL   bad arguments (empty argv, cwd not absolute, envp entry without '=')
//   -EBUSY    the launcher could not be started; kernel not booted
//   -ENOMEM / -EAGAIN from the kernel
// A rejected request never falls back to another backend.
int codipad_kernel_spawn(const struct codipad_spawn_opts *opts, codipad_session_t *out_session);
// Spawn a child attached to an existing authority session. opts->owner must match the parent's
// nonzero owner generation. Returns -ENOENT for a missing parent, -EPERM for an owner mismatch,
// and -ESHUTDOWN when the parent has begun cleanup. The parent relation is stored in the session
// record and parent close traverses it recursively.
int codipad_kernel_spawn_child(codipad_session_t parent, const struct codipad_spawn_opts *opts,
                             codipad_session_t *out_session);

// Writes to the session's pty (cooked input, as a terminal would). Returns bytes accepted >= 0.
int codipad_kernel_input(codipad_session_t session, const void *bytes, size_t len);
// Arm after an EAGAIN/short write. Checks existing space under the same tty lock
// as consumption, so a read between the failed write and arming is not lost.
// NULL disarms future callbacks; an in-flight callback still uses the close fence.
int codipad_kernel_set_input_ready_callback(codipad_session_t session, codipad_input_ready_cb callback);
// Acknowledges one complete output callback event using its original byte length.
int codipad_kernel_output_ack(codipad_session_t session, size_t bytes);

// Resizes the pty and delivers SIGWINCH semantics through the kernel's winsize path.
int codipad_kernel_resize(codipad_session_t session, unsigned cols, unsigned rows);

// Signals the session's process group and every descendant found by walking parentage under
// pids_lock (so a setsid() child is still reached). Returns 0 when every live descendant was
// reachable, -CODIPAD_EINCOMPLETE when the signal was delivered but coverage could not be confirmed,
// -ENOENT / -ESRCH otherwise. Callers must treat INCOMPLETE as "not cancelled".
int codipad_kernel_signal(codipad_session_t session, int sig);

// Reads the live guest cwd of the session (the root task's, else the first live member's) through
// the kernel's own path resolution — not a cached copy of the cwd passed to spawn(). Writes a
// NUL-terminated path into buffer. Returns 0, -EINVAL for a bad buffer, -ENOENT when no live task
// carries this session's context, -ENAMETOOLONG when the path does not fit, or the kernel's error.
int codipad_kernel_getcwd(codipad_session_t session, char *buffer, size_t capacity);

// Copies the current session record. Returns 0 or -ENOENT. Never fabricates a status.
int codipad_kernel_info(codipad_session_t session, struct codipad_session_info *out);

// Snapshot session ids belonging to a supervisor, without changing their state.
// Returns the total count; writes up to capacity ids. Owner zero is reserved for terminals.
size_t codipad_kernel_sessions_for_owner(uint64_t owner, codipad_session_t *ids, size_t capacity);

// Ends the session. Sends SIGHUP (then SIGKILL after grace_ms) to the group, marks the pty hung up,
// and releases the record once the kernel has reported the exit.
// Returns 0 only when the exit was observed, the zombie was reaped by wait4, AND the subtree is
// empty. -EINPROGRESS when the task has not reported exit (record retained; retry), -CODIPAD_EINCOMPLETE
// when the session is gone but a descendant survived, -ENOENT for an unknown id.
// Closing never invents an exit status and never reports completion it did not achieve.
int codipad_kernel_close(codipad_session_t session, unsigned grace_ms);

// Same as codipad_kernel_close, but reports the authority's final observed status before the record is
// dropped. `out` receives the live record's fields (never a synthesised code): after a successful
// close it describes the session that was just released (reaped, all_descendants_reaped, exit code or
// signal). On -EINPROGRESS / -CODIPAD_EINCOMPLETE it describes the retained record. `out` may be NULL,
// in which case this behaves exactly like codipad_kernel_close.
int codipad_kernel_close_status(codipad_session_t session, unsigned grace_ms,
                              struct codipad_session_info *out);

#ifdef __cplusplus
}
#endif

#endif // CODIPAD_ISH_KERNEL_H
