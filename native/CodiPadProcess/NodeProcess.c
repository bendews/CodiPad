// libuv transports spawn, wait and kill to the existing authority. No second process table.
#include "NodeProcess.h"
#include "IshKernel.h"
#include <uv.h>
#include <errno.h>
#include <fcntl.h>
#include <limits.h>
#include <pthread.h>
#include <signal.h>
#include <stdatomic.h>
#include <stdlib.h>
#include <string.h>
#include <sys/wait.h>
#include <unistd.h>

#define NODE_PID_BASE 0x40000000
static pthread_mutex_t workspace_lock = PTHREAD_MUTEX_INITIALIZER;
static pthread_mutex_t lifecycle_lock = PTHREAD_MUTEX_INITIALIZER;
static char workspace[PATH_MAX];
static atomic_bool host_active;
static codipad_node_process_cleanup_snapshot cleanup_snapshot = { .version = 2, .size = sizeof(cleanup_snapshot) };
static codipad_node_spawn_diagnostic_callback spawn_diagnostic_callback;
static void *spawn_diagnostic_context;
static char self_exec_identity[PATH_MAX];
static _Thread_local uint64_t owner;

int codipad_node_set_workspace(const char *path) {
    if (path == NULL || path[0] != '/' || strlen(path) >= sizeof(workspace)) return -EINVAL;
    char canonical[PATH_MAX];
    if (realpath(path, canonical) == NULL) return -errno;
    pthread_mutex_lock(&workspace_lock);
    int result = workspace[0] != '\0' && strcmp(workspace, canonical) != 0 ? -EBUSY : 0;
    if (result == 0) strcpy(workspace, canonical);
    pthread_mutex_unlock(&workspace_lock);
    return result;
}

int codipad_node_set_spawn_diagnostic_callback(codipad_node_spawn_diagnostic_callback callback,
                                              void *context) {
    if (callback == NULL && context != NULL) return -EINVAL;
    pthread_mutex_lock(&lifecycle_lock);
    int result = atomic_load(&host_active) ? -EBUSY : 0;
    if (result == 0) {
        spawn_diagnostic_callback = callback;
        spawn_diagnostic_context = context;
    }
    pthread_mutex_unlock(&lifecycle_lock);
    return result;
}

int codipad_node_set_self_exec_identity(const char *canonical_native_path) {
    char canonical[PATH_MAX] = {0};
    if (canonical_native_path != NULL) {
        if (canonical_native_path[0] != '/' || strlen(canonical_native_path) >= sizeof(canonical))
            return -EINVAL;
        if (realpath(canonical_native_path, canonical) == NULL)
            return -errno;
        if (strcmp(canonical, canonical_native_path) != 0)
            return -EINVAL;
    }
    pthread_mutex_lock(&lifecycle_lock);
    int result = atomic_load(&host_active) ? -EBUSY : 0;
    if (result == 0) memcpy(self_exec_identity, canonical, sizeof(self_exec_identity));
    pthread_mutex_unlock(&lifecycle_lock);
    return result;
}

bool codipad_node_process_begin(void) {
    pthread_mutex_lock(&lifecycle_lock);
    if (atomic_load(&host_active)) {
        pthread_mutex_unlock(&lifecycle_lock);
        return false;
    }
    uint64_t generation;
    if (codipad_kernel_reserve_owner_generation(&generation) < 0) {
        pthread_mutex_unlock(&lifecycle_lock);
        return false;
    }
    owner = generation;
    atomic_store(&host_active, true);
    cleanup_snapshot.active_owner = owner;
    cleanup_snapshot.host_active = 1;
    pthread_mutex_unlock(&lifecycle_lock);
    return true;
}

