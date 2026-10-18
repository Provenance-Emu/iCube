# Touch controls haptics audit (2026-10-17)

User report: the GameCube left stick on the touch overlay/skin gives no haptic feedback.

## Root cause

The stick had no haptic on any of the three touch paths. This was a choice, not a regression in
shared code:

- **Swift-drawn overlay:** `TouchOverlayStickView`'s doc comment said "No haptics: `TCJoystick`
  has none". It copied the xib stick, which never had one.
- **Skins:** `SkinStickView` made the same choice.
- **xib pads** ("Editable Controls" off): `TCJoystick` never had one.

Buttons and D-pads did buzz, so the stick was the odd one out. The C-stick, Nunchuk stick and
both Classic sticks were just as silent. The report named the left stick only because that is the
one players hold.

Two other skin bugs turned up in the audit:

- **Held controls swallowed later presses.** The whole skin is one touch cluster, and
  `SkinTouchLayer.apply` played the press haptic only when the cluster went from nothing held to
  something held. Pressing A while holding the D-pad or B played nothing.
- **Skin action items played nothing.** Menu, quick save and quick load fire from `onBegan` and
  never enter the pressed set.

## Rules (one set for every path)

Implemented in `TouchOverlay/TouchOverlayHaptics.swift`:

- **Press:** a medium impact when a button, shoulder, trigger, D-pad or skin action goes down.
  Nothing while it is held or when it is released.
  - Clusters (`TouchHapticRules.pressesSomethingNew`) play once per touch event that presses
    something new.
  - D-pads play on their first direction only. Rolling to another direction is silent.
  - Skins (`SkinOverlayInput.pressesNewItem`) play once per newly pressed item.
- **Stick** (`StickHapticTracker`):
  - a light impact when a finger lands on the stick;
  - one softer light impact (intensity 0.5) when the knob reaches the rim (|axes| ≥ 0.95);
  - the rim re-arms only after the knob comes back below 0.8, so a thumb resting on the edge
    doesn't buzz;
  - never a haptic per move sample.
- **Pointer surfaces** (Wii IR pad, skin pointer layer): silent. Pointing is continuous, so there
  is no press edge to mark.
- **Settings:** there is no in-app touch-haptics switch ("Device Haptics" under Rumble only picks
  where game rumble goes). `UIFeedbackGenerator` plays nothing when iOS Settings → Sounds & Haptics
  → System Haptics is off, or on a device without a Taptic Engine. That covers both cases without
  extra code. An in-app toggle is a possible follow-up.

## Control × layout

"Overlay" means the Swift-drawn computed layouts, used when "Editable Controls" is on (the
default). "Skin" means a loaded skin, whose items map onto the same pad ids. "xib" means the old
fixed pads, used when "Editable Controls" is off.

| Control | GameCube | Wii Remote (sideways) | Wii Remote + Nunchuk | Classic | Before | After |
|---|---|---|---|---|---|---|
| Face buttons (A B X Y / A B 1 2 / a b x y) | ✓ | ✓ | ✓ | ✓ | Overlay: press. Skin: press only if nothing else held. xib: press | Press, once per newly pressed button, on every path |
| Start / − / HOME / + / Mic | Start, Mic | ✓ | ✓ | ✓ | Same as face buttons | Same as face buttons |
| D-pad | ✓ | ✓ | ✓ | ✓ | Overlay and xib: press on first direction. Skin: press only if nothing else held | Press on first direction; rolling to another direction is silent |
| Shoulders / triggers (L R analog; Z, ZL ZR digital) | L R Z | — | Nunchuk C Z | L R ZL ZR | Overlay: press. Skin: press only if nothing else held. xib: press (analog L/R on 3D Touch hardware: tap at full force instead) | Press on every path (xib force path unchanged) |
| Main / left stick | Main stick | — | Nunchuk stick | Left stick | **None** on all three paths | Light tap on touch-down, softer tap at the rim |
| C-stick / right stick | C-stick | — | — | Right stick | **None** on all three paths | Light tap on touch-down, softer tap at the rim |
| IR pointer surface (overlay IR pad, skin pointer layer, xib `TCWiiPad`) | — | skin / xib only | ✓ | — | None | None (by design) |
| Skin action items (menu, quick save, quick load) | any skin | any skin | any skin | any skin | **None** | Press on touch-down |

Notes:

- The xib stick (`TCJoystick`) uses a pan recognizer, which begins only after the finger has moved
  a few points. Its touch-down tap therefore lands at the start of the drag, not on first contact.
  The overlay and skin sticks tap on first contact.
- A skin item that maps to both a pad button and an app action plays two press impacts in the same
  instant. They feel like one tap.

## Device checks owed

The simulator has no Taptic Engine, so none of this can be felt there. On a phone:

1. GameCube overlay: touching the main stick and the C-stick each gives a light tap. Pushing to
   the edge gives one softer tap, and circling the edge gives no more.
2. A GameCube skin with a left stick: same as check 1.
3. A skin: hold the D-pad and press A. Both should tap. Tap the skin's menu button: it should tap.
4. Wii + Nunchuk overlay (Nunchuk stick) and Classic overlay (both sticks): same as check 1.
5. "Editable Controls" off (xib pads): the stick taps when a drag starts and at the rim.
6. With System Haptics off in iOS Settings, nothing taps.
7. Judge feel: is the light touch-down tap distinct from the medium button tap, and is the rim tap
   subtle enough?
