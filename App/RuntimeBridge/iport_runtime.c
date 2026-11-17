/* SPDX-License-Identifier: GPL-3.0-or-later */
/*
 * iport_runtime.c — see include/iport_runtime.h.
 *
 * With IPORT_WITH_WINE this forwards to Playport's wine_host.h (session),
 * host_io.h (pads, focus, keys) and Madeira's display shim, all compiled from
 * vendor/playport and Runtime/src into the same static library
 * (project.runtime.yml). Without it, the stubs at the bottom.
 */
#include "iport_runtime.h"

#include <stdio.h>
#include <string.h>
#include <unistd.h>

/* csops(2): the code-signing status of a process. CS_DEBUGGED is set once a
 * debugger has attached (what lets iOS map writable+executable memory). */
#define CS_OPS_STATUS 0
#define CS_DEBUGGED 0x10000000
extern int csops(pid_t pid, unsigned int ops, void *useraddr, size_t usersize);

int iport_jit_enabled(void) {
    uint32_t flags = 0;
    if (csops(getpid(), CS_OPS_STATUS, &flags, sizeof flags) != 0) return 0;
    return (flags & CS_DEBUGGED) ? 1 : 0;
}

#ifdef IPORT_WITH_WINE

#include <stdlib.h>
#include "wine_host.h"
#include "host_io.h"
#include "session_protocol.h"   /* PP_CONTROL_PAUSE / RESUME / CLOSE */

/* Madeira's IOSDisplayShim / Winios (staged source): the CAMetalLayer the
 * guest's swap chains present to. */
extern void madeira_display_set_layer(void *layer);
/* Winios.m: a virtual key into the focused window's queue. */
extern void winios_post_key(int vk, int down);

static int started;

int iport_runtime_available(void) { return 1; }

const char *iport_runtime_describe(void) {
    static char buf[64];
    snprintf(buf, sizeof buf, "wine_host ABI %d", wine_host_abi_version());
    return buf;
}

static void set_err(char *err, size_t len, const char *fmt, int rc) {
    if (err && len) snprintf(err, len, fmt, rc);
}

int iport_runtime_start(const char *runtime_dir, const char *prefix_dir, const char *log_path,
                        size_t jit_pool_mb, int jit_wait_ms, iport_log_fn log, char *err, size_t errlen) {
    if (started) { set_err(err, errlen, "already started (%d)", 0); return -13; }
    void *rx = NULL, *rw = NULL;
    size_t size = (jit_pool_mb ? jit_pool_mb : 896) << 20;
    int rc = wine_host_jit_pool_acquire(log_path, size, jit_wait_ms, &rx, &rw);
    if (rc != 0) {
        set_err(err, errlen, rc == -2 ? "JIT is not enabled: no debugger attached (%d). Enable JIT with StikDebug or LiveContainer."
                                      : "the JIT pool could not be made (%d)", rc);
        return -11;
    }
    char report[512];
    int sc = wine_host_selfcheck(rx, rw, size, report, sizeof report);
    if (sc != 0 && log) log(report);

    wine_host_config cfg;
    memset(&cfg, 0, sizeof cfg);
    cfg.abi_version = WINE_HOST_ABI_VERSION;
    cfg.runtime_dir = runtime_dir;
    cfg.prefix_dir = prefix_dir;
    cfg.log_path = log_path;
    cfg.log = log;
    cfg.jit_rx = rx;
    cfg.jit_rw = rw;
    cfg.jit_size = size;
    if ((rc = wine_host_init(&cfg)) != 0) { set_err(err, errlen, "Wine could not start (%d)", rc); return -12; }
    if ((rc = wine_host_session_start(60000)) != 0) {
        set_err(err, errlen, "the Wine session did not start (%d)", rc);
        return -13;
    }
    started = 1;
    return 0;
}

int iport_runtime_launch(const char *dos_path, const char *const *args, int nargs,
                         const char *const *env, int nenv, const char *dll_overlay) {
    if (!started) return -1;
    /* wine_host reads the overlay list when it links system32 for the launch. */
    if (dll_overlay && *dll_overlay) setenv("PLAYPORT_DLL_OVERLAY", dll_overlay, 1);
    else unsetenv("PLAYPORT_DLL_OVERLAY");
    return wine_host_session_launch(dos_path, args, nargs, env, nenv, 30000);
}

int iport_runtime_wait(int timeout_ms, int *exit_code) {
    if (!started) return -1;
    int code = 0;
    int rc = wine_host_session_wait(timeout_ms, &code);
    if (rc == 0 && exit_code) *exit_code = code;
    return rc;
}


int iport_runtime_suspend(int on) {
    if (!started) return -1;
    unsigned n = 0;
    return wine_host_session_control(on ? PP_CONTROL_PAUSE : PP_CONTROL_RESUME, 0, 5000, &n);
}

int iport_runtime_quit(int grace_ms) {
    if (!started) return -1;
    unsigned n = 0;
    if (grace_ms < 0) grace_ms = 0;
    if (grace_ms > (int)PP_CONTROL_MAX_WAIT_MS) grace_ms = (int)PP_CONTROL_MAX_WAIT_MS;
    return wine_host_session_control(PP_CONTROL_CLOSE, (unsigned)grace_ms, grace_ms + 5000, &n);
}

void iport_display_set_layer(void *layer) { madeira_display_set_layer(layer); }
void *iport_display_windows_layer(void) { return winios_windows_layer(); }
void iport_focus(int active) { winios_post_focus(active ? 1 : 0); }

void iport_pad_set(int slot, const iport_pad *s) {
    hio_pad_state st = { s->buttons, s->left_trigger, s->right_trigger,
                         s->thumb_lx, s->thumb_ly, s->thumb_rx, s->thumb_ry };
    host_pad_set(slot, &st);
}
void iport_pad_disconnect(int slot) { host_pad_disconnect(slot); }
int iport_pads_release_all(void) { return host_pads_release_all(); }
void iport_key(int vk, int down) { winios_post_key(vk, down); }

#else /* no runtime in this build */

int iport_runtime_available(void) { return 0; }
const char *iport_runtime_describe(void) { return "none"; }

int iport_runtime_start(const char *runtime_dir, const char *prefix_dir, const char *log_path,
                        size_t jit_pool_mb, int jit_wait_ms, iport_log_fn log, char *err, size_t errlen) {
    (void)runtime_dir; (void)prefix_dir; (void)log_path; (void)jit_pool_mb; (void)jit_wait_ms; (void)log;
    if (err && errlen) snprintf(err, errlen, "This build has no Windows runtime. Build with `make runtime && make ipa RUNTIME=1`.");
    return -10;
}
int iport_runtime_launch(const char *d, const char *const *a, int na, const char *const *e, int ne, const char *o) {
    (void)d; (void)a; (void)na; (void)e; (void)ne; (void)o; return -1;
}
int iport_runtime_wait(int t, int *c) { (void)t; if (c) *c = 0; return -1; }
int iport_runtime_suspend(int on) { (void)on; return -1; }
int iport_runtime_quit(int g) { (void)g; return -1; }
void iport_display_set_layer(void *l) { (void)l; }
void *iport_display_windows_layer(void) { return NULL; }
void iport_focus(int a) { (void)a; }
void iport_pad_set(int s, const iport_pad *p) { (void)s; (void)p; }
void iport_pad_disconnect(int s) { (void)s; }
int iport_pads_release_all(void) { return 0; }
void iport_key(int vk, int down) { (void)vk; (void)down; }

#endif
