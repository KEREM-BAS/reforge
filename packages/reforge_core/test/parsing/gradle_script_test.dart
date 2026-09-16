import 'package:reforge_core/src/parsing/gradle/gradle_lexer.dart';
import 'package:reforge_core/src/parsing/gradle/gradle_script.dart';
import 'package:reforge_core/src/parsing/gradle/gradle_semantics.dart';
import 'package:test/test.dart';

/// Flutter 3.0 `android/settings.gradle` (imperative plugin loader).
const flutter30Settings = r'''
include ':app'

def localPropertiesFile = new File(rootProject.projectDir, "local.properties")
def properties = new Properties()

assert localPropertiesFile.exists()
localPropertiesFile.withReader("UTF-8") { reader -> properties.load(reader) }

def flutterSdkPath = properties.getProperty("flutter.sdk")
assert flutterSdkPath != null, "flutter.sdk not set in local.properties"
apply from: "$flutterSdkPath/packages/flutter_tools/gradle/app_plugin_loader.gradle"
''';

/// Flutter 3.0 `android/build.gradle`.
const flutter30RootBuild = r'''
buildscript {
    ext.kotlin_version = '1.6.10'
    repositories {
        google()
        mavenCentral()
    }

    dependencies {
        classpath 'com.android.tools.build:gradle:7.1.2'
        classpath "org.jetbrains.kotlin:kotlin-gradle-plugin:$kotlin_version"
    }
}

allprojects {
    repositories {
        google()
        mavenCentral()
    }
}

rootProject.buildDir = '../build'
subprojects {
    project.buildDir = "${rootProject.buildDir}/${project.name}"
}
subprojects {
    project.evaluationDependsOn(':app')
}

task clean(type: Delete) {
    delete rootProject.buildDir
}
''';

/// Flutter 3.16 `android/settings.gradle` (closure invoked separately).
const flutter316Settings = r'''
pluginManagement {
    def flutterSdkPath = {
        def properties = new Properties()
        file("local.properties").withInputStream { properties.load(it) }
        def flutterSdkPath = properties.getProperty("flutter.sdk")
        assert flutterSdkPath != null, "flutter.sdk not set in local.properties"
        return flutterSdkPath
    }
    settings.ext.flutterSdkPath = flutterSdkPath()

    includeBuild("${settings.ext.flutterSdkPath}/packages/flutter_tools/gradle")

    repositories {
        google()
        mavenCentral()
        gradlePluginPortal()
    }

    plugins {
        id "dev.flutter.flutter-gradle-plugin" version "1.0.0" apply false
    }
}

plugins {
    id "dev.flutter.flutter-plugin-loader" version "1.0.0"
    id "com.android.application" version "7.3.0" apply false
}

include ":app"
''';

/// Flutter 3.44 `android/settings.gradle.kts`.
const flutter344SettingsKts = r'''
pluginManagement {
    val flutterSdkPath =
        run {
            val properties = java.util.Properties()
            file("local.properties").inputStream().use { properties.load(it) }
            val flutterSdkPath = properties.getProperty("flutter.sdk")
            require(flutterSdkPath != null) { "flutter.sdk not set in local.properties" }
            flutterSdkPath
        }

    includeBuild("$flutterSdkPath/packages/flutter_tools/gradle")

    repositories {
        google()
        mavenCentral()
        gradlePluginPortal()
    }
}

plugins {
    id("dev.flutter.flutter-plugin-loader") version "1.0.0"
    id("com.android.application") version "9.0.1" apply false
    id("org.jetbrains.kotlin.android") version "2.3.20" apply false
}

include(":app")
''';

/// Flutter 3.44 `android/build.gradle.kts`.
const flutter344RootBuildKts = r'''
allprojects {
    repositories {
        google()
        mavenCentral()
    }
}

val newBuildDir: Directory =
    rootProject.layout.buildDirectory
        .dir("../../build")
        .get()
rootProject.layout.buildDirectory.value(newBuildDir)

subprojects {
    val newSubprojectBuildDir: Directory = newBuildDir.dir(project.name)
    project.layout.buildDirectory.value(newSubprojectBuildDir)
}
subprojects {
    project.evaluationDependsOn(":app")
}

tasks.register<Delete>("clean") {
    delete(rootProject.layout.buildDirectory)
}
''';

