#include "FairPlayCore.h"

#include <dlfcn.h>
#include <errno.h>
#include <fcntl.h>
#include <math.h>
#include <mach/mach.h>
#include <mach-o/fat.h>
#include <mach-o/loader.h>
#include <pthread.h>
#include <stdarg.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/mman.h>
#include <sys/stat.h>
#include <sys/fcntl.h>
#include <time.h>
#include <unistd.h>

#if __has_include(<libkern/OSByteOrder.h>)
#include <libkern/OSByteOrder.h>
#endif

#pragma mark - mremap_encrypted

typedef int (*fp_mremap_fn)(void *, size_t, uint32_t, uint32_t, uint32_t);

// xnu: int mremap_encrypted(void *addr, size_t len, uint32_t cryptid,
//                           cpu_type_t cpu_type, cpu_subtype_t cpu_subtype);
// Not exported by libsystem_kernel on every release, so fall back to the raw
// syscall (489 on arm64 Darwin).
static int fp_raw_mremap_encrypted(void *addr, size_t len, uint32_t cryptid,
                                   uint32_t cputype, uint32_t cpusubtype) {
#if defined(__arm64__)
    register uint64_t x0 __asm__("x0") = (uint64_t)addr;
    register uint64_t x1 __asm__("x1") = (uint64_t)len;
    register uint64_t x2 __asm__("x2") = (uint64_t)cryptid;
    register uint64_t x3 __asm__("x3") = (uint64_t)cputype;
    register uint64_t x4 __asm__("x4") = (uint64_t)cpusubtype;
    register uint64_t x16 __asm__("x16") = 489; // SYS_mremap_encrypted
    uint64_t carry;
    __asm__ volatile("svc #0x80\n\tcset %[c], cs"
                     : "+r"(x0), "+r"(x1), [c] "=r"(carry)
                     : "r"(x2), "r"(x3), "r"(x4), "r"(x16)
                     : "memory", "cc");
    if (carry) {
        errno = (int)x0;
        return -1;
    }
    return (int)x0;
#else
    (void)addr; (void)len; (void)cryptid; (void)cputype; (void)cpusubtype;
    errno = ENOTSUP;
    return -1;
#endif
}

static fp_mremap_fn fp_mremap_fn_ptr = NULL;
static pthread_once_t fp_mremap_once = PTHREAD_ONCE_INIT;

static void fp_resolve_mremap_encrypted(void) {
    fp_mremap_fn_ptr = (fp_mremap_fn)dlsym(RTLD_DEFAULT, "mremap_encrypted");
}

static int fp_mremap_encrypted(void *addr, size_t len, uint32_t cryptid,
                               uint32_t cputype, uint32_t cpusubtype) {
    pthread_once(&fp_mremap_once, fp_resolve_mremap_encrypted);
    if (fp_mremap_fn_ptr) return fp_mremap_fn_ptr(addr, len, cryptid, cputype, cpusubtype);
    return fp_raw_mremap_encrypted(addr, len, cryptid, cputype, cpusubtype);
}

#pragma mark - helpers

static void fp_log(fp_log_t log, void *ctx, const char *fmt, ...)
    __attribute__((format(printf, 3, 4)));
static void fp_log(fp_log_t log, void *ctx, const char *fmt, ...) {
    if (!log) return;
    char buf[1024];
    va_list ap;
    va_start(ap, fmt);
    vsnprintf(buf, sizeof buf, fmt, ap);
    va_end(ap);
    log(ctx, buf);
}

static double fp_now_ms(void) {
    struct timespec ts;
    clock_gettime(CLOCK_MONOTONIC, &ts);
    return ts.tv_sec * 1000.0 + ts.tv_nsec / 1e6;
}

static double fp_entropy(const uint8_t *p, size_t n) {
    if (!n) return 0;
    uint64_t histogram[256] = {0};
    for (size_t i = 0; i < n; i++) histogram[p[i]]++;
    double e = 0;
    for (int i = 0; i < 256; i++) {
        if (!histogram[i]) continue;
        double q = (double)histogram[i] / (double)n;
        e -= q * log2(q);
    }
    return e;
}

// ARM64 code landmarks. Encrypted text contains them at random rate ~2^-32;
// decrypted code has thousands.
static uint32_t fp_code_words(const uint8_t *p, size_t n) {
    uint32_t count = 0;
    for (size_t i = 0; i + 4 <= n; i += 4) {
        uint32_t w;
        memcpy(&w, p + i, 4);
        if (w == 0xd65f03c0 /* ret */ || w == 0xd503237f /* pacibsp */ ||
            w == 0xd65f0fff /* retab */) {
            count++;
        }
    }
    return count;
}

