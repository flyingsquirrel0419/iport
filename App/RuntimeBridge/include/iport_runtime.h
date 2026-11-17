/* SPDX-License-Identifier: GPL-3.0-or-later */
/*
 * iport_runtime.h — the one C ABI between the iPort app (Swift) and the
 * Windows runtime (Wine + FEX + DXVK/vkd3d-proton/DXMT on KosmicKrisp/Metal).
 *
 * Built two ways (App/RuntimeBridge/iport_runtime.c):
 *   - without IPORT_WITH_WINE (the default, `make ipa`): every call reports
 *     the runtime as absent. The whole app — Steam sign-in, library, the
 *     download manager, the touch controller — builds and runs without it.
 *   - with IPORT_WITH_WINE (`make ipa RUNTIME=1`, after `make runtime`): the
 *     calls go to Playport's wine_host / HostIO / Winios layer, linked
 *     statically from Runtime/ (scripts/build-runtime.sh, scripts/fetch-runtime.sh).
 *
 * Call order, once per app process (Wine keeps one session per process):
 *   iport_runtime_start → iport_runtime_launch → iport_runtime_wait (loop)
 * The pad, focus and display calls may come from the main thread at any time.
 */
#ifndef IPORT_RUNTIME_H
#define IPORT_RUNTIME_H

#include <stddef.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

/* 1 when this build carries the Windows runtime. */
int iport_runtime_available(void);

/* A short description of the linked runtime ("wine_host ABI 12"), or "none". */
const char *iport_runtime_describe(void);

/* 1 when a debugger has the process (CS_DEBUGGED): JIT is possible.
 * StikDebug, LiveContainer's JIT or SideStore's JIT attach one. */
int iport_jit_enabled(void);

typedef void (*iport_log_fn)(const char *line);

/* Acquire the JIT pool (waiting up to jit_wait_ms for a debugger), start
 * Wine's server and the session root. runtime_dir holds aarch64-windows/,
 * arm64ec-windows/, i386-windows/, nls/ (the app bundle). prefix_dir is the
 * writable Wine prefix (created if absent). Returns 0, or a negative step
 * code with err filled: -10 no runtime, -11 JIT, -12 init, -13 session. */
int iport_runtime_start(const char *runtime_dir, const char *prefix_dir, const char *log_path,
                        size_t jit_pool_mb, int jit_wait_ms, iport_log_fn log, char *err, size_t errlen);

/* Start the game: dos_path like "C:\\Games\\Title\\game.exe"; env entries are
 * "NAME=VALUE" for this title only; dll_overlay is the runtime directories whose
 * DLLs go first ("vulkan"), or NULL. 0 started, negative as wine_host_session_launch. */
int iport_runtime_launch(const char *dos_path, const char *const *args, int nargs,
                         const char *const *env, int nenv, const char *dll_overlay);

/* Wait up to timeout_ms for the game to end: 0 it ended (exit_code set),
 * 1 still running, negative on error. */
int iport_runtime_wait(int timeout_ms, int *exit_code);

/* Freeze (1) or thaw (0) the game's threads: the in-game menu's pause. */
int iport_runtime_suspend(int on);

/* Ask the game to close (WM_CLOSE to its windows, then terminate after grace_ms). */
int iport_runtime_quit(int grace_ms);

/* The game view: the CAMetalLayer the swap chain draws to (set once, before
 * the launch), and the CALayer that shows the game's GDI windows until then. */
void iport_display_set_layer(void *metal_layer);
void *iport_display_windows_layer(void);

/* The app is in front (1) or not (0): focus for the game's windows. */
void iport_focus(int active);

/* XInput, value for value. buttons: XINPUT_GAMEPAD_* bits. */
typedef struct {
    uint16_t buttons;
    uint8_t left_trigger, right_trigger;
    int16_t thumb_lx, thumb_ly, thumb_rx, thumb_ry;
} iport_pad;

#define IPORT_PAD_SLOTS 4
void iport_pad_set(int slot, const iport_pad *state);
void iport_pad_disconnect(int slot);
int iport_pads_release_all(void);

/* Keyboard (Windows virtual-key codes) for a hardware keyboard. */
void iport_key(int vk, int down);

#ifdef __cplusplus
}
#endif
#endif
