import 'dart:io';

Future<Directory> createAttachmentDirectory(Directory cache) =>
    cache.createTemp('mailshelf-attachment-');

bool isCautionFolder(String path) => path
    .toLowerCase()
    .split(RegExp(r'[/\\]'))
    .any(
      (part) => {'spam', 'junk', 'junk email', 'junk e-mail'}.contains(part),
    );

String? attachmentCaution(String name, String type) {
  final lower = name.toLowerCase().trim();
  if (RegExp(r'[\u202a-\u202e\u2066-\u2069]').hasMatch(name)) {
    return 'This filename contains characters that can disguise its extension.';
  }
  final extension = lower.split('.').last;
  const executable = {
    'exe',
    'msi',
    'com',
    'scr',
    'bat',
    'cmd',
    'ps1',
    'vbs',
    'js',
    'jse',
    'wsf',
    'sh',
    'apk',
    'app',
    'dmg',
    'pkg',
    'jar',
    'lnk',
    'desktop',
    'hta',
    'reg',
    'iso',
    'img',
    'docm',
    'xlsm',
    'pptm',
    'html',
    'htm',
    'svg',
  };
  if (executable.contains(extension) ||
      type.toLowerCase().contains('executable')) {
    return 'This file may run code, install software, or contain active content. Save only if you independently trust the sender and expected this file.';
  }
  if ({
    'zip',
    'rar',
    '7z',
    'tar',
    'gz',
    'bz2',
    'xz',
    'tgz',
  }.contains(extension)) {
    return 'Archives can conceal dangerous files, including password-protected content that scanners cannot inspect.';
  }
  return null;
}