bool codipad_node_process_end(void) {
    if (owner == 0) return true;
    codipad_session_t sessions[64];
    size_t count = codipad_kernel_sessions_for_owner(owner, sessions, 64);
    uint64_t closed = 0, attempts;
    pthread_mutex_lock(&lifecycle_lock);
    attempts = cleanup_snapshot.cleanup_attempts + 1;
    pthread_mutex_unlock(&lifecycle_lock);
    codipad_node_process_cleanup_snapshot result = { .version = 2, .size = sizeof(result),
        .active_owner = owner, .cleanup_attempts = attempts,
        .cleanup_owner = owner,
        .found_sessions = count, .remaining_sessions = count,
        .attempted_count = count < 64 ? (uint32_t)count : 64,
        .over_capacity = count > 64 };
    // Signal all children first, so blocked children and CPU loops stop concurrently.
    for (size_t i = 0; i < count && i < 64; i++) {
        result.attempted[i].session = sessions[i];
        int signal_result = codipad_kernel_signal(sessions[i], 9);
        result.attempted[i].signal_result = signal_result;
        if (signal_result != 0) result.last_error = signal_result;
    }
    bool complete = count <= 64;
    // close() deliberately retains a session when settlement is still in progress. In particular,
    // a just-killed descendant or an in-flight stdio borrow can make the first close return
    // EINPROGRESS/CODIPAD_EINCOMPLETE even though a later close can observe the completed reap.
    // Keep this generation reserved while retrying; only a successful close or an absent record is
    // evidence that ownership has been released.
    const uint64_t deadline = uv_hrtime() + UINT64_C(6000000000);
    for (size_t i = 0; i < count && i < 64; i++) {
        result.last_session = sessions[i];
        codipad_node_process_close_attempt *attempt = &result.attempted[i];
        for (;;) {
            memset(&attempt->final_info, 0, sizeof(attempt->final_info));
            int rc = codipad_kernel_close_status(sessions[i], 0, &attempt->final_info);
            attempt->close_calls++;
            attempt->close_result = rc;
            attempt->final_info_valid = attempt->final_info.session == sessions[i];
            if (rc == 0 || rc == -ENOENT) { closed++; break; }
            if (rc != -EINPROGRESS && rc != -CODIPAD_EINCOMPLETE) {
                complete = false;
                result.last_error = rc;
                break;
            }
            if (uv_hrtime() >= deadline) {
                complete = false;
                result.last_error = rc;
                result.timed_out = 1;
                break;
            }
            usleep(10 * 1000);
        }
    }
    if (result.attempted_count != 0) {
        codipad_node_process_close_attempt *last = &result.attempted[result.attempted_count - 1];
        result.session_info_valid = last->final_info_valid;
        result.running = last->final_info.running;
        result.exited = last->final_info.exited;
        result.reaped = last->final_info.reaped;
        result.settled = last->final_info.all_descendants_reaped;
    }
    codipad_session_t remaining[64];
    result.remaining_sessions = codipad_kernel_sessions_for_owner(owner, remaining, 64);
    result.diagnostic_count = result.remaining_sessions < 64 ? (uint32_t)result.remaining_sessions : 64;
    for (uint32_t i = 0; i < result.diagnostic_count; i++)
        (void)codipad_kernel_cleanup_diagnostic(remaining[i], &result.remaining[i]);
    result.closed_sessions = closed;
    complete = complete && result.remaining_sessions == 0;
    result.host_active = !complete;
    if (complete) result.active_owner = 0;
    if (complete) {
        owner = 0;
        pthread_mutex_lock(&lifecycle_lock);
        atomic_store(&host_active, false);
    }
    else pthread_mutex_lock(&lifecycle_lock);
    cleanup_snapshot = result;
    pthread_mutex_unlock(&lifecycle_lock);
    // Incomplete cleanup keeps the active generation reserved and prevents a new host.
    return complete;
}

void codipad_node_process_get_cleanup_snapshot(codipad_node_process_cleanup_snapshot *out) {
    if (!out) return;
    pthread_mutex_lock(&lifecycle_lock);
    *out = cleanup_snapshot;
    out->host_active = atomic_load(&host_active);
    pthread_mutex_unlock(&lifecycle_lock);
}

