#if !defined(VZ_ROOTHIDE)
#error "RootHide build required"
#endif

#include "VZPaths.h"
#include <dirent.h>
#include <errno.h>
#include <fcntl.h>
#include <limits.h>
#include <removefile.h>
#include <stdarg.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/socket.h>
#include <sys/stat.h>
#include <sys/un.h>

static const char *redirect_path(const char *path, char buffer[PATH_MAX])
{
    if (!path) return path;
    const char *source = strncmp(path, "/private/", 9) == 0 ? path + 8 : path;

    const struct { const char *from; const char *to; } network[] = {
        {"/tmp/bootpd.plist", "bootpd.plist"},
        {"/tmp/com.apple.mis.rtadvd.conf", "com.apple.mis.rtadvd.conf"},
        {"/var/db/dhcpd_leases", "dhcpd_leases"},
        {"/var/db/bsdpd_clients", "bsdpd_clients"},
        {"/var/run/bootpd.pid", "bootpd.pid"},
        {"/var/run/rtadvd.pid", "rtadvd.pid"},
        {"/var/run/rtadvd.dump", "rtadvd.dump"},
        {"/Library/Preferences/SystemConfiguration/com.apple.vmnet.plist", "com.apple.vmnet.plist"},
        {"/Library/Preferences/SystemConfiguration/com.apple.dhcp6d.plist", "com.apple.dhcp6d.plist"},
    };
    for (size_t i = 0; i < sizeof(network) / sizeof(network[0]); i++) {
        size_t length = strlen(network[i].from);
        if (strncmp(source, network[i].from, length) == 0 &&
            (source[length] == '\0' || source[length] == '.' || source[length] == '-')) {
            snprintf(buffer, PATH_MAX, "%s%s%s",
                     VZNetworkPath(""), network[i].to, source + length);
            return buffer;
        }
    }

    if (strcmp(source, "/var/run/usbmuxd") == 0)
        return VZSocketPath("usbmuxd");
    if (strcmp(source, "/tmp/vzusbmuxd") == 0)
        return VZSocketPath("vzusbmuxd");

    const char *pairing = "/var/db/lockdown";
    size_t pairing_length = strlen(pairing);
    if (strncmp(source, pairing, pairing_length) == 0 &&
        (source[pairing_length] == '\0' || source[pairing_length] == '/')) {
        snprintf(buffer, PATH_MAX, "%s%s",
                 VZRestorePath("Pairing"), source + pairing_length);
        return buffer;
    }

    if (strcmp(source, "/tmp/") == 0 ||
        strncmp(source, "/tmp/bootImg", 12) == 0 ||
        strncmp(source, "/tmp/unified_cache.", 19) == 0) {
        snprintf(buffer, PATH_MAX, "%s%s", VZRestorePath(""), source + 5);
        return buffer;
    }
    return path;
}

#define INTERPOSE(replacement, original)     __attribute__((used)) static const struct { const void *new; const void *old; }     interpose_##original __attribute__((section("__DATA,__interpose"))) =         {(const void *)&replacement, (const void *)&original}

static int redirected_open(const char *path, int flags, ...)
{
    mode_t mode = 0;
    if (flags & O_CREAT) {
        va_list ap;
        va_start(ap, flags);
        mode = (mode_t)va_arg(ap, int);
        va_end(ap);
    }
    char buffer[PATH_MAX];
    return open(redirect_path(path, buffer), flags, mode);
}
INTERPOSE(redirected_open, open);

static FILE *redirected_fopen(const char *path, const char *mode)
{
    char buffer[PATH_MAX];
    return fopen(redirect_path(path, buffer), mode);
}
INTERPOSE(redirected_fopen, fopen);

static int redirected_stat(const char *path, struct stat *info)
{
    char buffer[PATH_MAX];
    return stat(redirect_path(path, buffer), info);
}
INTERPOSE(redirected_stat, stat);

static int redirected_lstat(const char *path, struct stat *info)
{
    char buffer[PATH_MAX];
    return lstat(redirect_path(path, buffer), info);
}
INTERPOSE(redirected_lstat, lstat);

static int redirected_access(const char *path, int mode)
{
    char buffer[PATH_MAX];
    return access(redirect_path(path, buffer), mode);
}
INTERPOSE(redirected_access, access);

static DIR *redirected_opendir(const char *path)
{
    char buffer[PATH_MAX];
    return opendir(redirect_path(path, buffer));
}
INTERPOSE(redirected_opendir, opendir);

