import 'dart:io';

import 'package:analyzer/dart/element/element.dart';
import 'package:analyzer/dart/element/type.dart';
import 'package:code_builder/code_builder.dart';
import 'package:collection/collection.dart';
import 'package:dart_style/dart_style.dart';
// ignore: implementation_imports
import 'package:dart_style/src/config_cache.dart';
import 'package:one_for_all_generator/src/api_builder.dart';
import 'package:one_for_all_generator/src/codecs/codecs.dart';
import 'package:one_for_all_generator/src/handlers.dart';
import 'package:one_for_all_generator/src/options.dart';
import 'package:one_for_all_generator/src/utils.dart';
import 'package:path/path.dart';
import 'package:source_gen/source_gen.dart' show LibraryReader, TypeChecker;

class DartApiBuilder extends ApiBuilder {
  final DartOptions options;
  final ApiCodecs codecs;
  final _library = LibraryBuilder();

  @override
  String get outputFile {
    final path = pluginOptions.apiFile;
    return '${dirname(path)}/${basenameWithoutExtension(basenameWithoutExtension(path))}.api.dart';
  }

  DartApiBuilder(super.pluginOptions, this.options, this.codecs) {
    _library.comments.add(generatedCodeComment);
    _library.ignoreForFile.addAll([
      'unused_element',
      'cast_nullable_to_non_nullable',
      'prefer_if_elements_to_conditional_expressions',
      'unnecessary_lambdas',
      'curly_braces_in_flow_control_structures',
    ]);
    _library.directives.add(Directive.partOf(basename(pluginOptions.apiFile)));
  }

  void updateParameter(ParameterElement e, ParameterBuilder b) => b
    ..type = Reference('${e.type}')
    ..name = e.name;

  void _updateHostApiMethod(MethodElement e, MethodBuilder b) {
    b
      // ignore: prefer_const_constructors
      ..annotations.add(CodeExpression(Code('override')))
      ..returns = Reference('${e.returnType}')
      ..name = e.name
      ..requiredParameters.addAll(e.parameters.where((e) => !e.isNamed && e.isRequired).map((e) {
        return Parameter((b) => b..update((b) => updateParameter(e, b)));
      }))
      ..optionalParameters.addAll(e.parameters.where((e) => e.isNamed || !e.isRequired).map((e) {
        return Parameter((b) => b
          ..update((b) => updateParameter(e, b))
          ..required = e.isRequired
          ..named = e.isNamed
          ..defaultTo = e.defaultValueCode != null ? Code(e.defaultValueCode!) : null);
      }));
  }

  @override
  void writeHostApiClass(HostApiHandler handler) {
    final HostApiHandler(:element, :hostExceptionHandler) = handler;

    _library.body.add(Class((b) => b
      ..name = '_\$${codecs.encodeName(element.name)}'
      ..implements.add(Reference(element.name))
      ..fields.add(Field((b) => b
        ..static = true
        ..modifier = FieldModifier.constant
        ..name = r'_$channel'
        ..assignment = Code("MethodChannel('${handler.methodChannelName()}')")))
      ..fields.addAll(element.methods.where((e) => e.isHostApiEvent).map((e) {
        return Field((b) => b
          ..static = true
          ..modifier = FieldModifier.constant
          ..name = '_\$${e.name.no_}'
          ..assignment = Code("EventChannel('${handler.eventChannelName(e)}')"));
      }))
      ..methods.addAll(element.methods.where((e) => e.isHostApiEvent).map((e) {
        final returnType = e.returnType.singleTypeArg;

        final parameters =
            e.parameters.map((e) => codecs.encodeSerialization(e.type, e.name)).join(', ');

        final errorHandler = hostExceptionHandler != null
            ? '.handleError((error, _) {'
                '  if (error is PlatformException) ${hostExceptionHandler.accessor}(error);'
                '  throw error;'
                '})'
            : '';

        return Method((b) => b
          ..update((b) => _updateHostApiMethod(e, b))
          ..body = Code('return _\$${e.name.no_}'
              '.receiveBroadcastStream([$parameters])'
              '.map((e) => ${codecs.encodeDeserialization(returnType, 'e')})'
              '$errorHandler;'));
      }))
      ..methods.addAll(element.methods.where((e) => e.isHostApiMethod).map((e) {
        final returnType = e.returnType.singleTypeArg;

        final parameters =
            e.parameters.map((e) => codecs.encodeSerialization(e.type, e.name)).join(', ');

        String parseResult() {
          final code =
              "await _\$channel.invokeMethod('${handler.methodChannelName(e)}', [$parameters]);";
          if (returnType is VoidType) return code;
          return 'final result = $code'
              'return ${codecs.encodeDeserialization(returnType, 'result')};';
        }

        String tryParseResult() {
          if (hostExceptionHandler == null) return parseResult();
          return '''
try {
  ${parseResult()}
} on PlatformException catch(exception) {
  ${hostExceptionHandler.accessor}(exception);
  rethrow;
}''';
        }

        return Method((b) => b
          ..update((b) => _updateHostApiMethod(e, b))
          ..modifier = MethodModifier.async
          ..body = Code(tryParseResult()));
      }))));
  }

