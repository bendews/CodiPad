// CodiPadProcess/IshKernel.c — one process authority over the pinned iSH virtual kernel.
// See IshKernel.h for the contract and for what is deliberately not implemented.

#include "IshKernel.h"

#include <errno.h>
#include <arpa/inet.h>
#include <fcntl.h>
#include <limits.h>
#include <pthread.h>
#include <poll.h>
#include <resolv.h>
#include <time.h>
#include <stdatomic.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>
#include <sys/un.h>
#include <unistd.h>
#include <TargetConditionals.h>

#include "kernel/init.h"
#include "kernel/calls.h"
#include "kernel/fs.h"
#include "kernel/task.h"
#include "kernel/signal.h"
#include "fs/dev.h"
#include "fs/fd.h"
#include "fs/devices.h"
#include "fs/path.h"
#include "fs/sock.h"
#include "fs/tty.h"
// fs/fake.h (bind-mount API, no longer used by this module) is guarded by ISH_INTERNAL in the iSH
// build; the app target passes it too.
#ifndef ISH_INTERNAL
#define ISH_INTERNAL 1
#endif
#include "fs/fake.h"
#include "fs/real.h"
#include "misc.h"
#include "util/sync.h"

// WNOHANG_ and P_PID_ are file-local to kernel/exit.c; wait4's public entry point takes the raw
// numbers (options bit 0 is WNOHANG, a positive pid selects P_PID_).
#define CODIPAD_WNOHANG 1
// "signal delivered, descendant coverage incomplete" — a distinct code so no caller can mistake it
// for "nothing happened" or for success.
#define CODIPAD_EINCOMPLETE 2001

// ---------------------------------------------------------------------------
// records

#define CODIPAD_MAX_SESSIONS 64
#define CODIPAD_MAX_TTYS 64
#define CODIPAD_EXIT_QUEUE 128
#define CODIPAD_MAX_AUTHORIZED_ROOTS 16
#define CODIPAD_REAP_BATCH 64

struct codipad_session {
    codipad_session_t id;
    struct tty *tty;
    dword_t pid;
    dword_t pgid;
    codipad_backend_t backend;
    bool running;
    bool exit_reported;   // the kernel's exit_hook saw the leader exit
    bool reaped;          // wait4 actually freed the zombie
    bool has_status;
    int code;              // derived, see codipad_decode_wait_status()
    int terminating_signal;
    int raw_wait_status;   // as the kernel reported it; internal, never exported
    bool all_descendants_reaped; // only ever set from a completed scan + empty subtree
    bool close_requested;
    codipad_session_t parent_session;
    unsigned users;       // in-flight operations holding a borrowed tty pointer
    unsigned callback_users;
    unsigned borrowed_users;
    uint8_t close_wait_reason;
    int close_result;
    codipad_session_t close_wait_child;
    struct codipad_output_flow *output_flow;
    codipad_input_ready_cb on_input_ready;
    codipad_output_cb on_output;
    codipad_exit_cb on_exit;
    codipad_exit_cb on_settled;
    bool settlement_reported;
    uint64_t owner;
    void *ctx;
};

// PTY writers reserve a complete driver write against this per-session window before Swift copies
// it. The window is released only when the workbench acknowledges that output event.
struct codipad_output_flow {
    lock_t lock;
    cond_t available;
    size_t pending_bytes;
    size_t pending_events;
    bool initialized;
};

static struct codipad_session g_sessions[CODIPAD_MAX_SESSIONS];
// Hook-safe root status publication. The generation id associates a slot with its retained session;
// close clears it only after the session's owned task tree has been reaped.
struct codipad_root_status {
    atomic_uint_fast64_t id;
    atomic_int pid;
    atomic_int raw;
    atomic_bool ready;
};
static struct codipad_root_status g_root_status[CODIPAD_MAX_SESSIONS];
static struct codipad_output_flow g_output_flows[CODIPAD_MAX_SESSIONS];
static pthread_mutex_t g_sessions_lock = PTHREAD_MUTEX_INITIALIZER;
static atomic_uint_fast64_t g_next_session = 1;
static char *g_mounted_workspace_path;
static bool g_mounted_workspace_read_only;
static const char *g_workspace_mount_stage = "not-started";

const char *codipad_kernel_workspace_mount_stage(void) {
    return g_workspace_mount_stage;
}

static struct codipad_session *codipad_session_find(codipad_session_t id);

struct codipad_tty_slot {
    struct tty *tty;
    codipad_session_t session;
};
static struct codipad_tty_slot g_ttys[CODIPAD_MAX_TTYS];
static pthread_mutex_t g_ttys_lock = PTHREAD_MUTEX_INITIALIZER;

// exit_hook publishes status while holding pids_lock; dispatch runs outside that context.
struct codipad_exit_event {
    uint64_t context;   // struct task_group::fs_context == session id, read before the task is freed
    dword_t pid;
    int code;
};
static struct codipad_exit_event g_exit_queue[CODIPAD_EXIT_QUEUE];
static unsigned g_exit_head, g_exit_tail;
static pthread_mutex_t g_exit_lock = PTHREAD_MUTEX_INITIALIZER;
static pthread_cond_t g_exit_cond = PTHREAD_COND_INITIALIZER;
static void (*g_prev_exit_hook)(struct task *task, int code);

extern bool ish_jit_configure_mode(bool gadget_only);
extern void ish_jit_freeze_mode(void);

int codipad_kernel_configure_execution_mode(bool gadget_only) {
    return ish_jit_configure_mode(gadget_only) ? 0 : -EBUSY;
}

static bool g_booted;
static enum codipad_kernel_initialization_state g_initialization_state = CODIPAD_KERNEL_PRISTINE;

enum codipad_kernel_initialization_state codipad_kernel_initialization_state(void) {
    return g_initialization_state;
}
// Metadata-only TLS context, owned for the mounted kernel's lifetime. Never registered as a task
// or used for execution. It contains no borrowed task/files/group pointers from init.
static struct task g_path_lookup_task;
static struct tgroup g_path_lookup_group;
static const char *g_boot_phase = "not-started";
static pthread_once_t g_threads_once = PTHREAD_ONCE_INIT;
static bool g_threads_ok;

// Required by the pinned iSH native-offload patch; retired descriptors never dispatch.
int codipad_kernel_native_image_validate(const char *path) {
    (void) path;
    return -ENOEXEC;
}

// ---------------------------------------------------------------------------
// helpers

static char *codipad_flatten(const char *const *list) {
    size_t total = 0, count = 0;
    if (list != NULL)
        for (; list[count] != NULL; count++)
            total += strlen(list[count]) + 1;
    char *buf = calloc(1, total + 1);
    if (buf == NULL)
        return NULL;
    size_t at = 0;
    for (size_t i = 0; i < count; i++) {
        size_t len = strlen(list[i]);
        memcpy(buf + at, list[i], len);
        at += len + 1;
    }
    return buf;
}

int codipad_kernel_reserve_owner_generation(uint64_t *out_owner) {
    if (out_owner == NULL)
        return -EINVAL;
    *out_owner = 0;
    uint_fast64_t next = atomic_load_explicit(&g_next_session, memory_order_relaxed);
    for (;;) {
        if (next == 0 || next >= UINT64_MAX)
            return -EOVERFLOW;
        if (atomic_compare_exchange_weak_explicit(&g_next_session, &next, next + 1,
                                                 memory_order_relaxed, memory_order_relaxed)) {
            *out_owner = (uint64_t) next;
            return 0;
        }
    }
}

static int codipad_session_new(struct codipad_session *template, codipad_session_t parent,
                             codipad_session_t *out_id) {
    if (out_id == NULL)
        return -EINVAL;
    *out_id = CODIPAD_SESSION_NONE;
    codipad_session_t id;
    int allocation = codipad_kernel_reserve_owner_generation(&id);
    if (allocation < 0)
        return allocation;
    pthread_mutex_lock(&g_sessions_lock);
    if (parent != CODIPAD_SESSION_NONE) {
        struct codipad_session *parent_record = codipad_session_find(parent);
        if (parent_record == NULL) {
            pthread_mutex_unlock(&g_sessions_lock);
            return -ENOENT;
        }
        bool terminal_child_owner = parent_record->owner == 0 &&
            template->owner == parent_record->id;
        if (template->owner == 0 ||
            (parent_record->owner != template->owner && !terminal_child_owner)) {
            pthread_mutex_unlock(&g_sessions_lock);
            return -EPERM;
        }
        if (parent_record->close_requested) {
            pthread_mutex_unlock(&g_sessions_lock);
            return -ESHUTDOWN;
        }
    }
    for (int i = 0; i < CODIPAD_MAX_SESSIONS; i++) {
        if (g_sessions[i].id == 0) {
            struct codipad_output_flow *flow = &g_output_flows[i];
            if (!flow->initialized) {
                lock_init(&flow->lock);
                cond_init(&flow->available);
                flow->initialized = true;
            }
            lock(&flow->lock);
            flow->pending_bytes = 0;
            flow->pending_events = 0;
            unlock(&flow->lock);
            g_sessions[i] = *template;
            g_sessions[i].id = id;
            g_sessions[i].parent_session = parent;
            g_sessions[i].output_flow = flow;
            atomic_store_explicit(&g_root_status[i].pid, 0, memory_order_relaxed);
            atomic_store_explicit(&g_root_status[i].raw, 0, memory_order_relaxed);
            atomic_store_explicit(&g_root_status[i].ready, false, memory_order_relaxed);
            atomic_store_explicit(&g_root_status[i].id, id, memory_order_release);
            pthread_mutex_unlock(&g_sessions_lock);
            *out_id = id;
            return 0;
        }
    }
    pthread_mutex_unlock(&g_sessions_lock);
    return -ENOMEM;
}

static struct codipad_session *codipad_session_find(codipad_session_t id) {
    for (int i = 0; i < CODIPAD_MAX_SESSIONS; i++)
        if (g_sessions[i].id == id)
            return &g_sessions[i];
    return NULL;
}

// Returns -EBUSY while a callback invocation or borrowed use is still in flight: dropping then would
// free the ctx pointer the callee is still holding.
static int codipad_session_drop_idle(codipad_session_t id) {
    pthread_mutex_lock(&g_sessions_lock);
    struct codipad_session *s = codipad_session_find(id);
    if (s != NULL) {
        if (s->users != 0) {
            pthread_mutex_unlock(&g_sessions_lock);
            return -EBUSY;
        }
        if (s->output_flow != NULL) {
            lock(&s->output_flow->lock);
            s->output_flow->pending_bytes = 0;
            s->output_flow->pending_events = 0;
            notify(&s->output_flow->available);
            unlock(&s->output_flow->lock);
        }
        for (size_t i = 0; i < CODIPAD_MAX_SESSIONS; i++) {
            if (atomic_load_explicit(&g_root_status[i].id, memory_order_acquire) == id) {
                // The caller reaches this only after the session's owned task tree is reaped.
                atomic_store_explicit(&g_root_status[i].id, 0, memory_order_release);
                break;
            }
        }
        memset(s, 0, sizeof(*s));
    }
    pthread_mutex_unlock(&g_sessions_lock);
    return 0;
}

static void codipad_session_drop(codipad_session_t id) {
    (void) codipad_session_drop_idle(id);
}

static void codipad_tty_register(struct tty *tty, codipad_session_t id) {
    pthread_mutex_lock(&g_ttys_lock);
    for (int i = 0; i < CODIPAD_MAX_TTYS; i++) {
        if (g_ttys[i].tty == NULL) {
            g_ttys[i].tty = tty;
            g_ttys[i].session = id;
            break;
        }
    }
    pthread_mutex_unlock(&g_ttys_lock);
}

static codipad_session_t codipad_tty_lookup(struct tty *tty) {
    codipad_session_t id = CODIPAD_SESSION_NONE;
    pthread_mutex_lock(&g_ttys_lock);
    for (int i = 0; i < CODIPAD_MAX_TTYS; i++) {
        if (g_ttys[i].tty == tty) {
            id = g_ttys[i].session;
            break;
        }
    }
    pthread_mutex_unlock(&g_ttys_lock);
    return id;
}

static void codipad_tty_forget(struct tty *tty) {
    pthread_mutex_lock(&g_ttys_lock);
    for (int i = 0; i < CODIPAD_MAX_TTYS; i++) {
        if (g_ttys[i].tty == tty) {
            g_ttys[i].tty = NULL;
            g_ttys[i].session = CODIPAD_SESSION_NONE;
            break;
        }
    }
    pthread_mutex_unlock(&g_ttys_lock);
}

// Forward declarations: the tty write path is the first user, the helpers live with the fence.
static bool codipad_callback_enter(codipad_session_t id, codipad_output_cb *out_cb, codipad_exit_cb *out_exit,
                                 void **out_ctx, struct codipad_session **out_session);
static void codipad_callback_leave(codipad_session_t id);

static int codipad_output_reserve(struct codipad_session *session, size_t len, bool blocking) {
    struct codipad_output_flow *flow = session->output_flow;
    if (flow == NULL)
        return -EIO;
    if (len > CODIPAD_TERMINAL_OUTPUT_MAX_BYTES || len > INT_MAX)
        return -E2BIG;

    lock(&flow->lock);
    while (len > CODIPAD_TERMINAL_OUTPUT_MAX_BYTES - flow->pending_bytes ||
           flow->pending_events >= CODIPAD_TERMINAL_OUTPUT_MAX_EVENTS) {
        if (!blocking) {
            unlock(&flow->lock);
            return -EAGAIN;
        }
        int err = wait_for(&flow->available, &flow->lock, NULL);
        if (err < 0) {
            unlock(&flow->lock);
            return err;
        }
    }
    flow->pending_bytes += len;
    flow->pending_events++;
    unlock(&flow->lock);
    return 0;
}

