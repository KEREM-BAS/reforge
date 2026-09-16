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
  static const androidGradleJvmArgs = 'ANDROID_GRADLE_JVM_ARGS';
  static const androidJetifier = 'ANDROID_JETIFIER';
  static const androidMinSdk = 'ANDROID_MIN_SDK';
  static const androidAgp9OptOuts = 'ANDROID_AGP9_OPT_OUTS';
  static const androidCleanTask = 'ANDROID_CLEAN_TASK';
  static const androidAppKotlinPlugin = 'ANDROID_APP_KOTLIN_PLUGIN';
  static const iosDeploymentTarget = 'IOS_DEPLOYMENT_TARGET';
  static const dartSdkConstraint = 'DART_SDK_CONSTRAINT';
}
