# pvs-amplified-research

**Server-Side Visibility Analytics — Research Proof-of-Concept**

This repository demonstrates a safe, research-oriented approach to server-side visibility tracking for CS2 using SourceMod 1.12. The goal is to show how a server can manage spotted enemies and reduce the potential impact of radar cheats without modifying the engine or VAC.

## Repository Contents

```
pvs-amplified-research/
├─ LICENSE                 # MIT License
├─ README.md               # Project overview and usage
├─ CONTRIBUTING.md         # Guidelines for contributors
├─ CHANGELOG.md            # Version history and updates
├─ .gitignore              # Standard ignores
├─ src/pvs_amplify.sp      # SourceMod plugin implementing LOS-based spotting
├─ examples/sample_spotted_log.txt  # Sample plugin output logs
└─ docs/design.md          # Research design and architecture
```

## Features

* Multi-sample LOS checks per target (head/chest/legs + offsets)
* Server-side caching of visibility
* Compact broadcast of spotted entries (enemy ID, expiry, optional zone)
* Configurable ConVars for interval, distance, and FOV culling
* Safe for sharing as a research proof-of-concept

## Usage

1. Compile `src/pvs_amplify.sp` using the SourceMod compiler (`spcomp`) for SourceMod 1.12.
2. Place `pvs_amplify.smx` into `addons/sourcemod/plugins/` on a test server.
3. Tune ConVars in-game or in `plugins.ini` for your server tickrate and hardware.
4. Optionally implement a client HUD to visualize spotted entries for testing purposes.

## Security & Legal Notes

* Plugin uses **only public SourceMod/SDK natives**.
* No engine-level modifications, VAC bypass, or protected memory access.
* Intended for research, testing, and concept demonstration only.
* Suitable for sharing for anti-cheat purposes.

## Contributing

See `CONTRIBUTING.md` for submitting issues or pull requests. Keep contributions limited to research-safe improvements using public APIs.

## License

MIT License — see `LICENSE` file.

## Zip Archive Generation

You can package the repo into a ZIP for sharing:

### Bash / Linux / WSL / Git Bash

```bash
cd /path/to/repo
zip -r pvs-amplified-research.zip pvs-amplified-research/
unzip -l pvs-amplified-research.zip
```

### Windows PowerShell

```powershell
cd C:\path\to\parent
Compress-Archive -Path pvs-amplified-research -DestinationPath pvs-amplified-research.zip
Expand-Archive -Path pvs-amplified-research.zip -DestinationPath C:\temp\unzip_test -Force
```

This creates `pvs-amplified-research.zip` with the complete folder structure, ready to be tested.
