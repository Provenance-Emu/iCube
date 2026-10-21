# Performance controls in Pause and live tvOS play

**Status:** reviewed proposal; full-description approval requested. No gameplay input changes implemented by this document.

## Intent

The owner wants the pause-menu HUD submenu to provide the useful performance controls already in the iOS popover, and an additional transparent Siri Remote panel to see changes while gameplay continues. Preserve quick access without visiting full Settings. This follows the faster DEV build/test workflow; library editing, sharing and iCube/Provenance sync remain release blockers afterward.

## Requested behavior

- Rename the primary tile to **Performance**, occupying Save States’ current position beside Resume. Move Save States immediately after Quick Save and Quick Load in the options order.
- Selecting Performance opens a full submenu inside the existing pause session. It includes internal resolution, CPU clock override and percentage, VI frequency override and percentage, Adaptive Clock, VI Skip Off/On/Auto, HUD master/statistics toggles and the existing relevant quick controls. Keep CPU Engine clearly labeled as a next-launch choice, separate from live clock tuning.
- Reuse the backend writers and override semantics of the iOS performance popover. Refresh all values on opening, including Adaptive Clock and VI Skip. Game/Auto overrides display their source and a readable disabled reason.
- Resolution zero is labeled **Fit Window**. Fixed scaling and one-time Fit Window remain available. Do not restore the removed controller that repeatedly changes internal resolution during gameplay.
- Provide a second TV-friendly transparent panel that leaves emulation running. It is an additional entry point; the paused Performance pane remains available.

## Remote preference

The owner prefers a user setting because different behaviors for remote and pad buttons may confuse people. Proposed implementation choice: **Siri Remote Menu Button** with **Pause Menu** (default) and **Live Performance**. Store it as an installation-local TV control preference, exposed in Controller settings with a brief explanation. With no available gameplay controller, the remote falls back to Pause. While Live Performance owns the remote, a short Back/Menu closes it. Preserve the existing exit hold and the controller's existing pause shortcut/Start mapping.

## Layout and interaction choices

Reuse the app's readable TV menu styling for the paused pane. Multiple values open explicit choice panels; avoid press-to-cycle lists. In Live Performance, use a compact translucent top panel with a manually highlighted row and remote-only Up/Down/Select/Back routing. Values open a small choice list or bounded percentage adjustment. The gameplay controller continues to control the game, and never changes the live panel's selection. Provide a clearly labeled Pause action to reach the normal menu. Keep the iOS portrait footprint unchanged by this TV work.

## Input and pause ownership

An unassigned remote is not necessarily unmapped: the native input backend enumerates every GCController, and saved expressions can still reference the remote. Therefore `playerIndex == indexUnset` alone cannot guarantee safe live controls.

Add a narrow per-controller native input suppression lease for the owned Siri Remote, covering buttons, axes and motion. The overlay's remote adapter reads physical controls independently; the emulator sees neutral values while the lease is held. Keep the normal gameplay focus trap so the gamepad is not captured by tvOS UI focus. Do not change assignments or persisted bindings. Retain suppression until controls return to neutral when closing, so held inputs do not leak into the game. Remote disconnect or background tears down ownership safely. If the last gameplay controller disconnects while Live Performance is open, acquire/adopt the existing controller-disconnect pause first, close the live panel, then show the normal paused disconnect recovery UI. Never fall through to running remote-driven gameplay. Reconnection follows the existing disconnect-pause rules; closing the panel does not release that pause.

Live open/close acquires no PauseArbiter token and makes no pause/resume calls. Live to Pause claims the pending pause token before transition. Closing Live must never resume a pause held by another reason. Preserve GCController/UIPress duplicate coalescing and opening-release latches. This native input change requires rebuilt engine slices; an app-only cosmetic overlay is insufficient acceptance.

## Implementation structure

Extract a shared snapshot, actions and model builder for quick performance controls from EmulationScreen. Keep backend writes centralized and testable. Render the snapshot in the existing iOS popover, the tvOS Pause pane and the new live remote overlay. Keep live remote navigation state separate from the paused menu's native focus machinery. Tests cover actions, ownership and layout independently.

## Acceptance

1. Both platforms show fresh values and retain existing backend behavior; manual overrides cannot overwrite automatic/game-owned effective values.
2. Performance occupies the old Save States primary position; Save States follows Quick Save/Load; CPU Engine has no conflicting Performance title.
3. tvOS choices are readable and directly selectable; Back returns to Pause without releasing its token.
4. Live panel opens/closes once per remote press, with no pause/resume call. An unrelated pause remains held. Switching to Pause never exposes a running frame between ownership changes.
5. Native tests prove remote reads neutral while leased, gameplay pad reads unchanged, closing waits for neutral, and disconnect releases safely.
6. Real TV controller+remote acceptance proves game frames advance during tuning and gamepad movement does not navigate the panel. Simulator screenshots alone cannot establish this.
7. Preference default, opt-in, no-controller fallback, restoration, last-gameplay-controller disconnect while Live is open, and remote/pad duplicate routes are tested. Do not claim hardware acceptance while the owner's physical test window is deferred.

## Related recovery work

The owner also wants visible non-default indicators on iOS and tvOS, reset setting/group, and undo/redo or profiles for safe experimentation. Existing broad page reset does not reliably clear persisted values; use audited typed read/write/reset descriptors rather than exposing it unchanged. This is retained as the next settings task, not silently folded into this input-ownership change.
