// Curated Android toolchain compatibility tables.
//
// Every table records its source and retrieval date. When a source is
// updated, update the table and the date together, and add a test for the
// new rows.

import '../knowledge_source.dart';

const agpGradleSource = KnowledgeSource(
  title: 'Android Gradle plugin: update Gradle (minimum required Gradle version)',
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
  title: 'Flutter tool Java/AGP compatibility list (gradle_utils.dart, 3.47.0), '
      'mirroring the Android Gradle plugin release notes',
  url: 'https://github.com/flutter/flutter/blob/3.47.0/packages/flutter_tools/lib/src/android/gradle_utils.dart',
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
  url: 'https://developer.android.com/build/releases/about-agp#api-level-support',
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
  url: 'https://docs.flutter.dev/release/breaking-changes/flutter-gradle-plugin-apply',
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
