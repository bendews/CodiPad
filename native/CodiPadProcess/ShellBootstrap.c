// CodiPadProcess/ShellBootstrap.c — see ShellBootstrap.h.

#include "ShellBootstrap.h"

#include <errno.h>
#include <stdarg.h>
#include <stdbool.h>
#include <stdio.h>
#include <string.h>
#include <limits.h>
#include <sys/stat.h>

#include "tools/fakefs.h"

static char g_import_message[512];

const char *codipad_shell_import_message(void) {
    return g_import_message;
}

static void note(const char *fmt, ...) {
    va_list ap;
    va_start(ap, fmt);
    vsnprintf(g_import_message, sizeof(g_import_message), fmt, ap);
    va_end(ap);
}

int codipad_shell_import_rootfs(const char *archive_path, const char *root_dir) {
    g_import_message[0] = '\0';

    if (archive_path == NULL || archive_path[0] != '/' || root_dir == NULL || root_dir[0] != '/') {
        note("import: archive and root must be absolute paths");
        return -EINVAL;
    }

    struct stat st;
    if (stat(archive_path, &st) != 0) {
        note("import: archive %s: %s", archive_path, strerror(errno));
        return -ENOENT;
    }
    if (!S_ISREG(st.st_mode)) {
        note("import: %s is not a regular file", archive_path);
        return -EINVAL;
    }
    if (stat(root_dir, &st) == 0) {
        if (!S_ISDIR(st.st_mode)) {
            note("import: %s exists and is not a directory", root_dir);
            return -ENOTDIR;
        }
    } else if (mkdir(root_dir, 0755) != 0 && errno != EEXIST) {
        note("import: cannot create %s: %s", root_dir, strerror(errno));
        return -errno;
    }

    struct fakefsify_error err;
    memset(&err, 0, sizeof(err));
    struct progress progress;
    memset(&progress, 0, sizeof(progress));

    if (!fakefs_import(archive_path, root_dir, &err, progress)) {
        int code = err.code > 0 ? -err.code : -EIO;
        note("import into %s: %s (type %d, line %d)", root_dir,
             err.message != NULL ? err.message : "failed", (int) err.type, err.line);
        return code;
    }
    return 0;
}