static bool fp_pread_full(int fd, void *buf, size_t n, off_t off) {
    uint8_t *p = buf;
    while (n) {
        ssize_t r = pread(fd, p, n, off);
        if (r <= 0) {
            if (r < 0 && errno == EINTR) continue;
            return false;
        }
        p += r; n -= (size_t)r; off += r;
    }
    return true;
}

static bool fp_pwrite_full(int fd, const void *buf, size_t n, off_t off) {
    const uint8_t *p = buf;
    while (n) {
        ssize_t r = pwrite(fd, p, n, off);
        if (r <= 0) {
            if (r < 0 && errno == EINTR) continue;
            return false;
        }
        p += r; n -= (size_t)r; off += r;
    }
    return true;
}

const char *fp_mode_name(int mode) {
    switch (mode) {
        case FP_MODE_R_CID2: return "READ/cryptid2";
        case FP_MODE_RX_CID1: return "READ|EXEC/cryptid1";
        case FP_MODE_R_CID1: return "READ/cryptid1";
    }
    return "unknown";
}

#pragma mark - parsing

bool fp_is_macho(const char *path) {
    if (!path) return false;
    int fd = open(path, O_RDONLY);
    if (fd < 0) return false;
    uint32_t magic = 0;
    bool ok = fp_pread_full(fd, &magic, sizeof magic, 0);
    close(fd);
    if (!ok) return false;
    return magic == MH_MAGIC_64 || magic == MH_MAGIC || magic == FAT_CIGAM ||
           magic == FAT_CIGAM_64;
}

static int fp_parse_thin(int fd, uint64_t off, uint64_t size, fp_slice_t *s,
                         char *err, size_t errlen) {
    struct mach_header_64 mh;
    if (!fp_pread_full(fd, &mh, sizeof mh, (off_t)off)) {
        snprintf(err, errlen, "short read (header)");
        return -1;
    }
    if (mh.magic != MH_MAGIC_64) {
        snprintf(err, errlen, "unsupported magic 0x%x", mh.magic);
        return -1;
    }
    memset(s, 0, sizeof *s);
    s->slice_off = off;
    s->slice_size = size;
    s->cputype = mh.cputype;
    s->cpusubtype = mh.cpusubtype;
    s->filetype = mh.filetype;
    if (mh.sizeofcmds > 16u * 1024u * 1024u) {
        snprintf(err, errlen, "sizeofcmds too large");
        return -1;
    }
    uint8_t *cmds = malloc(mh.sizeofcmds ? mh.sizeofcmds : 1);
    if (!cmds || !fp_pread_full(fd, cmds, mh.sizeofcmds, (off_t)(off + sizeof mh))) {
        free(cmds);
        snprintf(err, errlen, "short read (load commands)");
        return -1;
    }
    uint32_t pos = 0;
    for (uint32_t i = 0; i < mh.ncmds && pos + 8 <= mh.sizeofcmds; i++) {
        struct load_command *lc = (struct load_command *)(cmds + pos);
        if (lc->cmdsize < 8 || pos + lc->cmdsize > mh.sizeofcmds) break;
        if (lc->cmd == LC_ENCRYPTION_INFO_64 || lc->cmd == LC_ENCRYPTION_INFO) {
            size_t min_size = (lc->cmd == LC_ENCRYPTION_INFO_64)
                ? sizeof(struct encryption_info_command_64)
                : sizeof(struct encryption_info_command);
            if (lc->cmdsize < min_size) break;
            struct encryption_info_command *e = (void *)lc;
            s->has_enc = true;
            s->enc_lc_off = off + sizeof mh + pos;
            s->cryptoff = e->cryptoff;
            s->cryptsize = e->cryptsize;
            s->cryptid = e->cryptid;
        } else if (lc->cmd == LC_CODE_SIGNATURE) {
            if (lc->cmdsize < sizeof(struct linkedit_data_command)) break;
            struct linkedit_data_command *l = (void *)lc;
            s->cs_off = l->dataoff;
            s->cs_size = l->datasize;
        }
        pos += lc->cmdsize;
    }
    free(cmds);
    return 0;
}