// ---------------------------------------------------------------------------
// pty driver: one driver, dispatch by tty pointer (no singleton shell tty)

static int codipad_tty_write(struct tty *tty, const void *buf, size_t len, bool blocking) {
    if (len == 0)
        return 0;
    if (len > INT_MAX)
        return -E2BIG;
    codipad_session_t id = codipad_tty_lookup(tty);
    if (id == CODIPAD_SESSION_NONE)
        return (int) len; // not attached yet: drop rather than misdeliver
    codipad_output_cb cb = NULL;
    void *ctx = NULL;
    struct codipad_session *session = NULL;
    // Holds a use for the duration of the call, so close() cannot drop the record underneath us.
    if (!codipad_callback_enter(id, &cb, NULL, &ctx, &session))
        return (int) len;
    if (cb == NULL) {
        codipad_callback_leave(id);
        return (int) len;
    }
    // tty_echo() calls this with blocking=false while tty->lock is held. That path only tries the
    // credit lock and returns EAGAIN; it never waits under tty->lock. Normal process writes arrive
    // without tty->lock and may sleep on the interruptible kernel condition until the UI acks data.
    int reserve_err = codipad_output_reserve(session, len, blocking);
    if (reserve_err == 0)
        cb(id, buf, len, ctx);
    codipad_callback_leave(id);
    return reserve_err < 0 ? reserve_err : (int) len;
}

// A tty pointer is only borrowed: the record's reference keeps the pty alive, but close() can clear
// and release it between our unlock and our use. Every operation that keeps the pointer past the
// registry lock registers as a user first, and close() refuses to release while users != 0.
// Order matters: g_sessions_lock is never held while taking tty->lock or calling tty_input, because
// the output callback runs with tty->lock held and takes g_sessions_lock.
static struct tty *codipad_tty_acquire(codipad_session_t id, bool require_running) {
    struct tty *tty = NULL;
    pthread_mutex_lock(&g_sessions_lock);
    struct codipad_session *s = codipad_session_find(id);
    if (s != NULL && s->tty != NULL && (!require_running || s->running)) {
        s->users++;
        s->borrowed_users++;
        tty = s->tty;
    }
    pthread_mutex_unlock(&g_sessions_lock);
    return tty;
}

// A callback invocation is itself an in-flight use of the session's ctx pointer. It is registered
// under the registry lock before the pointer is copied out, and released after the callback returns,
// so the record (and the Swift object behind ctx) cannot be dropped under a running callback.
static bool codipad_callback_enter(codipad_session_t id, codipad_output_cb *out_cb, codipad_exit_cb *out_exit,
                                 void **out_ctx, struct codipad_session **out_session) {
    bool ok = false;
    pthread_mutex_lock(&g_sessions_lock);
    struct codipad_session *s = codipad_session_find(id);
    if (s != NULL) {
        s->users++;
        s->callback_users++;
        if (out_cb != NULL) *out_cb = s->on_output;
        if (out_exit != NULL) *out_exit = s->on_exit;
        *out_ctx = s->ctx;
        if (out_session != NULL) *out_session = s;
        ok = true;
    }
    pthread_mutex_unlock(&g_sessions_lock);
    return ok;
}

static void codipad_callback_leave(codipad_session_t id) {
    pthread_mutex_lock(&g_sessions_lock);
    struct codipad_session *s = codipad_session_find(id);
    if (s != NULL && s->callback_users > 0) {
        s->callback_users--;
        s->users--;
    }
    pthread_mutex_unlock(&g_sessions_lock);
}

static void codipad_tty_end_use(codipad_session_t id) {
    pthread_mutex_lock(&g_sessions_lock);
    struct codipad_session *s = codipad_session_find(id);
    if (s != NULL && s->borrowed_users > 0) {
        s->borrowed_users--;
        s->users--;
    }
    pthread_mutex_unlock(&g_sessions_lock);
}

static struct codipad_session *codipad_session_acquire(codipad_session_t id) {
    struct codipad_session *session = NULL;
    pthread_mutex_lock(&g_sessions_lock);
    session = codipad_session_find(id);
    if (session != NULL) {
        session->users++;
        session->borrowed_users++;
    }
    pthread_mutex_unlock(&g_sessions_lock);
    return session;
}

// Releases the reference pty_open_fake() -> tty_get() handed the authority (tty_get increments the
// refcount under ttys_lock + tty->lock, fs/tty.c:55-83). tty_release() takes tty->lock itself, so
// the caller holds ONLY ttys_lock — the same discipline as tty_close (fs/tty.c:196-208).
// The session's pointer is cleared first, so no caller can use the tty after this.
// Returns -EBUSY (and changes nothing) when a borrowed pointer is still in use, so the caller can
// report "not yet" instead of freeing a tty under a running operation.
static int codipad_session_release_tty(codipad_session_t id) {
    struct tty *tty = NULL;
    pthread_mutex_lock(&g_sessions_lock);
    struct codipad_session *s = codipad_session_find(id);
    if (s != NULL) {
        if (s->users != 0) {
            pthread_mutex_unlock(&g_sessions_lock);
            return -EBUSY;
        }
        tty = s->tty;
        s->tty = NULL;
    }
    pthread_mutex_unlock(&g_sessions_lock);
    if (tty == NULL)
        return 0;
    codipad_tty_forget(tty);
    lock(&ttys_lock);
    tty_release(tty);
    unlock(&ttys_lock);
    return 0;
}

// Called by the kernel with ttys_lock held, when the refcount reaches zero (i.e. after the authority
// and every fd have released). Drops the map entry only; the session's pointer was cleared first by
// codipad_session_release_tty, so nothing reads a freed tty.
static void codipad_tty_cleanup(struct tty *tty) {
    codipad_tty_forget(tty);
}

// Called under tty->lock. Claim the one-shot callback and its session use together.
static void codipad_tty_input_ready(struct tty *tty) {
    codipad_session_t id = codipad_tty_lookup(tty);
    codipad_input_ready_cb callback = NULL;
    void *context = NULL;
    pthread_mutex_lock(&g_sessions_lock);
    struct codipad_session *session = codipad_session_find(id);
    if (session && session->tty == tty && session->on_input_ready) {
        callback = session->on_input_ready;
        context = session->ctx;
        session->on_input_ready = NULL;
        session->users++;
        session->callback_users++;
    }
    pthread_mutex_unlock(&g_sessions_lock);
    if (callback) {
        callback(id, context);
        codipad_callback_leave(id);
    }
}

static const struct tty_driver_ops codipad_tty_ops = {
    .write = codipad_tty_write,
    .input_ready = codipad_tty_input_ready,
    .cleanup = codipad_tty_cleanup,
};

// No ttys array: pty_open_fake() overwrites those fields on every open (fs/tty.h:167).
static struct tty_driver codipad_pty_driver = {.ops = &codipad_tty_ops};

// Console for init's stdio; its output has no consumer.
static int codipad_console_write(struct tty *tty, const void *buf, size_t len, bool blocking) {
    (void) tty; (void) buf; (void) len; (void) blocking;
    return (int) len;
}
static const struct tty_driver_ops codipad_console_ops = {.write = codipad_console_write};
DEFINE_TTY_DRIVER(codipad_console_driver, &codipad_console_ops, TTY_CONSOLE_MAJOR, 64);

// ---------------------------------------------------------------------------
// kernel-side observation and reaping

// One decode for the whole module. The kernel reports the raw wait status: sys_exit/sys_exit_group
// pass status<<8 (kernel/exit.c:535-543) and the signal-delivery paths pass the bare signal
// (kernel/signal.c:417,434,464). Low 7 bits are therefore the signal, and 0 means a normal exit.
// 0x7f marks a stopped/traced task, not a termination, so it is treated as "no signal".
static void codipad_decode_wait_status(int raw, int *out_code, int *out_signal) {
    int sig = raw & 0x7f;
    if (sig != 0 && sig != 0x7f) {
        *out_signal = sig;
        *out_code = 128 + sig;
    } else {
        *out_signal = 0;
        *out_code = (raw >> 8) & 0xff;
    }
}

// exit_hook contract (kernel/exit.c:222): called with pids_lock held, from the exiting thread.
// Append only; every user-visible effect happens on the dispatcher below.
static void codipad_exit_hook(struct task *task, int code) {
    if (task != NULL && task->group != NULL) {
        // The group (and its fs_context) can be freed as soon as this returns, so both values are
        // captured here; nothing is read from the task later.
        uint64_t context = task->group->fs_context;
        // iSH reports group death on its final exiting thread, which need not be the leader.
        // Match wait4's status selection rather than publishing that worker's individual status.
        struct task *leader = task->group->leader;
        if (leader != NULL && context != 0) {
            dword_t pid = leader->pid;
            int wait_status = task->group->doing_group_exit
                ? task->group->group_exit_code : leader->exit_code;
            for (size_t i = 0; i < CODIPAD_MAX_SESSIONS; i++) {
                struct codipad_root_status *status = &g_root_status[i];
                if (atomic_load_explicit(&status->id, memory_order_acquire) == context &&
                    atomic_load_explicit(&status->pid, memory_order_acquire) == (int)pid) {
                    atomic_store_explicit(&status->raw, wait_status, memory_order_relaxed);
                    atomic_store_explicit(&status->ready, true, memory_order_release);
                    break;
                }
            }
            pthread_mutex_lock(&g_exit_lock);
            unsigned next = (g_exit_tail + 1) % CODIPAD_EXIT_QUEUE;
            if (next != g_exit_head) { // queue is only a wakeup; status above is durable
                g_exit_queue[g_exit_tail].context = context;
                g_exit_queue[g_exit_tail].pid = pid;
                g_exit_queue[g_exit_tail].code = wait_status;
                g_exit_tail = next;
                pthread_cond_signal(&g_exit_cond);
            }
            pthread_mutex_unlock(&g_exit_lock);
        }
    }
    if (g_prev_exit_hook != NULL)
        g_prev_exit_hook(task, code);
}

// Actually free a zombie. wait4 only reaps children of `current`'s task group, and session tasks are
// children of pid 1, so this borrows init as `current` on our own thread (current is __thread) for
// the duration of the call. No kernel patch; the borrowing is this module's documented hack.
// Requires: the caller is not a guest thread and holds no kernel lock.
static int codipad_reap_pid(dword_t pid) {
    struct task *saved = current;

    lock(&pids_lock);
    struct task *init = pid_get_task(1);
    unlock(&pids_lock);
    if (init == NULL)
        return -ESRCH;

    current = init;
    dword_t reaped = sys_wait4((pid_t_) pid, 0, CODIPAD_WNOHANG, 0);
    current = saved;

    if ((dword_t) reaped == pid)
        return 0;
    if ((int_t) reaped < 0)
        return (int) reaped; // _ECHILD when it is not our child (or already reaped)
    return -EAGAIN;          // still running
}

// Sends sig to the session's group and to every descendant that left the group, found by walking
// parentage under pids_lock. Sets *out_all_signalled false when a descendant could not be reached.
// `context` is the session id carried in struct task_group::fs_context — NOT a pid. Every caller
// must pass the session, or the scan matches nothing (which the group signal used to mask).
static int codipad_signal_tree(uint64_t context, dword_t pgid, int sig, bool *out_all_signalled) {
    *out_all_signalled = true;
    if (pgid != 0) {
        int err = send_group_signal(pgid, sig, SIGINFO_NIL);
        if (err < 0 && err != _ESRCH)
            *out_all_signalled = false;
    }

    // Ownership is the group's opaque fs_context, set to the session id at launch and inherited
    // verbatim across fork (kernel/task.h:244). It survives reparenting, so a child cannot be lost
    // when its parent exits, and setsid() does not change it.
    bool reached_all = true;
    lock(&pids_lock);
    for (dword_t pid = 1; pid < MAX_PID; pid++) {
        struct task *task = pid_get_task(pid);
        if (task == NULL || task->group == NULL || task->group->fs_context != context)
            continue;
        struct task *leader = task->group->leader;
        if (leader == NULL || leader->zombie)
            continue; // a zombie needs no signal; it is reaped, not killed
        if (task->group->pgid == pgid)
            continue; // covered by the group signal above
        send_signal(leader, sig, SIGINFO_NIL);
        if (!leader->zombie)
            reached_all = false; // queued, not necessarily acted on yet
    }
    unlock(&pids_lock);
    *out_all_signalled = *out_all_signalled && reached_all;
    return 0;
}

// Reaps every task whose group carries this session's context, zombies included, until the scan is
// empty. A root exit reparents its children to init; the context is what keeps them ours.
// Returns the number of members still unreaped (0 = fully settled).
static unsigned codipad_reap_context(uint64_t context) {
    unsigned remaining = 0;
    dword_t targets[CODIPAD_REAP_BATCH];
    unsigned count = 0;

    lock(&pids_lock);
    for (dword_t pid = 1; pid < MAX_PID; pid++) {
        struct task *task = pid_get_task_zombie(pid);
        if (task == NULL || task->group == NULL || task->group->fs_context != context)
            continue;
        if (task->zombie) {
            if (count < CODIPAD_REAP_BATCH)
                targets[count++] = pid;
            else
                // pid_get_task() hides zombies, so every uncollected zombie must keep settlement
                // pending. A later pass starts from the beginning after this batch is reaped.
                remaining++;
        }
        else if (task->pid != 0)
            remaining++;
    }
    unlock(&pids_lock);

    for (unsigned i = 0; i < count; i++) {
        int err = codipad_reap_pid(targets[i]);
        // _ECHILD: the zombie was already reaped (by the dispatcher or an earlier sweep). It is
        // gone, which is what this function is asking, so it must not count as remaining.
        if (err != 0 && err != -ECHILD)
            remaining++;
    }
    // Anything still alive keeps the session incomplete; the caller signals, then retries.
    return remaining;
}

