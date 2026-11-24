#define _DARWIN_C_SOURCE
#include "codipad_vsix_extract.h"

#include <archive.h>
#include <archive_entry.h>
#include <ctype.h>
#include <errno.h>
#include <fcntl.h>
#include <fts.h>
#include <limits.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>
#include <unistd.h>

#define CODIPAD_MAX_ENTRIES 20000
#define CODIPAD_MAX_EXPANDED_BYTES (256ULL * 1024ULL * 1024ULL)

static void set_error(char *buffer, size_t size, const char *message) {
    if (buffer != NULL && size > 0) snprintf(buffer, size, "%s", message);
}

static int valid_path(const char *path) {
    if (path == NULL || path[0] == '\0' || path[0] == '/' || path[0] == '\\') return 0;
    if (isalpha((unsigned char)path[0]) && path[1] == ':') return 0;
    size_t length = strlen(path);
    if (length > 4096) return 0;
    char *copy = strdup(path);
    if (copy == NULL) return 0;
    for (char *p = copy; *p != '\0'; p++) if (*p == '\\') *p = '/';
    int valid = 1;
    char *save = NULL;
    for (char *part = strtok_r(copy, "/", &save); part != NULL; part = strtok_r(NULL, "/", &save)) {
        if (strcmp(part, "..") == 0) { valid = 0; break; }
    }
    free(copy);
    return valid;
}

static int validate_archive(const char *path, char *error, size_t error_size, int (*cancel)(void *), void *context) {
    struct archive *a = archive_read_new();
    if (a == NULL) { set_error(error, error_size, "archive reader allocation failed"); return -1; }
    archive_read_support_filter_all(a);
    archive_read_support_format_zip(a);
    if (archive_read_open_filename(a, path, 64 * 1024) != ARCHIVE_OK) {
        set_error(error, error_size, archive_error_string(a) ?: "cannot open VSIX archive");
        archive_read_free(a); return -1;
    }
    struct archive_entry *entry;
    int result = 0;
    size_t entries = 0;
    la_int64_t expanded = 0;
    while (1) {
        if (cancel && cancel(context)) { result = -2; break; }
        if (archive_read_next_header(a, &entry) != ARCHIVE_OK) break;
        const char *name = archive_entry_pathname(entry);
        mode_t type = archive_entry_filetype(entry);
        if (!valid_path(name)) { set_error(error, error_size, "VSIX contains an unsafe path"); result = -1; break; }
        if (archive_entry_symlink(entry) != NULL || archive_entry_hardlink(entry) != NULL ||
            (type != AE_IFREG && type != AE_IFDIR)) {
            set_error(error, error_size, "VSIX contains a link or unsupported entry type"); result = -1; break;
        }
        if (++entries > CODIPAD_MAX_ENTRIES || archive_entry_size(entry) < 0 ||
            (type == AE_IFREG && (la_int64_t)archive_entry_size(entry) > (la_int64_t)CODIPAD_MAX_EXPANDED_BYTES - expanded)) {
            set_error(error, error_size, "VSIX expanded content exceeds the safety limit"); result = -1; break;
        }
        if (type == AE_IFREG) expanded += archive_entry_size(entry);
        if (cancel && cancel(context)) { result = -2; break; }
        archive_read_data_skip(a);
        if (cancel && cancel(context)) { result = -2; break; }
    }
    if (result == 0 && archive_errno(a) != 0) {
        set_error(error, error_size, archive_error_string(a) ?: "invalid VSIX archive"); result = -1;
    }
    archive_read_close(a);
    archive_read_free(a);
    return result;
}

