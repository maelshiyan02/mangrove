// S6 verification harness — run with:
//
//   cd VeneraX
//   dart run tool/s6_project_roundtrip.dart [path/to/imgtrans_x.json]
//
// Exits non-zero when any check fails, so it can gate a build.
//
// This is the pure-Dart half of the S6 acceptance. The app-side half is
// `venera.exe --headless project-check <path>`, which runs the same
// [ProjectValidator] from inside the shipped binary and therefore also proves
// the model really got compiled in.
import 'dart:convert';
import 'dart:io';

import 'package:venera/foundation/translation_project/json_codec.dart';
import 'package:venera/foundation/translation_project/project_validator.dart';

/// Formatting rules captured from Python's `json.dumps(v, ensure_ascii=False)`.
///
/// Hard-coded on purpose: these are the exact strings FT writes, produced by a
/// run of the real interpreter, so the codec is checked against Python rather
/// than against itself.
const Map<String, Object?> _pythonFloatCases = {
  '20.0': 20.0,
  '0.0': 0.0,
  '-0.0': -0.0,
  '1.15': 1.15,
  '166.02710622064097': 166.02710622064097,
  '0.3333333333333333': 1 / 3,
  '1000000000000000.0': 1e15,
  '1e+16': 1e16,
  '1e+20': 1e20,
  '1e+21': 1e21,
  '1e-05': 1e-5,
  '1e-07': 1e-7,
  '0.0001': 0.0001,
  '1.5e+300': 1.5e300,
  '5e-324': 5e-324,
  '100.0': 100.0,
};

/// Whole-value cases, including containers, key order and non-ASCII.
const Map<String, Object?> _pythonValueCases = {
  '690': 690,
  '-42': -42,
  '[1, 2.0, "x", true, null]': [1, 2.0, 'x', true, null],
  '{"a": 20.0, "b": 0.0}': {'a': 20.0, 'b': 0.0},
  '{"z": 1, "a": 1, "m": 1}': {'z': 1, 'a': 1, 'm': 1},
  '"简体中文"': '简体中文',
};

Future<int> main(List<String> args) async {
  final projectPath = args.isNotEmpty
      ? args.first
      : 'D:/Ballonstranslator_Windows/ComicLibrary/downloads/'
            'Error the Echo/imgtrans_Error the Echo.json';

  stdout.writeln('=== S6 codec conformance (vs Python json.dumps) ===');
  var codecFailures = 0;
  _pythonFloatCases.forEach((expected, value) {
    final actual = PyJson.encodeNumber(value as num);
    // `5e-324` collapses to `0.0` under a JS-style literal; guard that here
    // rather than silently accepting a mismatch.
    final ok = actual == expected;
    if (!ok) codecFailures++;
    stdout.writeln(
      '  ${ok ? 'PASS' : 'FAIL'} '
      '${value.runtimeType} $value -> "$actual" (expected "$expected")',
    );
  });
  _pythonValueCases.forEach((expected, value) {
    final actual = PyJson.encode(value);
    final ok = actual == expected;
    if (!ok) codecFailures++;
    stdout.writeln(
      '  ${ok ? 'PASS' : 'FAIL'} $value -> "$actual" '
      '(expected "$expected")',
    );
  });

  stdout.writeln();
  stdout.writeln('=== S6 project validation ===');
  final file = File(projectPath);
  final report = await ProjectValidator.validate(jsonFile: file);
  stdout.writeln(report.toText());

  final resultPath = 'builds/s6_project_check.json';
  final resultFile = File(resultPath);
  if (!resultFile.parent.existsSync()) {
    resultFile.parent.createSync(recursive: true);
  }
  await resultFile.writeAsString(
    const JsonEncoder.withIndent('  ').convert(report.toJson()),
    encoding: utf8,
  );

  final failed = codecFailures > 0 || !report.passed;
  stdout.writeln('OVERALL: ${failed ? 'FAIL' : 'PASS'}');
  stdout.writeln('report -> ${resultFile.absolute.path}');
  return failed ? 1 : 0;
}
