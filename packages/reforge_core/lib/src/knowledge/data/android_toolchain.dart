// Curated Android toolchain compatibility tables.
//
// Every table records its source and retrieval date. When a source is
// updated, update the table and the date together, and add a test for the
// new rows.

import '../knowledge_source.dart';

const agpGradleSource = KnowledgeSource(
  title:
      'Android Gradle plugin: update Gradle (minimum required Gradle version)',
  url: 'https://developer.android.com/build/releases/about-agp#updating-gradle',
  retrieved: '2026-09-16',
);

/// Minimum Gradle version required by each Android Gradle Plugin minor line.
const agpMinimumGradle = <String, String>{
  '9.4': '9.6.0',
  '9.3': '9.5.0',
  '9.2': '9.4.1',
  '9.1': '9.3.1',
  '9.0': '9.1.0',
  '8.13': '8.13',
  '8.12': '8.13',
  '8.11': '8.13',
  '8.10': '8.11.1',
  '8.9': '8.11.1',
  '8.8': '8.10.2',
  '8.7': '8.9',
  '8.6': '8.7',
  '8.5': '8.7',
  '8.4': '8.6',
  '8.3': '8.4',
  '8.2': '8.2',
  '8.1': '8.0',
  '8.0': '8.0',
  '7.4': '7.5',
  '7.3': '7.4',
  '7.2': '7.3.3',
  '7.1': '7.2',
  '7.0': '7.0',
  '4.2': '6.7.1',
  '4.1': '6.5',
  '4.0': '6.1.1',
  '3.6': '5.6.4',
  '3.5': '5.4.1',
  '3.4': '5.1.1',
  '3.3': '4.10.1',
};

const gradleJavaSource = KnowledgeSource(
  title: 'Gradle compatibility matrix (support for running Gradle)',
  url: 'https://docs.gradle.org/current/userguide/compatibility.html',
  retrieved: '2026-09-16',
);

/// For each Java major version: the first Gradle version that can run on it,
/// and the last Gradle line that still can (`null` = still supported).
const gradleJavaSupport = <int, ({String first, String? last})>{
  8: (first: '2.0', last: '8.14'),
  9: (first: '4.3', last: '8.14'),
  10: (first: '4.7', last: '8.14'),
  11: (first: '5.0', last: '8.14'),
  12: (first: '5.4', last: '8.14'),
  13: (first: '6.0', last: '8.14'),
  14: (first: '6.3', last: '8.14'),
  15: (first: '6.7', last: '8.14'),
  16: (first: '7.0', last: '8.14'),
  17: (first: '7.3', last: null),
  18: (first: '7.5', last: null),
  19: (first: '7.6', last: null),
  20: (first: '8.3', last: null),
  21: (first: '8.5', last: null),
  22: (first: '8.8', last: null),
  23: (first: '8.10', last: null),
  24: (first: '8.14', last: null),
  25: (first: '9.1.0', last: null),
  26: (first: '9.4.0', last: null),
};

const agpJavaSource = KnowledgeSource(
  title:
      'Flutter tool Java/AGP compatibility list (gradle_utils.dart, 3.47.0), '
      'mirroring the Android Gradle plugin release notes',
  url:
      'https://github.com/flutter/flutter/blob/3.47.0/packages/flutter_tools/lib/src/android/gradle_utils.dart',
  retrieved: '2026-09-16',
);

/// Minimum Java version required to run each Android Gradle Plugin line.
/// Keys are inclusive lower bounds of AGP versions.
const agpMinimumJava = <String, int>{
  '8.0': 17,
  '7.0': 11,
  '4.2': 8,
};

const apiLevelAgpSource = KnowledgeSource(
  title: 'Android Gradle plugin: API level support',
  url:
      'https://developer.android.com/build/releases/about-agp#api-level-support',
  retrieved: '2026-09-16',
);

