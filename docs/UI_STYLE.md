# UI style: the front-end (M2 U1)

Design rules for every menu screen: boot, main menu, lobby, settings, sensitivity, haptics, HUD layout editor,
pause overlay and end screen. The in-match HUD (slice H1) should follow the same rules.
All values are placeholders by the M2U1 art pass (OQ-UI-STYLE, OQ-UI-TYPE, OQ-UI-BOOT, OQ-UI-BACKDROP), not design
values. Numbers live in `data/ui.json` (`menu_style`, `menu_type_scale`); the theme is `scenes/ui/menu_theme.tres`.
The HUD keeps `scenes/ui/theme.tres` until H1.

## 1. Identity

A Republic that never fell, seen at dusk: dark warm surfaces, crimson for the one primary action, gold for structure
and state, marble for text you read. Cut (chamfered) corners and hairlines give the "future"; the words, the laurel
and the Alesia skyline give the "Rome".

## 2. Colours (`menu_style.colors`, mirrored in the theme)

| Name | Hex | Use |
|---|---|---|
| night | #0C0809 | deepest background, vignette |
| oxblood | #2A0D10 | background mid tone |
| ember | #C4532A | dusk horizon glow (decor only, never text) |
| crimson | #B3211F | fill of the ONE primary action per screen |
| crimson_hi | #D2302B | primary hover, glow |
| crimson_deep | #6E1214 | primary disabled |
| gold | #D9A93A | hairlines, screen titles, selected (pressed) fill, icons |
| gold_hi | #F3D27A | highlights, focus ring, pressed border |
| marble | #EDE6D6 | body text, button text |
| marble_dim | #A89C88 | captions, placeholders, disabled text |
| surface | #140D0F at 82% | cards and list rows |
| surface_hi | #22161A at 92% | secondary buttons |
| field | #0A0708 at 85% | text fields, slider tracks |
| warn | #FF7359 | warnings only |

Rules:
- One crimson element per screen: the primary action (Host, Start, Main menu, Resume). Everything else is a dark
  surface with a gold hairline.
- Selected or switched-on = solid gold fill with dark text (the Button `pressed` style). Never colour alone: the
  label also says On / Off or carries a marker.
- Body text is marble, not gold. Gold text is for titles and state.

## 3. Type

| Face | File | Use |
|---|---|---|
| Display | `assets/third_party/kenney_fonts/kenney_future.ttf` (CC0) | logo, screen titles, primary action labels |
| Caption | `assets/third_party/kenney_fonts/kenney_future_narrow.ttf` (CC0) | section captions |
| Body | engine default (Open Sans, built into Godot) | everything else |

- The display and caption faces are caps-only techno faces. In them 5 reads as S, and K and X read as H. So they are
  used ONLY for fixed words with no digits and no K or X (`MenuStyle.display_ok(text)`). Anything with numbers, player
  text, K or X ("Back", "Kills 3", "Placed 2 of 3", IPs, names) is set in the body face.
- Look at every new display-face label in a shot before keeping it: the R can read as an A inside a word ("CONFIRM"
  read as "CONFIAM", so the pause menu's Confirm is crimson but set in the body face). HOST, START, RESUME, MAIN MENU
  and the screen titles read fine.
- Scale: multipliers of the UiScale font size (`font_size_frac_of_height` x canvas height), in
  `data/ui.json` `menu_type_scale`: logo 3.4, result 3.0, hero 2.4, headline 1.5, title 1.2, body 1.0, caption 0.78.
  `result` is the end-screen title in the display face; a title with digits uses `hero` in the body face.
  A control gets its role with `MenuStyle.set_role(control, role)`; UiScale re-applies sizes on every resize.
  Never set a fixed pixel font size.

## 4. Space and shape

- Unit `u` = 1.25% of the canvas height (`spacing_frac_of_height`). Gaps are multiples of `u`: 1 (tight), 2 (normal),
  3 (screen margin, added to the safe-area inset).
- Touch targets: every Button, LineEdit and HSlider is at least max(9% of height, 48 dp) high (UiScale, OQ-54).
  The primary action is 1.25x that (`primary_height_mult`).
- Corners are cut, not round: top-left and bottom-right chamfer (StyleBoxFlat corner radius with corner_detail 1).
  Buttons 10, cards 16; text fields are square (radius 4).
- Borders are 1 unit gold hairlines at 30-45% alpha. Only the primary action has a solid 2-unit gold border.
- Stroke widths, radii and stylebox paddings are canvas units (the canvas scales with the screen); gaps, margins, font
  sizes and control heights derive from the canvas height.

## 5. Layout

- Landscape only. The hero (logo, art) sits left; actions sit right, under the right thumb. The primary action is the
  largest control on the screen.
- Sub-pages (Settings, Sensitivity, Haptics, HUD layout): a header row with Back at the top-left and the title next to
  it, a gold rule, then the content. Back controls keep the word Back / Close / Cancel / Resume (the audio hook reads
  it); an icon may sit beside the word.
- Content stays inside the display safe area plus the screen margin (`MenuStyle.safe_margin`). Backdrops are
  full-bleed.
- Anything that can overflow lives in a vertical ScrollContainer; buttons inside one use MOUSE_FILTER_PASS so a drag
  that starts on a button still scrolls. Text fields and sliders keep MOUSE_FILTER_STOP.
- Use containers and anchors only. No fixed positions.

## 6. Backdrop

A 2D dusk scene drawn in code (`MenuBackdrop`): sky gradient, low sun, the Alesia skyline in three silhouette layers
(citadel hill, wall with towers, aqueduct arches), embers and a vignette. No 3D, no image files: it costs nothing to
load, is the same in tests and on the phone, and keeps the menu cheap.
- `hero` mode (boot, main menu, end screen): full art, slow drift and embers (`backdrop.animate`).
- `page` mode (lobby, settings pages): the same art dimmed (`backdrop.page_dim`) and still.
- The pause overlay shows the match behind a dim scrim instead.

## 7. Motion (`menu_style.motion`)

- Screen enter: content fades in (0.18 s). Never tween the position of something a container lays out.
- Press: the pressed style plus a quick scale to 0.97 and back (0.06 s in, 0.10 s out).
- Backdrop drift is slow (one cycle in about 48 s). `motion.enabled` / `backdrop.animate` false gives a still UI.
- Boot holds the logo for `boot.hold_s` (a guess, OQ-UI-BOOT) and then cuts to the menu.

## 8. Icons

Line icons drawn in code (`MenuIcon`): chevron, gear, standard (vexillum), enter, lock, play, crosshair, gyro, stick,
layout, vibrate, target, laurel. Stroke = size / 12, colour = the owner button's current font colour, so disabled and
pressed states follow the theme. No image files.

## 9. Sound

UI clicks come from `scripts/audio/sfx.gd`, which hooks every BaseButton. New controls must be Buttons.
