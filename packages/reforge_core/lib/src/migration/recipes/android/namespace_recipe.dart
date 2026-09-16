import '../../../common/source.dart';
import '../../../model/declarations.dart';
import '../../../model/finding.dart';
import '../../../parsing/gradle/gradle_lexer.dart';
import '../../../parsing/gradle/gradle_script.dart';
import '../../../text/text_edit.dart';
import '../../../version/tool_version.dart';
import '../../recipe.dart';
import '../../recipe_ids.dart';
import '../recipe_support.dart';

final _javaPackage =
    RegExp(r'^[A-Za-z_][A-Za-z0-9_]*(\.[A-Za-z_][A-Za-z0-9_]*)*$');

/// Moves the application namespace from AndroidManifest.xml `package`
/// attributes to `android.namespace`.
final class NamespaceRecipe extends MigrationRecipe {
  const NamespaceRecipe();

  @override
  RecipeDescriptor get descriptor => const RecipeDescriptor(
        id: RecipeIds.androidNamespace,
        title: 'Declare the Android namespace',
        summary: 'Declares android.namespace in the app module from the '
            'manifest package attribute and removes package attributes from '
            'AndroidManifest.xml files.',
        category: RecipeCategory.android,
        runsAfter: [
          RecipeIds.androidFlutterGradlePluginDsl,
          RecipeIds.androidAgpVersion,
        ],
      );

  @override
  RecipeResult evaluate(RecipeContext context) {
    final android = context.project.android;
    final app = android?.app;
    if (android == null || app == null) {
      return const NotApplicable('The project has no Android app module.');
    }
    final withPackage = android.manifests
        .where((m) => m.manifest.packageAttribute != null)
        .toList();
    if (!app.script.isReliable) {
      return NotApplicable('${app.script.path} could not be parsed reliably, '
          'so its namespace is unknown (see PROJECT_FILE_UNREADABLE).');
    }
    if (app.namespace != null && withPackage.isEmpty) {
      return const NotApplicable('android.namespace is declared and no '
          'manifest declares a package attribute.');
    }
    final agpDeclaration = android.toolchain.androidGradlePlugin;
    final agp = agpDeclaration?.version;
    if (agp == null) {
      return const NotApplicable('The Android Gradle Plugin version is '
          'unknown, so Reforge cannot tell whether the namespace is required.');
    }
    final Necessity necessity;
    if (agp >= ToolVersion(8, 0)) {
      necessity = Necessity.required;
    } else if (agp >= ToolVersion(7, 3)) {
      necessity = Necessity.recommended;
    } else {
      return NotApplicable('Android Gradle Plugin $agp still uses the '
          'manifest package attribute.');
    }

    final evidence = <Evidence>[
      declarationEvidence('Android Gradle Plugin', agpDeclaration!),
      for (final manifest in withPackage)
        Evidence.file('package="${manifest.manifest.packageAttribute}"',
            SourceRef(manifest.manifest.path)),
      if (app.namespace == null)
        Evidence.file('The android block declares no namespace',
            SourceRef(app.script.path)),
    ];
    const rationale = 'Android Gradle Plugin 8 requires the namespace to be '
        'declared in the build script and rejects the package attribute in '
        'source AndroidManifest.xml files.';

    Proposal manual(String summary, String detail, List<String> steps) =>
        Proposal(
          status: StepStatus.manual,
          necessity: necessity,
          summary: summary,
          rationale: '$rationale $detail',
          evidence: evidence,
          manualSteps: steps,
        );

    final packages =
        withPackage.map((m) => m.manifest.packageAttribute!).toSet();
    final declared = app.namespace;
    if (declared != null && declared is! LiteralString) {
      if (packages.isNotEmpty) {
        return manual(
          'Remove package attributes from AndroidManifest.xml files.',
          'The namespace is computed by an expression (${declared.text}), so '
              'Reforge cannot confirm it matches the manifests.',
          const [
            'Confirm the namespace matches the manifest package, then remove '
                'the package attributes.',
          ],
        );
      }
    }
    final declaredValue = declared is LiteralString ? declared.value : null;
    if (packages.length > 1 ||
        (declaredValue != null &&
            packages.isNotEmpty &&
            !packages.contains(declaredValue))) {
      return manual(
        'Reconcile the Android namespace.',
        'The manifests declare ${packages.join(', ')}'
            '${declaredValue == null ? '' : ' while the build script declares "$declaredValue"'}.',
        const [
          'Choose the namespace that matches the Kotlin/Java package of the app '
              'code, declare it in the android block, and remove package '
              'attributes from every AndroidManifest.xml.',
        ],
      );
    }

    final edits = <FileEdit>[];
    String? namespace;
    if (declared == null) {
      if (packages.isEmpty) {
        return manual(
          'Declare android.namespace in ${app.script.path}.',
          'No manifest declares a package attribute to derive it from.',
          const [
            'Declare namespace with the Kotlin/Java package of MainActivity.'
          ],
        );
      }
      namespace = packages.single;
      if (!_javaPackage.hasMatch(namespace)) {
        return manual(
          'Declare android.namespace in ${app.script.path}.',
          'The manifest package "$namespace" is not a valid Java package name.',
          const ['Declare a valid namespace manually.'],
        );
      }
      final insertion = _namespaceInsertion(app.script, namespace);
      if (insertion == null) {
        return manual(
          'Declare android.namespace in ${app.script.path}.',
          'The android block has a layout Reforge does not edit.',
          [
            'Add namespace "$namespace" as the first entry of the android block.'
          ],
        );
      }
      edits.add(FileEdit(app.script.path, [insertion]));
    }
    for (final manifest in withPackage) {
      final attribute = manifest.manifest.attribute('package')!;
      edits.add(FileEdit(manifest.manifest.path, [
        TextEdit.delete(attribute.leadingWhitespaceStart,
            attribute.range.end - attribute.leadingWhitespaceStart),
      ]));
    }

    return Proposal(
      status: StepStatus.auto,
      necessity: necessity,
      summary: namespace != null
          ? 'Declare namespace "$namespace" and remove the package attribute '
              'from ${withPackage.length} manifest(s).'
          : 'Remove the package attribute from ${withPackage.length} '
              'manifest(s).',
      rationale: rationale,
      impact: necessity == Necessity.required
          ? 'Android builds fail with "Namespace not specified" or "Incorrect '
              'package found in source AndroidManifest.xml".'
          : 'The Android Gradle Plugin prints deprecation warnings.',
      evidence: evidence,
      edits: edits,
      verification: const [
        VerificationCheck.staticAnalysis,
        VerificationCheck.androidBuild,
      ],
      details: {if (namespace != null) 'namespace': namespace},
    );
  }

