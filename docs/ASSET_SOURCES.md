# Gladius asset sources (verified Oct 24 2026)

Saved for the Codex / GPT world-build pass after Fold P0 placeholders work.
Standing: keep current art as **replaceable placeholders** so 3D models/textures/SFX can swap without breaking move/look/fire/pawn gameplay.

## Primary sources (fact-checked)

| Source | URL | Use for Gladius | License note (verify per asset) |
|--------|-----|-----------------|----------------------------------|
| Lospec | https://lospec.com/ | Pixel tools, palettes; https://lospec.com/palette-list ; https://lospec.com/pixel-editor/ | Tools/palettes — check each download |
| Mixamo | https://www.mixamo.com/ | Character rigs + mocap animations (Adobe account) | Adobe Mixamo terms; not Godot-only |
| itch.io assets | https://itch.io/game-assets | Indie packs (sprites, 3D, audio, UI) — **not** https://itch.io/ store root | Mix free/paid; per listing |
| Freesound | https://freesound.org/ | SFX / ambient | Per-sound CC (CC0 / BY / BY-NC etc.) |
| Game Icons | https://game-icons.net/ | UI / HUD icons (SVG/PNG) | CC BY 3.0 — credit required |
| Kenney Assets | https://kenney.nl/assets | Free game-ready 2D/3D/UI/audio packs | Site states free; support docs CC0 — still check pack |
| OpenGameArt | https://opengameart.org/ | Sprites, 2D/3D, textures, music, SFX | **Per-asset** license |
| Godot Asset Library | https://godotengine.org/asset-library/asset | Godot plugins/tools/addons | Per addon (engine homepage is NOT this) |

## Not for this bookmark list
- https://godotengine.org/ — engine itself, not an asset market (wrong landing in the X post we checked).

## Codex / placeholder rule
1. P0 gameplay stays on placeholders (capsules, magenta sky, simple blocks) until Fold move+look+fire+visible pawn prove.
2. When Codex is hooked: replace meshes/materials/textures/SFX via clear content paths; do not hard-wire gameplay to placeholder materials.
3. Prefer CC0 / clearly commercial-OK assets for shippable Gladius; log attribution for CC BY.

## Related Path A refs (code patterns, not art licenses)
- godotengine/tps-demo (camera/aim/shoot patterns)
- gdquest-demos/godot-4-3d-third-person-controller (code only; no NC art)
- ywmaa/Advanced-Movement-System-Godot (locomotion)
- KenneyNL/Starter-Kit-FPS + Whimfoome etc. for weapons/CC0 loot only

Updated: 2026-10-24 America/Detroit (Engineering Lead, from Shibi standing + DeepTechTR fact-check).