int fp_parse(const char *path, fp_slice_t *slices, int max, int *count,
             char *err, size_t errlen) {
    if (!path || !slices || !count || max <= 0) return -1;
    *count = 0;
    int fd = open(path, O_RDONLY);
    if (fd < 0) {
        snprintf(err, errlen, "open: %s", strerror(errno));
        return -1;
    }
    struct stat st;
    if (fstat(fd, &st) != 0) {
        snprintf(err, errlen, "stat: %s", strerror(errno));
        close(fd);
        return -1;
    }
    uint32_t magic = 0;
    if (!fp_pread_full(fd, &magic, 4, 0)) {
        snprintf(err, errlen, "short read");
        close(fd);
        return -1;
    }
    int rc = 0;
    if (magic == FAT_CIGAM || magic == FAT_CIGAM_64) {
        bool is64 = (magic == FAT_CIGAM_64);
        struct fat_header fh;
        if (!fp_pread_full(fd, &fh, sizeof fh, 0)) {
            snprintf(err, errlen, "short read (fat header)");
            close(fd);
            return -1;
        }
        uint32_t n = OSSwapBigToHostInt32(fh.nfat_arch);
        if (n > 64) n = 64;
        uint64_t p = sizeof fh;
        for (uint32_t i = 0; i < n && *count < max; i++) {
            uint64_t o = 0, sz = 0;
            uint32_t ct = 0;
            if (is64) {
                struct fat_arch_64 fa;
                if (!fp_pread_full(fd, &fa, sizeof fa, (off_t)p)) break;
                p += sizeof fa;
                o = OSSwapBigToHostInt64(fa.offset);
                sz = OSSwapBigToHostInt64(fa.size);
                ct = OSSwapBigToHostInt32(fa.cputype);
            } else {
                struct fat_arch fa;
                if (!fp_pread_full(fd, &fa, sizeof fa, (off_t)p)) break;
                p += sizeof fa;
                o = OSSwapBigToHostInt32(fa.offset);
                sz = OSSwapBigToHostInt32(fa.size);
                ct = OSSwapBigToHostInt32(fa.cputype);
            }
            if (!(ct & CPU_ARCH_ABI64)) continue; // 32-bit slices never execute here
            if (st.st_size < 0 || o > (uint64_t)st.st_size || sz > (uint64_t)st.st_size - o) continue;
            char detail[128] = {0};
            if (fp_parse_thin(fd, o, sz, &slices[*count], detail, sizeof detail) == 0) {
                (*count)++;
            }
        }
    } else if (magic == MH_MAGIC_64) {
        rc = fp_parse_thin(fd, 0, (uint64_t)st.st_size, &slices[0], err, errlen);
        if (rc == 0) *count = 1;
    } else {
        snprintf(err, errlen, "not a 64-bit Mach-O (magic 0x%08x)", magic);
        rc = -1;
    }
    close(fd);
    return rc;
}

#pragma mark - attempt

bool fp_attempt_looks_decrypted(const fp_attempt_t *a) {
    // Encrypted text stays at ~8.0 bits/byte regardless of size; real ARM64
    // code is well below 7.5. One extra RET/PACIBSP word is enough for a
    // single-page binary.
    return a->mremap_ret == 0 && a->pages_ok == a->pages_total && a->changed &&
           a->ent_before > 7.9 && a->ent_after < 7.5 && a->ret_after > a->ret_before;
}

void fp_attempt_describe(const fp_attempt_t *a, char *buf, size_t len) {
    snprintf(buf, len,
             "%s%s mremap=%d(%s) mmap=%s pages=%llu/%llu changed=%d "
             "code %u->%u entropy %.2f->%.2f %.0fms",
             fp_mode_name(a->mode), a->addsigs ? "+sigs" : "",
             a->mremap_ret,
             a->mremap_ret == 0 ? "ok" : strerror(a->mremap_errno ? a->mremap_errno : EINVAL),
             a->mmap_errno ? strerror(a->mmap_errno) : "ok",
             (unsigned long long)a->pages_ok, (unsigned long long)a->pages_total,
             a->changed ? 1 : 0, a->ret_before, a->ret_after,
             a->ent_before, a->ent_after, a->ms);
}