static int open_directory_chain(int root, const char *relative, int create) {
    char *copy = strdup(relative);
    if (copy == NULL) return -1;
    int current = dup(root);
    if (current < 0) { free(copy); return -1; }
    char *part = copy;
    while (part != NULL && *part != '\0') {
        char *slash = strchr(part, '/');
        if (slash != NULL) *slash = '\0';
        if (create && mkdirat(current, part, 0700) != 0 && errno != EEXIST) { close(current); free(copy); return -1; }
        int child = openat(current, part, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC);
        close(current);
        if (child < 0) { free(copy); return -1; }
        current = child;
        part = slash == NULL ? NULL : slash + 1;
    }
    free(copy);
    return current;
}

static int extract_archive(const char *archive_path, const char *destination,
                           char *error, size_t error_size, int (*cancel)(void *), void *context) {
    int root = open(destination, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC);
    if (root < 0) { set_error(error, error_size, "cannot open staging directory"); return -1; }
    struct archive *a = archive_read_new();
    if (a == NULL) { close(root); set_error(error, error_size, "archive reader allocation failed"); return -1; }
    archive_read_support_filter_all(a);
    archive_read_support_format_zip(a);
    if (archive_read_open_filename(a, archive_path, 64 * 1024) != ARCHIVE_OK) {
        set_error(error, error_size, archive_error_string(a) ?: "cannot reopen VSIX archive");
        archive_read_free(a); close(root); return -1;
    }
    struct archive_entry *entry;
    int result = 0;
    while (1) {
        if (cancel && cancel(context)) { result = -2; break; }
        if (archive_read_next_header(a, &entry) != ARCHIVE_OK) break;
        const char *name = archive_entry_pathname(entry);
        char *normalized = strdup(name);
        if (normalized == NULL) { result = -1; set_error(error, error_size, "out of memory"); break; }
        for (char *p = normalized; *p != '\0'; p++) if (*p == '\\') *p = '/';
        size_t length = strlen(normalized);
        while (length > 0 && normalized[length - 1] == '/') normalized[--length] = '\0';
        char *slash = strrchr(normalized, '/');
        const char *base = slash == NULL ? normalized : slash + 1;
        char *parent = NULL;
        if (slash != NULL) { *slash = '\0'; parent = normalized; }
        int directory = parent == NULL ? dup(root) : open_directory_chain(root, parent, 1);
        if (directory < 0) {
            free(normalized); result = -1; set_error(error, error_size, "cannot create safe VSIX directory"); break;
        }
        if (archive_entry_filetype(entry) == AE_IFDIR) {
            if (mkdirat(directory, base, 0700) != 0 && errno != EEXIST) result = -1;
            if (result == 0) {
                int check = openat(directory, base, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC);
                if (check < 0) result = -1; else close(check);
            }
        } else {
            int fd = openat(directory, base, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0600);
            if (fd < 0) result = -1;
            char buffer[64 * 1024];
            while (result == 0) {
                if (cancel && cancel(context)) { result = -2; break; }
                la_ssize_t count = archive_read_data(a, buffer, sizeof(buffer));
                if (count == 0) break;
                if (count < 0) { result = -1; break; }
                ssize_t offset = 0;
                while (offset < count) {
                    ssize_t wrote = write(fd, buffer + offset, (size_t)(count - offset));
                    if (wrote <= 0) { result = -1; break; }
                    offset += wrote;
                }
            }
            // Keep package files private while preserving upstream helper executability.
            // Do not import set-id, group, or world permissions from the archive.
            if (result == 0 && fchmod(fd, 0600 | (archive_entry_perm(entry) & S_IXUSR)) != 0) result = -1;
            if (fd >= 0 && close(fd) != 0) result = -1;
        }
        close(directory);
        free(normalized);
        if (result != 0) { if (result != -2) set_error(error, error_size, "cannot write safe VSIX entry"); break; }
    }
    archive_read_close(a);
    archive_read_free(a);
    close(root);
    return result;
}

