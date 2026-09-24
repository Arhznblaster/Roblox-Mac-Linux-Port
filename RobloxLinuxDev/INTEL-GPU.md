# Intel GPU support (Arc A750 / DG2, Mesa ANV)

## Portability

All launcher changes are conditional, so behavior is unchanged on non-Intel hosts:

- **NVIDIA hosts:** the GLX detection block matches `nvidia` and exports
  `__GLX_VENDOR_LIBRARY_NAME=nvidia`, byte-identical to the old hardcoded default.
- **AMD hosts:** previously forced `__GLX_VENDOR_LIBRARY_NAME=nvidia` (broken GL
  fallback); now auto-selects `mesa`. This is a bug fix for AMD-only machines too.
- **Vulkan path:** the default (no `ROBLOX_MAC_VK_LOADER`) is unchanged — loader
  enumeration order, which already prefers hardware ICDs over llvmpipe. The knob is
  opt-in and maps to `VK_LOADER_DRIVERS_SELECT`, a no-op on loaders older than 1.3.352.
- **Hybrid laptops (e.g. Intel iGPU + NVIDIA dGPU):** DRM card order decides the GL
  fallback vendor. To restore the previous always-NVIDIA behavior, export
  `__GLX_VENDOR_LIBRARY_NAME=nvidia` before launching (explicit values always win).
- The ICD log line and `RBX_VK_DEBUG` are additive logging only.

Validated end-to-end on Mesa 26.1.5 / ANV / Arc A750 (DG2): device selection,
shader translation, Vulkan swapchain presentation, and stable runtime (no ANV
errors, empty crash log). The stock release AppImage — which embeds the *old*
launcher — also ran on the A750, confirming the renderer was never vendor-gated.

This port has **no vendor blacklist**: it renders through Vulkan 1.3 with whichever
ICD the loader picks. On this machine that is Mesa ANV on the Intel Arc A750 (DG2,
`8086:56a1`, kernel driver `i915`). The renderer, shader translator and presentation
path are GPU-neutral; only the launcher needed Intel-host fixes.

## What was changed

`installed/AppDir/bin/roblox-mac` (mirrored to `RobloxLinuxDev/runtime/bin/roblox-mac`):

1. **GLX vendor no longer hardcoded to `nvidia`.** The old line
   `export __GLX_VENDOR_LIBRARY_NAME=${__GLX_VENDOR_LIBRARY_NAME:-nvidia}` blanked the
   X11/Cocotron GL fallback on Intel-only hosts. It now selects the vendor whose kernel
   driver owns a DRM device (`nvidia` / `mesa`), defaulting to `mesa`. An explicit
   `__GLX_VENDOR_LIBRARY_NAME` in the environment still wins.
2. **Vulkan driver selection knob.** `ROBLOX_MAC_VK_LOADER=intel|amd|swrast|lavapipe`
   maps to `VK_LOADER_DRIVERS_SELECT=<name>_icd.x86_64.json` (loader >= 1.3.352). The
   default (unset) uses the loader's normal enumeration order — ANV (Intel) sorts before
   llvmpipe, so it is chosen automatically.
3. **ICD visibility logging.** Every metal-renderer launch prints the Vulkan ICDs the
   guest can reach, so a "CPU renderer" symptom is diagnosable from the log alone.
4. **Full loader trace on demand.** Set `RBX_VK_DEBUG=1` to export `VK_LOADER_DEBUG=all`.

Nothing was patched in binaries, `libindium.dylib`, the Roblox client, or Roblox data.

## Validation on this machine (all commands run from `installed/`)

```sh
sh run.sh --diagnose          # GPU 0x8086/0x56a1 i915, namespaces, EGL, shader tools: pass
sh run.sh                     # or ./RobloxLinux.AppImage
```

Live-run log evidence (`/tmp/rbx-run*.log`, both via the stock AppImage and the
patched `AppDir/bin/roblox-mac`):