// Members still alive (not zombies) for a context.
static unsigned codipad_context_live(uint64_t context) {
    unsigned live = 0;
    lock(&pids_lock);
    for (dword_t pid = 1; pid < MAX_PID; pid++) {
        struct task *task = pid_get_task(pid);
        if (task == NULL || task->group == NULL || task->group->fs_context != context)
            continue;
        if (!task->zombie)
            live++;
    }
    unlock(&pids_lock);
    return live;
}

// ---------------------------------------------------------------------------
// dispatcher: reaps reported exits, then calls the user callback with no lock held.

static bool codipad_writers_closed(codipad_session_t id) {
    struct tty *tty = codipad_tty_acquire(id, false);
    if (tty == NULL)
        return true; // no tty attached: nothing can be writing
    lock(&tty->fds_lock);
    bool closed = tty->hung_up || list_empty(&tty->fds);
    unlock(&tty->fds_lock);
    codipad_tty_end_use(id);
    return closed;
}

// The exit event is queued by exit_hook and derived by the dispatcher. close() must not report a
// settled session without that status, nor reaping the leader first (which would make the dispatcher
// skip the record). Bounded wait; false means "still unknown", never a fabricated code.
static bool codipad_wait_for_status(codipad_session_t id, unsigned budget_ms) {
    unsigned waited = 0;
    for (;;) {
        bool have = false;
        pthread_mutex_lock(&g_sessions_lock);
        struct codipad_session *s = codipad_session_find(id);
        have = s != NULL && s->has_status;
        pthread_mutex_unlock(&g_sessions_lock);
        if (have)
            return true;
        if (waited >= budget_ms)
            return false;
        usleep(10 * 1000);
        waited += 10;
    }
}

// Poll until every task in this context is reaped and the pty has no writers. Returns true when
// that state was observed; false means it was not, after the budget, and the caller must say so.
static bool codipad_settle(codipad_session_t id, uint64_t context, unsigned budget_ms) {
    unsigned waited = 0;
    for (;;) {
        unsigned live = codipad_context_live(context);
        unsigned unreaped = codipad_reap_context(context);
        bool writers = codipad_writers_closed(id);
        if (live == 0 && unreaped == 0 && writers)
            return true;
        if (waited >= budget_ms)
            return false;
        usleep(10 * 1000);
        waited += 10;
    }
}

// Reap and re-measure a session that has reported exit but was not yet settled when its callback
// ran (the leader exits before its stdio/children are gone). No second callback: the record is the
// only thing updated, so info()/close() see the truth.
static void codipad_notify_settled(codipad_session_t id) {
    codipad_exit_cb cb = NULL;
    void *ctx = NULL;
    int code = 0, sig = 0;
    pthread_mutex_lock(&g_sessions_lock);
    struct codipad_session *s = codipad_session_find(id);
    if (s != NULL && s->has_status && s->all_descendants_reaped &&
        !s->settlement_reported && s->on_settled != NULL) {
        s->settlement_reported = true;
        s->users++;
        s->callback_users++;
        cb = s->on_settled;
        ctx = s->ctx;
        code = s->code;
        sig = s->terminating_signal;
    }
    pthread_mutex_unlock(&g_sessions_lock);
    if (cb != NULL) {
        cb(id, code, sig, true, ctx);
        codipad_callback_leave(id);
    }
}

static void codipad_dispatch_exit_event(const struct codipad_exit_event *event) {
    codipad_session_t id = CODIPAD_SESSION_NONE;
    bool is_leader_exit = false;
    int derived_code = 0, derived_signal = 0;
    pthread_mutex_lock(&g_sessions_lock);
    for (int i = 0; i < CODIPAD_MAX_SESSIONS; i++) {
        struct codipad_session *s = &g_sessions[i];
        if (s->id != 0 && s->id == event->context) {
            id = s->id;
            // Every fork creates a group leader, so a child's exit arrives here too. Only the
            // root's status defines the session's status and only the root's exit may reach the
            // callback; a child's exit just means "recheck whether this session is settled".
            is_leader_exit = s->pid == event->pid && !s->exit_reported;
            if (is_leader_exit) {
                int code = 0, sig = 0;
                codipad_decode_wait_status(event->code, &code, &sig);
                s->running = false;
                s->exit_reported = true;
                s->has_status = true;
                s->raw_wait_status = event->code;
                s->code = code;
                s->terminating_signal = sig;
                derived_code = code;
                derived_signal = sig;
            }
            break;
        }
    }
    pthread_mutex_unlock(&g_sessions_lock);

    if (id == CODIPAD_SESSION_NONE)
        return; // a task this authority does not own (e.g. a failed launch winding down)


    // _ECHILD here means the leader was already reaped (by the root-status recovery path).
    int leader_err = codipad_reap_pid(event->pid);
    bool leader_reap_ok = leader_err == 0 || leader_err == -ECHILD;

    // Leader exit is not completion: stdio teardown and children finish after the leader.
    bool settled = codipad_settle(id, event->context, is_leader_exit ? 1000 : 0);

    pthread_mutex_lock(&g_sessions_lock);
    struct codipad_session *s = codipad_session_find(id);
    if (s != NULL) {
        if (is_leader_exit)
            s->reaped = s->reaped || leader_reap_ok;
        s->all_descendants_reaped = settled && s->reaped;
    }
    pthread_mutex_unlock(&g_sessions_lock);

    if (is_leader_exit) {
        codipad_exit_cb cb = NULL;
        void *ctx = NULL;
        if (codipad_callback_enter(id, NULL, &cb, &ctx, NULL) && cb != NULL)
            cb(id, derived_code, derived_signal, settled, ctx);
        codipad_callback_leave(id);
    }
    codipad_notify_settled(id);
}

static void codipad_recover_root_statuses(void) {
    // The bounded table is authoritative for root status. The event queue only wakes this thread;
    // a full queue cannot erase an exit status before the session record has consumed it.
    for (size_t i = 0; i < CODIPAD_MAX_SESSIONS; i++) {
        struct codipad_root_status *status = &g_root_status[i];
        uint64_t id = atomic_load_explicit(&status->id, memory_order_acquire);
        if (id == 0 || !atomic_load_explicit(&status->ready, memory_order_acquire))
            continue;
        dword_t pid = (dword_t) atomic_load_explicit(&status->pid, memory_order_acquire);
        int raw = atomic_load_explicit(&status->raw, memory_order_relaxed);
        bool pending = false;
        pthread_mutex_lock(&g_sessions_lock);
        struct codipad_session *s = codipad_session_find(id);
        pending = s != NULL && s->pid == pid && !s->exit_reported;
        pthread_mutex_unlock(&g_sessions_lock);
        if (pending) {
            struct codipad_exit_event event = {.context = id, .pid = pid, .code = raw};
            codipad_dispatch_exit_event(&event);
        }
    }
}

static void codipad_reconcile_exited(void) {
    codipad_recover_root_statuses();
    for (int i = 0; i < CODIPAD_MAX_SESSIONS; i++) {
        codipad_session_t id = CODIPAD_SESSION_NONE;
        bool pending = false;
        pthread_mutex_lock(&g_sessions_lock);
        struct codipad_session *s = &g_sessions[i];
        if (s->id != 0 && s->exit_reported && !s->all_descendants_reaped) {
            id = s->id;
            pending = true;
        }
        pthread_mutex_unlock(&g_sessions_lock);
        if (!pending)
            continue;

        unsigned live = codipad_context_live(id);
        unsigned unreaped = codipad_reap_context(id);
        bool writers = codipad_writers_closed(id);
        bool settled = live == 0 && unreaped == 0 && writers;

        pthread_mutex_lock(&g_sessions_lock);
        s = codipad_session_find(id);
        if (s != NULL) {
            if (settled)
                s->reaped = true;
            s->all_descendants_reaped = settled;
        }
        pthread_mutex_unlock(&g_sessions_lock);
        codipad_notify_settled(id);
    }
}

static void *codipad_dispatch_main(void *unused) {
    (void) unused;
    for (;;) {
        struct codipad_exit_event event;
        pthread_mutex_lock(&g_exit_lock);
        while (g_exit_head == g_exit_tail) {
            // Bounded wait so exited-but-not-settled sessions are reconciled even with no new exit.
            struct timespec deadline;
            clock_gettime(CLOCK_REALTIME, &deadline);
            deadline.tv_nsec += 20 * 1000 * 1000;
            if (deadline.tv_nsec >= 1000000000) {
                deadline.tv_sec++;
                deadline.tv_nsec -= 1000000000;
            }
            int rc = pthread_cond_timedwait(&g_exit_cond, &g_exit_lock, &deadline);
            if (rc == ETIMEDOUT) {
                pthread_mutex_unlock(&g_exit_lock);
                codipad_reconcile_exited();
                pthread_mutex_lock(&g_exit_lock);
            }
        }
        event = g_exit_queue[g_exit_head];
        g_exit_head = (g_exit_head + 1) % CODIPAD_EXIT_QUEUE;
        pthread_cond_broadcast(&g_exit_cond);
        pthread_mutex_unlock(&g_exit_lock);
        codipad_dispatch_exit_event(&event);
        // Do not wait for an empty queue: a sustained stream of child exits must not starve a
        // durable root status whose wakeup was dropped under queue pressure.
        codipad_recover_root_statuses();
    }
    return NULL;
}

static void codipad_threads_init(void) {
    pthread_t dispatcher;
    if (pthread_create(&dispatcher, NULL, codipad_dispatch_main, NULL) == 0)
        g_threads_ok = true;
}

// ---------------------------------------------------------------------------
// boot

// Defined with the classifier below; boot/mount/getcwd need them earlier.
static struct task *codipad_borrow_guest_current(void);
static void codipad_restore_guest_current(struct task *saved);

static void codipad_create_dev_nodes(void) {
    static const struct { const char *path; int major, minor; } devs[] = {
        {"/dev/null", MEM_MAJOR, DEV_NULL_MINOR},
        {"/dev/zero", MEM_MAJOR, DEV_ZERO_MINOR},
        {"/dev/full", MEM_MAJOR, DEV_FULL_MINOR},
        {"/dev/random", MEM_MAJOR, DEV_RANDOM_MINOR},
        {"/dev/urandom", MEM_MAJOR, DEV_URANDOM_MINOR},
        {"/dev/tty", TTY_ALTERNATE_MAJOR, DEV_TTY_MINOR},
        {"/dev/console", TTY_ALTERNATE_MAJOR, DEV_CONSOLE_MINOR},
        {"/dev/ptmx", TTY_ALTERNATE_MAJOR, DEV_PTMX_MINOR},
    };
    for (size_t i = 0; i < sizeof(devs) / sizeof(devs[0]); i++)
        generic_mknodat(AT_PWD, devs[i].path, S_IFCHR | 0666,
                        dev_make(devs[i].major, devs[i].minor));
    for (int i = 1; i <= 7; i++) {
        char tty[16];
        snprintf(tty, sizeof(tty), "/dev/tty%d", i);
        generic_mknodat(AT_PWD, tty, S_IFCHR | 0666, dev_make(TTY_CONSOLE_MAJOR, i));
    }
    generic_mkdirat(AT_PWD, "/dev/pts", 0755);
    generic_setattrat(AT_PWD, "/", (struct attr) {.type = attr_mode, .mode = 0755}, false);
}

// Realfs opens the host directory as root_fd and passes host st_ino values through to the guest.
// Keep using it for native absolute mounts: fakefs_bind_mount inserts a symlink and synthesizes
// guest inodes, which splits identity across the same bytes.
static int codipad_make_guest_mountpoint(const char *path) {
    size_t length = strlen(path);
    if (length == 0 || length >= PATH_MAX || path[0] != '/')
        return -EINVAL;

    char prefix[PATH_MAX];
    memcpy(prefix, path, length + 1);
    struct task *saved = codipad_borrow_guest_current();
    int result = 0;
    for (size_t i = 1; i <= length; i++) {
        if (prefix[i] != '/' && prefix[i] != '\0')
            continue;
        char trailing = prefix[i];
        prefix[i] = '\0';
        if (prefix[0] != '\0') {
            int err = generic_mkdirat(AT_PWD, prefix, 0755);
            if (err < 0 && err != -EEXIST) {
                result = err;
                break;
            }
        }
        prefix[i] = trailing;
    }
    codipad_restore_guest_current(saved);
    return result;
}

static bool codipad_paths_overlap(const char *left, const char *right) {
    size_t left_len = strlen(left), right_len = strlen(right);
    return strcmp(left, right) == 0 ||
        (left_len < right_len && strncmp(left, right, left_len) == 0 && right[left_len] == '/') ||
        (right_len < left_len && strncmp(left, right, right_len) == 0 && left[right_len] == '/');
}

// Caller holds mounts_lock. This reads the kernel's mount records directly; no second root
// registry is maintained by CodiPadProcess.
static int codipad_same_directory(int left, int right) {
    struct stat a, b;
    if (fstat(left, &a) < 0 || fstat(right, &b) < 0)
        return -errno;
    if (!S_ISDIR(a.st_mode) || !S_ISDIR(b.st_mode))
        return -ENOTDIR;
    return a.st_dev == b.st_dev && a.st_ino == b.st_ino ? 1 : -EBUSY;
}

// Canonical names are namespace labels supplied by the validated adapter, not host authority.
static int codipad_validate_mount_directory(const char *path, int borrowed_fd) {
    if (path == NULL || path[0] != '/' || path[1] == '\0' || strlen(path) >= PATH_MAX)
        return -EINVAL;
    const char *part = path + 1;
    while (*part) {
        size_t length = strcspn(part, "/");
        if (length == 0 || (length == 1 && part[0] == '.') ||
            (length == 2 && part[0] == '.' && part[1] == '.'))
            return -EINVAL;
        part += length;
        if (*part && *++part == '\0')
            return -EINVAL;
    }
    struct stat metadata;
    if (fstat(borrowed_fd, &metadata) < 0)
        return -errno;
    return S_ISDIR(metadata.st_mode) ? 0 : -ENOTDIR;
}

