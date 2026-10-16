/* macOS (Darwin, x86_64 under Rosetta 2) counterparts of the Linux/glibc calls the runtime
 * uses. Included through runtime.h after the C library headers, so the macros below only
 * replace calls in this project's own sources. The kernel exposes no memfd, no fallocate,
 * no gettid, no timed pthread locks, no pthread_condattr_setclock and no CLOCK_MONOTONIC
 * condition variables, so those are emulated here. */
#ifndef BB_COMPAT_MAC_H
#define BB_COMPAT_MAC_H
#ifdef __APPLE__
#include <stdint.h>
#include <stddef.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>
#include <errno.h>
#include <fcntl.h>
#include <unistd.h>
#include <pthread.h>
#include <sys/types.h>
#include <sys/stat.h>
#include <sys/mman.h>
#include <sys/time.h>
#include <sys/resource.h>
#include <sys/random.h>
#include <netinet/in.h>

#ifndef PATH_MAX
#define PATH_MAX 1024
#endif
#ifndef MAX_PATH
#define MAX_PATH 1024
#endif
#ifndef MFD_CLOEXEC
#define MFD_CLOEXEC 0
#endif
#ifndef MAP_FIXED_NOREPLACE
#define MAP_FIXED_NOREPLACE 0x80000000
#endif
#ifndef PTHREAD_RECURSIVE_MUTEX_INITIALIZER_NP
#define PTHREAD_RECURSIVE_MUTEX_INITIALIZER_NP PTHREAD_RECURSIVE_MUTEX_INITIALIZER
#endif
#ifndef RUSAGE_THREAD
#define RUSAGE_THREAD RUSAGE_SELF
#endif
#ifndef CLOCK_REALTIME_COARSE
#define CLOCK_REALTIME_COARSE CLOCK_REALTIME
#endif
#ifndef CLOCK_MONOTONIC_COARSE
#define CLOCK_MONOTONIC_COARSE CLOCK_MONOTONIC
#endif

/* struct stat has st_atimespec/st_mtimespec/st_ctimespec instead of the POSIX st_atim/... names. */
#define st_atim st_atimespec
#define st_mtim st_mtimespec
#define st_ctim st_ctimespec

/* Anonymous in-memory file: an unlinked temp file. ftruncate/mmap(MAP_SHARED) both work. */
static inline int compat_memfd_create(const char *name, unsigned flags) {
    (void)flags;
    char path[PATH_MAX];
    const char *dir = getenv("TMPDIR");
    snprintf(path, sizeof path, "%sbb-%s-XXXXXX", dir ? dir : "/tmp/", name ? name : "memfd");
    int fd = mkstemp(path);
    if (fd >= 0) unlink(path);
    return fd;
}
#define memfd_create compat_memfd_create

/* macOS has no fallocate; punch-hole keeps the sparse file sparse, otherwise no-op. */
#ifndef FALLOC_FL_KEEP_SIZE
#define FALLOC_FL_KEEP_SIZE 0x01
#endif
#ifndef FALLOC_FL_PUNCH_HOLE
#define FALLOC_FL_PUNCH_HOLE 0x02
#endif
static inline int compat_fallocate_punch(int fd, off_t offset, off_t len) {
#if defined(F_PUNCHHOLE)
    struct fpunchhole {
        off_t fp_offset;
        off_t fp_length;
        uint32_t fp_flags;
    } hole = {offset, len, 0};
    return fcntl(fd, F_PUNCHHOLE, &hole);
#else
    (void)fd; (void)offset; (void)len;
    return 0;
#endif
}
static inline int compat_fallocate(int fd, int mode, off_t offset, off_t len) {
    if (mode & FALLOC_FL_PUNCH_HOLE) return compat_fallocate_punch(fd, offset, len);
    return 0;
}
#define fallocate compat_fallocate

/* mmap(MAP_FIXED_NOREPLACE) does not exist: try the hint without MAP_FIXED and verify. */
static inline void *compat_mmap(void *address, size_t size, int prot, int flags, int fd, off_t offset) {
    if (flags & MAP_FIXED_NOREPLACE) {
        flags &= ~MAP_FIXED_NOREPLACE;
        void *r = mmap(address, size, prot, flags, fd, offset);
        if (r == MAP_FAILED) return r;
        if (r != address) { munmap(r, size); errno = EEXIST; return MAP_FAILED; }
        return r;
    }
    return mmap(address, size, prot, flags, fd, offset);
}
#define mmap compat_mmap

/* No gettid: the kernel thread id via pthread_threadid_np. */
static inline pid_t compat_gettid(void) {
    uint64_t tid = 0;
    pthread_threadid_np(NULL, &tid);
    return (pid_t)tid;
}
#define gettid compat_gettid

static inline ssize_t compat_getrandom(void *buffer, size_t size, unsigned flags) {
    (void)flags;
    arc4random_buf(buffer, size);
    return (ssize_t)size;
}
#define getrandom compat_getrandom

