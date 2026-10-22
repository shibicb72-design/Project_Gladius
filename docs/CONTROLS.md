# Touch controls

Phone controls follow PUBG Mobile's layout design (source: `cc_gladius/staging/pubg_mobile_movement_research.md`).
That source gives layouts only; it has no official numbers for dead zones, sizes or curves, so no value below is
labelled as PUBG's.

## Move-stick modes

| `move_stick` | What it is |
|---|---|
| `virtual` (default) | Godot 4.7 `VirtualJoystick`. Drives four private InputMap actions (`vjoy_move_*`); `touch_hud.gd` turns them into `TouchProvider.move_value`. Gameplay never reads the joystick. |
| `custom` (fallback) | The hand-written `StickVisual` driven by `touch_hud.gd`. Fully working; keeps its own dead zone (`dead_zones.touch_move`) and ignores `move_feel`. |

## Layouts (virtual stick only, `vjoy_layout`)

- **floating (default)**: "Option 1: Left side of screen is dedicated to movement, right side dedicated to aim. Fixed fire button on the right side. This is the default setup." A `JOYSTICK_DYNAMIC` stick: a touch anywhere in the left half of the screen (`move_zone`, left 0.0 to right 0.5) spawns the base under the thumb. At rest the base is drawn at `move_stick_rest`. The left-half touch area is not drawn; `TouchHud.get_move_visual_rect()` is the drawn base.
- **fixed**: "Option 3: The entire screen can be used for aim, with a fixed stick for movement and a fixed fire button." A `JOYSTICK_FIXED` stick at `move_stick_rest`. Only touches on the stick grab it; a touch elsewhere on the left goes to look.

## How to switch

One place for players: main menu, Settings, buttons "Move stick: Virtual/Custom" and "Stick: Floating/Fixed". They are saved in the profile (`user://profile.json`: `move_stick`, `vjoy_layout`; empty = not chosen).
`touch_hud.gd` resolves each setting as: profile, else `data/input.json` `touch_layout.move_stick` / `vjoy_layout`; tests may force it with the static `move_stick_override` (never by editing data).

## Recentring

A DYNAMIC `VirtualJoystick` moves its base inside a fixed Control (the whole left half), so the Control itself does not move; the base returns to `move_stick_rest` on release. The custom stick moves itself (`place()`) under the thumb and back to rest.

## Tunables (all neutral placeholders unless noted)

`data/input.json` `move_feel` (each entry `{"_placeholder": true, "value": ...}`):

| Key | Unit | Value | Used by |
|---|---|---|---|
| `vjoy_deadzone_ratio` | ratio of joystick radius | 0.0 (engine default) | `VirtualJoystick.deadzone_ratio` |
| `vjoy_clampzone_ratio` | ratio | 1.0 (engine default) | `VirtualJoystick.clampzone_ratio`. Only acts in `JOYSTICK_FOLLOWING` (`class_virtualjoystick.md:8`); the shipped modes do not use FOLLOWING, so today it has no visible effect |
| `radial_deadzone` | stick length 0..1 | 0.1 | `TouchProvider.get_move`: on the vector length (no diagonal snapping), remainder rescaled to 0..1 |
| `response_exponent` | exponent | 1.0 (linear) | `out = dir * pow(remapped_length, exponent)` |

`data/stats.json` `movement`:

| Key | Unit | Value | Notes |
|---|---|---|---|
| `ground_accel.time_s` | seconds, rest to full speed | 0.125 (placeholder) | = 5.0 m/s / 40 m/s^2, today's behaviour; 0 = instant |
| `ground_decel.time_s` | seconds, full speed to stop | 0.125 (placeholder) | same as today's behaviour; 0 = instant |
| `strafe_back_ratio.value` | ratio of forward speed | 0.889 (NOT a placeholder) | sideways and backward; `_source`: "TSG Forge Wiki community tag data: sideways 2 / forward 2.25, backward 2" |

Speed scales continuously with stick length (full analog, no walk/run step). Forward walk speed (`base_speed_mps`) is unchanged. The ramp rate is `base_speed_mps / time_s` (40 m/s^2 with the shipped data) for every class, applied per horizontal axis.

## Rest-state screenshots (landscape only)

The project is landscape only (`window/handheld/orientation=4`, sensor_landscape). `tools/touch_capture.gd --vjoy-shot=<name>` saves the move stick at rest; the shots kept are `vjoy_rest_cover_landscape.png` and `vjoy_rest_inner_landscape.png` (Fold inner landscape 2176x1812). Portrait is out of scope (OQ-PORTRAIT in OPEN_QUESTIONS.md); the tool skips any `--vjoy-shot` name containing "portrait".
