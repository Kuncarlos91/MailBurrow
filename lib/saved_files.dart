import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_file_dialog/flutter_file_dialog.dart';
import 'package:open_filex/open_filex.dart';

const savedFilesChannel = MethodChannel('mailshelf/saved_files');
const _fileDiagnostics = bool.fromEnvironment('MAILSHELF_FILE_DIAGNOSTICS');

Future<String?> saveDownloadedFile(
  String source,
  String name,
  String type,
) async {
  if (defaultTargetPlatform == TargetPlatform.android ||
      defaultTargetPlatform == TargetPlatform.iOS) {
    return savedFilesChannel.invokeMethod<String>('save', {
      'source': source,
      'name': name,
      'type': type,
      if (_fileDiagnostics) 'diagnostics': true,
    });
  }
  return FlutterFileDialog.saveFile(
    params: SaveFileDialogParams(sourceFilePath: source, fileName: name),
  );
}

// Ask for an existing document only; never download, modify or open it here.
Future<String?> chooseSavedFile() async {
  if (defaultTargetPlatform != TargetPlatform.android) return null;
  return savedFilesChannel.invokeMethod<String>(
    'locate',
    _fileDiagnostics ? {'diagnostics': true} : null,
  );
}

Future<String> openSavedFile(String location) async {
  if (defaultTargetPlatform == TargetPlatform.android ||
      defaultTargetPlatform == TargetPlatform.iOS) {
    return await savedFilesChannel.invokeMethod<String>('open', {
          'location': location,
          if (_fileDiagnostics) 'diagnostics': true,
        }) ??
        'unavailable';
  }
  final path = location.startsWith('file:')
      ? Uri.parse(location).toFilePath()
      : location;
  if (!await File(path).exists()) return 'unavailable';
  final result = await OpenFilex.open(path);
  return switch (result.type) {
    ResultType.done => 'opened',
    ResultType.noAppToOpen => 'no_app',
    _ => 'unavailable',
  };
}

// Release app-held document access on mobile; never delete the saved file.
Future<void> releaseSavedFile(String location) async {
  if (defaultTargetPlatform != TargetPlatform.iOS &&
      defaultTargetPlatform != TargetPlatform.android) {
    return;
  }
  try {
    await savedFilesChannel.invokeMethod<void>('release', {
      'location': location,
      if (_fileDiagnostics) 'diagnostics': true,
    });
  } on PlatformException {
    // Cleanup is best effort if the native engine has already disconnected.
  } on MissingPluginException {
    // No native engine during host-only widget tests.
  }
}
