## What's Changed

### Added
- Gallery reader: fill-screen toggle for images
- Local favorites: multi-select tag/author filtering
- Local comics: status tabs (All / Downloading / Complete / Incomplete)
- Local comics: import/export menu with `.venera_comics` universal format
- Home page: export button in local comics section
- WebDAV sync: include local comics database in base sync
- WebDAV sync: background image package sync with toggle in settings
- Download: adaptive rate limiting — auto-throttle on 210, restore speed when clear

### Changed
- Local comics tab style unified to AppTabBar (matches follow-updates page)
- Follow-updates page layout simplified (inline buttons, removed text labels)
- Import menu now uses full import dialog for consistency

### Fixed
- Downloaded comics not showing in "Downloading" tab
- Hero tag conflicts between download tasks and local comic tiles
- Multi-chapter download: defensive re-fetch when chapter data lost during task restore
- Adaptive throttle timing: use request start time for accurate rate-limit detection
- Local comics deduplication: O(1) Set lookup replaces O(n*m) scan
- Multiple authors display in favorites filter

### Build / CI
- Web PWA: search error handling and experience improvements

**Full Changelog**: https://github.com/Kyosee/venera/compare/v2.0.4...v2.0.5