static int codipad_authorized_mount_status_locked(const char *canonical_path, int borrowed_fd) {
    struct mount *mount;
    size_t count = 0;
    list_for_each_entry(&mounts, mount, mounts) {
        if (mount->fs != &realfs || mount->point == NULL || mount->source == NULL ||
            strcmp(mount->point, mount->source) != 0)
            continue;
        count++;
        if (strcmp(mount->point, canonical_path) == 0)
            return codipad_same_directory(mount->root_fd, borrowed_fd);
        size_t length = strlen(mount->point);
        if (strncmp(mount->point, canonical_path, length) == 0 && canonical_path[length] == '/') {
            // A covering mount must actually reach the supplied object through held directories.
            char suffix[PATH_MAX];
            strcpy(suffix, canonical_path + length + 1);
            int directory = fcntl(mount->root_fd, F_DUPFD_CLOEXEC, 0);
            if (directory < 0) return -errno;
            char *state, *part = strtok_r(suffix, "/", &state);
            while (part != NULL) {
                int next = openat(directory, part, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC);
                int error = errno;
                close(directory);
                if (next < 0) return -error;
                directory = next;
                part = strtok_r(NULL, "/", &state);
            }
            int status = codipad_same_directory(directory, borrowed_fd);
            close(directory);
            return status;
        }
        if (codipad_paths_overlap(mount->point, canonical_path))
            return -EBUSY;
    }
    return count >= CODIPAD_MAX_AUTHORIZED_ROOTS ? -ENOSPC : 0;
}

int codipad_kernel_authorized_root_status(const char *canonical_native_dir, int borrowed_fd) {
    int validation = codipad_validate_mount_directory(canonical_native_dir, borrowed_fd);
    if (validation < 0) return validation;
    lock(&mounts_lock);
    int status = codipad_authorized_mount_status_locked(canonical_native_dir, borrowed_fd);
    if (status == 0) {
        // An alias can outlive its canonical registry entry; that is not absence proof.
        struct mount *mount;
        list_for_each_entry(&mounts, mount, mounts) {
            if (mount->fs == &realfs && strcmp(mount->point, "/workspace") == 0 &&
                strcmp(mount->source, canonical_native_dir) == 0) {
                status = codipad_same_directory(mount->root_fd, borrowed_fd);
                break;
            }
        }
    }
    unlock(&mounts_lock);
    return status;
}

bool codipad_kernel_native_path_is_mounted(const char *canonical_native_path) {
    if (!g_booted || canonical_native_path == NULL || canonical_native_path[0] != '/')
        return false;

    bool found = false;
    lock(&mounts_lock);
    struct mount *mount;
    list_for_each_entry(&mounts, mount, mounts) {
        if (mount->fs != &realfs || mount->point == NULL || mount->source == NULL ||
            strcmp(mount->point, mount->source) != 0)
            continue;
        size_t root_len = strlen(mount->point);
        if (strncmp(canonical_native_path, mount->point, root_len) == 0 &&
            (canonical_native_path[root_len] == '/' || canonical_native_path[root_len] == '\0')) {
            found = true;
            break;
        }
    }
    unlock(&mounts_lock);
    return found;
}

int codipad_kernel_mount_authorized_root(const char *canonical_native_dir, int borrowed_fd) {
    g_workspace_mount_stage = "authorized-root-validate";
    if (!g_booted)
        return -EBUSY;
    int validation = codipad_validate_mount_directory(canonical_native_dir, borrowed_fd);
    if (validation < 0) return validation;
    const char *canonical = canonical_native_dir;

    g_workspace_mount_stage = "authorized-root-conflict-check";
    lock(&mounts_lock);
    int status = codipad_authorized_mount_status_locked(canonical, borrowed_fd);
    unlock(&mounts_lock);
    if (status < 0) return status;
    if (status == 1) return 0;

    g_workspace_mount_stage = "authorized-root-mountpoint";
    int err = codipad_make_guest_mountpoint(canonical);
    if (err < 0)
        return err;

    // Recheck under the same lock used by path queries so concurrent mount requests cannot publish
    // duplicate or overlapping roots, and a Node worker never observes a partial mount record.
    struct task *saved = codipad_borrow_guest_current();
    g_workspace_mount_stage = "authorized-root-publish-check";
    lock(&mounts_lock);
    status = codipad_authorized_mount_status_locked(canonical, borrowed_fd);
    if (status == 1) {
        unlock(&mounts_lock);
        codipad_restore_guest_current(saved);
        return 0;
    }
    if (status < 0) {
        unlock(&mounts_lock);
        codipad_restore_guest_current(saved);
        return status;
    }
    g_workspace_mount_stage = "authorized-root-realfs-mount";
    err = do_mount_realfs_fd(canonical, canonical, borrowed_fd);
    unlock(&mounts_lock);
    codipad_restore_guest_current(saved);
    return err;
}

// Discover host DNS resolvers via Darwin res_ninit/res_getservers.
// Write through the guest filesystem so a guest symlink never resolves in the host namespace.
int codipad_kernel_refresh_dns(void) {
    if (!g_booted) return -EBUSY;
    struct __res_state resolver = {0};
    if (res_ninit(&resolver) != 0) return -EIO;
    union res_sockaddr_union servers[MAXNS];
    int count = res_getservers(&resolver, servers, MAXNS);
    char config[MAXNS * (INET6_ADDRSTRLEN + 16) + 1];
    size_t length = 0;
    for (int i = 0; i < count && i < MAXNS; i++) {
        int family = servers[i].sin.sin_family;
        const void *address = family == AF_INET ? (const void *) &servers[i].sin.sin_addr :
            family == AF_INET6 ? (const void *) &servers[i].sin6.sin6_addr : NULL;
        char text[INET6_ADDRSTRLEN];
        if (address == NULL || inet_ntop(family, address, text, sizeof(text)) == NULL) continue;
        int written = snprintf(config + length, sizeof(config) - length, "nameserver %s\n", text);
        if (written < 0 || (size_t) written >= sizeof(config) - length) {
            res_ndestroy(&resolver);
            return -ENOSPC;
        }
        length += (size_t) written;
    }
    res_ndestroy(&resolver);
    if (length == 0) return -ENOENT;

    struct task *saved = codipad_borrow_guest_current();
    struct fd *fd = generic_open("/etc/resolv.conf", O_WRONLY_ | O_CREAT_ | O_TRUNC_, 0644);
    if (IS_ERR(fd)) {
        int err = PTR_ERR(fd);
        codipad_restore_guest_current(saved);
        return err;
    }
    if (fd->ops == NULL || fd->ops->write == NULL) {
        fd_close(fd);
        codipad_restore_guest_current(saved);
        return -EOPNOTSUPP;
    }
    int result = 0;
    for (size_t offset = 0; offset < length;) {
        ssize_t written = fd->ops->write(fd, config + offset, length - offset);
        if (written <= 0) {
            result = written < 0 ? (int) written : -EIO;
            break;
        }
        offset += (size_t) written;
    }
    fd_close(fd);
    codipad_restore_guest_current(saved);
    return result;
}

// The native absolute path is the workspace identity. /workspace remains a compatibility alias
// for existing shell fixtures and experiments; both mounts point at the same real directory.
int codipad_kernel_mount_workspace(const char *native_workspace_dir, int borrowed_fd, bool read_only) {
    g_workspace_mount_stage = "workspace-validate";
    if (!g_booted) return -EBUSY;
    if (read_only) return -EOPNOTSUPP;
    int err = codipad_validate_mount_directory(native_workspace_dir, borrowed_fd);
    if (err < 0) return err;
    const char *canonical = native_workspace_dir;
    if (g_mounted_workspace_path != NULL && strcmp(g_mounted_workspace_path, canonical) != 0)
        return -EBUSY;

    char *workspace_path = strdup(canonical);
    if (workspace_path == NULL) return -ENOMEM;
    g_workspace_mount_stage = "workspace-authorized-root";
    err = codipad_kernel_mount_authorized_root(canonical, borrowed_fd);
    if (err < 0) { free(workspace_path); return err; }

    // Canonical publication can succeed before alias failure. Keep that mount and report the error.
    g_workspace_mount_stage = "workspace-alias-mountpoint";
    err = codipad_make_guest_mountpoint("/workspace");
    if (err < 0) { free(workspace_path); return err; }
    struct task *saved = codipad_borrow_guest_current();
    g_workspace_mount_stage = "workspace-alias-realfs-mount";
    lock(&mounts_lock);
    struct mount *mount;
    bool found = false;
    list_for_each_entry(&mounts, mount, mounts) {
        if (strcmp(mount->point, "/workspace") != 0) continue;
        found = true;
        err = mount->fs == &realfs ? codipad_same_directory(mount->root_fd, borrowed_fd) : -EBUSY;
        if (err == 1) err = 0;
        break;
    }
    if (!found)
        err = do_mount_realfs_fd(canonical, "/workspace", borrowed_fd);
    unlock(&mounts_lock);
    codipad_restore_guest_current(saved);
    if (err < 0) { free(workspace_path); return err; }
    free(g_mounted_workspace_path);
    g_mounted_workspace_path = workspace_path;
    g_mounted_workspace_read_only = false;
    g_workspace_mount_stage = "complete";
    return 0;
}

const char *codipad_kernel_boot_phase(void) {
    return g_boot_phase;
}

// Called only by normal boot before init's thread starts, while boot exclusively owns init/fs.
// generic_statat/path_normalize need fs; procfs self links need pid; fakefs's path hook reads the
// scalar group fs_context. Copy credentials as well, without borrowing any teardown-owned object.
static int codipad_prepare_path_lookup_context(struct task *init) {
    if (init == NULL || init->fs == NULL || init->group == NULL || g_path_lookup_task.fs != NULL)
        return -EBUSY;
    struct fs_info *fs = fs_info_new();
    if (fs == NULL)
        return -ENOMEM;
    fs->umask = init->fs->umask;
    fs->root = fd_retain(init->fs->root);
    fs->pwd = fd_retain(init->fs->pwd);
    g_path_lookup_group.fs_context = init->group->fs_context;
    g_path_lookup_task.pid = init->pid;
    g_path_lookup_task.tgid = init->tgid;
    g_path_lookup_task.uid = init->uid;
    g_path_lookup_task.gid = init->gid;
    g_path_lookup_task.euid = init->euid;
    g_path_lookup_task.egid = init->egid;
    g_path_lookup_task.suid = init->suid;
    g_path_lookup_task.sgid = init->sgid;
    g_path_lookup_task.ngroups = init->ngroups;
    memcpy(g_path_lookup_task.groups, init->groups, sizeof(init->groups));
    g_path_lookup_task.group = &g_path_lookup_group;
    g_path_lookup_task.fs = fs;
    return 0;
}

#if TARGET_OS_IPHONE && !TARGET_OS_SIMULATOR
// The guest socket namespace uses app-owned host sockets; this buffer outlives the kernel.
static char codipad_socket_prefix[sizeof(((struct sockaddr_un *)0)->sun_path)];
static int codipad_prepare_socket_prefix(void) {
    const char *temporary = getenv("TMPDIR");
    if (!temporary || temporary[0] != '/') return -EINVAL;
    struct stat info;
    if (stat(temporary, &info) != 0) return -errno;
    if (!S_ISDIR(info.st_mode)) return -ENOTDIR;
    if (access(temporary, W_OK | X_OK) != 0) return -errno;
    // iOS commonly reports /private/var/...; /var is shorter but only use it
    // when both names identify the exact same directory.
    if (strncmp(temporary, "/private/var/", 13) == 0) {
        struct stat shorter;
        const char *candidate = temporary + 8;
        if (stat(candidate, &shorter) == 0 && shorter.st_dev == info.st_dev &&
            shorter.st_ino == info.st_ino && access(candidate, W_OK | X_OK) == 0)
            temporary = candidate;
    }
    size_t length = strlen(temporary);
    int n = snprintf(codipad_socket_prefix, sizeof(codipad_socket_prefix), "%s%ss",
                     temporary, temporary[length - 1] == '/' ? "" : "/");
    // A host pid and uint32 socket id each need at most ten decimal digits.
    if (n < 0 || (size_t)n + 21 >= sizeof(codipad_socket_prefix)) return -ENAMETOOLONG;
    sock_tmp_prefix = codipad_socket_prefix;
    return 0;
}
#endif

