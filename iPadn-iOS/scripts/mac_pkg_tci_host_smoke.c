// Host-run smoke test for the exact no-JIT TCI fork used by the iPhone probe.
// No Apple proprietary frameworks, auth tokens, or Mac App Store packages.
#include <inttypes.h>
#include <stdint.h>
#include <stdio.h>
#include <string.h>
#include <unicorn/unicorn.h>

#define REQUIRE_OK(expr, label) do { \
    uc_err checked = (expr); \
    if (checked != UC_ERR_OK) { \
        fprintf(stderr, "%s: %s (%d)\\n", label, uc_strerror(checked), checked); \
        goto fail; \
    } \
} while (0)

struct shim_trace {
    unsigned int callbacks;
    uint64_t address;
    int hook_error;
};

static void shim_callback(uc_engine *uc, uint64_t address, uint32_t size, void *opaque) {
    struct shim_trace *trace = (struct shim_trace *)opaque;
    trace->callbacks++;
    trace->address = address;
    if (size == 0) trace->hook_error = 1;
    // Mimic a StoreAgent framework shim: a native host function services a
    // guest x86-64 call and modifies the guest return register.
    uint64_t value = 0x5678;
    if (uc_reg_write(uc, UC_X86_REG_RAX, &value) != UC_ERR_OK) {
        trace->hook_error = 2;
    }
}

int main(void) {
    uc_engine *uc = NULL;
    uc_hook hook;
    uint64_t rax = 0;
    uint64_t rsp = 0x3fff00;
    struct shim_trace trace = {0};
    // mov rax,0x1234 ; call 0x101000 ; add rax,7
    // Guest shim at 0x101000 contains a single RET instruction.
    const uint8_t code[] = {
        0x48, 0xc7, 0xc0, 0x34, 0x12, 0x00, 0x00,
        0xe8, 0xf4, 0x0f, 0x00, 0x00,
        0x48, 0x83, 0xc0, 0x07
    };
    const uint8_t ret[] = {0xc3};
    const uint64_t guest_code = 0x100000;
    const uint64_t guest_shim = 0x101000;

    REQUIRE_OK(uc_open(UC_ARCH_X86, UC_MODE_64, &uc), "open x86-64 TCI");
    // Match key StoreAgent guest memory layout: scratch, heap, stack and
    // high x86-64 framework addresses. Mapping alone does not execute Apple code.
    REQUIRE_OK(uc_mem_map(uc, guest_code, 0x2000, UC_PROT_ALL), "map guest executable");
    REQUIRE_OK(uc_mem_map(uc, 0x0000100000000000ULL, 0x1000, UC_PROT_ALL), "map framework");
    REQUIRE_OK(uc_mem_map(uc, 0x0000300000000000ULL, 32ULL << 20, UC_PROT_ALL), "map scratch");
    REQUIRE_OK(uc_mem_map(uc, 0x0000400000000000ULL, 64ULL << 20, UC_PROT_ALL), "map heap");
    REQUIRE_OK(uc_mem_map(uc, 0x0000500000000000ULL, 8ULL << 20, UC_PROT_ALL), "map stack");
    REQUIRE_OK(uc_mem_map(uc, 0x003ff000, 0x1000, UC_PROT_ALL), "map smoke stack");
    REQUIRE_OK(uc_mem_write(uc, guest_code, code, sizeof(code)), "write guest x86 code");
    REQUIRE_OK(uc_mem_write(uc, guest_shim, ret, sizeof(ret)), "write shim RET");
    REQUIRE_OK(uc_reg_write(uc, UC_X86_REG_RSP, &rsp), "set stack pointer");
    REQUIRE_OK(uc_hook_add(uc, &hook, UC_HOOK_CODE, shim_callback, &trace,
                           guest_shim, guest_shim), "add guest service callback");
    REQUIRE_OK(uc_emu_start(uc, guest_code, guest_code + sizeof(code), 500000, 64),
               "execute x86 shim call");
    REQUIRE_OK(uc_reg_read(uc, UC_X86_REG_RAX, &rax), "read x86 result");
    if (rax != 0x567f || trace.callbacks != 1 || trace.address != guest_shim ||
        trace.hook_error != 0) {
        fprintf(stderr, "FAILED: RAX=0x%" PRIx64 " callbacks=%u address=0x%" PRIx64
                        " callback_error=%d\\n",
                rax, trace.callbacks, trace.address, trace.hook_error);
        goto fail;
    }
    // Verify round-trip guest memory in the high-address region.
    uint64_t high_value = 0xAABBCCDDEEFF1122ULL;
    uint64_t read_value = 0;
    REQUIRE_OK(uc_mem_write(uc, 0x0000300000000000ULL, &high_value,
                            sizeof(high_value)), "high-address write");
    REQUIRE_OK(uc_mem_read(uc, 0x0000300000000000ULL, &read_value,
                           sizeof(read_value)), "high-address read");
    if (high_value != read_value) {
        fprintf(stderr, "FAILED: high-address memory round-trip mismatch\\n");
        goto fail;
    }
    REQUIRE_OK(uc_hook_del(uc, hook), "unregister shim hook");
    REQUIRE_OK(uc_close(uc), "close interpreter");
    puts("PASS: no-JIT TCI x86-64 CALL/RET hook, 100 MiB guest mapping and high virtual address memory");
    return 0;
fail:
    if (uc) uc_close(uc);
    return 1;
}
