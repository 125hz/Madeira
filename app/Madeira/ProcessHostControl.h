// SPDX-License-Identifier: GPL-3.0-or-later
// Madeira Converter Exception: see LICENSE-EXCEPTION.md
// ml1331: private socket protocol, same app/extension build and native ABI.
#pragma once
#include <stdint.h>
#include <stddef.h>
#include <errno.h>
#include <sys/socket.h>
#include <unistd.h>

#define PH_CONTROL_VERSION 1u
#define PH_CONTROL_LIMIT 65536u
enum { PH_READ = 1, PH_WRITE, PH_GET_CONTEXT, PH_SET_CONTEXT, PH_HOLD, PH_RELEASE, PH_SIGNAL };
static inline const char *ph_control_name(uint32_t op) {
    static const char *names[]={"unknown","read","write","get-context","set-context","suspend","resume","signal"};
    return op <= PH_SIGNAL ? names[op] : names[0];
}
typedef struct {
    uint32_t version, op, tid, machine;
    uint64_t address, teb, frame, sequence;
    uint32_t length, flags;
    int32_t status;
    uint32_t reserved;
} PHControlRequest;

// A short read is never interpreted as a complete message. EINTR is retryable;
// a timeout or disconnect poisons the connection (the caller shuts it down).
static inline int ph_control_transfer(int fd, void *data, size_t size, int writing) {
    unsigned char *p = data;
    while (size) {
        ssize_t n = writing ? send(fd, p, size, 0) : recv(fd, p, size, 0);
        if (n < 0 && errno == EINTR) continue;
        if (n <= 0) return 0;
        p += n; size -= (size_t)n;
    }
    return 1;
}
