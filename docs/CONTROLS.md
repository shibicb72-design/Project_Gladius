# Touch controls

Phone controls follow PUBG Mobile's layout design (source: `cc_gladius/staging/pubg_mobile_movement_research.md`).
That source gives layouts only; it has no official numbers for dead zones, sizes or curves, so no value below is
labelled as PUBG's.

## Action buttons and their feedback

All feedback numbers are placeholders in `data/ui.json` (`shot_fx`, `feedback`); aim numbers are in
`data/stats.json` `aim`. None are design or PUBG values. Tests: `tests/test_action_buttons.gd`.

| Button | Effect | Visible feedback |
|---|---|---|
| Fire | One burst/shot of the active weapon (hold = repeat). Hitscan ranged weapons spend ammo. | Muzzle flash and tracer from the weapon mesh toward the hit point or max range, drawn on top of the pawn body so the near-axis third-person view still shows it (`shot_fx.tracer_draw_on_top`, tested on screen against `tracer_min_screen_px`; others, including bots, see it from the host's shot report); hit marker on a hit; "Empty" cue when pressed on an empty mag; button highlight while held. |
| Reload | Starts a reload if the mag is not full and reserve ammo exists. | "Reloading" text and progress bar while reloading (feedback rows now sit in a centre band, `feedback.row_x_frac`, above the stick tops and button column, so none overlaps a stick or button; checked by tests/test_feedback_clearance.gd); "Full" cue on a full mag, "No reserve" cue with no reserve. |
| Swap | Switches the active weapon slot. | Toast with the new weapon name; the weapon label also changes. |
| Aim | Hold: camera FOV zooms (`aim_fov_mult`, eased by `aim_zoom_s`) and spread tightens (`aim_spread_mult`). Release restores. | FOV change. Aim state is read from `InputFrame.aim_pressed` in `pawn.gd`; the host takes aim from the client's latest `InputFrame` (`net_match_bridge.gd` `host_note_input` stores it, the shot's spread reads it) and ignores the client-sent aim flag. |
| Jump | Jumps when on the floor. | Camera hop. |

A placeholder weapon box is drawn on the pawn (the camera is third-person).

Touch debug overlay: set `data/ui.json` `touch_debug_overlay.enabled` to `true` to list each held touch with its
index, position and the button/stick it hit (OQ-DEVICE-TOUCH). Default off.

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

radial_deadzone 0.1 is new vs 8ffb2da, a placeholder, tunable in input.json move_feel.

`data/camera.json` (each entry `{"_placeholder": true, "value": ...}`):

| Key | Unit | Value | Notes |
|---|---|---|---|
| `shoulder_offset_m` | m | 0.6 (placeholder, right shoulder, no source) | Camera sits to the right of the pawn axis. Set on the `SpringArm3D` node (`camera_rig.gd`), because the arm rewrites a child camera's position every physics frame (measured with `tools/measure_shoulder.gd`: camera x was 0.0 with the offset on the camera). Left/right swap is undecided: OQ-SHOULDER |
| `aim_ray_length_m` | m | 200 (placeholder) | Far aim point when the camera-centre ray hits nothing |
| `aim_validate_epsilon_m` | m | 0.3 (placeholder) | Host tolerance for the muzzle ray reaching the client aim point |

Aim with the shoulder camera: the client takes the point under the screen centre (`AimMath.camera_aim_point`) and sends it in the `InputFrame` (`aim_point`). The host fires from its own muzzle toward that point (`pawn.get_aim_direction()` locally, `host_handle_fire` on the host) and rejects, with a logged warning and no shot, any point whose muzzle ray is blocked by world geometry before it arrives (`AimMath.validate_aim`, reason `aim_blocked`). Pawns in the way do not count as blocking. Context only, no numbers taken from them: the PUBG PC Update 20 patch note (Reddit) and the PUBG Mobile shoulder-aim help page.

`data/stats.json` `movement`:

| Key | Unit | Value | Notes |
|---|---|---|---|
| `ground_accel.time_s` | seconds, rest to full speed | 0.134375 (placeholder) | = 5.375 m/s / 40 m/s^2, so the rate stays 40 m/s^2; 0 = instant |
| `ground_decel.time_s` | seconds, full speed to stop | 0.134375 (placeholder) | same rate, 40 m/s^2; 0 = instant |
| `sprint_hold_s.value` | seconds | 0.5 (NOT a placeholder) | `_source` "Shibi Oct 22" |
| `sprint_speed_multiplier.value` | ratio of run speed | 1.3 (placeholder) | our placeholder starting value, no sourced number |
| `sprint_ramp_s.value` | seconds | 1.0 (placeholder) | ease run <-> sprint, both directions |
| `strafe_back_ratio.value` | ratio of forward speed | 0.889 (NOT a placeholder) | sideways and backward; `_source`: "TSG Forge Wiki community tag data: sideways 2 / forward 2.25, backward 2" |

Speed scales continuously with stick length (full analog, no walk/run step). Forward walk speed (`base_speed_mps`) is 5.375 (5.0 + 7.5%, Shibi Oct 22 "+5-10%"). The ramp rate is `base_speed_mps / time_s` (5.375 / 0.134375 = 40 m/s^2 with the shipped data) for every class, applied per horizontal axis.