static int redirected_unlink(const char *path)
{
    char buffer[PATH_MAX];
    return unlink(redirect_path(path, buffer));
}
INTERPOSE(redirected_unlink, unlink);

static int redirected_remove(const char *path)
{
    char buffer[PATH_MAX];
    return remove(redirect_path(path, buffer));
}
INTERPOSE(redirected_remove, remove);

static int redirected_mkdir(const char *path, mode_t mode)
{
    char buffer[PATH_MAX];
    return mkdir(redirect_path(path, buffer), mode);
}
INTERPOSE(redirected_mkdir, mkdir);

static int redirected_rmdir(const char *path)
{
    char buffer[PATH_MAX];
    return rmdir(redirect_path(path, buffer));
}
INTERPOSE(redirected_rmdir, rmdir);

static int redirected_rename(const char *from, const char *to)
{
    char source[PATH_MAX], destination[PATH_MAX];
    return rename(redirect_path(from, source), redirect_path(to, destination));
}
INTERPOSE(redirected_rename, rename);

static int redirected_removefile(const char *path, removefile_state_t state,
                                 removefile_flags_t flags)
{
    char buffer[PATH_MAX];
    return removefile(redirect_path(path, buffer), state, flags);
}
INTERPOSE(redirected_removefile, removefile);

static int redirected_chmod(const char *path, mode_t mode)
{
    char buffer[PATH_MAX];
    return chmod(redirect_path(path, buffer), mode);
}
INTERPOSE(redirected_chmod, chmod);

static int redirected_chown(const char *path, uid_t owner, gid_t group)
{
    char buffer[PATH_MAX];
    const char *mapped = redirect_path(path, buffer);
    return chown(mapped, owner, mapped == path ? group : 501);
}
INTERPOSE(redirected_chown, chown);

static int redirected_connect(int fd, const struct sockaddr *address,
                              socklen_t length)
{
    if (!address || address->sa_family != AF_UNIX)
        return connect(fd, address, length);
    struct sockaddr_un storage;
    memset(&storage, 0, sizeof(storage));
    const struct sockaddr_un *original = (const struct sockaddr_un *)address;
    size_t path_length = strnlen(original->sun_path, sizeof(original->sun_path));
    if (!path_length) return connect(fd, address, length);
    char buffer[PATH_MAX];
    const char *mapped = redirect_path(original->sun_path, buffer);
    if (mapped == original->sun_path)
        return connect(fd, address, length);
    if (strlen(mapped) >= sizeof(storage.sun_path)) {
        errno = ENAMETOOLONG;
        return -1;
    }
    storage.sun_family = AF_UNIX;
    strlcpy(storage.sun_path, mapped, sizeof(storage.sun_path));
    socklen_t mapped_length =
        (socklen_t)(offsetof(struct sockaddr_un, sun_path) +
                    strlen(storage.sun_path) + 1);
    return connect(fd, (const struct sockaddr *)&storage, mapped_length);
}
INTERPOSE(redirected_connect, connect);

static int redirected_bind(int fd, const struct sockaddr *address,
                           socklen_t length)
{
    if (!address || address->sa_family != AF_UNIX)
        return bind(fd, address, length);
    struct sockaddr_un storage;
    memset(&storage, 0, sizeof(storage));
    const struct sockaddr_un *original = (const struct sockaddr_un *)address;
    char buffer[PATH_MAX];
    const char *mapped = redirect_path(original->sun_path, buffer);
    if (mapped == original->sun_path)
        return bind(fd, address, length);
    if (strlen(mapped) >= sizeof(storage.sun_path)) {
        errno = ENAMETOOLONG;
        return -1;
    }
    storage.sun_family = AF_UNIX;
    strlcpy(storage.sun_path, mapped, sizeof(storage.sun_path));
    socklen_t mapped_length =
        (socklen_t)(offsetof(struct sockaddr_un, sun_path) +
                    strlen(storage.sun_path) + 1);
    return bind(fd, (const struct sockaddr *)&storage, mapped_length);
}
INTERPOSE(redirected_bind, bind);

static size_t redirected_confstr(int name, char *buffer, size_t size)
{
    if (name != _CS_DARWIN_USER_TEMP_DIR)
        return confstr(name, buffer, size);
    const char *path = VZRestorePath("");
    size_t required = strlen(path) + 1;
    if (size) strlcpy(buffer, path, size);
    return required;
}
INTERPOSE(redirected_confstr, confstr);

__attribute__((constructor))
static void configure_private_files(void)
{
    umask(0027);
}