int codipad_kernel_boot(const char *fakefs_root, const char *native_workspace_dir, int borrowed_workspace_fd) {
    g_boot_phase = "validate";
    if (fakefs_root == NULL || fakefs_root[0] != '/')
        return -EINVAL;
    if (native_workspace_dir != NULL) {
        int validation = codipad_validate_mount_directory(native_workspace_dir, borrowed_workspace_fd);
        if (validation < 0) return validation;
    }
    if (g_booted) {
        g_boot_phase = "workspace-mount";
        return native_workspace_dir != NULL
                   ? codipad_kernel_mount_workspace(native_workspace_dir, borrowed_workspace_fd, false)
                   : 0;
    }

    if (g_initialization_state != CODIPAD_KERNEL_PRISTINE)
        return -EBUSY;
    ish_jit_freeze_mode();
#if TARGET_OS_IPHONE && !TARGET_OS_SIMULATOR
    g_boot_phase = "socket-backing";
    int socket_error = codipad_prepare_socket_prefix();
    if (socket_error < 0) return socket_error;
#endif
    // mount_root and later steps can publish before an error; only preflight remains pristine.
    g_initialization_state = CODIPAD_KERNEL_INCOMPLETE;
    g_boot_phase = "root-mount";
    int err = mount_root(&fakefs, fakefs_root);
    if (err < 0)
        return err;
    g_boot_phase = "init-create";
    err = become_first_process();
    if (err < 0)
        return err;
    codipad_create_dev_nodes();

    g_boot_phase = "proc-mount";
    err = do_mount(&procfs, "proc", "/proc", "", 0);
    if (err < 0)
        return err;
    g_boot_phase = "pty-mount";
    err = do_mount(&devptsfs, "devpts", "/dev/pts", "", 0);
    if (err < 0)
        return err;

    generic_mkdirat(AT_PWD, "/workspace", 0755);

    tty_drivers[TTY_CONSOLE_MAJOR] = &codipad_console_driver;
    set_console_device(TTY_CONSOLE_MAJOR, 1);
    g_boot_phase = "console-stdio";
    err = create_stdio("/dev/console", TTY_CONSOLE_MAJOR, 1);
    if (err < 0)
        return err;

    // pid 1 keeps init's seat so sessions can be constructed from it. Console output is discarded;
    // sessions get their own ptys.
    // do_execve() demands the argv buffer end with a NUL *after* the last argument's own NUL
    // (kernel/exec.c:536 args_size asserts args_end[0] == '\0'), so this literal is deliberately
    // double-terminated.
    char argv[] = "/bin/sh\0";
    const char *envp = "TERM=xterm-256color\0HOME=/root\0PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin\0LANG=C.UTF-8\0";
    g_boot_phase = "init-exec";
    err = do_execve("/bin/sh", 1, argv, envp);
    if (err < 0)
        return err;
    g_boot_phase = "lookup-context";
    err = codipad_prepare_path_lookup_context(current);
    if (err < 0)
        return err;
    g_boot_phase = "init-start";
    err = task_start(current);
    if (err < 0) {
        fs_info_release(g_path_lookup_task.fs);
        g_path_lookup_task.fs = NULL;
        return err;
    }

    pthread_mutex_lock(&g_exit_lock);
    g_prev_exit_hook = exit_hook;
    pthread_mutex_unlock(&g_exit_lock);
    exit_hook = codipad_exit_hook;

    g_boot_phase = "observers-start";
    pthread_once(&g_threads_once, codipad_threads_init);
    if (!g_threads_ok)
        return -EBUSY;

    g_booted = true;
    g_initialization_state = CODIPAD_KERNEL_INITIALIZED;

    if (native_workspace_dir != NULL) {
        g_boot_phase = "workspace-mount";
        return codipad_kernel_mount_workspace(native_workspace_dir, borrowed_workspace_fd, false);
    }
    g_boot_phase = "ready";
    return 0;
}

// ---------------------------------------------------------------------------
// preflight

static bool codipad_is_macho(const unsigned char *magic) {
    static const uint32_t magics[] = {
        0xfeedfaceu, 0xfeedfacfu, 0xcefaedfeu, 0xcffaedfeu, 0xcafebabeu, 0xbebafecau,
    };
    uint32_t value;
    memcpy(&value, magic, sizeof(value));
    for (size_t i = 0; i < sizeof(magics) / sizeof(magics[0]); i++)
        if (value == magics[i])
            return true;
    return false;
}

// Implemented by the task loader. This read-only parse is shared with authority spawn
// classification, so unsupported Mach-O is rejected before a session/PTY is created.
extern int ish_macho_preflight_fd(struct fd *fd);

// Host-side guest-filesystem calls (generic_open/generic_mkdirat/generic_getpath and the fakefs
// layers under them) dereference `current`, which is __thread and NULL on an arbitrary Swift
// dispatch-queue thread — the second terminal's create ran on a second queue and crashed in
// path_normalize. Every such call borrows init for the duration and restores whatever was there.
// Returns the previous value so the caller can restore it; NULL when the kernel is not up yet.
static struct task *codipad_borrow_guest_current(void) {
    struct task *saved = current;
    struct task *init = NULL;
    lock(&pids_lock);
    init = pid_get_task(1);
    unlock(&pids_lock);
    current = init != NULL ? init : saved;
    return saved;
}

static void codipad_restore_guest_current(struct task *saved) {
    current = saved;
}

static codipad_backend_t codipad_classify_locked(const char *guest_path, int depth);

static codipad_backend_t codipad_classify(const char *guest_path, int depth) {
    if (guest_path == NULL || depth > 3)
        return CODIPAD_BACKEND_UNKNOWN;
    struct task *saved = codipad_borrow_guest_current();
    codipad_backend_t result = codipad_classify_locked(guest_path, depth);
    codipad_restore_guest_current(saved);
    return result;
}

static codipad_backend_t codipad_classify_locked(const char *guest_path, int depth) {
    struct fd *fd = generic_open(guest_path, O_RDONLY_ | O_NONBLOCK_, 0);
    if (IS_ERR(fd))
        return CODIPAD_BACKEND_UNKNOWN;
    unsigned char head[64];
    ssize_t got = fd->ops->read(fd, head, sizeof(head));
    if (got < 4) {
        fd_close(fd);
        return CODIPAD_BACKEND_UNKNOWN;
    }

    if (codipad_is_macho(head)) {
        int valid = ish_macho_preflight_fd(fd);
        fd_close(fd);
        return valid == 0 ? CODIPAD_BACKEND_GUEST_MACHO : CODIPAD_BACKEND_UNKNOWN;
    }
    fd_close(fd);
    if (head[0] == 0x7f && head[1] == 'E' && head[2] == 'L' && head[3] == 'F')
        return CODIPAD_BACKEND_GUEST_ELF;
    if (head[0] == '#' && head[1] == '!') {
        char line[128] = {0};
        size_t limit = got < (ssize_t) sizeof(head) ? (size_t) got : sizeof(head);
        memcpy(line, head + 2, limit - 2);
        char *interp = line;
        while (*interp == ' ' || *interp == '\t')
            interp++;
        char *end = interp;
        while (*end != '\0' && *end != ' ' && *end != '\t' && *end != '\n')
            end++;
        *end = '\0';
        if (*interp != '/')
            return CODIPAD_BACKEND_UNKNOWN;
        codipad_backend_t inner = codipad_classify(interp, depth + 1);
        // Only a resolvable guest interpreter counts. An UNKNOWN (missing interpreter, unsupported
        // format, unreadable) is rejected before any side effect rather than run as a guest script.
        if (inner == CODIPAD_BACKEND_UNKNOWN)
            return CODIPAD_BACKEND_UNKNOWN;
        return inner == CODIPAD_BACKEND_NATIVE ? CODIPAD_BACKEND_NATIVE : CODIPAD_BACKEND_GUEST_SCRIPT;
    }
    return CODIPAD_BACKEND_UNKNOWN;
}

static int codipad_join_guest_path(const char *directory, const char *name,
                                 char *result, size_t capacity) {
    if (directory == NULL || directory[0] != '/' || name == NULL || result == NULL || capacity == 0)
        return -EINVAL;
    int length;
    if (strcmp(directory, "/") == 0)
        length = snprintf(result, capacity, "/%s", name);
    else
        length = snprintf(result, capacity, "%s/%s", directory, name);
    return length < 0 || (size_t) length >= capacity ? -ENAMETOOLONG : 0;
}

// Resolve terminal/task command names in the guest namespace. This intentionally returns the
// first executable PATH candidate without classifying its format: codipad_kernel_spawn performs
// the single authoritative format preflight before allocating a session or PTY.
static int codipad_resolve_executable(const char *command, const char *cwd,
                                    const char *const *envp, char *resolved, size_t capacity) {
    if (command == NULL || command[0] == '\0' || resolved == NULL || capacity == 0)
        return -EINVAL;

    char working_directory[PATH_MAX];
    if (cwd != NULL) {
        size_t length = strnlen(cwd, sizeof(working_directory));
        if (length == 0 || length >= sizeof(working_directory) || cwd[0] != '/')
            return -EINVAL;
        memcpy(working_directory, cwd, length + 1);
    } else {
        if (current == NULL || current->fs == NULL ||
            generic_getpath(current->fs->pwd, working_directory) < 0 || working_directory[0] != '/')
            return -ENOENT;
    }

    if (strchr(command, '/') != NULL) {
        if (command[0] == '/') {
            size_t length = strnlen(command, capacity);
            if (length >= capacity)
                return -ENAMETOOLONG;
            memcpy(resolved, command, length + 1);
            return 0;
        }
        return codipad_join_guest_path(working_directory, command, resolved, capacity);
    }

    const char *path = "/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin";
    if (envp != NULL) {
        for (size_t i = 0; envp[i] != NULL; i++) {
            if (strncmp(envp[i], "PATH=", 5) == 0) {
                path = envp[i] + 5;
                break;
            }
        }
    }
    char *entries = strdup(path);
    if (entries == NULL)
        return -ENOMEM;
    int result = -ENOENT;
    bool access_error = false;
    char *cursor = entries;
    char *entry;
    while ((entry = strsep(&cursor, ":")) != NULL) {
        char directory[PATH_MAX];
        if (entry[0] == '\0') {
            memcpy(directory, working_directory, strlen(working_directory) + 1);
        } else if (entry[0] == '/') {
            size_t length = strnlen(entry, sizeof(directory));
            if (length >= sizeof(directory)) {
                result = -ENAMETOOLONG;
                continue;
            }
            memcpy(directory, entry, length + 1);
        } else {
            result = codipad_join_guest_path(working_directory, entry, directory, sizeof(directory));
            if (result < 0)
                continue;
        }

        char candidate[PATH_MAX];
        result = codipad_join_guest_path(directory, command, candidate, sizeof(candidate));
        if (result < 0)
            continue;

        struct statbuf metadata = {0};
        int stat_error = generic_statat(AT_PWD, candidate, &metadata, true);
        if (stat_error < 0) {
            if (stat_error == -EACCES) {
                access_error = true;
                result = -EACCES;
                continue;
            }
            if (stat_error == -ENOENT || stat_error == -ENOTDIR) {
                result = -ENOENT;
                continue;
            }
            result = stat_error;
            break;
        }
        if (!S_ISREG(metadata.mode)) {
            result = -ENOENT;
            continue;
        }
        if ((metadata.mode & 0111) == 0) {
            access_error = true;
            result = -EACCES;
            continue;
        }

        // Keep the open nonblocking too, so a concurrent replacement with a FIFO cannot hang
        // process creation between the read-only stat and this descriptor open.
        struct fd *probe = generic_open(candidate, O_RDONLY_ | O_NONBLOCK_, 0);
        if (!IS_ERR(probe)) {
            bool executable = S_ISREG(probe->open_stat.mode) &&
                              (probe->open_stat.mode & 0111) != 0;
            fd_close(probe);
            if (!executable) {
                access_error = true;
                result = -EACCES;
                continue;
            }
            size_t length = strlen(candidate);
            if (length >= capacity) {
                result = -ENAMETOOLONG;
                break;
            }
            memcpy(resolved, candidate, length + 1);
            result = 0;
            break;
        }
        int open_error = (int) PTR_ERR(probe);
        if (open_error != -ENOENT && open_error != -ENOTDIR) {
            if (open_error == -EACCES) {
                access_error = true;
                result = -EACCES;
                continue;
            }
            result = open_error;
            break;
        }
        result = -ENOENT;
    }
    free(entries);
    if (result == -ENOENT && access_error)
        return -EACCES;
    return result;
}

int codipad_kernel_path_is_file(const char *absolute_guest_path, bool *is_file) {
    if (is_file == NULL)
        return -EINVAL;
    *is_file = false;
    if (absolute_guest_path == NULL || absolute_guest_path[0] != '/')
        return -EINVAL;
    if (strnlen(absolute_guest_path, MAX_PATH) >= MAX_PATH)
        return -ENAMETOOLONG;
    if (!g_booted || g_path_lookup_task.fs == NULL)
        return -EBUSY;

    // Check availability under the PID lock, but never retain or dereference init afterwards.
    // In-flight lookups keep their independent fs/root/pwd valid even if finish_exit releases init's.
    lock(&pids_lock);
    struct task *init = pid_get_task(1);
    bool live = init != NULL && !atomic_load_explicit(&init->exit_started, memory_order_acquire);
    unlock(&pids_lock);
    if (!live)
        return -EBUSY;
    struct task *saved = current;
    current = &g_path_lookup_task;
    struct statbuf metadata = {0};
    int err = generic_statat(AT_PWD, absolute_guest_path, &metadata, true);
    codipad_restore_guest_current(saved);
    if (err < 0)
        return err == -ENOENT || err == -ENOTDIR ? 0 : err;
    *is_file = S_ISREG(metadata.mode);
    return 0;
}

int codipad_kernel_read_shells(char *buffer, size_t capacity, size_t *length) {
    if (buffer == NULL || length == NULL || capacity == 0) return -EINVAL;
    *length = 0;
    bool ignored = false;
    int err = codipad_kernel_path_is_file("/etc/shells", &ignored);
    if (err < 0 || !ignored) return err;
    struct task *saved = current;
    current = &g_path_lookup_task;
    struct fd *fd = generic_open("/etc/shells", O_RDONLY_ | O_NONBLOCK_, 0);
    if (IS_ERR(fd)) {
        err = (int) PTR_ERR(fd);
    } else if (!S_ISREG(fd->open_stat.mode)) {
        fd_close(fd);
        err = -EINVAL;
    } else {
        while (*length < capacity) {
            ssize_t count = fd->ops->read(fd, buffer + *length, capacity - *length);
            if (count < 0) { err = (int) count; break; }
            if (count == 0) break;
            *length += (size_t) count;
        }
        if (err == 0 && *length == capacity) {
            char extra;
            ssize_t count = fd->ops->read(fd, &extra, 1);
            if (count < 0) err = (int) count;
            else if (count != 0) err = -EFBIG;
        }
        fd_close(fd);
    }
    codipad_restore_guest_current(saved);
    return err;
}

