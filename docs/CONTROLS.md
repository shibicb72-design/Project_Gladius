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
| `ground_accel.time_s` | seconds, rest to full speed | 0.1175 (placeholder) | = 4.7 m/s / 40 m/s^2, so the rate stays 40 m/s^2; 0 = instant |
| `ground_decel.time_s` | seconds, full speed to stop | 0.1175 (placeholder) | same rate, 40 m/s^2; 0 = instant |
| `sprint_speed_multiplier.value` | ratio of run speed | 1.34 (placeholder) | community-measured on PC (not official): 4.7 x 1.34 = 6.298, about 6.3 m/s sprint |
| `weapon_speed_penalty.value` | multiplier on run speed while holding a weapon | 1.0 (placeholder) | 1.0 = no penalty; not wired yet (OQ-WEAPON-SPEED) |
| `sprint_ramp_s.value` | seconds | 1.0 (placeholder) | ease run <-> sprint, both directions |
| `strafe_back_ratio.value` | ratio of forward speed | 0.889 (COMMUNITY-sourced, NOT a placeholder) | sideways and backward; `_source`: "TSG Forge Wiki community tag data: sideways 2 / forward 2.25, backward 2" |

Speed scales continuously with stick length (full analog, no walk/run step). Forward run speed (`base_speed_mps`) is 4.7 m/s, community-measured on PC (pubg.fandom.com/wiki/Movement_Speed and samurai-gamers), not an official PUBG number and still a placeholder (Shibi Oct 23 2026, G3b-1; supersedes the Oct 22 +7.5% value). Crouch, prone and walk speeds are deferred (OQ-STANCE-SPEEDS). The ramp rate is `base_speed_mps / time_s` (4.7 / 0.1175 = 40 m/s^2 with the shipped data) for every class, applied per horizontal axis.

## Sprint

Sprint added by Shibi's decision, Oct 22 2026 (OQ-SPRINT, closed). Touch only for now; keyboard and gamepad bindings are undecided (TODO in OPEN_QUESTIONS.md).

