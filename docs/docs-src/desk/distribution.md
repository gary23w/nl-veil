# distribution

**File:** `desk/src/distribution.zig`  
**Module:** `desk`  
**Description:** MSIX identity and writable state. A Microsoft Store install learns its package family and moves its writable data to the package's LocalState folder; a portable build keeps its existing paths.

---

## Purpose Summary

An app installed from the Microsoft Store runs from a read-only package directory, so it cannot keep its data beside the executable the way a portable bundle does. `distribution.zig` answers the two questions that follow from that. Is this process running with package identity at all (`isPackaged`, via `GetCurrentPackageFamilyName`)? And if so, where may it write (`stateRoot`: `%LOCALAPPDATA%\Packages\<family>\LocalState`)?

`stateRoot` refuses a relative base path and a family name carrying a path separator or `..`, so a bad identity cannot point the data directory outside the package's own state folder.

## Key Exports

- `isPackaged() bool`: true only for a Windows process with package identity
- `packageFamily(gpa) !?[]u8`: the package family name, or null for a portable build
- `stateRoot(gpa, local_app_data, family)`: the per-package writable state folder
- `setWorkingDirectory(gpa, path)`: make that folder the process's working directory (Windows)

## Usage Context

`src/main.zig` resolves the data directory through it at startup when the app is packaged. `desk/src/updater.zig` reads `isPackaged` and refuses self-update for a Store install, because the Store manages updates. Packaging lives in `scripts/package-store.ps1` and `.github/workflows/windows-store.yml`.
