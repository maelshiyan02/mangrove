## What's Changed

### Added
- Image favorites: new grid layout with a toggle button next to search. Choice persists across app restarts. Grid mode tiles every favorited image showing cover, comic title and page number.

### Changed
- Local comics now share the unified comic detail entry and load local data first.
- Web client: continue-reading button shows whenever a last-read chapter exists (no longer requires page > 1).

### Fixed
- Image favorites: fixed thumbnails not matching their comic after the list was reordered (delete / sort / filter). Root cause was position-based state reuse with a cached image list; added stable item keys and refreshed the image getter.
- Image favorites: Hero tag now includes comic id to prevent cross-comic tag collisions.
- Local comic download: fixed two defects in the local comic download path.
- Web client: reading history now refreshes correctly when returning from the reader on keep-alive pages; chapter read/current styling reflects latest progress.
- Local comics: fixed a potential null-check crash when opening a comic that is still downloading.
- Download: chapter-info fetch failures during download setup now fall back gracefully instead of breaking the flow.
- Web client: the home page no longer fires redundant background refreshes while kept alive in the background.

**Full Changelog**: https://github.com/Kyosee/venera/compare/v2.0.6...v2.0.7

