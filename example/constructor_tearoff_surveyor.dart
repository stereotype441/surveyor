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

  var collector = _Collector();

  var stopwatch = Stopwatch()..start();

  var driver = Driver.forArgs(args);
  driver.forceSkipInstall = true;
  driver.showErrors = false;
  driver.resolveUnits = true;
  driver.visitor = collector;

  await driver.analyze();

  stopwatch.stop();

  var duration = Duration(milliseconds: stopwatch.elapsedMilliseconds);

  print('(Elapsed time: $duration)');
  print('');
  _summarize(collector._typeLiterals, 'type literal');
  for (var confidenceEntry in collector._tearoffs.entries) {
    for (var namednessEntry in confidenceEntry.value.entries) {
      _summarize(namednessEntry.value,
          '${confidenceEntry.key} confidence ${namednessEntry.key} tearoff');
    }
  }
}

int dirCount = 0;

/// If non-zero, stops once limit is reached (for debugging).
int _debugLimit = 0;

void _summarize(List<String> instances, String what) {
  var s = instances.length == 1 ? '' : 's';
  print('***** Found ${instances.length} $what$s');
  for (var instance in instances) {
    print('  $instance');
  }
}

class _Collector extends RecursiveAstVisitor {
  final List<String> _typeLiterals = [];

  final Map<String, Map<String, List<String>>> _tearoffs = {
    for (var confidence in ['high', 'low'])
      confidence: {
        for (var namedness in ['unnamed', 'named']) namedness: []
      }
  };

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
    _record(_tearoffs[confidence]![namedness]!, expression);
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
          _record(_typeLiterals, node);
        }
      }
    }
  }

  void _record(List<String> instances, AstNode node) {
    var compilationUnit = node.thisOrAncestorOfType<CompilationUnit>();
    var offset = node.offset;
    instances.add('$node at $offset in ${compilationUnit?.declaredElement}');
  }
}
