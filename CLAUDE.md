# CLAUDE.md
Read docs/DESIGN.md (approved design) and docs/ARCHITECTURE.md first.
Token limits are mandatory:
- Steps of at most ~30-60 turns, each in a fresh `claude -p` session; Sonnet runs with `--max-budget-usd 2.50`.
- No Sonnet helper subagents; subagents are Haiku only (log reading, bulk renames, Explore).
- Read files by line range (Grep, then Read with offset/limit); never read a file over 200 lines whole.
- Pin every model explicitly (`--model opus|sonnet|haiku`).
- Never push, merge, create release keys, or touch files outside this repo. The debug keystore in android/ is the shared fixed debug key; never use it for release.

CROSS-PLATFORM READINESS (Android ships first; Windows, Linux, Mac, iOS and web come later, so build so they need no rewrite):
- All input goes through Godot InputMap actions plus one input-abstraction layer (scripts/input/); touch, gyro, mouse/keyboard and gamepad are separate swappable providers. Never read raw touch events in gameplay code.
- UI uses anchors/containers and scales for any aspect ratio and DPI; the touch HUD is its own scene layered over the game, hideable on non-touch platforms.
- Platform-specific code (gyro, haptics, Android permissions, file paths) lives behind scripts/platform/ with an OS.get_name() switch and safe no-op fallbacks; use user:// for saves, never hard-coded paths.
- Networking via Godot high-level multiplayer (ENet) only, no Android-only APIs, so PC players can join later.
- Use the Compatibility or Mobile renderer settings that also run on desktop and web; keep graphics quality as data-driven presets.
- Keep export_presets.cfg with the Android and iOS presets for now, but nothing in code may assume Android.
