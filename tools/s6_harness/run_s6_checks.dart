// Session-friendly S6 verification driver.
//
// `dart run` inside VeneraX/ cannot work in this environment: the package's
// native-asset build hooks need to spawn cmd.exe, which the session sandbox
// blocks ("CreateFile failed 231"). Running from a folder with no pubspec.yaml
// ancestor skips package resolution entirely, and the model files only import
// dart:*, so relative imports compile straight from disk.
//
//   cd D:/Ballonstranslator_Windows/tools/s6_harness
//   dart run_s6_checks.dart [path/to/imgtrans_x.json]
//
// The canonical, shipped driver is VeneraX/tool/s6_project_roundtrip.dart; both
// call the same library code, and the app proves the same thing again through
// `venera.exe --headless project-check`.
import 'dart:convert';
import 'dart:io';

import '../../VeneraX/lib/foundation/translation_project/project_validator.dart';

Future<void> main(List<String> args) async {
  final projectPath = args.isNotEmpty
      ? args.first
      : 'D:/Ballonstranslator_Windows/ComicLibrary/downloads/'
            'Error the Echo/imgtrans_Error the Echo.json';

  final codecChecks = ProjectValidator.checkCodec();
  stdout.writeln('=== S6 codec conformance (vs Python json.dumps) ===');
  for (final check in codecChecks) {
    stdout.writeln('  $check');
  }

  final report = await ProjectValidator.validate(jsonFile: File(projectPath));
  stdout.writeln('=== S6 project validation ===');
  stdout.writeln(report.toText());

  final output = File('D:/Ballonstranslator_Windows/tools/s6_harness/out/'
      's6_project_check.json');
  if (!output.parent.existsSync()) output.parent.createSync(recursive: true);
  await output.writeAsString(
    const JsonEncoder.withIndent('  ').convert({
      'codec': [
        for (final check in codecChecks)
          {'name': check.name, 'passed': check.passed, 'detail': check.detail},
      ],
      'project': report.toJson(),
    }),
    encoding: utf8,
  );

  final failed = codecChecks.any((check) => !check.passed) || !report.passed;
  stdout.writeln('OVERALL: ${failed ? 'FAIL' : 'PASS'}');
  stdout.writeln('report -> ${output.path}');
  exitCode = failed ? 1 : 0;
}
