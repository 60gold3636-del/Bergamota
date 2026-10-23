/*
 * adreno_uc_test: exercises the SweetAdreno630 user client (docs/GPU_KERNEL.md) without Mesa.
 * Needs a kernel booted with sweetgpu=8 whose log shows "SweetAdreno630 published".
 *
 *   gpu/kernel-test/build.sh            -> out/adreno_uc_test (arm64e, stripped of PAC and ad-hoc signed by renegade)
 *   scp out/adreno_uc_test root@192.168.7.2:/usr/local/bin/ ; ssh root@192.168.7.2 /usr/local/bin/adreno_uc_test
 *
 * Steps (each prints PASS/FAIL; exit status = number of failures):
 *   1 open service, INFO (abi version, ready)      5 GEM_INFO GET_IOVA/GET_OFFSET + map into this task
 *   2 GET_PARAM chip id, GMEM size, GPU id, VA     6 CP_NOP + CP_MEM_WRITE (direct address) + CP_MEM_WRITE (address via
 *   3 GEM_NEW, error paths (bad handle, size 0)       relocation) through GEM_SUBMIT, WAIT_FENCE, CPU_PREP, check the BO
 *   4 SUBMITQUEUE_NEW / CLOSE                      7 second submit (fence order), poll wait, GEM_CLOSE, INFO again
 * Add "-v" for the raw numbers.
 */
#include <IOKit/IOKitLib.h>
#include <mach/mach.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>
#include "../../xnu/gpu-abi/sweet_adreno_abi.h"

static int g_fail, g_verbose;
#define CHECK(cond, ...) do { if (cond) { printf("PASS  "); } else { printf("FAIL  "); g_fail++; } printf(__VA_ARGS__); printf("\n"); } while (0)

static io_connect_t g_conn;

static kern_return_t
call(uint32_t sel, void *s, size_t in, size_t out)
{
	size_t o = out;
	return IOConnectCallStructMethod(g_conn, sel, s, in, out ? s : NULL, out ? &o : NULL);
}

static uint32_t
parity(uint32_t v)
{
	v ^= v >> 16; v ^= v >> 8; v ^= v >> 4; v ^= v >> 2; v ^= v >> 1;
	return (v & 1) ^ 1;     /* odd-parity bit as in Linux pm4_calc_odd_parity_bit() */
}

static uint32_t
pkt7(uint32_t opcode, uint32_t cnt)
{
	return 0x70000000u | cnt | (parity(cnt) << 15) | ((opcode & 0x7f) << 16) | (parity(opcode) << 23);
}

static kern_return_t
get_param(uint32_t p, uint64_t *v)
{
	struct sweet_msm_param a = { .pipe = SWEET_MSM_PIPE_3D0, .param = p };
	kern_return_t kr = call(SWEET_GPU_SEL_GET_PARAM, &a, sizeof(a), sizeof(a));
	*v = a.value;
	return kr;
}

/* Read-only register snapshot of the kernel (SWEET_GPU_SEL_DEBUG); index meaning in sweet_adreno_abi.h. */
static void
dump_debug(const char *when)
{
	struct sweet_gpu_debug d;
	memset(&d, 0, sizeof(d));
	kern_return_t kr = call(SWEET_GPU_SEL_DEBUG, &d, 0, sizeof(d));
	printf("DEBUG %s (kr %#x): flags %#x (b0 core readable, b1 lost, b2 ready)\n", when, kr, d.w[0]);
	printf("  GMU: RPMH_POWER_STATE %#x SPTPRAC %#x AHB_FENCE ctrl %#x dropped %#x AO counter %#x%08x KEEPALIVE %u SYSRESET %u HFI %#x HOST_INT %#x\n",
	    d.w[1], d.w[2], d.w[3], d.w[4], d.w[9], d.w[8], d.w[13], d.w[12], d.w[11], d.w[14]);
	printf("  gpucc: GX gdscr %#x (b31 on) gfx3d cbcr %#x (b31 off) CX gdscr %#x\n", d.w[5], d.w[7], d.w[6]);
	printf("  ring: submitted %u completed %u soft WPTR %u\n", d.w[15], d.w[17], d.w[16]);
	printf("  SMMU CB1: FSR %#x FAR %#x%08x FSYNR0 %#x SCTLR %#x; sGFSR %#x sGFSYNR0 %#x\n", d.w[19], d.w[21], d.w[20], d.w[22], d.w[25], d.w[23], d.w[24]);
	if (d.w[0] & 1) {
		printf("  CP: RPTR %u WPTR %u SQE_CNTL %#x STATUS_1 %#x RBBM_STATUS %#x HW_FAULT %#x CP_IRQ %#x PROTECT %#x RBBM_IRQ %#x IB1 %#x%08x rem %u RB_BASE %#x\n",
		    d.w[26], d.w[27], d.w[33], d.w[28], d.w[29], d.w[30], d.w[31], d.w[34], d.w[32], d.w[36], d.w[35], d.w[37], d.w[39]);
	}
}

