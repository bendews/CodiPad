// CodiPadProcess/ShellBootstrap.h — first-run guest rootfs import for the shell.
//
// Deliberately tiny and GUI-free: it calls the pinned fakefs_import() and nothing else. No
// iSHApp, no UIKit, no REH. The caller supplies the archive (the curated guest rootfs) and the
// fakefs root directory; the import produces <root_dir>/meta.db plus <root_dir>/data, and the
// caller then boots with codipad_kernel_boot(<root_dir>/data, workspace, borrowed_workspace_fd), which mounts the native
// workspace at /workspace, so files are shared, not copied.
//
// A rootfs is only usable when BOTH <root_dir>/meta.db and <root_dir>/data exist: fake_db_init()
// returns EINVAL (surfacing as a kernel boot failure of -22) when the schema database is missing,
// which is exactly what a tree imported one level too deep produces.

#ifndef CODIPAD_SHELL_BOOTSTRAP_H
#define CODIPAD_SHELL_BOOTSTRAP_H

#include <stddef.h>

#ifdef __cplusplus
extern "C" {
#endif

// Imports archive_path into root_dir, which is the *fakefs root*, not the data directory:
// fakefs_import() creates <root_dir>/data (the content root) and <root_dir>/meta.db (tools/fakefs.c
// lines 87-94). Pass <root_dir>/data to codipad_kernel_boot(); mount_root() looks for meta.db beside
// that data directory. Passing the data directory here nests the tree (data/meta.db + data/data) and
// makes the kernel mount find no schema, which surfaces as -EINVAL.
// Returns 0 on success and a negative errno on failure:
//   -EINVAL  NULL/empty/non-absolute arguments
//   -ENOENT  archive or target directory missing
//   -ENOTDIR target exists but is not a directory
//   -EIO     the importer failed without a more specific errno (see the message)
// The specific reason is available from codipad_shell_import_message() until the next call.
// Never returns 0 unless the import actually completed.
int codipad_shell_import_rootfs(const char *archive_path, const char *root_dir);

// Message from the last failed import, or "" — borrowed, not owned, not thread-safe.
const char *codipad_shell_import_message(void);

#ifdef __cplusplus
}
#endif

#endif // CODIPAD_SHELL_BOOTSTRAP_H
