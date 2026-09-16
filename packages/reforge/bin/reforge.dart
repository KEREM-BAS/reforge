import 'dart:io';

import 'package:reforge/reforge.dart';

Future<void> main(List<String> arguments) async {
  final code = await runReforge(arguments);
  await stdout.flush();
  await stderr.flush();
  exit(code);
}