/// Minimum Android Gradle Plugin version supporting each compile API level.
const apiLevelMinimumAgp = <int, String>{
  37: '9.1.1',
  36: '8.9.1',
  35: '8.6.0',
  34: '8.1.1',
  33: '7.2',
};

const pluginMarkerSource = KnowledgeSource(
  title: "Flutter breaking change: deprecated imperative apply of Flutter's "
      'Gradle plugins (plugin ids for AGP, Kotlin, Google Services and '
      'Crashlytics)',
  url:
      'https://docs.flutter.dev/release/breaking-changes/flutter-gradle-plugin-apply',
  retrieved: '2026-09-16',
);

/// Buildscript classpath artifacts whose Gradle plugin ids are documented for
/// use in a `plugins {}` block. Artifacts not listed here are never mapped by
/// guessing.
const classpathPluginIds = <String, String>{
  'com.android.tools.build:gradle': 'com.android.application',
  'org.jetbrains.kotlin:kotlin-gradle-plugin': 'org.jetbrains.kotlin.android',
  'com.google.gms:google-services': 'com.google.gms.google-services',
  'com.google.firebase:firebase-crashlytics-gradle':
      'com.google.firebase.crashlytics',
};

/// Legacy short plugin ids and their canonical ids.
const pluginIdAliases = <String, String>{
  'kotlin-android': 'org.jetbrains.kotlin.android',
  'com.android.application': 'com.android.application',
};

const jetifierTemplateRemovalSource = KnowledgeSource(
  title: 'flutter/flutter#173430: Remove jetifier usage from Android templates '
      '(Flutter no longer uses the Support Library; Jetifier fails on class '
      'files of newer Java versions)',
  url: 'https://github.com/flutter/flutter/issues/173430',
  retrieved: '2026-09-16',
);

const buildAnalyzerJetifierSource = KnowledgeSource(
  title: 'Android Studio Build Analyzer: Check Jetifier',
  url: 'https://developer.android.com/build/build-analyzer',
  retrieved: '2026-09-16',
);

const androidxMigrationSource = KnowledgeSource(
  title: 'Migrate to AndroidX',
  url: 'https://developer.android.com/jetpack/androidx/migrate',
  retrieved: '2026-09-16',
);

const agp9ReleaseNotesSource = KnowledgeSource(
  title: 'Android Gradle plugin 9.0.0 release notes: behavior changes '
      '(android.newDsl and android.builtInKotlin default to true)',
  url: 'https://developer.android.com/build/releases/agp-9-0-0-release-notes',
  retrieved: '2026-09-16',
);

const androidApiLevelsSource = KnowledgeSource(
  title: 'Android API levels and platform versions',
  url:
      'https://developer.android.com/guide/topics/manifest/uses-sdk-element#api-level-table',
  retrieved: '2026-09-16',
);

/// The Android platform version of each API level.
const androidApiLevelVersions = <int, String>{
  16: '4.1',
  17: '4.2',
  18: '4.3',
  19: '4.4',
  20: '4.4W',
  21: '5.0',
  22: '5.1',
  23: '6.0',
  24: '7.0',
  25: '7.1',
  26: '8.0',
  27: '8.1',
  28: '9',
  29: '10',
  30: '11',
  31: '12',
  32: '12L',
  33: '13',
  34: '14',
  35: '15',
  36: '16',
};

const agp8NamespaceSource = KnowledgeSource(
  title: 'Android Gradle plugin 8.0.0 release notes: namespace required in '
      'module-level build script',
  url:
      'https://developer.android.com/build/releases/past-releases/agp-8-0-0-release-notes',
  retrieved: '2026-09-16',
);

/// The first Flutter release without the Android v1 embedding API
/// (`io.flutter.plugin.common.PluginRegistry.Registrar`). The interface is in
/// the engine of Flutter 3.27.4 (engine 82bd5b72) and absent from the engine
/// sources of Flutter 3.29.0.
const androidV1EmbeddingRemovedIn = '3.29.0';

