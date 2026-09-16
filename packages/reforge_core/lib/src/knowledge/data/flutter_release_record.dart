/// Compact, generated representation of a Flutter release's facts.
///
/// Records are produced by `tool/generate_flutter_knowledge.dart` from
/// Flutter's release manifest and the `flutter/flutter` sources at each
/// release tag. Version floors are encoded as `'<error>/<warn>'`.
final class FlutterReleaseRecord {
  const FlutterReleaseRecord({
    required this.version,
    required this.revision,
    required this.dart,
    required this.date,
    required this.gradleFloor,
    required this.agpFloor,
    required this.kotlinFloor,
    required this.javaFloor,
    required this.minSdkFloor,
    required this.templateGradle,
    required this.templateAgp,
    required this.templateKotlin,
    required this.templateDsl,
    required this.templateDeclarativePlugins,
    required this.templateNamespace,
    required this.androidMigrations,
    required this.appliesKotlinPlugin,
    required this.templateAppKotlinPlugin,
    required this.templateGradleProperties,
    required this.compileSdk,
    required this.targetSdk,
    required this.minSdk,
    required this.ndk,
    required this.imperativeApply,
    required this.iosMinimum,
    required this.macosMinimum,
    required this.xcodeFloor,
    required this.cocoapodsFloor,
    required this.embeddingMinCompileSdk,
    required this.embeddingMinCompileSdkLibraries,
  });

  final String version;
  final String revision;
  final String dart;
  final String date;
  final String? gradleFloor;
  final String? agpFloor;
  final String? kotlinFloor;
  final String? javaFloor;
  final String? minSdkFloor;
  final String templateGradle;
  final String templateAgp;
  final String templateKotlin;
  final String templateDsl;
  final bool templateDeclarativePlugins;
  final bool templateNamespace;
  final List<String> androidMigrations;
  final bool appliesKotlinPlugin;
  final bool templateAppKotlinPlugin;
  final Map<String, String> templateGradleProperties;
  final int compileSdk;
  final int targetSdk;
  final int minSdk;
  final String ndk;
  final String imperativeApply;
  final String iosMinimum;
  final String macosMinimum;
  final String xcodeFloor;
  final String cocoapodsFloor;
  final int? embeddingMinCompileSdk;
  final List<String> embeddingMinCompileSdkLibraries;
}