int codipad_kernel_preflight_executable(const char *command, const char *cwd,
                                      const char *const *envp, char *resolved,
                                      size_t capacity, codipad_backend_t *backend) {
    if (resolved == NULL || capacity == 0 || backend == NULL)
        return -EINVAL;
    if (!g_booted)
        return -EBUSY;

    struct task *saved = codipad_borrow_guest_current();
    int err = codipad_resolve_executable(command, cwd, envp, resolved, capacity);
    if (err < 0) {
        codipad_restore_guest_current(saved);
        return err;
    }

    struct statbuf metadata = {0};
    err = generic_statat(AT_PWD, resolved, &metadata, true);
    if (err < 0) {
        codipad_restore_guest_current(saved);
        return err;
    }
    if (!S_ISREG(metadata.mode) || (metadata.mode & 0111) == 0) {
        codipad_restore_guest_current(saved);
        return -EACCES;
    }

    // Avoid blocking on a concurrent replacement by a FIFO between metadata and classification.
    struct fd *probe = generic_open(resolved, O_RDONLY_ | O_NONBLOCK_, 0);
    if (IS_ERR(probe)) {
        err = (int) PTR_ERR(probe);
        codipad_restore_guest_current(saved);
        return err;
    }
    bool executable = S_ISREG(probe->open_stat.mode) && (probe->open_stat.mode & 0111) != 0;
    fd_close(probe);
    if (!executable) {
        codipad_restore_guest_current(saved);
        return -EACCES;
    }

    *backend = codipad_classify_locked(resolved, 0);
    codipad_restore_guest_current(saved);
    return *backend == CODIPAD_BACKEND_UNKNOWN ? -ENOEXEC : 0;
}

codipad_backend_t codipad_kernel_backend_for(const char *guest_path) {
    return codipad_classify(guest_path, 0);
}

// ---------------------------------------------------------------------------
// spawn: one launcher thread per request. A fresh thread keeps `current` (thread-local) from being
// inherited across launches, and lets a failed launch exit through the kernel's own exit path.

struct codipad_launch {
    struct codipad_spawn_opts opts;
    char *argv_buf;
    char *envp_buf;
    size_t argc;
    codipad_session_t session;
    int result;
    size_t host_fd_count;
    int host_fds[CODIPAD_SPAWN_MAX_STDIO_FDS];
    unsigned char host_modes[CODIPAD_SPAWN_MAX_STDIO_FDS];
    unsigned char host_status_flags[CODIPAD_SPAWN_MAX_STDIO_FDS];
};

extern const struct fd_ops socket_fdops;

// The kernel task owns signal wakeup and host readiness for every caller.
static int codipad_host_wait(struct fd *fd, bool writing) {
    int ready = task_wait_host_fd(fd->real_fd, writing ? POLLOUT : POLLIN,
            (fd->flags & O_NONBLOCK_) ? 0 : -1);
    return ready > 0 ? 0 : ready == 0 ? _EAGAIN : ready;
}

static ssize_t codipad_host_io(struct fd *fd, void *buf, size_t size, bool writing) {
    if (size == 0) return 0;
    for (;;) {
        int readiness = codipad_host_wait(fd, writing);
        if (readiness) return readiness;
        ssize_t n;
        if (S_ISSOCK(fd->stat.mode)) {
            int flags = MSG_DONTWAIT;
#ifdef MSG_NOSIGNAL
            if (writing) flags |= MSG_NOSIGNAL;
#endif
            n = writing ? send(fd->real_fd, buf, size, flags)
                        : recv(fd->real_fd, buf, size, flags);
        } else {
            size_t chunk = size;
#ifdef PIPE_BUF
            if (writing && chunk > PIPE_BUF) chunk = PIPE_BUF;
#endif
            n = writing ? write(fd->real_fd, buf, chunk) : read(fd->real_fd, buf, size);
        }
        if (n >= 0) return n;
        if (errno == EPIPE) {
            // Deliver pipe failure to the guest, never to the app that hosts it.
            send_signal(current, SIGPIPE_, SIGINFO_NIL);
            return _EPIPE;
        }
        if (errno != EAGAIN && errno != EWOULDBLOCK && errno != EINTR) return errno_map();
        if (fd->flags & O_NONBLOCK_) return _EAGAIN;
    }
}
static ssize_t codipad_host_read(struct fd *fd, void *buf, size_t size) {
    return codipad_host_io(fd, buf, size, false);
}
static ssize_t codipad_host_write(struct fd *fd, const void *buf, size_t size) {
    return codipad_host_io(fd, (void *) buf, size, true);
}
static int codipad_host_setflags(struct fd *fd, dword_t flags) {
    // The guest flag controls whether readiness waits; borrowed host flags stay untouched.
    fd->flags = (fd->flags & ~O_NONBLOCK_) | (flags & O_NONBLOCK_);
    return 0;
}
static int codipad_host_getflags(struct fd *fd) { return fd->flags; }
static const struct fd_ops codipad_host_ops = {
    .read = codipad_host_read, .write = codipad_host_write,
    .poll = realfs_poll, .close = realfs_close,
    .getflags = codipad_host_getflags, .setflags = codipad_host_setflags,
};

static struct fd *codipad_reserved_host_fd(void) {
    int host_fd = open("/dev/null", O_RDWR);
    if (host_fd < 0) return NULL;
    struct fd *fd = adhoc_fd_create(&codipad_host_ops);
    if (fd == NULL) {
        close(host_fd);
        return NULL;
    }
    fd->real_fd = host_fd;
    fd->stat.mode = S_IFCHR | 0600;
    fd->flags = O_RDWR_;
    return fd;
}

static int codipad_install_host_stdio(struct codipad_launch *job) {
    bool reserved[CODIPAD_SPAWN_MAX_STDIO_FDS] = {0};
    for (size_t i = 0; i < job->host_fd_count; i++) {
        int host_fd = job->host_fds[i];
        bool null_device = false;
        if (host_fd < 0) {
            if (i >= 3) {
                bool later_descriptor = false;
                for (size_t j = i + 1; j < job->host_fd_count; j++)
                    if (job->host_fds[j] >= 0) { later_descriptor = true; break; }
                if (later_descriptor) {
                    struct fd *placeholder = codipad_reserved_host_fd();
                    if (placeholder == NULL) return -ENOMEM;
                    int installed = f_install(placeholder, 0);
                    if (installed < 0) return installed;
                    if (installed != (int)i) return -EIO;
                    reserved[i] = true;
                }
                continue;
            }
            host_fd = open("/dev/null", i == 0 ? O_RDONLY : O_WRONLY);
            if (host_fd < 0) return -errno;
            job->host_fds[i] = host_fd;
            null_device = true;
        }
        int host_flags = fcntl(host_fd, F_GETFL);
        if (host_flags < 0) return -EIO;
        struct stat host_stat = {0};
        if (fstat(host_fd, &host_stat) < 0) {
            close(host_fd);
            job->host_fds[i] = -1;
            return -EIO;
        }
        bool host_socket = !null_device && S_ISSOCK(host_stat.st_mode);
        struct fd *fd = adhoc_fd_create(host_socket ? &socket_fdops : &codipad_host_ops);
        if (fd == NULL) return -ENOMEM;
        fd->real_fd = host_fd;
        fd->stat.mode = null_device ? S_IFCHR | 0666
                      : (host_stat.st_mode & (S_IFMT | 0777));
        fd->stat.uid = null_device ? current->uid : host_stat.st_uid;
        fd->stat.gid = null_device ? current->gid : host_stat.st_gid;
        unsigned char mode = job->host_modes[i];
        fd->flags = mode == CODIPAD_HOST_FD_READ ? O_RDONLY_
                  : mode == CODIPAD_HOST_FD_WRITE ? O_WRONLY_ : O_RDWR_;
        unsigned char status = job->opts.stdio_host_status_flags != NULL
            ? job->opts.stdio_host_status_flags[i]
            : (host_flags & O_NONBLOCK) != 0 ? CODIPAD_HOST_STATUS_NONBLOCK : 0;
        if ((status & CODIPAD_HOST_STATUS_NONBLOCK) != 0) fd->flags |= O_NONBLOCK_;
        if (host_socket) {
            fd->socket.domain = AF_LOCAL_;
            fd->socket.type = SOCK_STREAM_;
            fd->socket.protocol = 0;
            fd->socket.unix_peer = NULL;
            // The pinned iSH patch recognizes this authority-owned socket kind and virtualizes
            // status flags plus bounded nonblocking I/O without changing the borrowed host OFD.
            fd->socket.netlink_peer_fd = -1;
            fd->socket.adopted_host = true;
            cond_init(&fd->socket.unix_got_peer);
            list_init(&fd->socket.unix_scm);
        }
        // Transfer even on f_install failure: that function closes its owned description.
        job->host_fds[i] = -1;
        f_close((int)i);
        int installed = f_install(fd, 0);
        if (installed < 0) return installed;
        if (installed != (int)i) return -EIO;
    }
    for (size_t i = 0; i < job->host_fd_count; i++)
        if (reserved[i]) f_close((int)i);
    return 0;
}

static void *codipad_launch_main(void *cookie) {
    struct codipad_launch *job = cookie;

    int err = become_new_init_child();
    if (err < 0) {
        job->result = err;
        return NULL;
    }

    struct tty *tty = NULL;
    if (job->opts.stdio_mode == CODIPAD_STDIO_HOST_FDS) {
        err = codipad_install_host_stdio(job);
    } else {
        tty = pty_open_fake(&codipad_pty_driver);
        if (IS_ERR(tty)) {
            job->result = (int) PTR_ERR(tty);
            do_exit_group(127);
        }
        // Own the returned reference immediately, including every launch failure path.
        pthread_mutex_lock(&g_sessions_lock);
        struct codipad_session *s = codipad_session_find(job->session);
        if (s != NULL) s->tty = tty;
        pthread_mutex_unlock(&g_sessions_lock);
        char slave[32];
        snprintf(slave, sizeof(slave), "/dev/pts/%d", tty->num);
        err = create_stdio(slave, TTY_PSEUDO_SLAVE_MAJOR, tty->num);
        unsigned cols = job->opts.cols ? job->opts.cols : 80;
        unsigned rows = job->opts.rows ? job->opts.rows : 24;
        tty_set_winsize(tty, (struct winsize_) {.row = rows, .col = cols});
    }
    if (err < 0) {
        job->result = err;
        do_exit_group(127);
    }

    if (job->opts.cwd != NULL) {
        struct fd *pwd = generic_open(job->opts.cwd, O_RDONLY_, 0);
        if (IS_ERR(pwd)) {
            job->result = -ENOENT;
            do_exit_group(127);
        }
        fs_chdir(current->fs, pwd);
    }

    // Register before the task starts: the child may write to the pty immediately.
    // Ownership token: the kernel never interprets fs_context (kernel/task.h:244); the host gives
    // it a meaning. Setting it before exec means every fork inherits the session id verbatim.
    if (current->group != NULL)
        current->group->fs_context = job->session;

    pthread_mutex_lock(&g_sessions_lock);
    struct codipad_session *s = codipad_session_find(job->session);
    if (s != NULL) {
        s->tty = tty;
        s->pid = current->pid;
        s->pgid = current->group->pgid;
        for (size_t i = 0; i < CODIPAD_MAX_SESSIONS; i++)
            if (atomic_load_explicit(&g_root_status[i].id, memory_order_acquire) == job->session)
                atomic_store_explicit(&g_root_status[i].pid, (int)current->pid, memory_order_release);
    }
    pthread_mutex_unlock(&g_sessions_lock);
    if (tty != NULL) codipad_tty_register(tty, job->session);

    // The executable path lives in the copied opts; there is no second copy to get out of step with
    // the one the preflight classified.
    err = do_execve(job->opts.exe, job->argc, job->argv_buf, job->envp_buf);
    if (err < 0) {
        job->result = err;
        do_exit_group(127);
    }
    err = task_start(current);
    job->result = err < 0 ? err : 0;
    return NULL;
}

static int codipad_validate_host_fd(int fd, unsigned char mode, unsigned char status) {
    if (fd < 0)
        return -EBADF;
    if (mode > CODIPAD_HOST_FD_READ_WRITE ||
        (status & ~CODIPAD_HOST_STATUS_NONBLOCK) != 0)
        return -EINVAL;
    struct stat metadata = {0};
    if (fstat(fd, &metadata) < 0)
        return -errno;
    int host_flags = fcntl(fd, F_GETFL);
    if (host_flags < 0)
        return -errno;
    int access = host_flags & O_ACCMODE;
    if ((mode != CODIPAD_HOST_FD_WRITE && access == O_WRONLY) ||
        (mode != CODIPAD_HOST_FD_READ && access == O_RDONLY))
        return -EACCES;

    if (S_ISSOCK(metadata.st_mode)) {
        int type = 0;
        socklen_t type_size = sizeof(type);
        struct sockaddr_storage address = {0};
        socklen_t address_size = sizeof(address);
        struct sockaddr_storage peer = {0};
        socklen_t peer_size = sizeof(peer);
        if (getsockopt(fd, SOL_SOCKET, SO_TYPE, &type, &type_size) < 0 ||
            getsockname(fd, (struct sockaddr *)&address, &address_size) < 0 ||
            getpeername(fd, (struct sockaddr *)&peer, &peer_size) < 0 ||
            type != SOCK_STREAM || address.ss_family != AF_UNIX ||
            peer.ss_family != AF_UNIX)
            return -ENOTSUP;
        return 0;
    }
    if (S_ISFIFO(metadata.st_mode)) {
        if ((host_flags & O_NONBLOCK) == 0)
            return -ENOTSUP;
        if (mode != CODIPAD_HOST_FD_READ) {
#ifdef F_GETNOSIGPIPE
            int no_sigpipe = fcntl(fd, F_GETNOSIGPIPE);
            if (no_sigpipe != 1)
                return -ENOTSUP;
#else
            return -ENOTSUP;
#endif
        }
        return 0;
    }
    if (S_ISCHR(metadata.st_mode)) {
        struct stat null_device = {0};
        if (stat("/dev/null", &null_device) < 0 ||
            metadata.st_rdev != null_device.st_rdev)
            return -ENOTSUP;
        return 0;
    }
    return S_ISREG(metadata.st_mode) ? 0 : -ENOTSUP;
}