static int uv_error(int err) {
    // Guest errno numbers are Linux values. Translate the supported spawn/wait failures explicitly.
    switch (-err) {
        case 1: return UV_EPERM;
        case 2: return UV_ENOENT;
        case 3: return UV_ESRCH;
        case 5: return UV_EIO;
        case 8: return UV_ENOEXEC;
        case 9: return UV_EBADF;
        case 11: return UV_EAGAIN;
        case 12: return UV_ENOMEM;
        case 13: return UV_EACCES;
        case 16: return UV_EBUSY;
        case 20: return UV_ENOTDIR;
        case 22: return UV_EINVAL;
        case 24: return UV_EMFILE;
        default: return UV_EIO;
    }
}

// Copy under the lifecycle lock, then invoke after releasing it. Spawn failure sites call this
// only after workspace/kernel operations have returned, so app callbacks never run under either
// authority's locks. No command, path, or environment data crosses this diagnostic boundary.
static void report_spawn_failure(int stage, int error, int backend) {
    pthread_mutex_lock(&lifecycle_lock);
    codipad_node_spawn_diagnostic_callback callback = spawn_diagnostic_callback;
    void *context = spawn_diagnostic_context;
    pthread_mutex_unlock(&lifecycle_lock);
    if (callback != NULL) callback(stage, error, backend, context);
}

static int guest_signal(int sig) {
    switch (sig) {
        case 0: return 0;
        case SIGHUP: return 1;
        case SIGINT: return 2;
        case SIGQUIT: return 3;
        case SIGKILL: return 9;
        case SIGTERM: return 15;
        case SIGCONT: return 18;
        case SIGSTOP: return 19;
        default: return -1;
    }
}
static int host_signal(int sig) {
    switch (sig) {
        case 1: return SIGHUP;
        case 2: return SIGINT;
        case 3: return SIGQUIT;
        case 9: return SIGKILL;
        case 15: return SIGTERM;
        case 18: return SIGCONT;
        case 19: return SIGSTOP;
        default: return sig;
    }
}

static void child_settled(codipad_session_t id, int code, int sig, bool settled, void *ctx) {
    (void)id; (void)code; (void)sig; (void)ctx;
    // libuv already owns the SIGCHLD watcher and visits its handles on the correct event loop.
    // The dispatcher may inherit a blocked signal mask. Send to the process so an unblocked
    // libuv thread can handle it; raise() targets only this dispatcher thread.
    if (settled) kill(getpid(), SIGCHLD);
}

static int host_fd_mode(int fd, unsigned char *mode, unsigned char *status) {
    int flags = fcntl(fd, F_GETFL);
    if (flags < 0) return uv_translate_sys_error(errno);
    *status = (flags & O_NONBLOCK) != 0 ? CODIPAD_HOST_STATUS_NONBLOCK : 0;
    switch (flags & O_ACCMODE) {
        case O_RDONLY: *mode = CODIPAD_HOST_FD_READ; return 0;
        case O_WRONLY: *mode = CODIPAD_HOST_FD_WRITE; return 0;
        case O_RDWR: *mode = CODIPAD_HOST_FD_READ_WRITE; return 0;
        default: return UV_EINVAL;
    }
}

static int guest_path(const char *path, char *out, size_t size) {
    char canonical[PATH_MAX];
    // Native file URIs can contain /var aliases or a directory's trailing slash.
    // Resolve those before comparing with the authorized mount, as the Swift filesystem does.
    if (path != NULL && (strncmp(path, "/private/", 9) == 0 || strncmp(path, "/var/", 5) == 0)) {
        if (realpath(path, canonical) == NULL) return uv_translate_sys_error(errno);
        path = canonical;
    }
    pthread_mutex_lock(&workspace_lock);
    size_t prefix = strlen(workspace);
    if (prefix == 0) {
        pthread_mutex_unlock(&workspace_lock);
        return UV_EBUSY;
    }
    int n;
    // The canonical native path is mounted directly in the guest. Keep it intact so cwd,
    // executable paths, and opaque argv/env entries all resolve in the same namespace.
    if (path == NULL) n = snprintf(out, size, "%s", workspace);
    else if (strncmp(path, workspace, prefix) == 0 && (path[prefix] == '/' || path[prefix] == '\0'))
        n = snprintf(out, size, "%s", path);
    else if (path[0] == '/' &&
             ((strcmp(path, "/private") != 0 && strncmp(path, "/private/", 9) != 0 &&
               strcmp(path, "/var") != 0 && strncmp(path, "/var/", 5) != 0) ||
              codipad_kernel_native_path_is_mounted(path)))
        n = snprintf(out, size, "%s", path);
    else n = -1;
    pthread_mutex_unlock(&workspace_lock);
    return n < 0 ? UV_EACCES : (size_t)n >= size ? UV_ENAMETOOLONG : 0;
}