const androidV1EmbeddingRemovalSource = KnowledgeSource(
  title: 'flutter/engine#52022: Delete v1 android engine embedding '
      '(PluginRegistry.Registrar is absent from Flutter 3.29.0)',
  url: 'https://github.com/flutter/engine/pull/52022',
  retrieved: '2026-09-16',
);

const builtInKotlinGuideSource = KnowledgeSource(
  title: 'Flutter breaking change: migrate to built-in Kotlin (app developers)',
  url:
      'https://docs.flutter.dev/release/breaking-changes/migrate-to-built-in-kotlin/for-app-developers',
  retrieved: '2026-09-16',
);

const kotlinCompilerOptionsSource = KnowledgeSource(
  title: 'Kotlin: compiler options in the Kotlin Gradle plugin (kotlinOptions '
      'deprecated since Kotlin 2.0.0)',
  url: 'https://kotlinlang.org/docs/gradle-compiler-options.html',
  retrieved: '2026-09-16',
);

const gradle9JcenterRemovalSource = KnowledgeSource(
  title: 'Gradle 9.0 upgrade guide: removal of deprecated jcenter() '
      '(deprecated in Gradle 7.0; JCenter redirected to Maven Central in '
      'August 2024; mavenCentral() is the closest direct replacement)',
  url:
      'https://docs.gradle.org/current/userguide/upgrading_major_version_9.html',
  retrieved: '2026-09-16',
);

/// Flutter's app templates declared `jcenter()` until Flutter 2.5.
const flutterTemplateJcenterRemovalSource = KnowledgeSource(
  title: 'flutter/flutter#80908: migrate from jcenter to mavencentral (app '
      'templates since Flutter 2.5.0)',
  url: 'https://github.com/flutter/flutter/pull/80908',
);

/// Flutter 3.22 app templates did not set the Kotlin JVM target; new projects
/// failed to build with Kotlin 1.9.23 on Gradle 8.6 (flutter/flutter#147185).
const flutterTemplateJvmTargetSource = KnowledgeSource(
  title: 'flutter/flutter#147326: Add kotlinOptions jvmTarget to templates '
      '(Flutter 3.24; fixes #147185, "Inconsistent JVM-target compatibility '
      "detected for tasks 'compileDebugJavaWithJavac' (1.8) and "
      "'compileDebugKotlin' (17)\" with Kotlin 1.9.23 and Gradle 8.6)",
  url: 'https://github.com/flutter/flutter/pull/147326',
  retrieved: '2026-09-16',
);

const kotlinJvmTargetValidationSource = KnowledgeSource(
  title: 'Kotlin Gradle plugin: check for JVM target compatibility of related '
      'compile tasks (kotlin.jvm.target.validation.mode is error by default '
      'on Gradle 8.0+)',
  url: 'https://kotlinlang.org/docs/gradle-configure-project.html',
  retrieved: '2026-09-16',
);

/// The first Kotlin Gradle plugin version shown to fail Flutter app builds
/// without a Kotlin JVM target on Gradle 8 (flutter/flutter#147185).
const kotlinJvmTargetFailureSince = '1.9.0';

/// With Android Gradle Plugin 9, plugin (library) modules check the AAR
/// metadata of their dependencies too. Observed in Reforge's validation runs;
/// the release notes only describe the related compile SDK behavior change.
const pluginAarMetadataCheckSinceAgp = '9.0.0';

const pluginAarMetadataCheckSource = KnowledgeSource(
  title: 'Reforge validation run 10: plugin modules compiling against Android '
      'SDK 31 and 33 failed checkDebugAarMetadata with Android Gradle Plugin '
      '9.0.1 and Flutter 3.44.0 (androidx.fragment:fragment:1.7.1 requires '
      '34), and built with 8.11.1. See also the AGP 9.0.0 release notes, '
      '"Behavior changes".',
  url: 'https://github.com/KEREM-BAS/reforge/blob/main/docs/validation.md',
  retrieved: '2026-09-16',
);