/* No pthread_mutex_timedlock: poll trylock until the absolute deadline. */
static inline int compat_mutex_timedlock(pthread_mutex_t *m, const struct timespec *abstime) {
    for (;;) {
        int e = pthread_mutex_trylock(m);
        if (e != EBUSY) return e;
        struct timespec now;
        clock_gettime(CLOCK_REALTIME, &now);
        if (now.tv_sec > abstime->tv_sec ||
            (now.tv_sec == abstime->tv_sec && now.tv_nsec >= abstime->tv_nsec))
            return ETIMEDOUT;
        struct timespec slice = {0, 2000000};
        nanosleep(&slice, NULL);
    }
}
#define pthread_mutex_timedlock compat_mutex_timedlock

/* No timed rwlock either. */
static inline int compat_rwlock_timedrdlock(pthread_rwlock_t *r, const struct timespec *abstime) {
    for (;;) {
        int e = pthread_rwlock_tryrdlock(r);
        if (e != EBUSY && e != EAGAIN) return e;
        struct timespec now;
        clock_gettime(CLOCK_REALTIME, &now);
        if (now.tv_sec > abstime->tv_sec ||
            (now.tv_sec == abstime->tv_sec && now.tv_nsec >= abstime->tv_nsec))
            return ETIMEDOUT;
        struct timespec slice = {0, 2000000};
        nanosleep(&slice, NULL);
    }
}
static inline int compat_rwlock_timedwrlock(pthread_rwlock_t *r, const struct timespec *abstime) {
    for (;;) {
        int e = pthread_rwlock_trywrlock(r);
        if (e != EBUSY && e != EAGAIN) return e;
        struct timespec now;
        clock_gettime(CLOCK_REALTIME, &now);
        if (now.tv_sec > abstime->tv_sec ||
            (now.tv_sec == abstime->tv_sec && now.tv_nsec >= abstime->tv_nsec))
            return ETIMEDOUT;
        struct timespec slice = {0, 2000000};
        nanosleep(&slice, NULL);
    }
}
#define pthread_rwlock_timedrdlock compat_rwlock_timedrdlock
#define pthread_rwlock_timedwrlock compat_rwlock_timedwrlock

/* macOS condition variables are CLOCK_REALTIME only; the clock attribute is ignored. */
static inline int compat_condattr_setclock(pthread_condattr_t *attr, clockid_t clock_id) {
    (void)attr; (void)clock_id;
    return 0;
}
#define pthread_condattr_setclock compat_condattr_setclock

/* No clock_nanosleep: relative nanosleep, or convert an absolute deadline. */
#ifndef TIMER_ABSTIME
#define TIMER_ABSTIME 1
#endif
static inline int compat_clock_nanosleep(clockid_t clock_id, int flags,
                                         const struct timespec *request, struct timespec *remain) {
    if (flags & TIMER_ABSTIME) {
        struct timespec now, delta;
        if (clock_gettime(clock_id, &now)) return errno;
        delta.tv_sec = request->tv_sec - now.tv_sec;
        delta.tv_nsec = request->tv_nsec - now.tv_nsec;
        if (delta.tv_nsec < 0) { delta.tv_nsec += 1000000000; delta.tv_sec -= 1; }
        if (delta.tv_sec < 0) return 0;
        return nanosleep(&delta, remain);
    }
    return nanosleep(request, remain);
}
#define clock_nanosleep compat_clock_nanosleep

/* macOS has no pthread barriers (the tests use one). */
typedef struct {
    pthread_mutex_t mutex;
    pthread_cond_t cond;
    unsigned count, waiting, generation;
} compat_barrier_t;
typedef compat_barrier_t pthread_barrier_t;
#ifndef PTHREAD_BARRIER_SERIAL_THREAD
#define PTHREAD_BARRIER_SERIAL_THREAD (-1)
#endif
static inline int compat_barrier_init(pthread_barrier_t *b, const void *attr, unsigned count) {
    (void)attr;
    b->count = count; b->waiting = 0; b->generation = 0;
    pthread_mutex_init(&b->mutex, NULL);
    pthread_cond_init(&b->cond, NULL);
    return 0;
}
static inline int compat_barrier_wait(pthread_barrier_t *b) {
    pthread_mutex_lock(&b->mutex);
    unsigned generation = b->generation;
    int serial = 0;
    if (++b->waiting == b->count) {
        b->waiting = 0;
        b->generation++;
        pthread_cond_broadcast(&b->cond);
        serial = 1;
    } else {
        while (generation == b->generation) pthread_cond_wait(&b->cond, &b->mutex);
    }
    pthread_mutex_unlock(&b->mutex);
    return serial ? PTHREAD_BARRIER_SERIAL_THREAD : 0;
}
static inline int compat_barrier_destroy(pthread_barrier_t *b) {
    pthread_mutex_destroy(&b->mutex);
    pthread_cond_destroy(&b->cond);
    return 0;
}
#define pthread_barrier_init compat_barrier_init
#define pthread_barrier_wait compat_barrier_wait
#define pthread_barrier_destroy compat_barrier_destroy

/* No close_range: close each descriptor in the range. */
static inline int compat_close_range(unsigned first, unsigned last, int flags) {
    (void)flags;
    long limit = sysconf(_SC_OPEN_MAX);
    if (limit < 0 || limit > 65536) limit = 65536;
    if (last > (unsigned)limit) last = (unsigned)limit;
    for (unsigned fd = first; fd <= last; fd++) close((int)fd);
    return 0;
}
#define close_range compat_close_range

#endif /* __APPLE__ */
#endif /* BB_COMPAT_MAC_H */
