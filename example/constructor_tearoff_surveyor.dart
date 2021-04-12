//  Copyright 2021 Google LLC
//
//  Licensed under the Apache License, Version 2.0 (the "License");
//  you may not use this file except in compliance with the License.
//  You may obtain a copy of the License at
//
//      https://www.apache.org/licenses/LICENSE-2.0
//
//  Unless required by applicable law or agreed to in writing, software
//  distributed under the License is distributed on an "AS IS" BASIS,
//  WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
//  See the License for the specific language governing permissions and
//  limitations under the License.

import 'dart:io';

import 'package:analyzer/dart/ast/ast.dart';
import 'package:analyzer/dart/ast/visitor.dart';
import 'package:analyzer/dart/element/element.dart';
import 'package:analyzer/dart/element/type.dart';
import 'package:surveyor/src/driver.dart';

void main(List<String> args) async {
  if (args.length == 1) {
    var dir = args[0];
    if (!File('$dir/pubspec.yaml').existsSync()) {
      print("Recursing into '$dir'...");
      args = Directory(dir).listSync().map((f) => f.path).toList()..sort();
      dirCount = args.length;
      print('(Found $dirCount subdirectories.)');
    }
  }

  if (_debugLimit != 0) {
    print('Limiting analysis to $_debugLimit packages.');
  }

  var stopwatch = Stopwatch()..start();

  _Analysis<Object> analysis = _ConstructorTearoffAnalysis();
  await analysis.run(args);

  stopwatch.stop();

  var duration = Duration(milliseconds: stopwatch.elapsedMilliseconds);

  print('(Elapsed time: $duration)');
}

int dirCount = 0;

/// If non-zero, stops once limit is reached (for debugging).
int _debugLimit = 0;

abstract class _Analysis<Value> {
  Future<void> run(List<String> args) async {
    var outputs = <String, List<Value>>{};

    var driver = Driver.forArgs(args);
    driver.forceSkipInstall = true;
    driver.showErrors = false;
    driver.resolveUnits = true;
    driver.visitor = _createVisitor((key, value) {
      (outputs[key] ??= []).add(value);
    });

    await driver.analyze();

    var results = {
      for (var entry in outputs.entries) entry.key: _reduce(entry.value)
    };
    for (var entry in results.entries) {
      _show(entry.key, entry.value);
    }
  }

  AstVisitor<dynamic> _createVisitor(void Function(String, Value) output);

  Value _reduce(List<Value> values);

  void _show(String key, Value value);
}

class _Collector extends RecursiveAstVisitor {
  final void Function(String key, _CountAndExamples value) _output;

  _Collector(this._output);

  @override
  void visitBlockFunctionBody(BlockFunctionBody node) {
    var statements = node.block.statements;
    if (statements.length == 1) {
      var statement = statements.single;
      if (statement is ReturnStatement) {
        _checkForSimpleConstructorInvocation(
            statement.expression, _extractFormalParameters(node.parent));
      }
    }
    super.visitBlockFunctionBody(node);
  }

  @override
  void visitExpressionFunctionBody(ExpressionFunctionBody node) {
    _checkForSimpleConstructorInvocation(
        node.expression, _extractFormalParameters(node.parent));
    super.visitExpressionFunctionBody(node);
  }

  @override
  void visitPrefixedIdentifier(PrefixedIdentifier node) {
    _handleIdentifier(node);
    super.visitPrefixedIdentifier(node);
  }

  @override
  void visitSimpleIdentifier(SimpleIdentifier node) {
    _handleIdentifier(node);
    super.visitSimpleIdentifier(node);
  }

  void _checkForSimpleConstructorInvocation(
      Expression? expression, FormalParameterList? formalParameters) {
    if (expression is! InstanceCreationExpression) return;
    late var formalParameterElements = {
      for (var parameter in formalParameters?.parameters ?? const [])
        parameter.declaredElement
    };
    for (var argument in expression.argumentList.arguments) {
      if (argument is NamedExpression) {
        argument = argument.expression;
      }
      if (argument is! SimpleIdentifier) return;
      if (!formalParameterElements.contains(argument.staticElement)) {
        return;
      }
    }
    var formalParametersParent = formalParameters?.parent;
    var confidence = formalParametersParent is FunctionExpression &&
            formalParametersParent.parent is! FunctionDeclaration
        ? 'high'
        : 'low';
    var namedness = expression.constructorName.staticElement!.name.isEmpty
        ? 'unnamed'
        : 'named';
    _output('$confidence confidence $namedness constructor tearoff',
        _item(formalParametersParent ?? expression));
  }

  FormalParameterList? _extractFormalParameters(AstNode? parent) {
    if (parent is FunctionExpression) {
      return parent.parameters;
    } else if (parent is MethodDeclaration) {
      return parent.parameters;
    } else if (parent is ConstructorDeclaration) {
      return parent.parameters;
    }
    throw 'Unexpected parent: ${parent.runtimeType}';
  }

  void _handleIdentifier(Identifier node) {
    if (node.parent is TypeAnnotation) return;
    var type = node.staticType;
    if (type is InterfaceType) {
      var typeElement = type.element;
      if (typeElement.library.isDartCore && typeElement.name == 'Type') {
        var element = node.staticElement;
        if (element is TypeDefiningElement) {
          _output('type literal', _item(node));
        }
      }
    }
  }

  _CountAndExamples _item(AstNode node) {
    var source =
        node.thisOrAncestorOfType<CompilationUnit>()!.declaredElement!.source;
    var offset = node.offset;
    return _CountAndExamples(1, ['$source@$offset: $node']);
  }
}

class _ConstructorTearoffAnalysis extends _Analysis<_CountAndExamples> {
  @override
  AstVisitor _createVisitor(void Function(String, _CountAndExamples) output) =>
      _Collector(output);

  @override
  _CountAndExamples _reduce(List<_CountAndExamples> values) {
    var total = 0;
    var examples = <String>[];
    for (var value in values) {
      total += value._count;
      examples.addAll(value._examples);
    }
    return _CountAndExamples(total, examples);
  }

  @override
  void _show(String key, _CountAndExamples value) {
    print('$key: $value');
    for (var example in value._examples) {
      print('- $example');
    }
  }
}

class _CountAndExamples {
  final int _count;

  final List<String> _examples;

  _CountAndExamples(this._count, this._examples);
}