void main() {
  group('lexer', () {
    test('decodes string escapes and interpolation references', () {
      final lexed = GradleLexer(
              r'''x "a\tb $name ${other.path} ${call("q")} \$literal"''',
              GradleDialect.groovy)
          .tokenize();
      expect(lexed.diagnostics, isEmpty);
      final literal = lexed.tokens[1].string!;
      expect(literal.hasInterpolation, isTrue);
      final references = literal.parts
          .whereType<GradleInterpolation>()
          .map((p) => p.reference)
          .toList();
      expect(references, ['name', 'other.path', null]);
      expect(literal.templateText,
          'a\tb \$name \${other.path} \${call("q")} \$literal');
    });

    test('single-quoted Groovy strings do not interpolate', () {
      final lexed =
          GradleLexer(r"x '$notInterpolated'", GradleDialect.groovy).tokenize();
      expect(lexed.tokens[1].string!.constantValue, r'$notInterpolated');
    });

    test('Groovy dotted interpolation vs Kotlin simple names', () {
      final groovy =
          GradleLexer(r'x "$a.b/c"', GradleDialect.groovy).tokenize();
      expect(
          (groovy.tokens[1].string!.parts.first as GradleInterpolation)
              .reference,
          'a.b');
      final kotlin =
          GradleLexer(r'x "$a.b/c"', GradleDialect.kotlin).tokenize();
      expect(
          (kotlin.tokens[1].string!.parts.first as GradleInterpolation)
              .reference,
          'a');
    });

    test('Kotlin raw strings keep backslashes', () {
      final lexed =
          GradleLexer(r'val x = """C:\path\n"""', GradleDialect.kotlin)
              .tokenize();
      expect(lexed.tokens[3].string!.constantValue, r'C:\path\n');
    });

    test('Groovy slashy strings versus division', () {
      final lexed = GradleLexer(
              'def r = /[0-9]+\\/x/\ndef d = a / b / c\n', GradleDialect.groovy)
          .tokenize();
      expect(lexed.diagnostics, isEmpty);
      final strings =
          lexed.tokens.where((t) => t.kind == GradleTokenKind.string).toList();
      expect(strings, hasLength(1));
      expect(strings.single.string!.constantValue, '[0-9]+/x');
    });

    test('comments are recorded, and Kotlin block comments nest', () {
      final lexed = GradleLexer(
              '/* outer /* inner */ still comment */ val a = 1 // tail',
              GradleDialect.kotlin)
          .tokenize();
      expect(lexed.diagnostics, isEmpty);
      expect(lexed.comments, hasLength(2));
      expect(lexed.tokens.first.text, 'val');
    });

    test('reports unterminated strings', () {
      final lexed = GradleLexer('x "open', GradleDialect.groovy).tokenize();
      expect(lexed.diagnostics, isNotEmpty);
    });

    test('ignores a byte order mark and CRLF line endings', () {
      final lexed = GradleLexer('\uFEFFandroid {\r\n    namespace "a"\r\n}\r\n',
              GradleDialect.groovy)
          .tokenize();
      expect(lexed.diagnostics, isEmpty);
      expect(lexed.tokens.first.text, 'android');
    });
  });

  group('structure', () {
    test('Flutter 3.0 settings.gradle', () {
      final script =
          GradleScript.parse('android/settings.gradle', flutter30Settings);
      expect(script.isReliable, isTrue, reason: '${script.diagnostics}');
      expect(script.statements.map((s) => s.leadingPath), [
        'include',
        'def',
        'def',
        'assert',
        'localPropertiesFile.withReader',
        'def',
        'assert',
        'apply',
      ]);
      final withReader = script.statements[4];
      expect(withReader.blocks.single.parameters, ['reader']);
      final apply = parseApplyStatement(script.statements.last)!;
      expect(apply.kind, 'from');
      expect(apply.value!.templateText,
          r'$flutterSdkPath/packages/flutter_tools/gradle/app_plugin_loader.gradle');
    });

    test('Flutter 3.0 root build.gradle', () {
      final script =
          GradleScript.parse('android/build.gradle', flutter30RootBuild);
      expect(script.isReliable, isTrue, reason: '${script.diagnostics}');
      expect(script.statements.map((s) => s.leadingPath), [
        'buildscript',
        'allprojects',
        'rootProject.buildDir',
        'subprojects',
        'subprojects',
        'task',
      ]);
      final dependencies = script.findBlock(['buildscript', 'dependencies'])!;
      final notations =
          dependencies.statements.map(parseDependencyNotation).toList();
      expect(notations.map((n) => n!.module), [
        'com.android.tools.build:gradle',
        'org.jetbrains.kotlin:kotlin-gradle-plugin',
      ]);
      expect(
          notations.map((n) => n!.versionText), ['7.1.2', r'$kotlin_version']);

      final definitions = findVariableDefinitions(script, 'kotlin_version');
      expect(definitions.single.literalValue, '1.6.10');
      expect(
          isReferenced(script, 'kotlin_version',
              excluding: {definitions.single.statement}),
          isTrue);
    });

    test('Flutter 3.16 settings.gradle with a separately invoked closure', () {
      final script =
          GradleScript.parse('android/settings.gradle', flutter316Settings);
      expect(script.isReliable, isTrue, reason: '${script.diagnostics}');
      expect(script.statements.map((s) => s.leadingPath),
          ['pluginManagement', 'plugins', 'include']);
      final pluginManagement = script.findBlock(['pluginManagement'])!;
      expect(pluginManagement.statements.map((s) => s.leadingPath), [
        'def',
        'settings.ext.flutterSdkPath',
        'includeBuild',
        'repositories',
        'plugins',
      ]);
      final plugins = parsePluginsBlock(script.findBlock(['plugins'])!);
      expect(plugins.unrecognized, isEmpty);
      expect(plugins.declarations.map((d) => d.id), [
        'dev.flutter.flutter-plugin-loader',
        'com.android.application',
      ]);
      final agp = plugins.byId('com.android.application')!;
      expect(agp.version, '7.3.0');
      expect(agp.apply, isFalse);
      expect(agp.syntax, GradlePluginSyntax.idCommand);
      expect(
          script.source.substring(agp.versionToken!.string!.contentRange.offset,
              agp.versionToken!.string!.contentRange.end),
          '7.3.0');
    });

    test('Flutter 3.44 settings.gradle.kts', () {
      final script = GradleScript.parse(
          'android/settings.gradle.kts', flutter344SettingsKts);
      expect(script.dialect, GradleDialect.kotlin);
      expect(script.isReliable, isTrue, reason: '${script.diagnostics}');
      final pluginManagement = script.findBlock(['pluginManagement'])!;
      expect(pluginManagement.statements.map((s) => s.leadingPath),
          ['val', 'includeBuild', 'repositories']);
      final plugins = parsePluginsBlock(script.findBlock(['plugins'])!);
      expect(plugins.unrecognized, isEmpty);
      expect(plugins.declarations.map((d) => (d.id, d.version, d.apply)), [
        ('dev.flutter.flutter-plugin-loader', '1.0.0', null),
        ('com.android.application', '9.0.1', false),
        ('org.jetbrains.kotlin.android', '2.3.20', false),
      ]);
      expect(plugins.declarations.first.syntax, GradlePluginSyntax.idCall);
    });

    test('Flutter 3.44 build.gradle.kts with chained calls across lines', () {
      final script = GradleScript.parse(
          'android/build.gradle.kts', flutter344RootBuildKts);
      expect(script.isReliable, isTrue, reason: '${script.diagnostics}');
      expect(script.statements.map((s) => s.leadingPath), [
        'allprojects',
        'val',
        'rootProject.layout.buildDirectory.value',
        'subprojects',
        'subprojects',
        'tasks.register',
      ]);
    });

    test('if/else chains form a single statement', () {
      final script = GradleScript.parse('build.gradle', '''
if (a) {
    x()
}
else if (b) {
    y()
} else {
    z()
}
after()
''');
      expect(script.isReliable, isTrue);
      expect(script.statements, hasLength(2));
      expect(script.statements.first.blocks, hasLength(3));
    });

    test('Android block property styles', () {
      final script = GradleScript.parse('app/build.gradle', '''
android {
    namespace "com.example.groovy"
    compileSdkVersion 34
    ndkVersion = flutter.ndkVersion
    defaultConfig {
        minSdkVersion(21)
    }
}
''');
      final android = script.findBlock(['android'])!;
      String? valueOf(GradleBlock block, String name) {
        for (final statement in block.statements) {
          final value = statement.propertyValue(name);
          if (value != null) return value.map((t) => t.text).join();
        }
        return null;
      }

      expect(valueOf(android, 'namespace'), '"com.example.groovy"');
      expect(valueOf(android, 'compileSdkVersion'), '34');
      expect(valueOf(android, 'ndkVersion'), 'flutter.ndkVersion');
      expect(
          valueOf(
              script.findBlock(['android', 'defaultConfig'])!, 'minSdkVersion'),
          '21');
    });

    test('plugin declaration forms', () {
      final script = GradleScript.parse('settings.gradle.kts', '''
plugins {
    kotlin("android") version "1.9.0" apply false
    id("com.google.gms.google-services").version("4.4.0").apply(false)
    alias(libs.plugins.android.application) apply false
    `kotlin-dsl`
    id(pluginId)
}
''');
      final plugins = parsePluginsBlock(script.findBlock(['plugins'])!);
      expect(plugins.declarations.map((d) => (d.id, d.version, d.apply)), [
        ('org.jetbrains.kotlin.android', '1.9.0', false),
        ('com.google.gms.google-services', '4.4.0', false),
        (null, null, false),
        ('kotlin-dsl', null, null),
      ]);
      expect(plugins.declarations[2].catalogAlias,
          'libs.plugins.android.application');
      expect(plugins.unrecognized, hasLength(1));
    });

    test('unbalanced braces make a script unreliable', () {
      final script = GradleScript.parse('build.gradle', 'android {\n  x 1\n');
      expect(script.isReliable, isFalse);
      final extra = GradleScript.parse('build.gradle', 'android {}\n}\n');
      expect(extra.isReliable, isFalse);
    });

    test('variable definitions in ext blocks and Kotlin extras', () {
      final groovy = GradleScript.parse('build.gradle', '''
ext {
    agp_version = '8.1.0'
}
''');
      expect(findVariableDefinitions(groovy, 'agp_version').single.literalValue,
          '8.1.0');
      final kotlin = GradleScript.parse('build.gradle.kts', '''
extra["kotlin_version"] = "1.9.22"
val agpVersion: String = "8.2.0"
''');
      expect(
          findVariableDefinitions(kotlin, 'kotlin_version').single.literalValue,
          '1.9.22');
      expect(findVariableDefinitions(kotlin, 'agpVersion').single.literalValue,
          '8.2.0');
    });
  });
}
