import 'package:reforge_core/reforge_core.dart';

import '../commands/inspect_command.dart';
import '../output/terminal.dart';

void renderProject(Terminal t, ProjectReport report, KnowledgeBase knowledge,
    {required bool verbose}) {
  final project = report.project;
  final kind = switch (project.kind) {
    FlutterProjectKind.app => 'Flutter app',
    FlutterProjectKind.plugin => 'Flutter plugin',
    FlutterProjectKind.module => 'Flutter module',
    FlutterProjectKind.package => 'Flutter package',
    FlutterProjectKind.dartPackage => 'Dart package',
  };
  t.heading('${project.name} ${t.dim('${t.dot} $kind'
      '${project.path.isEmpty ? '' : ' ${t.dot} ${project.path}'}')}');

  final current = report.current;
  if (current == null) {
    t.field(
        'Flutter',
        t.yellow('unknown') +
            t.dim('  no pin, SDK or generated files identify a known release'));
  } else {
    final basis = switch (current.basis) {
      CurrentFlutterBasis.pinned =>
        'pinned in ${current.evidence.location?.path}',
      CurrentFlutterBasis.environment => 'flutter on PATH',
      CurrentFlutterBasis.lastPubGet => 'last pub get',
      CurrentFlutterBasis.created => 'created with; no newer evidence',
    };
    t.field('Flutter', '${current.release.version} ${t.dim('($basis)')}');
  }
  if (verbose) {
    for (final observation in project.flutterVersionObservations) {
      t.field(
          '',
          t.dim('${observation.signal.name}: ${observation.value}'
              '${observation.version != null && observation.value != '${observation.version}' ? ' = ${observation.version}' : ''}'
              ' (${observation.location.path})'));
    }
  }
  final sdk = project.pubspec.sdkConstraint;
  t.field(
      'Dart SDK',
      sdk == null
          ? t.yellow('no constraint')
          : '${sdk.value} ${t.dim(sdk.location.display)}');

  final android = project.android;
  if (android != null) _renderAndroid(t, android, current?.release);
  for (final host in [project.ios, project.macos].nonNulls) {
    _renderDarwin(t, host);
  }
  if (project.otherPlatforms.isNotEmpty) {
    t.line();
    t.line(
        '  ${t.bold('Other platforms')}  ${project.otherPlatforms.join(', ')}');
  }
  _renderDependencies(t, project, report.dependencies);
}

void _renderAndroid(
    Terminal t, AndroidProject android, FlutterRelease? release) {
  final app = android.app;
  final dsl = switch ((app?.script ?? android.settings)?.dialect.name) {
    'kotlin' => 'Kotlin DSL',
    'groovy' => 'Groovy DSL',
    _ => 'no Gradle scripts',
  };
  final style = switch (android.pluginApplication.style) {
    GradlePluginStyle.declarative => 'declarative plugins {}',
    GradlePluginStyle.imperative => 'imperative apply',
    GradlePluginStyle.mixed => 'mixed imperative and declarative apply',
    GradlePluginStyle.unknown => 'Flutter plugin application not recognized',
  };
  t.line();
  t.line('  ${t.bold('Android')}  ${t.dim('$dsl ${t.dot} $style')}');

  void declaration(String label, VersionDeclaration? value) {
    if (value == null) {
      t.field(label, t.dim('not declared'));
      return;
    }
    final where = value.definition ?? value.usage;
    final via = switch (value.resolution) {
      ValueResolution.literal => '',
      ValueResolution.variable => ' via ${value.rawText}',
      ValueResolution.gradleProperty => ' via gradle.properties',
      ValueResolution.unresolved => '',
    };
    final shown =
        value.version?.toString() ?? t.yellow('unknown (${value.rawText})');
    t.field(label, '$shown ${t.dim('${where.display}$via')}');
  }

  declaration('AGP', android.toolchain.androidGradlePlugin);
  declaration('Kotlin', android.toolchain.kotlin);
  final wrapper = android.toolchain.gradleWrapper;
  if (wrapper == null) {
    t.field('Gradle', t.dim('no wrapper'));
  } else {
    t.field(
        'Gradle',
        '${wrapper.version ?? t.yellow('unknown')} '
            '${t.dim('${wrapper.location.display}'
                '${wrapper.distributionType == null ? '' : ' ${t.dot} ${wrapper.distributionType}'}'
                '${wrapper.hasChecksum ? ' ${t.dot} checksum pinned' : ''}')}');
  }
  if (android.toolchain.gradleJavaHome != null) {
    t.field(
        'Java home',
        '${android.toolchain.gradleJavaHome} '
            '${t.dim('org.gradle.java.home')}');
  }

  if (app != null) {
    String sdkLevel(
        ScriptValue? value, int? Function(FlutterAndroidDefaults) pick) {
      return switch (value) {
        null => t.dim('not set'),
        LiteralInt(:final value) => '$value',
        FlutterDefaultReference(:final text) => release == null
            ? text
            : '${pick(release.androidDefaults)} ${t.dim('$text in Flutter ${release.version}')}',
        _ => value.text,
      };
    }

    t.field('compileSdk', sdkLevel(app.compileSdk, (d) => d.compileSdk));
    t.field('minSdk', sdkLevel(app.minSdk, (d) => d.minSdk));
    t.field('targetSdk', sdkLevel(app.targetSdk, (d) => d.targetSdk));
    final namespace = app.namespace;
    final package = android.mainManifest?.manifest.packageAttribute;
    t.field(
        'namespace',
        namespace is LiteralString
            ? namespace.value
            : namespace != null
                ? namespace.text
                : t.yellow('not declared') +
                    (package == null
                        ? ''
                        : t.dim('  manifest package="$package"')));
    if (app.productFlavors.isNotEmpty) {
      t.field('flavors', app.productFlavors.join(', '));
    }
  }
  final unreliable = android.scripts.where((s) => !s.isReliable).toList();
  for (final script in unreliable) {
    t.field(
        '', t.yellow('${t.warn} ${script.path} could not be parsed reliably'));
  }
}