int fp_attempt(const char *path, const fp_slice_t *s, int mode, bool addsigs,
               uint8_t *out, fp_attempt_t *res) {
    if (!path || !s || !res) return -1;
    memset(res, 0, sizeof *res);
    res->mode = mode;
    res->addsigs = addsigs;
    res->mremap_ret = -1;
    res->mmap_errno = 0;
    res->sig_errno = 0;
    double t0 = fp_now_ms();

    int pg = getpagesize();
    if (pg <= 0) { res->mmap_errno = EINVAL; return -1; }
    const uint64_t page = (uint64_t)pg;
    if (!s->has_enc || s->cryptsize == 0) return -1;
    if (s->slice_off % page) { res->mmap_errno = EINVAL; return -1; }
    if (s->cryptoff % page) { res->mremap_errno = EINVAL; return -1; }

    int fd = open(path, O_RDONLY);
    if (fd < 0) { res->mmap_errno = errno; return -1; }

    struct stat st;
    if (fstat(fd, &st) != 0 || st.st_size < 0) {
        res->mmap_errno = errno ? errno : EINVAL;
        close(fd);
        return -1;
    }
    uint64_t fsz = (uint64_t)st.st_size;
    if (s->slice_off > fsz || s->slice_size > fsz - s->slice_off ||
        (uint64_t)s->cryptoff > s->slice_size ||
        (uint64_t)s->cryptsize > s->slice_size - (uint64_t)s->cryptoff) {
        res->mmap_errno = EINVAL;
        close(fd);
        return -1;
    }

    if (addsigs && s->cs_size &&
        (uint64_t)s->cs_off <= s->slice_size &&
        (uint64_t)s->cs_size <= s->slice_size - (uint64_t)s->cs_off) {
        fsignatures_t fs = {
            .fs_file_start = (off_t)s->slice_off,
            .fs_blob_start = (void *)(uintptr_t)s->cs_off,
            .fs_blob_size = s->cs_size,
        };
        if (fcntl(fd, F_ADDFILESIGS_RETURN, &fs) == -1) res->sig_errno = errno;
    }

    uint64_t crypt_end = (uint64_t)s->cryptoff + (uint64_t)s->cryptsize;
    if (crypt_end > UINT64_MAX - (page - 1)) {
        res->mmap_errno = EOVERFLOW;
        close(fd);
        return -1;
    }
    uint64_t map_len = (crypt_end + page - 1) & ~(page - 1);
    if (map_len == 0 || map_len > SIZE_MAX || (uint64_t)s->cryptsize > SIZE_MAX) {
        res->mmap_errno = EOVERFLOW;
        close(fd);
        return -1;
    }
    int prot = PROT_READ | (mode == FP_MODE_RX_CID1 ? PROT_EXEC : 0);
    uint8_t *base = mmap(NULL, (size_t)map_len, prot, MAP_PRIVATE, fd, (off_t)s->slice_off);
    if (base == MAP_FAILED) {
        res->mmap_errno = errno;
        close(fd);
        res->ms = fp_now_ms() - t0;
        return -1;
    }

    uint8_t *original = malloc(s->cryptsize);
    uint8_t *plain = out ? out : malloc(s->cryptsize);
    if (!original || !plain ||
        !fp_pread_full(fd, original, s->cryptsize, (off_t)(s->slice_off + s->cryptoff))) {
        free(original);
        if (!out) free(plain);
        munmap(base, (size_t)map_len);
        close(fd);
        res->mmap_errno = EIO;
        res->ms = fp_now_ms() - t0;
        return -1;
    }

    uint32_t cryptid = (mode == FP_MODE_R_CID2) ? 2 : 1;
    errno = 0;
    res->mremap_ret = fp_mremap_encrypted(base + s->cryptoff, s->cryptsize, cryptid,
                                          s->cputype, s->cpusubtype);
    res->mremap_errno = res->mremap_ret == 0 ? 0 : errno;

    if (res->mremap_ret == 0) {
        // vm_read_overwrite turns a failed page-in (FairPlay refused this page)
        // into a kern_return_t instead of a SIGBUS.
        uint64_t total = ((uint64_t)s->cryptsize + page - 1) / page;
        res->pages_total = total;
        for (uint64_t i = 0; i < total; i++) {
            uint64_t off = i * page;
            uint64_t n = (off + page <= s->cryptsize) ? page : (s->cryptsize - off);
            vm_size_t got = 0;
            kern_return_t kr = vm_read_overwrite(
                mach_task_self(), (vm_address_t)(base + s->cryptoff + off), (vm_size_t)n,
                (vm_address_t)(plain + off), &got);
            if (kr == KERN_SUCCESS && got == n) {
                res->pages_ok++;
            } else {
                if (!res->first_fail_kr) {
                    res->first_fail_kr = kr ? (int)kr : -1;
                    res->first_fail_off = s->cryptoff + off;
                }
                memset(plain + off, 0, (size_t)n);
            }
        }
        res->changed = memcmp(original, plain, s->cryptsize) != 0;
        res->ret_after = fp_code_words(plain, s->cryptsize);
        res->ent_after = fp_entropy(plain, s->cryptsize);
    }

    res->ret_before = fp_code_words(original, s->cryptsize);
    res->ent_before = fp_entropy(original, s->cryptsize);

    free(original);
    if (!out) free(plain);
    munmap(base, (size_t)map_len);
    close(fd);
    res->ms = fp_now_ms() - t0;
    return (res->mremap_ret == 0 && res->pages_ok == res->pages_total && res->changed) ? 0 : -1;
}

