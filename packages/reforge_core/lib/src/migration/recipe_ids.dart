/// Stable identifiers of built-in migration recipes.
///
/// These strings appear in CLI output, JSON, documentation, configuration and
/// issues. Never change or reuse an identifier.
abstract final class RecipeIds {
  static const androidFlutterGradlePluginDsl =
      'ANDROID_FLUTTER_GRADLE_PLUGIN_DSL';
  static const androidGradleWrapper = 'ANDROID_GRADLE_WRAPPER';
  static const androidAgpVersion = 'ANDROID_AGP_VERSION';
  static const androidKotlinVersion = 'ANDROID_KOTLIN_VERSION';
  static const androidNamespace = 'ANDROID_NAMESPACE';
  static const iosDeploymentTarget = 'IOS_DEPLOYMENT_TARGET';
  static const dartSdkConstraint = 'DART_SDK_CONSTRAINT';
}
