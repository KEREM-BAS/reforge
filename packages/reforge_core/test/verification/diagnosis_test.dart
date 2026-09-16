import 'package:reforge_core/reforge_core.dart';
import 'package:test/test.dart';

FailureDiagnosis single(String output) => diagnoseFailure(output).single;

Finding finding(String code, {String? subject}) => Finding(
      code: code,
      severity: Severity.error,
      title: '$code ${subject ?? ''}',
      message: '',
      subject: subject,
    );

void main() {
  group('signatures from the Flutter tool', () {
    test('plugin and dependency requirements', () {
      final minSdk =
          single('uses-sdk:minSdkVersion 21 cannot be smaller than version 24 '
              'declared in library [:camera_android] /tmp/AndroidManifest.xml');
      expect(minSdk.id, 'PLUGIN_MIN_SDK_HIGHER');
      expect(minSdk.details,
          {'library': 'camera_android', 'declared': '21', 'required': '24'});
      expect(minSdk.source!.url, contains('gradle_errors.dart'));

      final compileSdk = single('   > The minCompileSdk (35) specified in a '
          "dependency's AAR metadata (META-INF/com/android/build/gradle/"
          'aar-metadata.properties) is greater than this module');
      expect(compileSdk.id, 'COMPILE_SDK_BELOW_DEPENDENCY_MINIMUM');
      expect(compileSdk.details['required'], '35');

      expect(
          single('You have not accepted the license agreements of the '
                  'following SDK components: [Android SDK Platform 35].')
              .explanation,
          contains('Android SDK Platform 35'));
    });

    test('Gradle 9 removed jcenter()', () {
      final groovy = single('> Could not find method jcenter() for arguments '
          '[] on repository container of type '
          'org.gradle.api.internal.artifacts.dsl.DefaultRepositoryHandler.');
      expect(groovy.id, 'GRADLE_JCENTER_REMOVED');
      expect(groovy.relatedRecipes, [RecipeIds.androidJcenter]);
      expect(
          single('e: file:///app/android/build.gradle.kts:4:9: Unresolved '
                  "reference 'jcenter'.")
              .id,
          'GRADLE_JCENTER_REMOVED');
    });

    test('Apple toolchain versions', () {
      final xcode = single('Found "Xcode 14.3, Build version 14E222b". Xcode '
          '15 or greater is required to develop for iOS.');
      expect(xcode.id, 'XCODE_TOO_OLD');
      expect(
          xcode.explanation,
          'Xcode 14.3 is older than the Xcode 15 the Flutter tool requires '
          'for iOS builds.');
      expect(xcode.details, {'required': '15', 'installed': '14.3'});
      expect(xcode.source!.url, endsWith('lib/src/ios/mac.dart'));
      expect(
          single('Cannot find "xcodebuild". Xcode 15 or greater is required '
                  'to develop for iOS.')
              .explanation,
          startsWith('xcodebuild was not found'));

      final pods = single('Warning: CocoaPods minimum required version 1.10.0 '
          'or greater not installed. Skipping pod install.');
      expect(pods.id, 'COCOAPODS_TOO_OLD');
      expect(pods.details, {'required': '1.10.0'});
      expect(
          single('Warning: CocoaPods not installed. Skipping pod install.').id,
          'COCOAPODS_NOT_INSTALLED');
    });

    test('CocoaPods deployment targets name the platform', () {
      const specs = 'Specs satisfying the `url_launcher_macos (from '
          '`Flutter/ephemeral/.symlinks/plugins/url_launcher_macos/macos`)` '
          'dependency were found, but they required a higher minimum '
          'deployment target.';
      final macos = single('$specs\n'
          'Error: The plugin "url_launcher_macos" requires a higher minimum '
          'macOS deployment version than your application is targeting.\n'
          "To build, increase your application's deployment target to at "
          'least 10.15 as described at https://flutter.dev/to/macos-deploy');
      expect(macos.id, 'COCOAPODS_DEPLOYMENT_TARGET');
      expect(
          macos.explanation,
          'Pod url_launcher_macos requires a newer macOS deployment target '
          'than the platform CocoaPods resolves for (macOS 10.15).');
      expect(macos.relatedRecipes, [RecipeIds.macosDeploymentTarget]);
      expect(macos.details, {
        'platform': 'macos',
        'pod': 'url_launcher_macos',
        'minimum': '10.15',
      });

      final ios = single('Specs satisfying the `camera_avfoundation (from '
          '`.symlinks/plugins/camera_avfoundation/ios`)` dependency were '
          'found, but they required a higher minimum deployment target.');
      expect(ios.relatedRecipes, [RecipeIds.iosDeploymentTarget]);
      expect(ios.details['platform'], 'ios');
    });

    test('toolchain bugs and AGP 9 defaults', () {
      expect(
          single('ERROR:/tmp/classes.jar: R8: com.android.tools.r8.internal.'
                  'Hc: Unused argument with users in foo')
              .details['minimumAgp'],
          '7.4.0');
      expect(
          single('> Error while executing process /opt/jdk-21/bin/jlink with '
                  'arguments {--module-path ...}')
              .details['minimumAgp'],
          '8.2.1');
      expect(
          single("The 'org.jetbrains.kotlin.android' plugin is no longer "
                  'required for Kotlin support since AGP 9.0.')
              .relatedRecipes,
          [RecipeIds.androidAgp9OptOuts]);

      const newDsl =
          "> Failed to apply plugin 'dev.flutter.flutter-gradle-plugin'.";
      expect(diagnoseFailure(newDsl), isEmpty,
          reason: 'the plugin can fail to apply for other reasons');
      expect(
          single('$newDsl\n   > java.lang.NullPointerException '
                  '(no error message)')
              .id,
          'AGP9_NEW_DSL');
    });

    test('AAR metadata failures wrap over several lines', () {
      const output = '''
> An issue was found when checking AAR metadata:

  1.  Dependency 'androidx.core:core:1.16.0' requires libraries and applications that
      depend on it to compile against version 35 or later of the
      Android APIs.

      :app is currently compiled against android-34.
''';
      final diagnosis = single(output);
      expect(diagnosis.id, 'COMPILE_SDK_BELOW_LIBRARY_MINIMUM');
      expect(diagnosis.details,
          {'library': 'androidx.core:core:1.16.0', 'required': '35'});
      expect(diagnosis.relatedRecipes, [RecipeIds.androidCompileSdk]);
    });

    test('secondary signatures only explain otherwise unexplained output', () {
      const kotlin = 'e: Class kotlin.Unit was compiled with an incompatible '
          'version of Kotlin. The binary version of its metadata is 2.1.0, '
          'expected version is 1.9.0.';
      expect(single(kotlin).id, 'KOTLIN_METADATA_INCOMPATIBLE');
      expect(
          diagnoseFailure('$kotlin\nNamespace not specified.').map((d) => d.id),
          ['ANDROID_NAMESPACE_MISSING']);
    });

    test('v1 embedding failures name the plugins from compiler errors', () {
      const output = '''
/home/dev/.pub-cache/hosted/pub.dev/old_share-0.3.1/android/src/main/java/OldShare.java:12: error: cannot find symbol
  public static void registerWith(io.flutter.plugin.common.PluginRegistry.Registrar registrar) {
C:\\Users\\dev\\AppData\\Local\\Pub\\Cache\\hosted\\pub.dev\\old_camera-1.0.0\\android\\src\\main\\java\\Cam.java:3: error: cannot find symbol
  symbol:   class Registrar
''';
      final diagnosis = diagnoseFailure(output).single;
      expect(diagnosis.id, 'PLUGIN_V1_EMBEDDING');
      expect(diagnosis.details['plugins'], 'old_share,old_camera');
      expect(diagnosis.explanation, startsWith('old_share, old_camera'));
    });

    test('pub SDK failures name the package', () {
      const output = '''
The current Dart SDK version is 3.13.3.

Because app depends on string_tools >=1.2.0 which requires SDK version >=3.0.0 <3.5.0, version solving failed.
''';
      final diagnosis = diagnoseFailure(output).single;
      expect(diagnosis.details, {'dart': '3.13.3', 'package': 'string_tools'});
      expect(diagnosis.explanation, contains('string_tools requires Dart'));
    });
  });

  group('correlation', () {
    final findings = [
      finding('PLUGIN_ANDROID_NAMESPACE_MISSING', subject: 'old_camera'),
      finding('PLUGIN_ANDROID_NAMESPACE_MISSING', subject: 'other_plugin'),
      finding('ANDROID_NAMESPACE_MISSING'),
      finding('PLUGIN_ANDROID_V1_EMBEDDING', subject: 'old_share'),
      finding('PLUGIN_MIN_SDK_ABOVE_APP', subject: 'camera_android'),
      finding('PLUGIN_GRADLE_JCENTER', subject: 'speech_to_text'),
      finding('ANDROID_JCENTER_REPOSITORY'),
      finding('DEPENDENCY_DART_SDK_INCOMPATIBLE', subject: 'string_tools'),
      finding('ANDROID_KOTLIN_BELOW_FLUTTER_MINIMUM'),
      finding('ENV_JAVA_CANNOT_RUN_GRADLE'),
      finding('ENV_XCODE_BELOW_FLUTTER_MINIMUM'),
      finding('ANDROID_COMPILE_SDK_BELOW_FLUTTER_MINIMUM'),
      finding('PLUGIN_IOS_DEPLOYMENT_TARGET_ABOVE_APP', subject: 'share_ios'),
      finding('PLUGIN_MACOS_DEPLOYMENT_TARGET_ABOVE_APP',
          subject: 'share_macos'),
      finding('PLUGIN_IOS_DEPLOYMENT_TARGET_ABOVE_APP', subject: 'other_pod'),
    ];

    List<String?> confirmed(String output, {String? module}) =>
        correlateFailures(diagnoseFailure(output), findings,
                failingModule: module)
            .single
            .confirmedBy
            .map((f) => f.subject ?? f.code)
            .toList();

    test('jcenter() failures are confirmed for the failing module', () {
      const output = '* Where:\n'
          "Build file '/Users/me/.pub-cache/hosted/pub.dev/"
          "speech_to_text-7.0.0/android/build.gradle' line: 7\n\n"
          '* What went wrong:\n'
          "A problem occurred evaluating project ':speech_to_text'.\n"
          '> Could not find method jcenter() for arguments [] on repository '
          'container of type '
          'org.gradle.api.internal.artifacts.dsl.DefaultRepositoryHandler.';
      final failure = diagnoseFailure(output).single;
      expect(
          failure.explanation,
          'The build script of speech_to_text declares jcenter(), which '
          'Gradle 9 removed.');
      expect(
          correlateFailures([failure], findings,
                  failingModule: failingGradleModule(output))
              .single
              .confirmedBy
              .map((f) => f.subject ?? f.code),
          ['speech_to_text']);
      expect(
          confirmed(
              "A problem occurred evaluating root project 'android'.\n"
              '> Could not find method jcenter() for arguments []',
              module: ':'),
          ['ANDROID_JCENTER_REPOSITORY']);
    });

    test('namespace failures are confirmed for the failing module', () {
      expect(confirmed('Namespace not specified', module: ':old_camera'),
          ['old_camera']);
      expect(confirmed('Namespace not specified', module: ':app'),
          ['ANDROID_NAMESPACE_MISSING']);
      expect(confirmed('Namespace not specified'), hasLength(3));
    });

    test('dependency and toolchain failures', () {
      expect(
          confirmed('error: cannot find symbol\n  symbol:   class Registrar'),
          ['old_share']);
      expect(
          confirmed('The current Dart SDK version is 3.13.3.\n'
              'Because string_tools requires SDK version >=3.0.0 <3.5.0, '
              'version solving failed.'),
          ['string_tools']);
      expect(
          confirmed("Error: Your project's Kotlin version (1.9.0) is lower "
              "than Flutter's minimum supported version of 2.2.20."),
          ['ANDROID_KOTLIN_BELOW_FLUTTER_MINIMUM']);
      expect(confirmed('Unsupported class file major version 69'),
          ['ENV_JAVA_CANNOT_RUN_GRADLE']);
      expect(confirmed('java.lang.OutOfMemoryError: Java heap space'), isEmpty);
      expect(
          confirmed('uses-sdk:minSdkVersion 21 cannot be smaller than version '
              '24 declared in library [:camera_android] '
              '/tmp/AndroidManifest.xml'),
          ['camera_android']);
      expect(
          confirmed('Found "Xcode 14.3, Build version 14E222b". Xcode 15 or '
              'greater is required to develop for iOS.'),
          ['ENV_XCODE_BELOW_FLUTTER_MINIMUM']);
      // From a Flutter 2.2 app built with Flutter 3.44 and compileSdk 30.
      expect(
          confirmed('   > 21 issues were found when checking AAR metadata:\n\n'
              "       1.  Dependency 'androidx.fragment:fragment:1.7.1' "
              'requires libraries and applications that\n'
              '           depend on it to compile against version 34 or later '
              'of the\n'
              '           Android APIs.\n\n'
              '           :app is currently compiled against android-30.\n\n'
              "       2.  Dependency 'androidx.window:window:1.2.0' requires "
              'libraries and applications that\n'
              '           depend on it to compile against version 34 or later '
              'of the\n'
              '           Android APIs.'),
          ['ANDROID_COMPILE_SDK_BELOW_FLUTTER_MINIMUM']);
      expect(
          confirmed('[!] CocoaPods could not find compatible versions for pod '
              '"share_ios":\nSpecs satisfying the `share_ios (from '
              '`.symlinks/plugins/share_ios/ios`)` dependency were found, but '
              'they required a higher minimum deployment target.'),
          ['share_ios']);
      expect(
          confirmed('Specs satisfying the `share_macos (from '
              '`Flutter/ephemeral/.symlinks/plugins/share_macos/darwin`)` '
              'dependency were found, but they required a higher minimum '
              'deployment target.'),
          ['share_macos']);
    });
  });
}
