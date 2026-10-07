## What's Changed

### Added
- Windows updater now shows a WPF progress window during update (download, extract, install stages)
- Local comics page: friendly dialog when tapping a not-downloaded comic, with Import and Download options
- Sync Local Comic Images setting marked as "Experimental" with confirmation dialog warning about bandwidth/storage

### Changed
- App initialization split into critical (before UI) and deferred (after UI) phases — eliminates blank screen on Windows startup
- Image sync (`syncComicImages`) no longer triggers immediately after download/upload; deferred 30 seconds to avoid blocking startup
- Windows monitor thread: 15-second startup grace period + 10-second normal timeout (was 5s flat)
- Task status label changed from "正在检查更新" to "检查更新"

### Fixed
- Windows startup freeze/crash caused by heavy initialization blocking UI thread before first frame
- Windows updater appearing to "flash and disappear" with no feedback during update process
- Image sync blocking app startup when `syncLocalComicImages` is enabled

### Build / CI
- Version bump to 2.0.6+207

### Translations
- Added 62 missing zh_CN and zh_TW translations across the project
- Added translations for update flow, experimental feature dialog, and local comic availability prompts

**Full Changelog**: https://github.com/Kyosee/venera/compare/v2.0.5...v2.0.6
