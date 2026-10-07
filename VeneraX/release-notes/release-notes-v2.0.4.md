## What's Changed

### Added
- Added sorting options for local comics and favorites lists.

### Changed
- Improved multi-chapter download progress display.
- Started image-list fetching and image downloads in a pipeline to reduce download startup time.
- Fetch chapter image lists concurrently for faster download initialization.
- Removed documentation for the deprecated configurable GitHub update source.

### Fixed
- Fixed downloads that required pause and resume before progressing normally.
- Fixed tag wrapping and bottom spacing issues on comic detail and local list pages.

### Removed
- Removed user-facing documentation for the deprecated configurable GitHub update source.

### Build / CI
- Bumped release version to `2.0.4+205`.

**Full Changelog**: https://github.com/Kyosee/venera/compare/v2.0.3...v2.0.4