- **Trigger:** the move stick reaching the forward extreme starts sprint on that tick; there is no hold (Shibi Oct 23 2026: "Start on the threshold like PUBG"). "Forward extreme" = deflection >= the forward threshold AND the stick direction within `input.json` `sprint.forward_cone_half_angle_deg` of straight forward. Leaving the extreme (below the threshold or outside the cone) stops the sprint request at once, and returning starts it again on the first tick back. Works for the floating and fixed VirtualJoystick and the custom stick (the check is in `TouchProvider`/`SprintDetector`, on the provider's move vector).
- **Speed:** `InputFrame.sprint` asks the pawn to ease its speed factor from 1 (run) to `movement.sprint_speed_multiplier` (1.34, giving 6.3 m/s sprint at 4.7 m/s run; community-measured on PC, not official, still a placeholder; Shibi Oct 23 2026) over `movement.sprint_ramp_s` (placeholder), with no snap. Releasing, dropping below the threshold, or leaving the cone eases back down over the same time.
- **Sprint lock:** while the stick is past the trigger a lock target appears above the stick origin. Releasing the finger ON it locks forward sprint (no finger needed; movement is straight forward at sprint speed). Releasing anywhere else stops movement. A new move-stick touch or a tap on the lock button cancels the lock (speed eases down); look still works. The separate, movable Sprint lock button shows the lock state: tapping it while moving forward locks, tapping it while locked cancels. Its default position is `input.json` `touch_layout.sprint_lock_pos` (`"_placeholder": true`); the profile key `sprint_lock_pos` ([x, y] fractions) overrides it so the layout editor (G2e/G2L) can store it. At least 48 dp.
- **Sprint sensitivity:** Settings slider (main menu), profile key `sprint_sensitivity`, `input.json` `sprint_sensitivity` min 0, max 100, default 50, step 5 (single unofficial source, HT Tech report of BGMI 1.6 notes; Shibi chose it as the starting point Oct 22 2026). It only sets the forward deflection threshold used by BOTH the sprint trigger and the lock target: threshold = lerp(`sprint.threshold_at_sensitivity_0`, `sprint.threshold_at_sensitivity_100`, sensitivity / 100), both ends placeholders. Higher sensitivity = lower threshold = shorter push. It never changes speed, the cone or `sprint_ramp_s`.

Research quotes (staging `pubg_mobile_movement_research.md`; PUBG publishes no numbers, so none are taken from it):
- Official support reply: "In the customize buttons section, you can increase or decrease the length at which the Auto-Sprint is triggered." Also: "Your character will stop moving when you lift your finger up."
- Article: "The auto sprint icon appears when you're running at full speed - simply hover over it and let go to continue running without holding your screen."
- Accessory maker: "Drag the 'Sprint lock' button up and out of the way".
- GuruGamer 18712: "The higher sprint sensitivity is, the less distance your left thumb needs to move up to sprint."
- Reddit 1rbgu31: "you don't have to move the joystick as much to start sprinting ... but not your actual speed."
- PuK: "It defines how much you need to move the PuK Thumbstick forward before sprint is activated".

### Compared with PUBG Mobile (G3a)

- **Auto-sprint past an adjustable threshold** (OFFICIAL Google Play editorial plus COMMUNITY-REPORTED: "Sprint Sensitivity" sets how far you must push). Gladius: `scripts/input/sprint_detector.gd:35-43`, threshold from the slider at `data/input.json:64-69` and `scripts/ui/settings_panel.gd:177-198`. The former difference (a 0.5 s hold) is closed by G3a2: Gladius now matches PUBG and starts sprint on the threshold. See closed OQ-SPRINT-HOLD in OPEN_QUESTIONS.md.
- **Drag onto the "Sprint Lock" icon above the stick locks sprint** (OFFICIAL Google Play editorial plus COMMUNITY-REPORTED). Gladius: release on the lock target, `scripts/ui/touch_hud.gd:628-633`, target size in `data/input.json:70`.
- **Tapping the movement joystick again cancels the lock** (COMMUNITY-REPORTED). Gladius: `scripts/ui/touch_hud.gd:579-580`. Tests: `tests/test_sprint.gd:346-393` (new touch cancels) and `test_tap_on_stick_cancels_lock_and_stops` (whole tap, then stopped).

## In-match menu (gear)

Shibi (via EL, Oct 22 2026): the menu opens ONLY from a small gear icon in the top-right corner. Android Back, `ui_cancel` and Escape do not open it, and no Back handling was added (Godot's default for Back is unchanged).

- **Gear:** drawn icon `pause_gear.icon_dp` (28 dp) inside a tap target `pause_gear.touch_dp` (48 dp), both from `PlatformServices.get_dp_scale()`. Position (`anchor`, `margin_dp`) is data in `data/ui.json` and sits below the HUD's top row; if crowded it moves in data, the HUD text is never shrunk. `PauseMenu._input` runs before the touch HUD (it is later in the tree), consumes the tap, and so the tap is never a stick, button or look touch.
- **Menu:** full-screen overlay with Resume, Settings (the shared `scenes/ui/settings_panel.tscn`, the same scene as the main menu) and Quit to main menu (Confirm / Cancel). Buttons are at least 48 dp; sizes are `pause_menu` in `data/ui.json`. All placeholders (OQ-PAUSE-MENU).
- **Offline:** `get_tree().paused = true` while open; the menu and settings panel are `PROCESS_MODE_ALWAYS`; Resume unpauses.
- **Online:** overlay only. The simulation and networking keep running and the local pawn gets a zero `InputFrame` (no move, look, fire, jump or sprint; the touch HUD drops its held sticks, buttons and sprint lock). **You can be shot while in the menu.**

## Sensitivity (G2d)

Settings has a **Sensitivity** button (shared panel: main menu and in-match menu) that opens `scenes/ui/sensitivity_screen.tscn`. Controls are at least 48 dp; every change is saved to the profile at once.

- **Presets:** Low / Medium / High set every value of every table. Editing any slider switches the preset to **Custom** (state only, not a button). Preset values are placeholders.
- **Tables** (percent, 100 = the base look rate in `data/input.json`): Camera, ADS, Gyro, ADS Gyro, and a separate Free Look table. Rows are `tpp_fpp_no_scope`, `red_dot`, `2x`, `4x`, `8x`, `16x` (the scopes in DESIGN.md). PUBG's 3x and 6x rows are **not** added because our weapons have no such scopes; PUBG's parachuting Free Look row is skipped because our design has no parachute. Free Look rows are `tpp_character` and `fpp_character`. The tables live in `data/input.json` `sensitivity_tables` (the old `sensitivity` key already holds the base look rates).
- **Ranges:** the Gyro and ADS Gyro max is 400 (PUBG MOBILE Patch Notes 1.1). Every other min, max, default and step is a placeholder (OQ-SENS).
- **Gyro mode:** Off (default, OQ-34), ADS (`scope_on`, only while aiming) or Always (`always_on`). Invert X and Invert Y are separate toggles. Gyro has no aim assist. The quick "Gyro aim" button in the panel still flips Off / Always (existing tests pin it).
- **iOS motion permission (G3d):** the iOS export preset (`export_presets.cfg` `[preset.1.options]` `application/additional_plist_content`) carries `NSMotionUsageDescription` with a placeholder string (OQ-IOS-MOTION-STRING). Signing is not set up (OQ-IOS-SIGNING). Gyro still needs a check on a real phone (Android and, later, iOS); no device was tested. Gyro recenter is deferred (OQ-GYRO-RECENTER).
- **Which row applies:** `InputRouter.set_ads(aim_blend > 0)` selects the ADS tables (the match calls it each tick); `set_aim_state(state)` with `no_scope`, `red_dot`, `2x`, `4x`, `8x` or `16x` selects the row. No scopes exist yet, so it stays `no_scope` and the scope rows are data only (OQ-ADS-ZOOM). `set_free_look_row` multiplies the camera value by the Free Look row (no free look exists yet).
- **Profile:** `user://profile.json` key `sensitivity` (preset, gyro mode, inversion, values per table/row). Missing keys use the data defaults. An old profile with only `gyro_enabled` loads as `always_on` (true) or `off` (false); `gyro_enabled` is still written, derived from the mode.
- **Shots:** `tools/sensitivity_capture.tscn` writes `build/shots/sensitivity_{cover,inner}_landscape.png` and `sensitivity_{cover,inner}_small_landscape.png` (1512x648, 1152x959).

## Layout editor (G2e)

Settings > "HUD layout" opens the editor (main menu and in-match menu). It shows the live touch HUD: both sticks at rest, every button and the Sprint lock button. Tap an element to select it, drag to move it, use the Size and Opacity sliders. The shape follows the research guide (tap an element, drag to move, adjust size and transparency, three saved layouts, a reset); every range is our placeholder (`data/input.json` `layout_editor`, `_placeholder: true`; OQ-LAYOUT-EDITOR), not PUBG's.

- **Slots:** 3 layouts (Slot 1-3) with an active slot. Save writes all three plus the active one to `user://profile.json` key `hud_layouts` (`scripts/systems/hud_layout_model.gd`); it survives a restart. Back drops unsaved edits. A slot stores only what changed: element key -> `pos` (fractions of the HUD, so it scales), `size_pct`, `alpha_pct`. `touch_hud.gd` applies the active slot over the data defaults (`reload_profile_layout()`; the in-match menu calls it after Save).
- **Reset** (current slot) clears the slot, which is exactly the G2L default layout from `data/input.json` `touch_layout`, Sprint lock button included. The data default is never edited. The editor mirrors the active slot's lock position into the profile `sprint_lock_pos` on Save (`[]` when the slot keeps the default); the HUD uses slot, then `sprint_lock_pos`, then the data default.
- **48 dp:** an element's touch target never goes below 48 dp at the device's scale (platform layer `get_dp_scale()`): the size slider's lower end is raised to it, and `TouchHud` clamps stored values too.
- **Off-screen warning:** every edited slot is checked at 2520x1080, 2176x1812, 1512x648 and 1152x959 (landscape only, OQ-PORTRAIT) against the platform safe area (`PlatformServices.get_safe_insets()`, none = whole viewport). A partly-outside element is named in a red warning and outlined, and Save is blocked until it is fixed or the slot is reset.
- **Overlap policy (chosen: warn only):** overlap with the gear (top-right, not editable) or the HUD bars is named in the warning but does not block Save. Only leaving the safe viewport blocks.
- **Shots:** `tools/layout_editor_capture.tscn` writes `build/shots/layout_editor_{cover,inner}_landscape.png` and `layout_editor_{cover,inner}_small_landscape.png` (1512x648, 1152x959); the cover_small shot shows the off-screen warning.
- **Tests:** `tests/test_layout_editor.gd` (temp `user://` profile, restores `AppFlow.profile`).

## Left Fire button (G3e, off by default)

PUBG Mobile offers a second Fire button on the left as an option; so do we, and it is off. Settings > "Left Fire button: Off/On" stores the profile key `left_fire_enabled` (`SaveService` keeps only a bool; default `touch_layout.left_fire.enabled_default`, false).

- **Behaviour:** when on, `touch_hud.gd` builds one more round button (element key `fire_left`, label "Fire"), the same size as the right Fire button and never below `button_min_dp` (48 dp via the platform layer). It presses and releases the same `fire` action through `_on_down` / `_on_up`; `fire` stays down while either Fire button is held, so releasing one of two held buttons keeps firing. Off: no node is built and `fire_left` is not in `get_element_keys()`.
- **Position:** `data/input.json` `touch_layout.left_fire.pos` (fractions of width/height of the centre; left half, above the move stick, clear of the Sprint lock target). It is a placeholder, not a design value (OQ-LEFT-FIRE-POS). It is not a key of `touch_layout.buttons` (those are InputMap actions).
- **Layout editor:** "Left Fire" (`fire_left`) shows up only while enabled. Its `pos`, `size_pct` and `alpha_pct` save per slot like any element (`hud_layout_model.gd`), are covered by the off-screen/overlap check, and Reset returns it to the data default.
- **Tests / shots:** `tests/test_left_fire.gd`; `touch_capture.tscn --left-fire --tag=left_fire_on --layout-shot=<cover|inner>_landscape` and `layout_editor_capture.tscn --left-fire-shot=<cover|inner>`.

## Haptics (G2f)

Settings > "Haptics" opens the Haptics screen (main menu and in-match menu). Research (`pubg_mobile_movement_research.md`, official): tactile feedback for weapons, character status and sound visualisation, a system vibration setting, High and Low quality, on/off switches, "only available on select devices". We have no vehicles, so there is no vehicle category.

- **API (staged docs):** `Input.vibrate_handheld(duration_ms: int = 500, amplitude: float = -1.0)` is in `staging/godot-docs/class_input.md:1834`. Amplitude is 0.0 to 1.0 (:1838). "Implemented on Android, iOS, and Web. It has no effect on other platforms." (:1840). Android needs the `VIBRATE` permission in the export preset (:1842), so `export_presets.cfg` has `permissions/vibrate=true`. On iOS the duration is only supported from iOS 13 (:1844). Device settings (vibration off, do not disturb) can suppress it (:1850). `docs/engine-reference/godot/` (breaking-changes.md, deprecated-apis.md) does not mention `vibrate_handheld` or any haptic API, and none of the other APIs used here (Button toggle_mode, set_pressed_no_signal, CanvasLayer, OS.get_name, DisplayServer.get_name, JSON) appears in either file.
- **Layers:** `scripts/platform/haptics_backend.gd` is the only code that calls Input (Android and iOS, non-headless; desktop, web and the headless server are a no-op). `scripts/platform/haptics_service.gd` holds settings and looks up the event in `data/haptics.json`. `scripts/platform/haptics.gd` is the static entry point for gameplay: `Haptics.play("weapon_fire")`. The service takes a backend, so tests inject a fake.
- **Events and categories:** weapons (`weapon_fire`, `weapon_reload`, `melee_hit`), status (`damage_taken`, `shield_break`, `death`), sound cues (`sound_cue`). `scripts/systems/haptics_events.gd` binds the local pawn only, from `MatchRoot.begin()`: `shot_resolved`, `reload_started`, the new `melee_landed`, and the new `damaged` (one status event per damaging hit: death, else shield break, else damage taken). Sound cues are wired to nothing: the project has no audio or sound-visualisation events yet (OQ-HAPTICS-SOUND-CUES).
- **Quality:** High or Low picks the `high` or `low` block of the event in `data/haptics.json`. Choosing a quality plays a sample.
- **Defaults (placeholders):** haptics on where supported, every category on, quality High. Every duration, amplitude and the damage-event precedence is a placeholder (`_placeholder: true`; OQ-HAPTICS-VALUES), not PUBG's.
- **Unsupported device:** `is_supported()` is false, `is_enabled()` reads off, `play()` makes no backend call, and the screen shows "Not available on this device" with the controls disabled. The stored choice is kept.
- **Persistence:** profile key `haptics` (`enabled`, `quality`, `categories`) in `user://profile.json` via `SaveService`; bad values fall back to the data defaults.
- **48 dp:** the screen uses `UiScale`, so every button is at least 48 dp at the device scale.
- **Shots:** `tools/haptics_capture.tscn` writes `build/shots/haptics_settings_{cover,inner}_landscape.png` and `haptics_settings_{cover,inner}_small_landscape.png` (1512x648, 1152x959), using a fake supported backend because a desktop cannot vibrate.
- **Tests:** `tests/test_haptics.gd`.

## Rest-state screenshots (landscape only)

The project is landscape only (`window/handheld/orientation=4`, sensor_landscape). `tools/touch_capture.gd --vjoy-shot=<name>` saves the move stick at rest; the shots kept are `vjoy_rest_cover_landscape.png` and `vjoy_rest_inner_landscape.png` (Fold inner landscape 2176x1812). Portrait is out of scope (OQ-PORTRAIT in OPEN_QUESTIONS.md); the tool skips any `--vjoy-shot` name containing "portrait".
