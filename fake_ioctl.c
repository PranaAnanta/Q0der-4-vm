/* fake_ioctl.c — Intercept only ioctl(SIOCGIFHWADDR) and return a fake MAC
 * Build:  gcc -shared -fPIC -O2 -o fake_ioctl.so fake_ioctl.c -ldl
 * Install: write the absolute path into /etc/ld.so.preload (handled by refresh.sh)
 * Compat: pure C (gnu17 default standard is fine), no C11-only keywords used
 * Safety: does not intercept open/close/read (safe for the dynamic linker), only ioctl
 */
#define _GNU_SOURCE
#include <stdio.h>
#include <string.h>
#include <stdlib.h>
#include <sys/socket.h>
#include <sys/ioctl.h>
#include <net/if.h>
#include <dlfcn.h>
#include <stdarg.h>

/* Some distros' glibc headers do not expose SIOCGIFHWADDR; fall back to the kernel uapi header */
#ifndef SIOCGIFHWADDR
#include <linux/sockios.h>
#endif

static int (*real_ioctl)(int, unsigned long, ...) = NULL;

/* Each process reads /tmp/fk/if_mac only once (format: XX:XX:XX:XX:XX:XX) */
#define MAC_FILE "/tmp/fk/if_mac"
static int mac_loaded = 0;
static unsigned char fake_mac[6];

static int read_fake_mac(unsigned char *mac) {
    FILE *f;
    unsigned int v[6];
    int n, i;
    if (mac_loaded) {
        memcpy(mac, fake_mac, 6);
        return 0;
    }
    f = fopen(MAC_FILE, "r");
    if (!f) return -1;
    n = fscanf(f, "%02x:%02x:%02x:%02x:%02x:%02x",
               &v[0], &v[1], &v[2], &v[3], &v[4], &v[5]);
    fclose(f);
    if (n != 6) return -1;
    for (i = 0; i < 6; i++) fake_mac[i] = (unsigned char)v[i];
    mac_loaded = 1;
    memcpy(mac, fake_mac, 6);
    return 0;
}

int ioctl(int fd, unsigned long req, ...) {
    va_list ap;
    void *arg;

    if (!real_ioctl) {
        real_ioctl = dlsym(RTLD_NEXT, "ioctl");
        if (!real_ioctl) return -1;
    }
    va_start(ap, req);
    arg = va_arg(ap, void *);
    va_end(ap);

    if (req == (unsigned long)SIOCGIFHWADDR && arg) {
        struct ifreq *ifr = (struct ifreq *)arg;
        /* Pass loopback through directly, preserving the real 00:00:00:00:00:00 semantics */
        if (ifr->ifr_name[0] == 'l' && ifr->ifr_name[1] == 'o'
            && ifr->ifr_name[2] == '\0') {
            return real_ioctl(fd, req, arg);
        }
        if (read_fake_mac((unsigned char *)ifr->ifr_hwaddr.sa_data) == 0)
            return 0;
        /* If the fake MAC file does not exist, fall back to the real ioctl */
    }
    return real_ioctl(fd, req, arg);
}