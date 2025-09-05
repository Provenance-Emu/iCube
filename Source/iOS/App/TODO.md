# TODO.md

## tvOS

### Bugs

- [X] If multiple sources found, and click cancle, still tries to boot game
- [ ] Crash in Settings > Controllers > GameCube/Wii > Configure on tvOS (Could not find a storyboard named 'ButtonMapping' in bundle NSBundle)

### WebDav

- [X] RVZ over network broken import
- [X] RVZ over network broken playing

### Save States

- [ ] New UI needs testing
- [ ] Boot to savestate

### Game Info page

- [X] UI need improvements

## iOS

- [ ] touch cursor control doesn't work

## All Platforms

- [X] FF / Pause menu gestures are wrong / conflicting
- [ ] Remove extra logging when done
- [ ] Excessive webdav refreshes
- [ ] Re-test all 4 paddels fast forward

### New Feature?

- [ ] AirPlay from iOS
- [ ] Automatically discover other dolphin webdav's via bonjour

## Graphics (Vulkan/MoltenVK 1.4)

- [X] Baseline/API bump
  - [X] Query `vkEnumerateInstanceVersion`, prefer Vulkan 1.4, fallback to 1.3.
  - [ ] Chain `VkPhysicalDeviceVulkan14Features` (+ any 1.3 structs still needed) into device `pNext` and enable supported bits.
- [X] Enable/guard new extensions (runtime feature checks, graceful fallback)
  - [ ] `VK_KHR_dynamic_rendering_local_read`
  - [X] `VK_KHR_present_id` + `VK_KHR_present_id2` (present IDs plumbed)
  - [ ] `VK_KHR_present_wait` + `VK_KHR_present_wait2`
  - [ ] `VK_KHR_shader_float_controls2`
  - [X] `VK_KHR_line_rasterization` (or `VK_EXT_line_rasterization` as fallback)
  - [ ] `VK_KHR_global_priority` (HIGH, fallback to default)
  - [X] `VK_KHR_maintenance5` and `VK_KHR_maintenance8`
- [~] Swapchain pacing
  - [X] Plumb present IDs (`vkQueuePresentKHR`)
  - [ ] Use `vkWaitForPresentKHR` when `present_wait(2)` is supported.
  - [X] Keep existing CPU-based vsync as fallback.
- [ ] Dynamic rendering + local read integration
  - [ ] Where we perform EFB/RT copies or peeks within a render pass, switch to dynamic rendering and use local-read to avoid resolves/layout transitions on tile memory.
  - [ ] Validate attachment formats vs dynamic rendering (MoltenVK bug fixed; re-test).
- [ ] Shader pipeline/toolchain
  - [ ] Request RTE rounding for FP16/FP32 via `shaderFloatControls2` where exposed.
  - [ ] Update SPIRV-Cross options: target MSL 3.2 when available, disable `fast::normalize` for half, enable precise transcendentals, respect fast‑math decorations.
  - [ ] Rebuild pipeline cache keys to include float controls/rounding where relevant; measure cache hit rate (MoltenVK fix claims fewer misses).
- [ ] Line rasterization
  - [ ] If we render any diagnostic/UI lines, opt into parallelogram lines via KHR/EXT; otherwise skip.
- [ ] MVK configuration API
  - [ ] If we call `vkSetMoltenVKConfigurationMVK()` / `vkGetPhysicalDeviceMetalFeaturesMVK()`, explicitly enable `VK_MVK_moltenvk` first (now required). Keep behind runtime checks.
- [ ] Robustness/QA
  - [ ] Run device matrix: iPhone (A14–A18), iPad (M1–M4), Apple TV 4K (A12/A15), Intel/AMD Macs if applicable.
  - [ ] Scenarios: GC/Wii boot, EFB copies (copy/peek), stereo/dual-source blending paths, MSAA on/off, shader cache warm/cold.
  - [ ] Measure: frametime p95/p99, GPU time, present-to-present latency with and without `present_wait`.
  - [ ] Compare visual correctness: float controls on/off, EQ of transcendentals, FP16 diffs.
- [X] Rollout plan
  - [X] Land behind feature probes; keep 1.3/legacy path.
  - [ ] Gate present-wait by a setting if needed (debug toggle), default on when supported.
  - [ ] File follow-ups for any MoltenVK regressions.

- [X] Logging
  - [X] Add one-shot summary after device creation listing API and enabled instance/device extensions.