#pragma mark - decrypt to file

static int fp_copy_file(const char *src, const char *dst) {
    int in = open(src, O_RDONLY);
    if (in < 0) return -1;
    struct stat st;
    if (fstat(in, &st) != 0) { close(in); return -1; }
    int out = open(dst, O_WRONLY | O_CREAT | O_TRUNC, (st.st_mode & 0777) | 0600);
    if (out < 0) { close(in); return -1; }
    uint8_t *buf = malloc(1 << 20);
    if (!buf) { close(in); close(out); return -1; }
    ssize_t r;
    int rc = 0;
    while ((r = read(in, buf, 1 << 20)) > 0) {
        if (write(out, buf, (size_t)r) != r) { rc = -1; break; }
    }
    if (r < 0) rc = -1;
    free(buf);
    close(in);
    close(out);
    if (rc != 0) unlink(dst);
    return rc;
}

int fp_decrypt_file(const char *in_path, const char *out_path, fp_log_t log, void *ctx) {
    if (!in_path || !out_path) return -1;
    fp_slice_t slices[FP_MAX_SLICES];
    int count = 0;
    char err[256] = {0};
    if (fp_parse(in_path, slices, FP_MAX_SLICES, &count, err, sizeof err) != 0) {
        fp_log(log, ctx, "  parse failed: %s", err);
        return -1;
    }

    bool encrypted = false;
    for (int i = 0; i < count; i++) {
        if (slices[i].has_enc && slices[i].cryptid != 0) encrypted = true;
    }
    if (!encrypted) {
        if (strcmp(in_path, out_path) != 0 && fp_copy_file(in_path, out_path) != 0) return -1;
        return 1;
    }
    if (strcmp(in_path, out_path) != 0 && fp_copy_file(in_path, out_path) != 0) {
        fp_log(log, ctx, "  copy failed: %s", strerror(errno));
        return -1;
    }

    int out = open(out_path, O_RDWR);
    if (out < 0) {
        fp_log(log, ctx, "  open output: %s", strerror(errno));
        return -1;
    }

    // The READ/cryptid2 attempt is the one that works without PROT_EXEC; the
    // others are fallbacks for releases where the model-encryption path is not
    // reachable.
    const struct { int mode; bool addsigs; } order[] = {
        {FP_MODE_R_CID2, false},
        {FP_MODE_R_CID2, true},
        {FP_MODE_RX_CID1, false},
        {FP_MODE_RX_CID1, true},
    };

    int rc = 0;
    for (int i = 0; i < count && rc == 0; i++) {
        const fp_slice_t *s = &slices[i];
        if (!s->has_enc || s->cryptid == 0) continue;
        uint8_t *plain = malloc(s->cryptsize);
        if (!plain) { rc = -1; break; }
        bool done = false;
        for (size_t k = 0; k < sizeof order / sizeof order[0] && !done; k++) {
            fp_attempt_t attempt;
            char line[512];
            fp_attempt(in_path, s, order[k].mode, order[k].addsigs, plain, &attempt);
            fp_attempt_describe(&attempt, line, sizeof line);
            done = fp_attempt_looks_decrypted(&attempt);
            fp_log(log, ctx, "  slice[%d] %s %s", i, done ? "[OK]" : "[--]", line);
        }
        if (!done) { free(plain); rc = -1; break; }
        uint32_t zero = 0;
        if (!fp_pwrite_full(out, plain, s->cryptsize, (off_t)(s->slice_off + s->cryptoff)) ||
            !fp_pwrite_full(out, &zero, 4,
                            (off_t)(s->enc_lc_off + offsetof(struct encryption_info_command, cryptid)))) {
            fp_log(log, ctx, "  write failed: %s", strerror(errno));
            rc = -1;
        }
        free(plain);
    }
    close(out);
    if (rc != 0 && strcmp(in_path, out_path) != 0) unlink(out_path);
    return rc;
}