static struct sweet_msm_timespec
rel(int sec, int nsec)
{
	struct sweet_msm_timespec t = { sec, nsec };
	return t;
}

int
main(int argc, char **argv)
{
	g_verbose = argc > 1 && !strcmp(argv[1], "-v");
	io_service_t svc = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching(SWEET_GPU_SERVICE_NAME));
	CHECK(svc != IO_OBJECT_NULL, "service %s found", SWEET_GPU_SERVICE_NAME);
	if (svc == IO_OBJECT_NULL) {
		printf("is the kernel booted with sweetgpu=8 and did the log say \"SweetAdreno630 published\"?\n");
		return 1;
	}
	kern_return_t kr = IOServiceOpen(svc, mach_task_self(), 0, &g_conn);
	CHECK(kr == KERN_SUCCESS, "IOServiceOpen -> %#x", kr);
	if (kr != KERN_SUCCESS) {
		return 1;
	}

	/* 1 */
	struct sweet_gpu_info info;
	memset(&info, 0, sizeof(info));
	kr = call(SWEET_GPU_SEL_INFO, &info, 0, sizeof(info));
	CHECK(kr == 0 && info.abi_version == SWEET_GPU_ABI_VERSION, "INFO abi %u (want %u) kr %#x", info.abi_version, SWEET_GPU_ABI_VERSION, kr);
	CHECK(info.flags == 1, "INFO flags %#x (1 = ready, 2 = lost) chip %#x va %#llx+%#llx last_fence %u",
	    info.flags, info.chip_id, info.va_start, info.va_size, info.last_fence);
	if (info.flags != 1) {
		return 1;
	}

	dump_debug("at start (GPU idle since boot)");
	/* 2 */
	uint64_t v = 0;
	kr = get_param(SWEET_MSM_PARAM_CHIP_ID, &v);
	CHECK(kr == 0 && v == 0x06030001, "GET_PARAM CHIP_ID %#llx (want 0x06030001)", v);
	kr = get_param(SWEET_MSM_PARAM_GPU_ID, &v);
	CHECK(kr == 0 && v == 630, "GET_PARAM GPU_ID %llu", v);
	kr = get_param(SWEET_MSM_PARAM_GMEM_SIZE, &v);
	CHECK(kr == 0 && v == 0x100000, "GET_PARAM GMEM_SIZE %#llx", v);
	kr = get_param(SWEET_MSM_PARAM_MAX_FREQ, &v);
	CHECK(kr == 0 && v != 0, "GET_PARAM MAX_FREQ %llu Hz", v);
	uint64_t t0 = 0, t1 = 0;
	kr = get_param(SWEET_MSM_PARAM_TIMESTAMP, &t0);
	usleep(1000);
	(void)get_param(SWEET_MSM_PARAM_TIMESTAMP, &t1);
	CHECK(kr == 0 && t1 > t0, "GET_PARAM TIMESTAMP advances: %llu -> %llu (19.2 MHz: ~19200 per ms)", t0, t1);
	kr = get_param(SWEET_MSM_PARAM_VA_START, &v);
	CHECK(kr == 0 && v == 0x80000000ull, "GET_PARAM VA_START %#llx", v);
	kr = get_param(0x7777, &v);
	CHECK(kr != 0, "GET_PARAM unknown -> %#x (expected error)", kr);

	/* 3 */
	struct sweet_msm_gem_new nb = { .size = 0 };
	kr = call(SWEET_GPU_SEL_GEM_NEW, &nb, sizeof(nb), sizeof(nb));
	CHECK(kr != 0, "GEM_NEW size 0 -> %#x (expected error)", kr);
	struct sweet_msm_gem_info bad = { .handle = 0x1234, .info = SWEET_MSM_INFO_GET_IOVA };
	kr = call(SWEET_GPU_SEL_GEM_INFO, &bad, sizeof(bad), sizeof(bad));
	CHECK(kr != 0, "GEM_INFO bad handle -> %#x (expected error)", kr);
	struct sweet_msm_gem_new nb2 = { .size = 16384, .flags = 0 };
	kr = call(SWEET_GPU_SEL_GEM_NEW, &nb2, sizeof(nb2), sizeof(nb2));
	CHECK(kr == 0 && nb2.handle != 0, "GEM_NEW 16384 -> handle %u kr %#x", nb2.handle, kr);
	if (kr != 0) {
		return g_fail ? g_fail : 1;
	}

	/* 4 */
	struct sweet_msm_submitqueue q = { 0 };
	kr = call(SWEET_GPU_SEL_SUBMITQUEUE_NEW, &q, sizeof(q), sizeof(q));
	CHECK(kr == 0 && q.id != 0, "SUBMITQUEUE_NEW id %u", q.id);
	uint32_t qid = q.id;
	kr = call(SWEET_GPU_SEL_SUBMITQUEUE_CLOSE, &qid, sizeof(qid), 0);
	CHECK(kr == 0, "SUBMITQUEUE_CLOSE %u", qid);

	/* 5 */
	struct sweet_msm_gem_info gi = { .handle = nb2.handle, .info = SWEET_MSM_INFO_GET_IOVA };
	kr = call(SWEET_GPU_SEL_GEM_INFO, &gi, sizeof(gi), sizeof(gi));
	uint64_t iova = gi.value;
	CHECK(kr == 0 && iova >= 0x80000000ull && iova < 0x100000000ull && !(iova & 0xfff), "GEM_INFO GET_IOVA %#llx", iova);
	struct sweet_msm_gem_info go = { .handle = nb2.handle, .info = SWEET_MSM_INFO_GET_OFFSET };
	kr = call(SWEET_GPU_SEL_GEM_INFO, &go, sizeof(go), sizeof(go));
	CHECK(kr == 0 && go.value == nb2.handle, "GEM_INFO GET_OFFSET %llu (= handle, the memoryType)", go.value);
	mach_vm_address_t addr = 0;
	mach_vm_size_t size = 0;
	kr = IOConnectMapMemory64(g_conn, (uint32_t)go.value, mach_task_self(), &addr, &size, kIOMapAnywhere | kIOMapWriteCombineCache);
	CHECK(kr == 0 && addr != 0 && size >= 16384, "IOConnectMapMemory64 -> %#llx size %llu kr %#x", (unsigned long long)addr, (unsigned long long)size, kr);
	if (kr != 0) {
		return g_fail ? g_fail : 1;
	}
	volatile uint32_t *bo = (volatile uint32_t *)(uintptr_t)addr;
	CHECK(bo[0] == 0 && bo[4095] == 0, "BO is zero-filled");

	/* 6: command stream at BO+0, targets at BO+0x1000 (direct) and BO+0x1004 (through a relocation) */
	struct sweet_msm_gem_cpu_prep cp = { .handle = nb2.handle, .op = SWEET_MSM_PREP_WRITE, .timeout = rel(1, 0) };
	kr = call(SWEET_GPU_SEL_GEM_CPU_PREP, &cp, sizeof(cp), 0);
	CHECK(kr == 0, "CPU_PREP write (idle BO) kr %#x", kr);
	const uint32_t v1 = 0x5ee70011u, v2 = 0x5ee70022u;
	unsigned n = 0;
	bo[n++] = pkt7(16, 1);                          /* CP_NOP */
	bo[n++] = 0;
	bo[n++] = pkt7(61, 3);                          /* CP_MEM_WRITE addr_lo addr_hi value */
	bo[n++] = (uint32_t)(iova + 0x1000);
	bo[n++] = (uint32_t)((iova + 0x1000) >> 32);
	bo[n++] = v1;
	bo[n++] = pkt7(61, 3);
	unsigned reloc_at = n;
	bo[n++] = 0xdeadbeef;                           /* patched by the kernel: iova(BO) + 0x1004 */
	bo[n++] = 0;
	bo[n++] = v2;
	struct sweet_msm_gem_cpu_fini cf = { .handle = nb2.handle };
	kr = call(SWEET_GPU_SEL_GEM_CPU_FINI, &cf, sizeof(cf), 0);
	CHECK(kr == 0, "CPU_FINI kr %#x", kr);

	struct sweet_msm_gem_submit_reloc rl = { .submit_offset = reloc_at * 4, .or_ = 0, .shift = 0, .reloc_idx = 0, .reloc_offset = 0x1004 };
	struct sweet_msm_gem_submit_bo sb = { .flags = SWEET_MSM_SUBMIT_BO_READ | SWEET_MSM_SUBMIT_BO_WRITE, .handle = nb2.handle };
	struct sweet_msm_gem_submit_cmd sc = { .type = SWEET_MSM_SUBMIT_CMD_BUF, .submit_idx = 0, .submit_offset = 0, .size = n * 4,
		.nr_relocs = 1, .relocs = (uint64_t)(uintptr_t)&rl };
	struct sweet_msm_gem_submit sub = { .nr_bos = 1, .nr_cmds = 1, .bos = (uint64_t)(uintptr_t)&sb, .cmds = (uint64_t)(uintptr_t)&sc };
	kr = call(SWEET_GPU_SEL_GEM_SUBMIT, &sub, sizeof(sub), sizeof(sub));
	CHECK(kr == 0 && sub.fence != 0, "GEM_SUBMIT (NOP + 2x MEM_WRITE, one reloc) -> fence %u kr %#x", sub.fence, kr);
	if (kr != 0) {
		return g_fail ? g_fail : 1;
	}
	CHECK(bo[reloc_at] == (uint32_t)(iova + 0x1004), "relocation patched: %#x (want %#x)", bo[reloc_at], (uint32_t)(iova + 0x1004));
	struct sweet_msm_wait_fence wf = { .fence = sub.fence, .timeout = rel(2, 0) };
	kr = call(SWEET_GPU_SEL_WAIT_FENCE, &wf, sizeof(wf), 0);
	CHECK(kr == 0, "WAIT_FENCE %u kr %#x", sub.fence, kr);
	if (kr != 0) {
		dump_debug("after the WAIT_FENCE failed");
	}
	cp.op = SWEET_MSM_PREP_READ;
	kr = call(SWEET_GPU_SEL_GEM_CPU_PREP, &cp, sizeof(cp), 0);
	CHECK(kr == 0, "CPU_PREP read kr %#x", kr);
	CHECK(bo[0x1000 / 4] == v1, "BO+0x1000 = %#x (want %#x: direct CP_MEM_WRITE)", bo[0x1000 / 4], v1);
	CHECK(bo[0x1004 / 4] == v2, "BO+0x1004 = %#x (want %#x: CP_MEM_WRITE through the relocation)", bo[0x1004 / 4], v2);

	/* 7: a second submission, polled; fences are ordered */
	bo[0x1008 / 4] = 0;
	n = 0;
	bo[n++] = pkt7(61, 3);
	bo[n++] = (uint32_t)(iova + 0x1008);
	bo[n++] = 0;
	bo[n++] = 0xc0ffee00u;
	sc.size = n * 4;
	sc.nr_relocs = 0;
	sc.relocs = 0;
	struct sweet_msm_gem_submit sub2 = sub;
	sub2.fence = 0;
	kr = call(SWEET_GPU_SEL_GEM_SUBMIT, &sub2, sizeof(sub2), sizeof(sub2));
	CHECK(kr == 0 && (int32_t)(sub2.fence - sub.fence) > 0, "second GEM_SUBMIT fence %u > %u kr %#x", sub2.fence, sub.fence, kr);
	wf.fence = sub2.fence;
	wf.timeout = rel(0, 0);
	int polls = 0;
	for (; polls < 2000 && (kr = call(SWEET_GPU_SEL_WAIT_FENCE, &wf, sizeof(wf), 0)) != 0; polls++) {
		usleep(1000);
	}
	CHECK(kr == 0 && bo[0x1008 / 4] == 0xc0ffee00u, "polled WAIT_FENCE done after %d polls, BO+0x1008 = %#x", polls, bo[0x1008 / 4]);
	struct sweet_msm_wait_fence future = { .fence = sub2.fence + 1000, .timeout = rel(0, 0) };
	kr = call(SWEET_GPU_SEL_WAIT_FENCE, &future, sizeof(future), 0);
	CHECK(kr != 0, "WAIT_FENCE on a fence never submitted -> %#x (expected error)", kr);
	sub2.queueid = 63;
	kr = call(SWEET_GPU_SEL_GEM_SUBMIT, &sub2, sizeof(sub2), sizeof(sub2));
	CHECK(kr != 0, "GEM_SUBMIT with an unopened queue id -> %#x (expected error)", kr);

	IOConnectUnmapMemory64(g_conn, (uint32_t)go.value, mach_task_self(), addr);
	struct sweet_gem_close gc = { .handle = nb2.handle };
	kr = call(SWEET_GPU_SEL_GEM_CLOSE, &gc, sizeof(gc), 0);
	CHECK(kr == 0, "GEM_CLOSE kr %#x", kr);
	kr = call(SWEET_GPU_SEL_GEM_CLOSE, &gc, sizeof(gc), 0);
	CHECK(kr != 0, "GEM_CLOSE again -> %#x (expected error)", kr);
	memset(&info, 0, sizeof(info));
	kr = call(SWEET_GPU_SEL_INFO, &info, 0, sizeof(info));
	CHECK(kr == 0 && info.flags == 1 && info.last_fence == sub2.fence, "INFO after the run: flags %#x last_fence %u", info.flags, info.last_fence);
	IOServiceClose(g_conn);
	printf("%s: %d failure(s)\n", g_fail ? "FAILED" : "ALL PASSED", g_fail);
	return g_fail;
}
