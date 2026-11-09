import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';

final supportPage = Uri.parse('https://mailburrow-at0.pages.dev/');
final privacyPage = Uri.parse('https://mailburrow-at0.pages.dev/privacy');

/// Fixed public destinations: never include archive settings or credentials.
class PublicInformationLinks extends StatelessWidget {
  const PublicInformationLinks({super.key, this.openPage});

  final Future<bool> Function(Uri)? openPage;

  Future<void> _open(BuildContext context, Uri destination) async {
    var opened = false;
    try {
      opened =
          await (openPage?.call(destination) ??
              launchUrl(destination, mode: LaunchMode.externalApplication));
    } catch (_) {
      // Do not expose plugin exceptions or private device state in the UI.
    }
    if (!opened && context.mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text(
            'Could not open the website. Check your browser and connection, then try again.',
          ),
        ),
      );
    }
  }

  @override
  Widget build(BuildContext context) => Column(
    children: [
      ListTile(
        leading: const Icon(Icons.help_outline),
        title: const Text('Support'),
        subtitle: const Text('Setup help and contact information'),
        trailing: const Icon(Icons.open_in_new),
        onTap: () => _open(context, supportPage),
      ),
      ListTile(
        leading: const Icon(Icons.privacy_tip_outlined),
        title: const Text('Privacy notice'),
        subtitle: const Text('How the app handles your information'),
        trailing: const Icon(Icons.open_in_new),
        onTap: () => _open(context, privacyPage),
      ),
    ],
  );
}
