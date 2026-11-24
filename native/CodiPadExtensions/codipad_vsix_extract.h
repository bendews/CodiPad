#ifndef CODIPAD_VSIX_EXTRACT_H
#define CODIPAD_VSIX_EXTRACT_H

#include <stddef.h>

/// Extract a VSIX ZIP archive below destinationRoot.
/// Performs a full validation pass before creating files. Rejects traversal,
/// absolute paths, links, and non-file entries. Packaged optional native addons
/// remain ordinary files; the Node environment rejects loading them at runtime.
/// Returns 0 on success; otherwise writes a short diagnostic and returns nonzero.
int codipad_vsix_extract(const char *archivePath, const char *destinationRoot,
                       char *errorBuffer, size_t errorBufferSize);

/// Returns -2 when shouldCancel reports cancellation; the caller removes staged files.
int codipad_vsix_extract_cancellable(const char *archivePath, const char *destinationRoot,
                                   char *errorBuffer, size_t errorBufferSize,
                                   int (*shouldCancel)(void *), void *context);

/// Create an unsigned VSIX from an already validated immutable package directory.
int codipad_vsix_pack(const char *packageRoot, const char *archivePath,
                      char *errorBuffer, size_t errorBufferSize);

#endif
