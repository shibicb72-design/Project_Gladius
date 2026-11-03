# Later manual rifle-animation import

Mixamo is an Adobe browser tool requiring an Adobe ID. Raw FBX/GLB files may not be redistributed in this public repo. Keep drops and their generated imports/textures here (ignored), or in a private asset repo. Never commit these files. No .gdignore: Godot must import local drops.

DECIDED by Shibi via EL, Oct 29 2026: clips MAY be packed into APKs built locally; raw files are NEVER committed. The all_resources export filter includes imported local resources, so an APK built on a machine with local drops can contain derived resources.

Later steps for Shibi/follow-up dig:
1. Obtain rifle aim/fire/reload clips in the browser and drop their raw files here.
2. Create this source skeleton's OWN BoneMap using Godot auto-mapping with SkeletonProfileHumanoid. Keep that BoneMap here, ignored. A UAL map does not match these source bone names. Never put the source prefix or map elsewhere.
3. Retarget and test against the existing 17-bone soldier, fixed head shell, rifle/foregrip IK, recoil and cover-wall contracts.
4. Add explicit local candidate paths in a private source table; committed data/anim_sources.json intentionally contains no import_local paths. No directory discovery occurs.

Logical slots: idle, walk_fwd, walk_back, strafe_l, strafe_r, run_fwd; aim_down, aim, aim_up, fire, reload; cover_enter, cover_idle_l, cover_idle_r, peek_left, peek_right, cover_exit and their _crouch variants; cover_slide_l, cover_slide_r (optional _crouch variants). No free-crouch slot. Cover slide left is model-relative step RIGHT; cover slide right is model-relative step LEFT. Fire is additive and requires first-frame-relative rotation deltas; reload is scaled to WeaponDef.reload_s. Missing slots keep the existing procedural fallback; slides have no procedural slot and add no state when unresolved.

This is a LATER MANUAL STEP, not an imported or tested rifle library.