```
roblox-mac: Vulkan ICDs available to the renderer: ... intel_icd.x86_64.json->/usr/lib64/libvulkan_intel.so ...
[FLog::Graphics] Metal renderer: Intel(R) Arc(tm) A750 Graphics (DG2)
Compiled 1256 shaders in 155 ms. ... Shader Loading Threads: 2
Metal presentation: Vulkan swapchain
```

Note: the stock 359 MB `RobloxLinux.AppImage` embeds its own copy of the launcher
script, so AppImage launches do not see the patched `AppDir/bin/roblox-mac`. The
shipped AppImage already worked on the Arc (verified); to use the added knobs and
diagnostics, launch via the extracted directory, e.g.
`APPDIR=$PWD/AppDir AppDir/bin/roblox-mac`, or take them from the next release built
from this tree (`build.sh` packages `runtime/bin/roblox-mac`).

and measurable GPU engine time (DRM fdinfo, works without root):

```sh
PIDS=$(fuser /dev/dri/renderD128 2>/dev/null)
for p in $PIDS; do grep -s drm-engine-render /proc/$p/fdinfo/* \
  2>/dev/null | awk '{s+=$2} END {print FILENAME, s}'; done
```

Observed: game processes (`Main`, comm `mldr` is the Darling loader) accumulating
~300 ms of render-engine time per 12 s at the login screen (idle menu; in-game
utilization is higher). No ANV errors, no device lost, no crashes; `crashes/fatal.log`
stayed 0 bytes.

## Environment knobs (set before launching, or in `config.env`)

| Variable | Values | Effect |
|---|---|---|
| `ROBLOX_MAC_VK_LOADER` | `intel` (recommended), `amd`, `swrast`, `lavapipe` | Force the Vulkan ICD. Unset = auto (Intel wins). |
| `RBX_VK_DEBUG=1` | — | Full Vulkan loader trace in the log. |
| `__GLX_VENDOR_LIBRARY_NAME` | `mesa` / `nvidia` | GL fallback vendor; auto-detected now. |

If you ever see llvmpipe/CPU rendering, launch with
`ROBLOX_MAC_VK_LOADER=intel sh run.sh` and check the `roblox-mac: Vulkan ICDs` line.

## Rollback plan

- **Test process cleanup:** `pkill -f RobloxPlayer` if a backgrounded test run lingers.
- **Launcher (installed tree):**
  ```sh
  cp installed/AppDir/bin/roblox-mac.orig-intel installed/AppDir/bin/roblox-mac
  chmod +x installed/AppDir/bin/roblox-mac
  ```
  The pristine original is kept at `installed/AppDir/bin/roblox-mac.orig-intel`.
- **Dev tree:** `git checkout -- RobloxLinuxDev/runtime/bin/roblox-mac`.
- **Runtime GPU state:** nothing persistent was touched — close the game; the i915/ANV
  stack, ICD manifests, and caches are untouched. Optional: delete
  `DO_NOT_SHARE/vk-pipeline-cache-v1.bin` and `DO_NOT_SHARE/mesa-cache/` to rebuild
  caches from scratch.
- **Verify rollback:** `git diff RobloxLinuxDev/runtime/bin/roblox-mac` prints nothing.

## Troubleshooting quick reference

- **"Metal renderer: llvmpipe"** → `ROBLOX_MAC_VK_LOADER=intel sh run.sh`; confirm
  `intel_icd.x86_64.json` appears in the `roblox-mac: Vulkan ICDs` log line.
- **Stuck on GL fallback** → normal only on X11; on Wayland the log must say
  `Metal presentation: Vulkan swapchain`.
- **GPU hangs (dmesg: `GPU HANG`)** → update Mesa; `ANV_ENABLE_QUEUE_RESET=0` is not
  needed on current Mesa; report `DO_NOT_SHARE/diagnostics/` contents (minus private
  files) upstream.
