## What's Changed

### Added
- Unified sync button on home page (replaces separate upload/download buttons) for both App and Web
- Remote backup list in settings: browse and download specific backups from WebDAV
- `syncData()`, `listRemoteBackups()`, `downloadSpecificBackup()` APIs for both native and web platforms
- Full auto-update system ported from venera-backup
- Web-side sync service with backup listing and specific backup download

### Changed
- GitHub update source hardcoded to Kyosee/venera (removed repo owner/name/token input UI)
- Sync button behavior: single button now auto-detects whether to upload or download based on version comparison
- Release title now shows clean version (e.g. `v2.0.3`) without build number suffix

### Fixed
- Web server periodic follow-updates timer reading `followUpdatesFolder` from wrong path
- Initial sync marked as completed when local version >= remote (prevents unnecessary re-downloads)
- `followUpdatesFolder` restored to `_disableSync` list (prevents overwriting local folder config)
- Sync task duplication bug with unified WebDAV sync specification
- Reader: continuous mode swipe triggering previous chapter page jump
- Reader: "continue reading" navigating to wrong chapter
- Web mobile viewport issues on explore, search, and favorites pages

### Removed
- GitHub update source settings dialog (repo owner/name inputs, private repo toggle, token field)
- `updateRepoOwner`, `updateRepoName`, `updateUsePrivateRepo`, `updateRepoToken` settings

### Build / CI
- Explicit `name` field in release action to ensure clean version display

**Full Changelog**: https://github.com/Kyosee/venera/compare/v2.0.2...v2.0.3
