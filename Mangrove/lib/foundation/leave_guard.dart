// dart:async comes through the export below? No — keep it explicit: this file
// has **no Flutter dependency** so headless checks can exercise it directly.

import 'dart:async';

/// A veto over "the user is about to leave the current screen".
///
/// Returning `true` means "go ahead". The registry treats every non-`true`
/// answer — including a thrown error — as "stay".
typedef LeaveGuard = Future<bool> Function();

/// Global, ordered stack of [LeaveGuard]s contributed by live editors.
///
/// ## Why this exists
///
/// `PopScope` alone cannot protect an editing screen on this app. Flutter's
/// `PopScope` only makes `ModalRoute.popDisposition` return `doNotPop`, which
/// `Navigator.maybePop` consults. Every *imperative* removal skips that check
/// entirely — `NavigatorState.pop()` goes straight to
/// `_RouteEntry.pop(imperativeRemoval: true)` and never looks at
/// `popDisposition`. This app leaves the editor imperatively on four paths:
///
/// | path | mechanism | `PopScope` catches it? |
/// |---|---|---|
/// | system back / app-bar back | `Navigator.maybePop` | yes |
/// | iOS edge swipe | `maybePop` | yes |
/// | sidebar navigation | `NaviPaneState.updatePage` → `popUntil` | **no** |
/// | title-bar close button | `WindowFrameController.addCloseListener` | **no** |
/// | Alt+F4 / taskbar close | `window_manager` `onWindowClose` | **no** |
///
/// So each of those call sites asks this registry instead, and the editor
/// registers exactly one guard that renders the "you have unsaved changes"
/// prompt. Adding a second editor means registering a second guard, not
/// patching five call sites.
///
/// A guard is asked **top-down** (most recently registered first) and the
/// first refusal wins, mirroring the LIFO rule the window-close listener chain
/// already uses (`_WindowFrameState._onClose`).
class LeaveGuardRegistry {
  const LeaveGuardRegistry._();

  static final List<LeaveGuard> _guards = [];

  /// Whether any screen currently wants a say in leaving.
  ///
  /// Callers that would otherwise *enable* interception (e.g. arming
  /// `windowManager.setPreventClose`) can check this to stay out of the way
  /// when there is nothing to protect.
  static bool get hasGuards => _guards.isNotEmpty;

  /// Registers [guard]. Registering the same closure twice is a no-op, so a
  /// rebuild that re-runs the registration cannot grow the stack.
  static void add(LeaveGuard guard) {
    if (_guards.contains(guard)) return;
    _guards.add(guard);
  }

  /// Removes [guard]. Safe to call when it was never registered — the dispose
  /// path must not need to know whether `initState` got as far as `add`.
  static void remove(LeaveGuard guard) => _guards.remove(guard);

  /// Asks every guard, newest first. `true` only if all of them agree.
  ///
  /// A guard that throws is treated as a refusal: losing an edit because a
  /// dialog failed to build is strictly worse than an unexpected "stay".
  static Future<bool> requestLeave() async {
    if (_guards.isEmpty) return true;
    for (final guard in _guards.reversed.toList()) {
      try {
        if (!await guard()) return false;
      } catch (e) {
        return false;
      }
    }
    return true;
  }
}