static int codipad_validate_opts(const struct codipad_spawn_opts *opts) {
    if (opts == NULL || opts->exe == NULL || opts->exe[0] == '\0')
        return -EINVAL;
    if (opts->argv == NULL || opts->argv[0] == NULL)
        return -EINVAL;
    if (opts->cwd != NULL && opts->cwd[0] != '/')
        return -EINVAL;
    if (opts->envp != NULL)
        for (size_t i = 0; opts->envp[i] != NULL; i++)
            if (strchr(opts->envp[i], '=') == NULL)
                return -EINVAL;
    if (opts->cols > 10000 || opts->rows > 10000)
        return -EINVAL;
    if (opts->stdio_mode != CODIPAD_STDIO_PTY && opts->stdio_mode != CODIPAD_STDIO_HOST_FDS)
        return -EINVAL;
    if (opts->stdio_mode == CODIPAD_STDIO_HOST_FDS && opts->stdio_host_fds == NULL &&
        (opts->stdin_fd < 0 || opts->stdout_fd < 0 || opts->stderr_fd < 0))
        return -EBADF;
    size_t host_fd_count = opts->stdio_host_fds != NULL
        ? opts->stdio_host_fd_count : 3;
    if (opts->stdio_host_fds != NULL) {
        if (opts->stdio_mode != CODIPAD_STDIO_HOST_FDS ||
            opts->stdio_host_fd_count < 3 ||
            opts->stdio_host_fd_count > CODIPAD_SPAWN_MAX_STDIO_FDS)
            return -EINVAL;
    } else if (opts->stdio_host_fd_count != 0) {
        return -EINVAL;
    }
    if (opts->stdio_host_modes != NULL) {
        if (opts->stdio_mode != CODIPAD_STDIO_HOST_FDS)
            return -EINVAL;
        for (size_t i = 0; i < host_fd_count; i++)
            if (opts->stdio_host_modes[i] > CODIPAD_HOST_FD_READ_WRITE)
                return -EINVAL;
    }
    if (opts->stdio_host_status_flags != NULL) {
        if (opts->stdio_mode != CODIPAD_STDIO_HOST_FDS)
            return -EINVAL;
        for (size_t i = 0; i < host_fd_count; i++)
            if ((opts->stdio_host_status_flags[i] & ~CODIPAD_HOST_STATUS_NONBLOCK) != 0)
                return -EINVAL;
    }
    if (opts->stdio_mode == CODIPAD_STDIO_HOST_FDS) {
        for (size_t i = 0; i < host_fd_count; i++) {
            int fd = opts->stdio_host_fds != NULL ? opts->stdio_host_fds[i]
                : i == 0 ? opts->stdin_fd : i == 1 ? opts->stdout_fd : opts->stderr_fd;
            if (fd < -1)
                return -EBADF;
            if (fd < 0)
                continue;
            int host_flags = fcntl(fd, F_GETFL);
            if (host_flags < 0)
                return -errno;
            unsigned char mode = opts->stdio_host_modes != NULL
                ? opts->stdio_host_modes[i]
                : i == 0 ? CODIPAD_HOST_FD_READ
                : i < 3 ? CODIPAD_HOST_FD_WRITE : CODIPAD_HOST_FD_READ_WRITE;
            unsigned char status = opts->stdio_host_status_flags != NULL
                ? opts->stdio_host_status_flags[i]
                : (host_flags & O_NONBLOCK) != 0 ? CODIPAD_HOST_STATUS_NONBLOCK : 0;
            int fd_error = codipad_validate_host_fd(fd, mode, status);
            if (fd_error < 0)
                return fd_error;
        }
    }
    return 0;
}

int codipad_kernel_spawn(const struct codipad_spawn_opts *opts, codipad_session_t *out_session) {
    if (out_session == NULL)
        return -EINVAL;
    *out_session = CODIPAD_SESSION_NONE;
    int err = codipad_validate_opts(opts);
    if (err < 0)
        return err;
    if (opts->parent_session != CODIPAD_SESSION_NONE) {
        pthread_mutex_lock(&g_sessions_lock);
        struct codipad_session *parent = codipad_session_find(opts->parent_session);
        if (parent == NULL)
            err = -ENOENT;
        else if (opts->owner == 0 || parent->owner != opts->owner)
            err = -EPERM;
        else if (parent->close_requested)
            err = -ESHUTDOWN;
        else
            err = 0;
        pthread_mutex_unlock(&g_sessions_lock);
        if (err < 0)
            return err;
    }
    if (!g_booted)
        return -EBUSY;

    char resolved_executable[PATH_MAX];
    codipad_backend_t backend = CODIPAD_BACKEND_UNKNOWN;
    err = codipad_kernel_preflight_executable(opts->exe, opts->cwd, opts->envp,
                                            resolved_executable, sizeof(resolved_executable),
                                            &backend);
    if (err < 0)
        return err;
    struct codipad_spawn_opts resolved_opts = *opts;
    resolved_opts.exe = resolved_executable;
    const struct codipad_spawn_opts *spawn_opts = &resolved_opts;
    // No quiet fallback and no host tool lane: a native or unknown image is rejected here, before
    // any side effect. The kernel's built-in offload is therefore unreachable through this API.
    if (backend == CODIPAD_BACKEND_NATIVE || backend == CODIPAD_BACKEND_UNKNOWN)
        return -ENOEXEC;

    struct codipad_launch *job = calloc(1, sizeof(*job));
    if (job == NULL)
        return -ENOMEM;
    for (size_t i = 0; i < CODIPAD_SPAWN_MAX_STDIO_FDS; i++) job->host_fds[i] = -1;
    if (spawn_opts->stdio_mode == CODIPAD_STDIO_HOST_FDS) {
        job->host_fd_count = spawn_opts->stdio_host_fds != NULL
            ? spawn_opts->stdio_host_fd_count : 3;
        for (size_t i = 0; i < job->host_fd_count; i++) {
            job->host_modes[i] = spawn_opts->stdio_host_modes != NULL
                ? spawn_opts->stdio_host_modes[i]
                : i == 0 ? CODIPAD_HOST_FD_READ
                : i < 3 ? CODIPAD_HOST_FD_WRITE : CODIPAD_HOST_FD_READ_WRITE;
            int original = spawn_opts->stdio_host_fds != NULL
                ? spawn_opts->stdio_host_fds[i]
                : i == 0 ? spawn_opts->stdin_fd : i == 1 ? spawn_opts->stdout_fd
                                                         : spawn_opts->stderr_fd;
            if (original < 0) continue;
            job->host_fds[i] = dup(original);
            if (job->host_fds[i] < 0) {
                int saved_errno = errno;
                for (size_t j = 0; j < i; j++)
                    if (job->host_fds[j] >= 0) close(job->host_fds[j]);
                free(job);
                return -saved_errno;
            }
            int inherited_status = fcntl(job->host_fds[i], F_GETFL);
            if (inherited_status < 0) {
                int saved_errno = errno;
                for (size_t j = 0; j <= i; j++)
                    if (job->host_fds[j] >= 0) close(job->host_fds[j]);
                free(job);
                return -saved_errno;
            }
            job->host_status_flags[i] = spawn_opts->stdio_host_status_flags != NULL
                ? spawn_opts->stdio_host_status_flags[i]
                : (inherited_status & O_NONBLOCK) != 0 ? CODIPAD_HOST_STATUS_NONBLOCK : 0;
            fcntl(job->host_fds[i], F_SETFD, FD_CLOEXEC);
        }
    }
    job->opts = *spawn_opts;
    if (spawn_opts->stdio_mode == CODIPAD_STDIO_HOST_FDS) {
        job->opts.stdin_fd = job->host_fds[0];
        job->opts.stdout_fd = job->host_fds[1];
        job->opts.stderr_fd = job->host_fds[2];
        job->opts.stdio_host_fds = job->host_fds;
        job->opts.stdio_host_fd_count = job->host_fd_count;
        job->opts.stdio_host_modes = job->host_modes;
        job->opts.stdio_host_status_flags = job->host_status_flags;
    }
    job->result = -EAGAIN;
    job->argv_buf = codipad_flatten(spawn_opts->argv);
    job->envp_buf = codipad_flatten(spawn_opts->envp);
    if (job->argv_buf == NULL || job->envp_buf == NULL) {
        free(job->argv_buf);
        free(job->envp_buf);
        for (size_t i = 0; i < job->host_fd_count; i++)
            if (job->host_fds[i] >= 0) close(job->host_fds[i]);
        free(job);
        return -ENOMEM;
    }
    while (spawn_opts->argv[job->argc] != NULL)
        job->argc++;

    struct codipad_session record;
    memset(&record, 0, sizeof(record));
    record.running = true;
    record.backend = backend;
    record.on_output = spawn_opts->on_output;
    record.on_exit = spawn_opts->on_exit;
    record.on_settled = spawn_opts->on_settled;
    record.owner = spawn_opts->owner;
    record.ctx = spawn_opts->ctx;
    codipad_session_t id = CODIPAD_SESSION_NONE;
    int session_err = codipad_session_new(&record, spawn_opts->parent_session, &id);
    if (session_err < 0) {
        free(job->argv_buf);
        free(job->envp_buf);
        for (size_t i = 0; i < job->host_fd_count; i++)
            if (job->host_fds[i] >= 0) close(job->host_fds[i]);
        free(job);
        return session_err;
    }
    job->session = id;

    pthread_t thread;
    if (pthread_create(&thread, NULL, codipad_launch_main, job) != 0) {
        codipad_session_drop(id);
        free(job->argv_buf);
        free(job->envp_buf);
        for (size_t i = 0; i < job->host_fd_count; i++)
            if (job->host_fds[i] >= 0) close(job->host_fds[i]);
        free(job);
        return -EAGAIN;
    }
    pthread_join(thread, NULL); // the launch handshake: task started, or a real error returned

    int result = job->result;
    free(job->argv_buf);
    free(job->envp_buf);
    for (size_t i = 0; i < job->host_fd_count; i++)
        if (job->host_fds[i] >= 0) close(job->host_fds[i]);
    free(job);

    if (result < 0) {
        // A failed launch may already have opened a pty before the exec error. The record is about to
        // be dropped, so its reference must be returned or the pty leaks for the process lifetime.
        codipad_session_release_tty(id);
        (void) codipad_session_drop_idle(id);
        return result;
    }
    *out_session = id;
    return 0;
}

int codipad_kernel_spawn_child(codipad_session_t parent, const struct codipad_spawn_opts *opts,
                             codipad_session_t *out_session) {
    if (parent == CODIPAD_SESSION_NONE || opts == NULL)
        return -EINVAL;
    if (opts->parent_session != CODIPAD_SESSION_NONE && opts->parent_session != parent)
        return -EINVAL;
    struct codipad_spawn_opts child_opts = *opts;
    child_opts.parent_session = parent;
    return codipad_kernel_spawn(&child_opts, out_session);
}

// ---------------------------------------------------------------------------
// session operations

int codipad_kernel_input(codipad_session_t session, const void *bytes, size_t len) {
    if (bytes == NULL && len > 0)
        return -EINVAL;
    struct tty *tty = codipad_tty_acquire(session, true);
    if (tty == NULL)
        return -ENOENT;
    ssize_t written = tty_input(tty, bytes, len, false);
    codipad_tty_end_use(session);
    return written < 0 ? (int) written : (int) written;
}

int codipad_kernel_set_input_ready_callback(codipad_session_t id, codipad_input_ready_cb callback) {
    struct tty *tty = codipad_tty_acquire(id, callback != NULL);
    if (!tty) return -ENOENT;
    lock(&tty->lock);
    pthread_mutex_lock(&g_sessions_lock);
    struct codipad_session *session = codipad_session_find(id);
    // The borrowed tty use keeps this record alive until the check and callback finish.
    session->on_input_ready = callback;
    pthread_mutex_unlock(&g_sessions_lock);
    if (callback && tty_can_accept_input(tty)) codipad_tty_input_ready(tty);
    unlock(&tty->lock);
    codipad_tty_end_use(id);
    return 0;
}

int codipad_kernel_output_ack(codipad_session_t id, size_t bytes) {
    if (bytes == 0)
        return -EINVAL;
    struct codipad_session *session = codipad_session_acquire(id);
    if (session == NULL)
        return -ENOENT;
    struct codipad_output_flow *flow = session->output_flow;
    int result = 0;
    if (flow == NULL) {
        result = -EIO;
    } else {
        lock(&flow->lock);
        if (flow->pending_events == 0 || bytes > flow->pending_bytes) {
            result = -EINVAL;
        } else {
            flow->pending_bytes -= bytes;
            flow->pending_events--;
            notify(&flow->available);
        }
        unlock(&flow->lock);
    }
    codipad_tty_end_use(id);
    return result;
}

int codipad_kernel_resize(codipad_session_t session, unsigned cols, unsigned rows) {
    if (cols == 0 || rows == 0 || cols > 10000 || rows > 10000)
        return -EINVAL;
    struct tty *tty = codipad_tty_acquire(session, false);
    if (tty == NULL)
        return -ENOENT;
    tty_set_winsize(tty, (struct winsize_) {.row = rows, .col = cols});
    codipad_tty_end_use(session);
    return 0;
}