// ABI consumed only by the reviewed iOS libuv patch. Errors are already libuv errors.
int codipad_node_uv_spawn(const uv_process_options_t *options, int stdio_count,
                        int (*pipes)[2], int *pid) {
    if (options == NULL || options->file == NULL || pipes == NULL || pid == NULL ||
        options->stdio_count < 0 ||
        (options->stdio_count > 0 && options->stdio == NULL))
        return UV_EINVAL;
    if (owner == 0) return UV_EPERM; // workers without a supervisor binding are unsupported
    if (options->flags & (UV_PROCESS_DETACHED | UV_PROCESS_SETUID | UV_PROCESS_SETGID)) return UV_ENOTSUP;
    if (stdio_count < 3 || stdio_count > CODIPAD_SPAWN_MAX_STDIO_FDS ||
        options->stdio_count > stdio_count || options->args == NULL || options->args[0] == NULL) {
        report_spawn_failure(CODIPAD_NODE_SPAWN_STDIO_SETUP, UV_ENOTSUP, CODIPAD_BACKEND_UNKNOWN);
        return UV_ENOTSUP;
    }
    int stdio_fds[CODIPAD_SPAWN_MAX_STDIO_FDS];
    unsigned char stdio_modes[CODIPAD_SPAWN_MAX_STDIO_FDS];
    unsigned char stdio_status_flags[CODIPAD_SPAWN_MAX_STDIO_FDS];
    for (int i = 0; i < stdio_count; i++) {
        stdio_fds[i] = -1;
        stdio_modes[i] = i == 0 ? CODIPAD_HOST_FD_READ
                        : i < 3 ? CODIPAD_HOST_FD_WRITE : CODIPAD_HOST_FD_READ_WRITE;
        stdio_status_flags[i] = 0;
    }
    bool saw_ipc = false;
    for (int i = 0; i < options->stdio_count; i++) {
        unsigned flags = options->stdio[i].flags;
        int mode = options->stdio[i].flags & (UV_CREATE_PIPE | UV_INHERIT_FD | UV_INHERIT_STREAM);
        if (mode == UV_IGNORE) {
            if (flags != UV_IGNORE) {
                report_spawn_failure(CODIPAD_NODE_SPAWN_STDIO_SETUP, UV_ENOTSUP,
                                     CODIPAD_BACKEND_UNKNOWN);
                return UV_ENOTSUP;
            }
            continue;
        }
        if ((flags & ~(UV_CREATE_PIPE | UV_INHERIT_FD | UV_INHERIT_STREAM |
                       UV_READABLE_PIPE | UV_WRITABLE_PIPE)) != 0) {
            report_spawn_failure(CODIPAD_NODE_SPAWN_STDIO_SETUP, UV_ENOTSUP,
                                 CODIPAD_BACKEND_UNKNOWN);
            return UV_ENOTSUP;
        }
        if (mode == UV_INHERIT_FD || mode == UV_INHERIT_STREAM) {
            if ((flags & (UV_READABLE_PIPE | UV_WRITABLE_PIPE)) != 0) {
                report_spawn_failure(CODIPAD_NODE_SPAWN_STDIO_SETUP, UV_ENOTSUP,
                                     CODIPAD_BACKEND_UNKNOWN);
                return UV_ENOTSUP;
            }
            int inherited_fd = -1;
            if (mode == UV_INHERIT_FD) {
                inherited_fd = options->stdio[i].data.fd;
            } else {
                uv_stream_t *inherited_stream = options->stdio[i].data.stream;
                uv_os_fd_t native_fd;
                int fileno_error = inherited_stream == NULL ? UV_EBADF
                    : uv_fileno((const uv_handle_t *)inherited_stream, &native_fd);
                if (fileno_error != 0 || native_fd < 0 || native_fd > INT_MAX) {
                    int error = fileno_error != 0 ? fileno_error : UV_EBADF;
                    report_spawn_failure(CODIPAD_NODE_SPAWN_STDIO_SETUP, error,
                                         CODIPAD_BACKEND_UNKNOWN);
                    return error;
                }
                inherited_fd = (int)native_fd;
            }
            int inherited_mode_error = inherited_fd < 0 ? UV_EBADF
                : host_fd_mode(inherited_fd, &stdio_modes[i], &stdio_status_flags[i]);
            if (inherited_mode_error != 0) {
                int error = inherited_mode_error;
                report_spawn_failure(CODIPAD_NODE_SPAWN_STDIO_SETUP, error,
                                     CODIPAD_BACKEND_UNKNOWN);
                return error;
            }
            stdio_fds[i] = inherited_fd;
            continue;
        }
        if (mode != UV_CREATE_PIPE ||
            (flags & (UV_READABLE_PIPE | UV_WRITABLE_PIPE)) == 0 || pipes[i][1] < 0) {
            report_spawn_failure(CODIPAD_NODE_SPAWN_STDIO_SETUP, UV_ENOTSUP,
                                 CODIPAD_BACKEND_UNKNOWN);
            return UV_ENOTSUP;
        }
        uv_pipe_t *stream = (uv_pipe_t *)options->stdio[i].data.stream;
        if (stream == NULL) {
            report_spawn_failure(CODIPAD_NODE_SPAWN_STDIO_SETUP, UV_EINVAL,
                                 CODIPAD_BACKEND_UNKNOWN);
            return UV_EINVAL;
        }
        if (stream->ipc) {
            if (saw_ipc ||
                (options->stdio[i].flags & (UV_READABLE_PIPE | UV_WRITABLE_PIPE)) !=
                    (UV_READABLE_PIPE | UV_WRITABLE_PIPE)) {
                report_spawn_failure(CODIPAD_NODE_SPAWN_STDIO_SETUP, UV_ENOTSUP,
                                     CODIPAD_BACKEND_UNKNOWN);
                return UV_ENOTSUP;
            }
            saw_ipc = true;
        }
        bool child_readable = (flags & UV_READABLE_PIPE) != 0;
        bool child_writable = (flags & UV_WRITABLE_PIPE) != 0;
        stdio_modes[i] = child_readable
            ? child_writable ? CODIPAD_HOST_FD_READ_WRITE : CODIPAD_HOST_FD_READ
            : CODIPAD_HOST_FD_WRITE;
        stdio_fds[i] = pipes[i][1];
    }
#ifdef F_SETNOSIGPIPE
    // Node is embedded without process-global signal resets. Protect each parent-side pipe end,
    // so a child closing stdin produces EPIPE rather than terminating the app.
    for (int i = 0; i < options->stdio_count; i++) {
        if ((options->stdio[i].flags & UV_CREATE_PIPE) != 0 &&
            pipes[i][0] >= 0 && fcntl(pipes[i][0], F_SETNOSIGPIPE, 1) < 0) {
            int error = uv_translate_sys_error(errno);
            report_spawn_failure(CODIPAD_NODE_SPAWN_STDIO_SETUP, error,
                                 CODIPAD_BACKEND_UNKNOWN);
            return error;
        }
    }
#endif

    char cwd[PATH_MAX], executable[PATH_MAX], configured_self[PATH_MAX];
    pthread_mutex_lock(&lifecycle_lock);
    memcpy(configured_self, self_exec_identity, sizeof(configured_self));
    pthread_mutex_unlock(&lifecycle_lock);
    bool self_exec = configured_self[0] != '\0' && strcmp(options->file, configured_self) == 0;
    const char *command = self_exec ? "/usr/local/bin/node" : options->file;
    int rc = guest_path(options->cwd, cwd, sizeof(cwd));
    if (rc != 0) {
        report_spawn_failure(CODIPAD_NODE_SPAWN_CWD_ADMISSION, rc, CODIPAD_BACKEND_UNKNOWN);
        return rc;
    }
    if (self_exec) {
        codipad_backend_t backend = CODIPAD_BACKEND_UNKNOWN;
        rc = codipad_kernel_preflight_executable(command, cwd,
                (const char *const *)options->env, executable, sizeof(executable), &backend);
        if (rc == 0 && backend != CODIPAD_BACKEND_GUEST_ELF) rc = UV_ENOEXEC;
        if (rc != 0) {
            report_spawn_failure(CODIPAD_NODE_SPAWN_EXECUTABLE_ADMISSION, rc, backend);
            return rc < 0 ? uv_error(rc) : rc;
        }
    } else if (strchr(command, '/') != NULL) {
        if (command[0] == '/') rc = guest_path(command, executable, sizeof(executable));
        else {
            int n = snprintf(executable, sizeof(executable), "%s/%s", cwd, command);
            rc = n < 0 || (size_t)n >= sizeof(executable) ? UV_ENAMETOOLONG : 0;
        }
        if (rc != 0) {
            report_spawn_failure(CODIPAD_NODE_SPAWN_EXECUTABLE_ADMISSION, rc,
                                 CODIPAD_BACKEND_UNKNOWN);
            return rc;
        }
    } else {
        const char *path = "/usr/local/bin:/usr/bin:/bin";
        if (options->env != NULL) for (char **e = options->env; *e != NULL; e++)
            if (strncmp(*e, "PATH=", 5) == 0) { path = *e + 5; break; }
        char *copy = strdup(path);
        if (copy == NULL) return UV_ENOMEM;
        bool access_error = false;
        codipad_backend_t backend = CODIPAD_BACKEND_UNKNOWN;
        int search_error = -ENOENT;
        char *at = copy, *part;
        while ((part = strsep(&at, ":")) != NULL) {
            char mapped[PATH_MAX], candidate[PATH_MAX];
            if (part[0] == '\0') part = cwd;
            int map_error = guest_path(part, mapped, sizeof(mapped));
            if (map_error != 0) {
                if (map_error == UV_EACCES) access_error = true;
                continue;
            }
            int n = snprintf(candidate, sizeof(candidate), "%s/%s", mapped, command);
            if (n < 0 || (size_t)n >= sizeof(candidate)) continue;
            backend = CODIPAD_BACKEND_UNKNOWN;
            int candidate_error = codipad_kernel_preflight_executable(candidate, cwd,
                    (const char *const *)options->env, executable, sizeof(executable), &backend);
            if (candidate_error == -ENOENT || candidate_error == -ENOTDIR) continue;
            if (candidate_error == -EACCES) { access_error = true; continue; }
            search_error = candidate_error;
            break;
        }
        free(copy);
        if (search_error != 0) {
            if (search_error == -ENOENT && access_error) search_error = -EACCES;
            report_spawn_failure(CODIPAD_NODE_SPAWN_EXECUTABLE_ADMISSION, search_error, backend);
            return uv_error(search_error);
        }
    }
    int nulls[3] = {-1, -1, -1};
    for (int i = 0; i < 3; i++) {
        if (stdio_fds[i] < 0) {
            nulls[i] = stdio_fds[i] = open("/dev/null", i == 0 ? O_RDONLY : O_WRONLY);
            if (stdio_fds[i] < 0) {
                rc = uv_translate_sys_error(errno);
                report_spawn_failure(CODIPAD_NODE_SPAWN_STDIO_SETUP, rc,
                                     CODIPAD_BACKEND_UNKNOWN);
                for (int j = 0; j < i; j++) if (nulls[j] >= 0) close(nulls[j]);
                return rc;
            }
        }
    }
    // Keep the libuv-created endpoints' host status flags unchanged. The shared iSH socket
    // operations provide guest nonblocking behavior without mutating a shared host OFD.
    for (int i = 0; i < options->stdio_count; i++) {
        if ((options->stdio[i].flags & UV_CREATE_PIPE) == 0) continue;
        int fd = pipes[i][1];
        if (fd < 0) {
            rc = UV_EBADF;
            report_spawn_failure(CODIPAD_NODE_SPAWN_STDIO_SETUP, rc,
                                 CODIPAD_BACKEND_UNKNOWN);
            for (int j = 0; j < 3; j++) if (nulls[j] >= 0) close(nulls[j]);
            return rc;
        }
#ifdef F_SETNOSIGPIPE
        if (fcntl(fd, F_SETNOSIGPIPE, 1) < 0) {
            rc = uv_translate_sys_error(errno);
            report_spawn_failure(CODIPAD_NODE_SPAWN_STDIO_SETUP, rc,
                                 CODIPAD_BACKEND_UNKNOWN);
            for (int j = 0; j < 3; j++) if (nulls[j] >= 0) close(nulls[j]);
            return rc;
        }
#endif
    }
    struct codipad_spawn_opts opts = {
        .exe = executable, .argv = (const char *const *)options->args,
        .envp = (const char *const *)options->env, .cwd = cwd,
        .stdio_mode = CODIPAD_STDIO_HOST_FDS,
        .stdin_fd = stdio_fds[0], .stdout_fd = stdio_fds[1], .stderr_fd = stdio_fds[2],
        .stdio_host_fds = stdio_fds, .stdio_host_fd_count = (size_t)stdio_count,
        .stdio_host_modes = stdio_modes,
        .stdio_host_status_flags = stdio_status_flags,
        .on_settled = child_settled, .owner = owner,
    };
    codipad_session_t session = 0;
    rc = codipad_kernel_spawn(&opts, &session);
    for (int i = 0; i < 3; i++) if (nulls[i] >= 0) close(nulls[i]);
    if (rc < 0) {
        codipad_backend_t backend = codipad_kernel_backend_for(executable);
        report_spawn_failure(CODIPAD_NODE_SPAWN_AUTHORITY, rc, backend);
        return uv_error(rc);
    }
    if (session >= NODE_PID_BASE) { codipad_kernel_close(session, 0); return UV_EOVERFLOW; }
    *pid = NODE_PID_BASE + (int)session; // reversible token, not a second lifecycle record
    return 0;
}

