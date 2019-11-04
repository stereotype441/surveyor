import 'dart:io';

import 'package:analyzer/dart/analysis/analysis_context.dart';
import 'package:analyzer/dart/analysis/results.dart';
import 'package:analyzer/dart/ast/visitor.dart';
import 'package:analyzer/error/error.dart';
import 'package:analyzer/src/generated/engine.dart' show AnalysisErrorInfoImpl;
import 'package:path/path.dart' as path;
import 'package:surveyor/src/analysis.dart';
import 'package:surveyor/src/driver.dart';
import 'package:surveyor/src/visitors.dart';

/// Analyzes projects, filtering specifically for errors of a specified type.
///
/// Run like so:
///
/// dart example/error_surveyor.dart <source dir>
main(List<String> args) async {
  final stopwatch = Stopwatch()..start();

  if (args.length == 1) {
    final dir = args[0];
    if (!File('$dir/pubspec.yaml').existsSync()) {
      print("Recursing into '$dir'...");

      args = Directory(dir)
          .listSync()
          .where(
              (f) => !path.basename(f.path).startsWith('.') && f is Directory)
          .map((f) => f.path)
          .toList()
            ..sort();
      dirCount = args.length;
      print('(Found $dirCount subdirectories.)');
    }
  }

  if (_debuglimit != null) {
    print('Limiting analysis to $_debuglimit packages.');
  }

  final driver = Driver.forArgs(args);
  driver.visitor = AnalysisAdvisor();
  driver.showErrors = true;
  driver.excludes = [''];

  await driver.analyze();

  print(
      '(Elapsed time: ${Duration(milliseconds: stopwatch.elapsedMilliseconds)})');
}

int dirCount;

class AnalysisAdvisor extends SimpleAstVisitor
    implements
        PreAnalysisCallback,
        PostAnalysisCallback,
        PostVisitCallback,
        ErrorReporter {
  int count = 0;

  AnalysisStats stats;
  HumanErrorFormatter formatter;

  AnalysisAdvisor() {
    stats = AnalysisStats();
    formatter = HumanErrorFormatter(stdout, stats);
  }

  @override
  void postAnalysis(AnalysisContext context, DriverCommands cmd) {
    cmd.continueAnalyzing = _debuglimit == null || count < _debuglimit;
  }

  @override
  void preAnalysis(AnalysisContext context,
      {bool subDir, DriverCommands commandCallback}) {
    if (subDir) {
      ++dirCount;
    }
    final root = context.contextRoot.root;
    String dirName = path.basename(root.path);
    if (subDir) {
      // Qualify.
      dirName = '${path.basename(root.parent.path)}/$dirName';
    }
    print("Analyzing '$dirName' • [${++count}/$dirCount]...");
  }

  bool showError(AnalysisError error) {
    final errorType = error.errorCode.type;
    if (errorType == ErrorType.HINT ||
        errorType == ErrorType.LINT ||
        errorType == ErrorType.TODO) {
      return false;
    }
    // todo (pq): filter on specific error type
    //print('${error.errorCode.type} :  ${error.errorCode.name}');
    return true;
  }

  @override
  void reportError(AnalysisResultWithErrors result) {
    final errors = result.errors.where(showError).toList();
    if (errors.isEmpty) {
      return;
    }
    formatter
        .formatErrors([AnalysisErrorInfoImpl(errors, result.lineInfo)]);
    formatter.flush();
  }

  @override
  void onVisitFinished() {
    stats.print();
  }
}

/// If non-null, stops once limit is reached (for debugging).
int _debuglimit; // = 300;
