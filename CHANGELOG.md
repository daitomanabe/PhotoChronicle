# Version History

## [1.1.0] - 2026-01-12
### Added
- **Video Support**: Added support for archiving video files (`MTS`, `AVI`, `MOV`, `MP4`, `M4V`, `m2ts`, `wmv`, `flv`, `3gp`, `mpg`, `mpeg`, `dv`, `vob`, `mkv`, `webm`).
- **Media Type Selection**: Added UI toggles to select "Images", "Videos", or both for Phase 1 scanning.
- **Video Date Extraction**: Implemented logic to extract "Creation Date" from video metadata using AVFoundation, with a fallback to file modification time.

### Changed
- Updated `PlannerEngine` to support dynamic extension filtering based on user selection.
- Updated documentation (README, User Manual) to reflect video support features.

## [1.0.0] - 2026-01-09
### Added
- Initial release of PhotoChronicle.
- Core features: Phase 1 (Scanning/Hashing), Phase 2 (Safe/Fast Copy), Dedup logic, SQLite plan persistence.