int codipad_vsix_extract_cancellable(const char *archivePath, const char *destinationRoot,
                                   char *errorBuffer, size_t errorBufferSize,
                                   int (*shouldCancel)(void *), void *context) {
    if (archivePath == NULL || destinationRoot == NULL) {
        set_error(errorBuffer, errorBufferSize, "missing archive or destination"); return -1;
    }
    int result = validate_archive(archivePath, errorBuffer, errorBufferSize, shouldCancel, context);
    if (result != 0) return result;
    return extract_archive(archivePath, destinationRoot, errorBuffer, errorBufferSize, shouldCancel, context);
}

int codipad_vsix_extract(const char *archivePath, const char *destinationRoot,
                       char *errorBuffer, size_t errorBufferSize) {
    return codipad_vsix_extract_cancellable(archivePath, destinationRoot, errorBuffer, errorBufferSize, NULL, NULL);
}

int codipad_vsix_pack(const char *packageRoot, const char *archivePath, char *error, size_t error_size) {
    if (!packageRoot || !archivePath) { set_error(error, error_size, "missing package or archive"); return -1; }
    char *paths[] = { (char *)packageRoot, NULL };
    FTS *tree = fts_open(paths, FTS_PHYSICAL | FTS_NOCHDIR, NULL);
    struct archive *out = archive_write_new();
    if (!tree || !out) { if (tree) fts_close(tree); if (out) archive_write_free(out); set_error(error, error_size, "cannot open package"); return -1; }
    int result = -1;
    if (archive_write_set_format_zip(out) != ARCHIVE_OK || archive_write_open_filename(out, archivePath) != ARCHIVE_OK) goto done;
    size_t count = 0; unsigned long long total = 0;
    FTSENT *item;
    while (errno = 0, (item = fts_read(tree)) != NULL) {
        if (item->fts_level == 0 || item->fts_info == FTS_DP) continue;
        if (item->fts_info == FTS_D) continue;
        if (item->fts_info != FTS_F || ++count > CODIPAD_MAX_ENTRIES || !item->fts_statp || item->fts_statp->st_size < 0) goto done;
        total += (unsigned long long)item->fts_statp->st_size;
        if (total > CODIPAD_MAX_EXPANDED_BYTES) goto done;
        const char *relative = item->fts_path + strlen(packageRoot);
        if (*relative != '/' || !valid_path(relative + 1)) goto done;
        size_t length = strlen(relative) + sizeof("extension");
        char *name = malloc(length);
        if (!name) goto done;
        snprintf(name, length, "extension%s", relative);
        int fd = open(item->fts_accpath, O_RDONLY | O_NOFOLLOW);
        struct stat actual;
        if (fd < 0 || fstat(fd, &actual) != 0 || !S_ISREG(actual.st_mode) || actual.st_dev != item->fts_statp->st_dev || actual.st_ino != item->fts_statp->st_ino || actual.st_size != item->fts_statp->st_size) {
            if (fd >= 0) close(fd); free(name); goto done;
        }
        struct archive_entry *entry = archive_entry_new();
        if (!entry) { close(fd); free(name); goto done; }
        archive_entry_set_pathname(entry, name);
        archive_entry_set_filetype(entry, AE_IFREG);
        archive_entry_set_perm(entry, actual.st_mode & 0777);
        archive_entry_set_size(entry, actual.st_size);
        int ok = archive_write_header(out, entry) == ARCHIVE_OK;
        char buffer[65536]; ssize_t bytes = 0; off_t written = 0;
        while (ok && (bytes = read(fd, buffer, sizeof(buffer))) > 0) {
            if (archive_write_data(out, buffer, (size_t)bytes) != bytes) ok = 0;
            written += bytes;
        }
        if (!ok || bytes < 0 || written != actual.st_size) ok = 0;
        archive_entry_free(entry); close(fd); free(name);
        if (!ok) goto done;
    }
    if (errno != 0) goto done;
    result = 0;
done:
    if (archive_write_close(out) != ARCHIVE_OK) result = -1;
    archive_write_free(out); fts_close(tree);
    if (result != 0) { unlink(archivePath); set_error(error, error_size, "cannot create safe VSIX archive"); }
    return result;
}
