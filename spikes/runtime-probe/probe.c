// OpenClaw iOS runtime probe
// Validates the foundational assumptions for running Node/V8 on jailbroken iOS 15 (Dopamine, arm64):
//   1. an ad-hoc (ldid) signed arm64 iOS binary executes at all
//   2. JIT is possible (V8 needs writable+executable code memory) via several strategies
//   3. fork()/exec works (Node child_process; Dopamine forkfix.dylib)
//
// Each risky JIT test runs in a forked child so an AMFI/kernel SIGKILL (code 9) on one
// strategy is *reported* rather than aborting the whole probe.
//
// Build (CI, macОS runner):
//   xcrun --sdk iphoneos clang -arch arm64 -miphoneos-version-min=15.0 \
//         -O0 -o probe probe.c
// Sign on device: ldid -S[ents.plist] probe

#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <stdint.h>
#include <errno.h>
#include <unistd.h>
#include <dlfcn.h>
#include <sys/mman.h>
#include <sys/wait.h>
#include <sys/utsname.h>

#ifndef MAP_JIT
#define MAP_JIT 0x0800
#endif

// arm64 machine code for: int f(void){ return 42; }
//   mov  w0, #42   -> 0x52800540
//   ret            -> 0xd65f03c0
static const uint32_t CODE[] = { 0x52800540, 0xd65f03c0 };
typedef int (*fn_t)(void);

// The SDK marks pthread_jit_write_protect_np "unavailable on iOS", so resolve at
// runtime via dlsym — this both compiles and tells us if the symbol exists on-device.
typedef void (*jit_wp_t)(int);
typedef int  (*jit_wp_supported_t)(void);

static int emit_and_call(void *m) {
    memcpy(m, CODE, sizeof(CODE));
    __builtin___clear_cache((char *)m, (char *)m + sizeof(CODE));
    fn_t f = (fn_t)m;
    return f();
}

// Strategy 1: single mmap with PROT_READ|WRITE|EXEC (classic jailbreak RWX).
static int t_rwx_mmap(void) {
    void *m = mmap(NULL, 4096, PROT_READ | PROT_WRITE | PROT_EXEC,
                   MAP_PRIVATE | MAP_ANON, -1, 0);
    if (m == MAP_FAILED) { fprintf(stderr, "mmap RWX failed: %s\n", strerror(errno)); return 0; }
    int r = emit_and_call(m);
    munmap(m, 4096);
    return r == 42;
}

// Strategy 2: MAP_JIT region toggled with pthread_jit_write_protect_np (Apple hardened-JIT path).
static int t_map_jit(void) {
    jit_wp_t wp = (jit_wp_t)dlsym(RTLD_DEFAULT, "pthread_jit_write_protect_np");
    void *m = mmap(NULL, 4096, PROT_READ | PROT_WRITE | PROT_EXEC,
                   MAP_PRIVATE | MAP_ANON | MAP_JIT, -1, 0);
    if (m == MAP_FAILED) { fprintf(stderr, "mmap MAP_JIT failed: %s\n", strerror(errno)); return 0; }
    if (wp) wp(0); // make writable
    memcpy(m, CODE, sizeof(CODE));
    if (wp) wp(1); // make executable
    __builtin___clear_cache((char *)m, (char *)m + sizeof(CODE));
    int r = ((fn_t)m)();
    munmap(m, 4096);
    return r == 42;
}

// Strategy 3: W^X — mmap RW, write, mprotect to RX, execute.
static int t_wx_mprotect(void) {
    void *m = mmap(NULL, 4096, PROT_READ | PROT_WRITE, MAP_PRIVATE | MAP_ANON, -1, 0);
    if (m == MAP_FAILED) { fprintf(stderr, "mmap RW failed: %s\n", strerror(errno)); return 0; }
    memcpy(m, CODE, sizeof(CODE));
    if (mprotect(m, 4096, PROT_READ | PROT_EXEC) != 0) {
        fprintf(stderr, "mprotect RX failed: %s\n", strerror(errno)); munmap(m, 4096); return 0;
    }
    __builtin___clear_cache((char *)m, (char *)m + sizeof(CODE));
    int r = ((fn_t)m)();
    munmap(m, 4096);
    return r == 42;
}

// Run a test in a child process; report exit vs signal (SIGKILL=9 => AMFI/kernel denied).
static void run_isolated(const char *name, int (*fn)(void)) {
    fflush(stdout); fflush(stderr);
    pid_t p = fork();
    if (p < 0) { printf("  [%-11s] SKIP (fork failed: %s)\n", name, strerror(errno)); return; }
    if (p == 0) { int ok = fn(); _exit(ok ? 42 : 1); }
    int st = 0; waitpid(p, &st, 0);
    if (WIFEXITED(st)) {
        int c = WEXITSTATUS(st);
        printf("  [%-11s] %s (exit %d)\n", name, c == 42 ? "PASS" : "FAIL", c);
    } else if (WIFSIGNALED(st)) {
        int s = WTERMSIG(st);
        printf("  [%-11s] KILLED by signal %d%s\n", name, s, s == 9 ? " (SIGKILL = codesign/AMFI denial)" : "");
    } else {
        printf("  [%-11s] unknown wait status 0x%x\n", name, st);
    }
}

static int t_fork(void) {
    pid_t p = fork();
    if (p < 0) return 0;
    if (p == 0) _exit(7);
    int st = 0; waitpid(p, &st, 0);
    return WIFEXITED(st) && WEXITSTATUS(st) == 7;
}

int main(void) {
    struct utsname u; uname(&u);
    printf("== OpenClaw iOS runtime probe ==\n");
    printf("kernel: %s %s (%s)\n", u.sysname, u.release, u.machine);
    printf("uid=%d euid=%d pid=%d\n", getuid(), geteuid(), getpid());
    printf("[exec] basic execution PASS\n");
    jit_wp_supported_t sup = (jit_wp_supported_t)dlsym(RTLD_DEFAULT, "pthread_jit_write_protect_supported_np");
    printf("[jit ] pthread_jit_write_protect_np present=%d supported=%d\n",
           dlsym(RTLD_DEFAULT, "pthread_jit_write_protect_np") != NULL,
           sup ? sup() : -1);

    printf("[fork] %s\n", t_fork() ? "PASS" : "FAIL");

    printf("JIT strategies (each isolated in a child):\n");
    run_isolated("rwx-mmap",    t_rwx_mmap);
    run_isolated("map-jit",     t_map_jit);
    run_isolated("wx-mprotect", t_wx_mprotect);

    printf("== probe done ==\n");
    return 0;
}