int codipad_node_uv_wait(int pid, int *status, int options) {
    if (pid < NODE_PID_BASE) return waitpid(pid, status, options);
    if (options != WNOHANG) { errno = ENOTSUP; return -1; }
    struct codipad_session_info info;
    codipad_session_t id = (unsigned)(pid - NODE_PID_BASE);
    int rc = codipad_kernel_info(id, &info);
    if (rc != 0) { errno = ECHILD; return -1; }
    if (!info.has_status || !info.reaped || !info.all_descendants_reaped) return 0;
    rc = codipad_kernel_close_status(id, 0, &info);
    if (rc != 0) return 0;
    *status = info.terminating_signal != 0 ? host_signal(info.terminating_signal) : info.code << 8;
    return pid;
}

int codipad_node_uv_kill(int pid, int sig) {
    if (pid < NODE_PID_BASE) return UV_ENOTSUP;
    int translated = guest_signal(sig);
    if (translated < 0) return UV_ENOTSUP;
    codipad_session_t id = (unsigned)(pid - NODE_PID_BASE);
    struct codipad_session_info info;
    if (codipad_kernel_info(id, &info) != 0 || info.all_descendants_reaped) return UV_ESRCH;
    if (sig == 0) return 0;
    int rc = codipad_kernel_signal(id, translated);
    return rc == 0 ? 0 : uv_error(rc);
}
