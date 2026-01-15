# Changelog

<!-- markdownlint-disable MD024 -->

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.0.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [1.0.4] - 2026-01-14

### Changed

- UI: Removed the global "Filters" header and positioned per-filter titles directly above each control (Faction, Race, Class, Level). Labels are now centered above each dropdown and widths adjusted to match controls.



## [1.0.3] - 2025-12-30

### Added

- List view statistics header:
  - Total players (for current filters)
  - Most detected class
  - Most played race
  - Level spread (min-max) and average level (based on known levels only)
- Per-class average level displayed under each class header.
- Class-counts summary near the top of the list (counts per class for current filters).

### Changed

- Sorting now prioritizes classes by frequency (most seen first), then class name, then recency.
- Race tokens are normalized for display/statistics (e.g., `NightElf` → `Night Elf`, `BloodElf` → `Blood Elf`).

## [1.0.2] - 2025-12-29

### Changed

- Grouped the player list by class with class headers.
- Updated list sorting to prioritize class grouping.

## [1.0.1] - 2025-12-29

### Added

- Settings management (quiet mode and print throttling).
- `/cs refresh`, `/cs help`, and improved `/cs` command handling.

### Changed

- Improved age formatting in the list view.
- Improved player scanning robustness (GUID validation and safer scanning from combat log events).

## [1.0.0] - 2025-12-29

### Added

- Initial release of ClassScanner.
- Tracks player race/class/level when encountered (target, mouseover, combat log proximity).
