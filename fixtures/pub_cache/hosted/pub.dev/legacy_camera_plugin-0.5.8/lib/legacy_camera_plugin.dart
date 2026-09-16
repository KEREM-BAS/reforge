import 'package:flutter/services.dart';

class LegacyCamera {
  static const MethodChannel _channel = MethodChannel('legacy_camera_plugin');

  static Future<String?> takePicture() =>
      _channel.invokeMethod<String>('takePicture');
}
