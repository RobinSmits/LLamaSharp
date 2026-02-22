# GLM-OCR Local Patch Notes

This folder stores local `llama.cpp` patch files used by the `GLM-OCR` branch packaging flow.

## Why this exists

- `LLamaSharp` tracks `llama.cpp` as a submodule.
- For GLM-OCR local packaging, this branch currently needs small CMake changes in `llama.cpp`.
- Keeping those changes as a patch file makes local rebuilds reproducible and traceable.

## Current patch

- `llama.cpp.mtmd-tools.patch`
- Scope:
  - `CMakeLists.txt`
  - `tools/CMakeLists.txt`
  - `tools/mtmd/CMakeLists.txt`

## Upstream merge workflow

1. Merge/rebase upstream LLamaSharp into `GLM-OCR`.
2. Update submodule pointer as needed.
3. Run `scripts/pack-local-glm-ocr.ps1` (default applies patch).
4. If patch apply fails, refresh `llama.cpp.mtmd-tools.patch` against the new submodule revision and commit the updated patch.

## Optional future state (recommended)

If you create your own `llama.cpp` fork:

1. Push these CMake changes as normal commits to your `llama.cpp` fork.
2. Update `.gitmodules` submodule URL to your fork.
3. Update the submodule pointer commit in this repo.
4. You can then disable patch application (`-ApplyLocalLlamaCppPatch:$false`) or keep patch flow as a fallback.