int codipad_kernel_signal(codipad_session_t session, int sig) {
    if (sig <= 0 || sig >= 65)
        return -EINVAL;
    dword_t pid = 0, pgid = 0;
    bool running = false, found = false;
    pthread_mutex_lock(&g_sessions_lock);
    struct codipad_session *s = codipad_session_find(session);
    if (s != NULL) {
        found = true;
        pid = s->pid;
        pgid = s->pgid;
        running = s->running;
    }
    pthread_mutex_unlock(&g_sessions_lock);
    if (!found)
        return -ENOENT;
    if (pid == 0)
        return -ESRCH;
    // `running` is the leader's state only. A leader that exited leaves members behind (a background
    // setsid() child is the case that matters), so the scan runs regardless.
    (void) running;

    bool all_signalled = false;
    int err = codipad_signal_tree(session, pgid, sig, &all_signalled);
    if (err < 0)
        return err;
    // A descendant that could not be reached is reported, never hidden: the caller must treat the
    // session as "signal delivered, coverage incomplete".
    return all_signalled ? 0 : -CODIPAD_EINCOMPLETE;
}

int codipad_kernel_getcwd(codipad_session_t session, char *buffer, size_t capacity) {
    if (buffer == NULL || capacity < 2)
        return -EINVAL;

    dword_t root_pid = 0;
    pthread_mutex_lock(&g_sessions_lock);
    struct codipad_session *s = codipad_session_find(session);
    if (s != NULL)
        root_pid = s->pid;
    pthread_mutex_unlock(&g_sessions_lock);

    // Walk the session's context. The live task's fs_info is copied (refcount) before the kernel
    // lock is dropped, so the fs (and its pwd fd) cannot be freed while we resolve the path.
    struct fs_info *fs = NULL;
    lock(&pids_lock);
    struct task *fallback = NULL;
    for (dword_t pid = 1; pid < MAX_PID; pid++) {
        struct task *task = pid_get_task(pid);
        if (task == NULL || task->group == NULL || task->group->fs_context != session)
            continue;
        if (task->fs == NULL)
            continue;
        if (task->pid == root_pid) {
            fs = fs_info_copy(task->fs);
            break;
        }
        if (fallback == NULL)
            fallback = task;
    }
    if (fs == NULL && fallback != NULL && fallback->fs != NULL)
        fs = fs_info_copy(fallback->fs);
    unlock(&pids_lock);

    if (fs == NULL)
        return -ENOENT;

    char path[MAX_PATH];
    path[0] = '\0';
    struct task *saved = codipad_borrow_guest_current();
    int err = generic_getpath(fs->pwd, path);
    codipad_restore_guest_current(saved);
    fs_info_release(fs);
    if (err < 0)
        return err;
    size_t len = strlen(path);
    if (len + 1 > capacity)
        return -ENAMETOOLONG;
    memcpy(buffer, path, len + 1);
    return 0;
}

// Caller holds g_sessions_lock.
static void codipad_fill_info(const struct codipad_session *s, struct codipad_session_info *out) {
    memset(out, 0, sizeof(*out));
    out->session = s->id;
    out->parent_session = s->parent_session;
    out->guest_pid = s->pid;
    out->guest_pgid = s->pgid;
    out->pty_num = s->tty != NULL ? s->tty->num : -1;
    out->backend = s->backend;
    out->running = s->running;
    out->exited = s->exit_reported;
    out->reaped = s->reaped;
    out->all_descendants_reaped = s->all_descendants_reaped;
    out->has_status = s->has_status;
    out->code = s->code;
    out->terminating_signal = s->terminating_signal;
}

int codipad_kernel_info(codipad_session_t session, struct codipad_session_info *out) {
    if (out == NULL)
        return -EINVAL;
    memset(out, 0, sizeof(*out));
    pthread_mutex_lock(&g_sessions_lock);
    struct codipad_session *s = codipad_session_find(session);
    if (s == NULL) {
        pthread_mutex_unlock(&g_sessions_lock);
        return -ENOENT;
    }
    codipad_fill_info(s, out);
    pthread_mutex_unlock(&g_sessions_lock);
    return 0;
}

// Snapshot of a retained record; false when it is already gone.
size_t codipad_kernel_sessions_for_owner(uint64_t owner, codipad_session_t *ids, size_t capacity) {
    if (owner == 0) return 0;
    size_t count = 0;
    pthread_mutex_lock(&g_sessions_lock);
    for (int i = 0; i < CODIPAD_MAX_SESSIONS; i++) {
        if (g_sessions[i].id == 0 || g_sessions[i].owner != owner) continue;
        if (ids != NULL && count < capacity) ids[count] = g_sessions[i].id;
        count++;
    }
    pthread_mutex_unlock(&g_sessions_lock);
    return count;
}

static bool codipad_peek_info(codipad_session_t session, struct codipad_session_info *out) {
    if (out == NULL)
        return false;
    bool found = false;
    pthread_mutex_lock(&g_sessions_lock);
    struct codipad_session *s = codipad_session_find(session);
    if (s != NULL) {
        codipad_fill_info(s, out);
        found = true;
    } else {
        memset(out, 0, sizeof(*out));
    }
    pthread_mutex_unlock(&g_sessions_lock);
    return found;
}

static int codipad_close_pending(codipad_session_t id, int result,
                                enum codipad_close_wait_reason reason, codipad_session_t child) {
    pthread_mutex_lock(&g_sessions_lock);
    struct codipad_session *s = codipad_session_find(id);
    if (s != NULL) {
        s->close_result = result;
        s->close_wait_reason = reason;
        s->close_wait_child = child;
    }
    pthread_mutex_unlock(&g_sessions_lock);
    return result;
}

int codipad_kernel_close_status(codipad_session_t session, unsigned grace_ms,
                              struct codipad_session_info *out) {
    dword_t pid = 0, pgid = 0;
    struct tty *tty = NULL;
    codipad_session_t children[CODIPAD_MAX_SESSIONS];
    size_t child_count = 0;
    bool found = false;
    pthread_mutex_lock(&g_sessions_lock);
    struct codipad_session *s = codipad_session_find(session);
    if (s != NULL) {
        found = true;
        pid = s->pid;
        pgid = s->pgid;
        tty = s->tty;
        s->close_requested = true;
        s->close_result = 0;
        s->close_wait_reason = CODIPAD_CLOSE_WAIT_NONE;
        s->close_wait_child = 0;
        for (int i = 0; i < CODIPAD_MAX_SESSIONS; i++) {
            if (g_sessions[i].id != 0 && g_sessions[i].parent_session == session)
                children[child_count++] = g_sessions[i].id;
        }
    }
    pthread_mutex_unlock(&g_sessions_lock);
    if (!found)
        return -ENOENT;

    // Close child authority records first. Marking the parent close_requested under the same lock
    // prevents a concurrent spawn from appearing after this snapshot. Each child recursively
    // closes its own children, so cleanup follows the stored parent relation without another tree.
    for (size_t i = 0; i < child_count; i++) {
        int child_err = codipad_kernel_close_status(children[i], grace_ms, NULL);
        if (child_err < 0 && child_err != -ENOENT) {
            codipad_peek_info(session, out);
            return codipad_close_pending(session, child_err, CODIPAD_CLOSE_WAIT_CHILD, children[i]);
        }
    }

    // Signal the whole context even when the leader has already exited: a background child can
    // outlive it, and the leader's state says nothing about the members.
    bool all_signalled = false;
    if (pid != 0)
        codipad_signal_tree(session, pgid, SIGHUP_, &all_signalled);

    unsigned waited = 0;
    bool settled = codipad_settle(session, session, 0);
    while (!settled && waited < grace_ms) {
        usleep(10 * 1000);
        waited += 10;
        settled = codipad_settle(session, session, 0);
    }
    if (!settled) {
        if (pid != 0)
            codipad_signal_tree(session, pgid, SIGKILL_, &all_signalled);
        settled = codipad_settle(session, session, 1000);
    }

    if (!settled) {
        // Nothing is released: the record, the tty reference and the context stay so the caller can
        // retry or read the real state. Losing the record here is what made the old close() final
        // even when a child survived.
        pthread_mutex_lock(&g_sessions_lock);
        s = codipad_session_find(session);
        bool running = s != NULL && s->running;
        if (s != NULL)
            s->all_descendants_reaped = false;
        pthread_mutex_unlock(&g_sessions_lock);
        codipad_peek_info(session, out); // retained record: describe it, do not invent a status
        return codipad_close_pending(session, running ? -EINPROGRESS : -CODIPAD_EINCOMPLETE,
                                   CODIPAD_CLOSE_WAIT_SETTLEMENT, 0);
    }

    // Derive the status before anything is reaped or dropped: the retained root-status table is
    // authoritative and the queue only wakes its dispatcher. Keep the session record when delivery
    // is delayed; close must not report success without the real status.
    if (!codipad_wait_for_status(session, 500)) {
        codipad_peek_info(session, out);
        return codipad_close_pending(session, -EINPROGRESS, CODIPAD_CLOSE_WAIT_ROOT_STATUS, 0);
    }

    // Fully settled: every task in the context is reaped and the pty has no writers.
    pthread_mutex_lock(&g_sessions_lock);
    s = codipad_session_find(session);
    if (s != NULL) {
        s->reaped = true;
        s->all_descendants_reaped = true;
        // Snapshot before anything is released: this is the record's own final status.
        if (out != NULL)
            codipad_fill_info(s, out);
    }
    pthread_mutex_unlock(&g_sessions_lock);

    // Settled: give the pty reference back. No hangup is performed here. tty_hangup() must be called
    // with tty->lock held and releases it itself, while tty_release() acquires tty->lock internally
    // and requires only ttys_lock; mixing the two from outside the tty's own op path is what produced
    // the earlier deadlock. The kernel hangs the pty up itself when its last fd closes.
    // A still-running input/resize borrow keeps the reference until it finishes; the record is
    // retained so a retry can complete the close.
    (void) tty;
    unsigned spins = 0;
    while (codipad_session_release_tty(session) == -EBUSY) {
        if (spins >= 100) { // ~1 s
            pthread_mutex_lock(&g_sessions_lock);
            struct codipad_session *still = codipad_session_find(session);
            if (still != NULL)
                still->all_descendants_reaped = true;
            pthread_mutex_unlock(&g_sessions_lock);
            codipad_peek_info(session, out);
            return codipad_close_pending(session, -EINPROGRESS, CODIPAD_CLOSE_WAIT_TTY_RELEASE, 0);
        }
        usleep(10 * 1000);
        spins++;
    }

    // The pty reference is returned, but the record may still be referenced by a callback that is
    // running (or queued) with its ctx. Spin on the same bounded budget, then report honestly.
    spins = 0;
    while (codipad_session_drop_idle(session) == -EBUSY) {
        if (spins >= 100) {
            pthread_mutex_lock(&g_sessions_lock);
            struct codipad_session *still = codipad_session_find(session);
            if (still != NULL)
                still->all_descendants_reaped = true;
            pthread_mutex_unlock(&g_sessions_lock);
            codipad_peek_info(session, out);
            return codipad_close_pending(session, -EINPROGRESS, CODIPAD_CLOSE_WAIT_RECORD_DROP, 0);
        }
        usleep(10 * 1000);
        spins++;
    }
    return 0;
}

int codipad_kernel_close(codipad_session_t session, unsigned grace_ms) {
    return codipad_kernel_close_status(session, grace_ms, NULL);
}

int codipad_kernel_cleanup_diagnostic(codipad_session_t id, struct codipad_session_cleanup_diagnostic *out) {
    if (!out) return -EINVAL;
    memset(out, 0, sizeof(*out));
    out->version = 2;
    out->size = sizeof(*out);
    out->session = id;
    struct tty *tty = NULL;
    pthread_mutex_lock(&g_sessions_lock);
    struct codipad_session *s = codipad_session_find(id);
    if (!s) { pthread_mutex_unlock(&g_sessions_lock); return -ENOENT; }
    out->record_valid = 1;
    out->parent_session = s->parent_session;
    out->owner = s->owner;
    out->backend = s->backend;
    out->root_pid = s->pid;
    out->root_pgid = s->pgid;
    out->root_running = s->running;
    out->root_exited = s->exit_reported;
    out->root_reaped = s->reaped;
    out->root_status_valid = s->has_status;
    out->root_code = s->code;
    out->root_signal = s->terminating_signal;
    out->descendants_reaped = s->all_descendants_reaped;
    out->users = s->users;
    out->callback_users = s->callback_users;
    out->borrowed_users = s->borrowed_users;
    out->close_requested = s->close_requested;
    out->wait_reason = s->close_wait_reason;
    out->close_result = s->close_result;
    out->waiting_child = s->close_wait_child;
    size_t slot = (size_t)(s - g_sessions);
    out->root_status_published = atomic_load_explicit(&g_root_status[slot].ready, memory_order_acquire);
    tty = s->tty;
    out->has_tty = tty != NULL;
    if (tty != NULL) { s->users++; s->borrowed_users++; }
    pthread_mutex_unlock(&g_sessions_lock);

    // A PID-table observation never reaps, signals, or reads unprotected task blocking pointers.
    lock(&pids_lock);
    for (dword_t pid = 1; pid < MAX_PID; pid++) {
        struct task *task = pid_get_task_zombie(pid);
        if (task == NULL || task->group == NULL || task->group->fs_context != id) continue;
        if (task->zombie) out->zombie_tasks++;
        else out->live_tasks++;
    }
    unlock(&pids_lock);
    out->unreaped_tasks = out->live_tasks + out->zombie_tasks;
    out->guest_tasks_valid = 1;
    out->writers_valid = 1;
    out->writers_closed = 1; // HOST_FDS has no authority PTY; task counts cover guest ownership.
    if (tty != NULL) {
        lock(&tty->fds_lock);
        struct fd *fd;
        list_for_each_entry(&tty->fds, fd, tty_other_fds) out->pty_open_fds++;
        out->writers_closed = tty->hung_up || out->pty_open_fds == 0;
        unlock(&tty->fds_lock);
        codipad_tty_end_use(id);
    }
    return 0;
}

