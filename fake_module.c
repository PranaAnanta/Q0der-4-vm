/* fake_module.c — Intercept /sys/module/ directory scans and filter out VM-related kernel module entries
 * Build:  gcc -shared -fPIC -O2 -o fake_module.so fake_module.c -ldl
 * Install: write the absolute path into /etc/ld.so.preload (handled by refresh.sh)
 * Compat: pure C, no thread_local/C11 keywords (thread_local is undefined under gcc's default gnu17)
 *         Thread-local storage uses the GCC builtin __thread; DIR handle tracking avoids
 *         false filtering when a program interleaves traversal of multiple directories
 */
#define _GNU_SOURCE
#include <dirent.h>
#include <string.h>
#include <stdlib.h>
#include <dlfcn.h>
#include <stdio.h>
#include <errno.h>

static DIR *(*real_opendir)(const char *) = NULL;
static struct dirent *(*real_readdir)(DIR *) = NULL;
static struct dirent64 *(*real_readdir64)(DIR *) = NULL;
static int (*real_closedir)(DIR *) = NULL;

/* Module name prefixes to hide */
static const char *hidden_prefixes[] = {
    "vmw_", "vmware", "vmxnet", "vsock", "vmci", "vmmon", "vmblock",
    "vboxguest", "vboxsf", "vboxvideo",
    "xen_", "xenfs",
    NULL
};

static int is_hidden(const char *name) {
    int i;
    for (i = 0; hidden_prefixes[i]; i++) {
        if (strncmp(name, hidden_prefixes[i], strlen(hidden_prefixes[i])) == 0)
            return 1;
    }
    return 0;
}

/* Track DIR* handles returned by opendir("/sys/module").
 * Compared with a single global flag, handle tracking avoids false filtering of
 * other directories when a program interleaves traversal of multiple directories. */
#define MAX_TRACKED 64
static DIR *tracked[MAX_TRACKED];

static void track(DIR *d) {
    int i;
    for (i = 0; i < MAX_TRACKED; i++) {
        if (tracked[i] == NULL) { tracked[i] = d; return; }
    }
}

static int is_tracked(DIR *d) {
    int i;
    for (i = 0; i < MAX_TRACKED; i++)
        if (tracked[i] == d) return 1;
    return 0;
}

static void untrack(DIR *d) {
    int i;
    for (i = 0; i < MAX_TRACKED; i++)
        if (tracked[i] == d) { tracked[i] = NULL; return; }
}

/* Match only /sys/module or /sys/module/..., without falsely matching paths like /sys/moduleXXX */
static int is_sys_module_path(const char *p) {
    if (p == NULL) return 0;
    if (strncmp(p, "/sys/module", 11) != 0) return 0;
    return (p[11] == '\0' || p[11] == '/');
}

DIR *opendir(const char *path) {
    DIR *d;
    if (!real_opendir) real_opendir = dlsym(RTLD_NEXT, "opendir");
    if (!real_opendir) { errno = ENOSYS; return NULL; }
    d = real_opendir(path);
    if (d && is_sys_module_path(path))
        track(d);
    return d;
}

struct dirent *readdir(DIR *dirp) {
    struct dirent *e;
    if (!real_readdir) real_readdir = dlsym(RTLD_NEXT, "readdir");
    if (!real_readdir) { errno = ENOSYS; return NULL; }
    if (!is_tracked(dirp))
        return real_readdir(dirp);
    while ((e = real_readdir(dirp)) != NULL) {
        if (is_hidden(e->d_name)) continue;
        return e;
    }
    return NULL;
}

/* Rust/some C++ code uses readdir64; glibc exports this symbol (GLIBC_2.2.5), so intercept it separately */
struct dirent64 *readdir64(DIR *dirp) {
    struct dirent64 *e;
    if (!real_readdir64) real_readdir64 = dlsym(RTLD_NEXT, "readdir64");
    if (!real_readdir64) { errno = ENOSYS; return NULL; }
    if (!is_tracked(dirp))
        return real_readdir64(dirp);
    while ((e = real_readdir64(dirp)) != NULL) {
        if (is_hidden(e->d_name)) continue;
        return e;
    }
    return NULL;
}

/* Remove the handle from the tracking table when it is closed, to prevent false filtering
 * if the DIR* is later reused */
int closedir(DIR *dirp) {
    if (!real_closedir) real_closedir = dlsym(RTLD_NEXT, "closedir");
    untrack(dirp);
    if (!real_closedir) { errno = ENOSYS; return -1; }
    return real_closedir(dirp);
}