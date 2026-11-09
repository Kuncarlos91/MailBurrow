import 'package:flutter/material.dart';

import 'native_license_notices.dart';
import 'screens/archive_home.dart';

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  registerBundledNativeNotices();
  runApp(const MailShelfPreview());
}

class MailShelfPreview extends StatelessWidget {
  const MailShelfPreview({super.key});
  @override
  Widget build(BuildContext context) => MaterialApp(
    title: 'MailBurrow',
    debugShowCheckedModeBanner: false,
    theme: ThemeData(
      colorScheme: ColorScheme.fromSeed(seedColor: const Color(0xff6355b5)),
      useMaterial3: true,
    ),
    darkTheme: ThemeData(
      colorScheme: ColorScheme.fromSeed(
        seedColor: const Color(0xff6355b5),
        brightness: Brightness.dark,
      ),
      useMaterial3: true,
    ),
    home: const ArchiveHome(),
  );
}