  @override
  void writeFlutterApiClass(FlutterApiHandler handler) {
    final FlutterApiHandler(:element) = handler;
    final methods = element.methods.where((e) => e.isFlutterApiMethod);

    _library.body.add(Method((b) => b
      ..returns = const Reference('void')
      ..name = '_\$setup${codecs.encodeName(element.name)}'
      ..requiredParameters.add(Parameter((b) => b
        ..type = Reference(element.name)
        ..name = 'hostApi'))
      ..body = Code('''
const channel = MethodChannel('${handler.methodChannelName()}');
channel.setMethodCallHandler((call) async {
  final args = call.arguments as List<Object?>;
  return switch (call.method) {
  ${methods.map((e) {
        final isFutureReturnType = e.returnType.isDartAsyncFuture;
        return '''
    '${e.name}' => ${isFutureReturnType ? 'await ' : ''}hostApi.${e.name}(${e.parameters.mapIndexed((i, e) => codecs.encodeDeserialization(e.type, 'args[$i]')).join(', ')}),
        ''';
      }).join('\n')}
    _ =>  throw UnsupportedError('${element.name}#Flutter.\${call.method} method'),
  };
});''')));
  }

  @override
  void writeSerializableClass(SerializableClassHandler handler, {bool withName = false}) {
    final SerializableClassHandler(:element, :flutterToHost, :hostToFlutter, :params, :children) =
        handler;

    const serializedRef = Reference('List<Object?>');
    final deserializedRef = Reference(element.name);

    if (children != null) {
      if (flutterToHost) {
        final childChecker = TypeChecker.fromStatic(element.thisType);
        final children = LibraryReader(element.library).classes.where(childChecker.isSuperOf);
        _library.body.add(Method((b) => b
          ..returns = serializedRef
          ..name = '_\$serialize${element.name}'
          ..requiredParameters.add(Parameter((b) => b
            ..type = deserializedRef
            ..name = 'deserialized'))
          ..lambda = true
          ..body = Code('switch (deserialized) {\n'
              '${children.map((e) => '  ${e.name}() => _\$serialize${e.name}(deserialized),\n').join()}'
              '}')));
      }
      for (final child in children) {
        writeSerializableClass(child, withName: true);
      }
      return;
    }

    if (flutterToHost) {
      _library.body.add(Method((b) => b
        ..returns = serializedRef
        ..name = '_\$serialize${element.name}'
        ..requiredParameters.add(Parameter((b) => b
          ..type = deserializedRef
          ..name = 'deserialized'))
        ..lambda = true
        ..body = Code('[${[
          if (withName) "'${element.name}'",
          ...params.map((e) {
            return codecs.encodeSerialization(e.type, 'deserialized.${e.name}');
          }),
        ].join(',')}]')));
    }

    if (hostToFlutter) {
      _library.body.add(Method((b) => b
        ..returns = deserializedRef
        ..name = '_\$deserialize${element.name}'
        ..requiredParameters.add(Parameter((b) => b
          ..type = serializedRef
          ..name = 'serialized'))
        ..lambda = true
        ..body = Code('${element.name}(${params.mapIndexed((i, e) {
          return '${e.name}: ${codecs.encodeDeserialization(e.type, 'serialized[$i]')}';
        }).join(',')})')));
    }
  }

  @override
  void writeSerializableEnum(SerializableEnumHandler handler) {}

  @override
  void writeException(EnumElement element) {
    // _library.body.add(Class((b) => b
    //   ..name = element.name.replaceFirst('Code', '')
    //   ..fields.add(Field((b) => b
    //     ..modifier = FieldModifier.final$
    //     ..type = Reference(element.name)
    //     ..name = 'code'))
    //   ..fields.add(Field((b) => b
    //     ..modifier = FieldModifier.final$
    //     ..type = Reference('String?')
    //     ..name = 'message'))
    //   ..fields.add(Field((b) => b
    //     ..modifier = FieldModifier.final$
    //     ..type = Reference('String?')
    //     ..name = 'details'))
    //   ..constructors.add(Constructor((b) => b
    //     ..name = '_'
    //     ..requiredParameters.add(Parameter((b) => b
    //       ..toThis = true
    //       ..name = 'code'))
    //     ..requiredParameters.add(Parameter((b) => b
    //       ..toThis = true
    //       ..name = 'message'))
    //     ..requiredParameters.add(Parameter((b) => b
    //       ..toThis = true
    //       ..name = 'details'))))
    //   ..methods.add(Method((b) => b
    //     ..annotations.add(CodeExpression(Code('override')))
    //     ..returns = Reference('String')
    //     ..name = 'toString'
    //     ..lambda = true
    //     ..body = Code('['
    //         '\'\$runtimeType: \${code.name}\', '
    //         'code.message, '
    //         'message, '
    //         'details'
    //         '].nonNulls.join(\'\\n\')')))));
  }

  @override
  Future<String> build() async {
    final cache = ConfigCache();
    final folder = '${Directory.current.path}/lib';
    final pageWidth = await cache.findPageWidth(File(folder));
    final languageVersion = await cache.findLanguageVersion(File(folder), folder);

    final formatter = DartFormatter(
      pageWidth: pageWidth,
      languageVersion: languageVersion ?? DartFormatter.latestLanguageVersion,
    );
    final emitter = DartEmitter(
      orderDirectives: true,
      useNullSafetySyntax: true,
    );
    return formatter.format('${_library.build().accept(emitter)}');
  }
}