  /// Inserts `namespace` as the first entry of the android block, matching the
  /// indentation and assignment style of the entries already there.
  static TextEdit? _namespaceInsertion(GradleScript script, String value) {
    final statement =
        script.statements.where((s) => s.isBlockNamed('android')).firstOrNull;
    if (statement == null) return null;
    final block = statement.blocks.first;
    final source = script.source;
    final lines = script.lineIndex;
    final eol = eolOf(source);
    final assignment = script.dialect == GradleDialect.kotlin ||
        block.statements.any((s) =>
            s.blocks.isEmpty &&
            s.head.length > 2 &&
            s.head[1].isPunctuation('='));
    final entry = assignment ? 'namespace = "$value"' : 'namespace "$value"';

    if (block.statements.isNotEmpty) {
      final first = block.statements.first;
      final lineStart = lines.lineStart(lines.lineOf(first.start));
      final indent = source.substring(lineStart, first.start);
      if (indent.trim().isNotEmpty) return null;
      return TextEdit.insert(lineStart, '$indent$entry$eol');
    }
    final braceIndent = lines.indentationOf(lines.lineOf(block.openBrace));
    if (lines.lineOf(block.openBrace) == lines.lineOf(block.closeBrace)) {
      return TextEdit.insert(
          block.openBrace + 1, '$eol$braceIndent    $entry$eol$braceIndent');
    }
    return TextEdit.insert(block.openBrace + 1, '$eol$braceIndent    $entry');
  }
}