## Sprint

Sprint added by Shibi's decision, Oct 22 2026 (OQ-SPRINT, closed). Touch only for now; keyboard and gamepad bindings are undecided (TODO in OPEN_QUESTIONS.md).

- **Trigger:** the move stick is pushed to the forward extreme and held there for `stats.json` `movement.sprint_hold_s` = 0.5 s (`_source` "Shibi Oct 22", not a placeholder). "Forward extreme" = deflection >= the forward threshold AND the stick direction within `input.json` `sprint.forward_cone_half_angle_deg` of straight forward. Breaking the condition restarts the timer from zero. Works for the floating and fixed VirtualJoystick and the custom stick (the check is in `TouchProvider`/`SprintDetector`, on the provider's move vector).
- **Speed:** `InputFrame.sprint` asks the pawn to ease its speed factor from 1 (run) to `movement.sprint_speed_multiplier` (1.3, our placeholder starting value, no sourced number) over `movement.sprint_ramp_s` (placeholder), with no snap. Releasing, dropping below the threshold, or leaving the cone eases back down over the same time.
- **Sprint lock:** while the stick is past the trigger a lock target appears above the stick origin. Releasing the finger ON it locks forward sprint (no finger needed; movement is straight forward at sprint speed). Releasing anywhere else stops movement. A new move-stick touch or a tap on the lock button cancels the lock (speed eases down); look still works. The separate, movable Sprint lock button shows the lock state: tapping it while moving forward locks, tapping it while locked cancels. Its default position is `input.json` `touch_layout.sprint_lock_pos` (`"_placeholder": true`); the profile key `sprint_lock_pos` ([x, y] fractions) overrides it so the layout editor (G2e/G2L) can store it. At least 48 dp.
- **Sprint sensitivity:** Settings slider (main menu), profile key `sprint_sensitivity`, `input.json` `sprint_sensitivity` min 0, max 100, default 50, step 5 (single unofficial source, HT Tech report of BGMI 1.6 notes; Shibi chose it as the starting point Oct 22 2026). It only sets the forward deflection threshold used by BOTH the 0.5 s hold trigger and the lock target: threshold = lerp(`sprint.threshold_at_sensitivity_0`, `sprint.threshold_at_sensitivity_100`, sensitivity / 100), both ends placeholders. Higher sensitivity = lower threshold = shorter push. It never changes speed, the cone, `sprint_hold_s` or `sprint_ramp_s`.

Research quotes (staging `pubg_mobile_movement_research.md`; PUBG publishes no numbers, so none are taken from it):
- Official support reply: "In the customize buttons section, you can increase or decrease the length at which the Auto-Sprint is triggered." Also: "Your character will stop moving when you lift your finger up."
- Article: "The auto sprint icon appears when you're running at full speed - simply hover over it and let go to continue running without holding your screen."
- Accessory maker: "Drag the 'Sprint lock' button up and out of the way".
- GuruGamer 18712: "The higher sprint sensitivity is, the less distance your left thumb needs to move up to sprint."
- Reddit 1rbgu31: "you don't have to move the joystick as much to start sprinting ... but not your actual speed."
- PuK: "It defines how much you need to move the PuK Thumbstick forward before sprint is activated".

## In-match menu (gear)

Shibi (via EL, Oct 22 2026): the menu opens ONLY from a small gear icon in the top-right corner. Android Back, `ui_cancel` and Escape do not open it, and no Back handling was added (Godot's default for Back is unchanged).

- **Gear:** drawn icon `pause_gear.icon_dp` (28 dp) inside a tap target `pause_gear.touch_dp` (48 dp), both from `PlatformServices.get_dp_scale()`. Position (`anchor`, `margin_dp`) is data in `data/ui.json` and sits below the HUD's top row; if crowded it moves in data, the HUD text is never shrunk. `PauseMenu._input` runs before the touch HUD (it is later in the tree), consumes the tap, and so the tap is never a stick, button or look touch.
- **Menu:** full-screen overlay with Resume, Settings (the shared `scenes/ui/settings_panel.tscn`, the same scene as the main menu) and Quit to main menu (Confirm / Cancel). Buttons are at least 48 dp; sizes are `pause_menu` in `data/ui.json`. All placeholders (OQ-PAUSE-MENU).
- **Offline:** `get_tree().paused = true` while open; the menu and settings panel are `PROCESS_MODE_ALWAYS`; Resume unpauses.
- **Online:** overlay only. The simulation and networking keep running and the local pawn gets a zero `InputFrame` (no move, look, fire, jump or sprint; the touch HUD drops its held sticks, buttons and sprint lock). **You can be shot while in the menu.**

## Rest-state screenshots (landscape only)

The project is landscape only (`window/handheld/orientation=4`, sensor_landscape). `tools/touch_capture.gd --vjoy-shot=<name>` saves the move stick at rest; the shots kept are `vjoy_rest_cover_landscape.png` and `vjoy_rest_inner_landscape.png` (Fold inner landscape 2176x1812). Portrait is out of scope (OQ-PORTRAIT in OPEN_QUESTIONS.md); the tool skips any `--vjoy-shot` name containing "portrait".
