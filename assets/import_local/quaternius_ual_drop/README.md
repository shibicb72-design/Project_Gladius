# Later manual UAL Standard drop

The scripted free download could not reach the upload page in this dig. Download Universal Animation Library[Standard].zip (free Standard tier, never Pro or Source) from https://quaternius.itch.io/universal-animation-library in a browser.

Drop the ZIP UNEXTRACTED into C:/Users/shibi/cc_gladius/out/libs_dl/manual/ outside this repo. Do not extract archives in the repo. Everything except this README in this folder is ignored as a clean-tree safeguard, not an invitation to import an unchecked archive.

A follow-up dig hashes the archive, verifies its licence and extracts it into a new isolated scratch folder, copies only allowed model/texture/licence files, reads the REAL bone and clip names, creates the UAL BoneMap/import settings and fills data/anim_sources.json. Names and paths are unknown until inspection; code/import changes may be required. Existing procedural clips remain live until that work passes every locked pose test.