void _renderDarwin(Terminal t, DarwinProject host) {
  final manager = switch (host.dependencyManager) {
    DarwinDependencyManager.cocoapods => 'CocoaPods',
    DarwinDependencyManager.swiftPackageManager => 'Swift Package Manager',
    DarwinDependencyManager.both => 'CocoaPods and Swift Package Manager',
    DarwinDependencyManager.none => 'no dependency manager configured',
  };
  t.line();
  t.line('  ${t.bold(host.platform.displayName)}  ${t.dim(manager)}');
  final targets = host.deploymentTargets;
  if (targets.isEmpty) {
    t.field('Deployment', t.dim('unknown'));
  } else {
    final byValue = <String, List<DeploymentTargetSetting>>{};
    for (final setting in targets) {
      byValue.putIfAbsent(setting.value, () => []).add(setting);
    }
    for (final entry in byValue.entries) {
      final owners = entry.value.map((s) => s.owner).toSet().join(', ');
      t.field(
          'Deployment',
          '${entry.key} ${t.dim('$owners ${t.dot} '
              '${entry.value.map((s) => s.configuration).toSet().join('/')}')}');
    }
  }
  final podfile = host.podfile;
  if (podfile != null) {
    final platform = podfile.platform;
    t.field(
        'Podfile',
        platform != null
            ? 'platform ${platform.version ?? platform.name} ${t.dim(platform.location.display)}'
            : t.dim('platform not set'
                '${podfile.commentedPlatform == null ? '' : ' (template comment: ${podfile.commentedPlatform!.version})'}'));
    final custom = podfile.buildSettingAssignments;
    if (custom.isNotEmpty) {
      t.field(
          '',
          t.dim('post_install overrides: '
              '${custom.map((a) => a.setting).toSet().join(', ')}'));
    }
  }
  if (host.appDelegateLanguage != null) {
    t.field('AppDelegate',
        host.appDelegateLanguage == 'swift' ? 'Swift' : 'Objective-C');
  }
}

void _renderDependencies(
    Terminal t, FlutterProject project, DependencyReport? dependencies) {
  t.line();
  t.line('  ${t.bold('Dependencies')}');
  final pubspec = project.pubspec;
  t.field(
      'Declared',
      '${pubspec.dependencies.length} direct ${t.dot} '
          '${pubspec.devDependencies.length} dev'
          '${pubspec.dependencyOverrides.isEmpty ? '' : ' ${t.dot} ${pubspec.dependencyOverrides.length} overrides'}');
  final lock = project.lockfile;
  t.field(
      'Resolved',
      lock == null
          ? t.dim('no pubspec.lock')
          : '${lock.packages.length} packages');
  if (dependencies != null && dependencies.resolved) {
    final plugins = [
      for (final package in dependencies.packages)
        if (package.android != null) package,
    ];
    t.field(
        'Android',
        plugins.isEmpty
            ? t.dim('no Android plugins')
            : plugins
                .map((p) =>
                    '${p.name}${p.version == null ? '' : ' ${p.version}'}')
                .join(', '));
    if (dependencies.unavailable.isNotEmpty) {
      t.field(
          'Unread',
          t.yellow('${dependencies.unavailable.length} package(s) missing; '
              'run flutter pub get'));
    }
  } else if (project.pluginRegistry == null) {
    t.field('Plugins',
        t.dim('unknown (run flutter pub get to generate the plugin registry)'));
  } else {
    final android = project.pluginsFor('android').length;
    final ios = project.pluginsFor('ios').length;
    final macos = project.pluginsFor('macos').length;
    t.field(
        'Plugins',
        '$android Android ${t.dot} $ios iOS'
            '${project.macos == null ? '' : ' ${t.dot} $macos macOS'}');
  }
}
