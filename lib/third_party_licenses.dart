import 'package:flutter/material.dart';

import 'build_information.dart';

/// Shows the notices bundled by Flutter, without a network request.
class ThirdPartyLicensesTile extends StatelessWidget {
  const ThirdPartyLicensesTile({super.key});

  @override
  Widget build(BuildContext context) => ListTile(
    leading: const Icon(Icons.description_outlined),
    title: const Text('Open source licenses'),
    subtitle: const Text('Third-party software notices available offline'),
    trailing: const Icon(Icons.chevron_right),
    onTap: () => showLicensePage(
      context: context,
      applicationName: 'MailBurrow',
      applicationVersion: buildInformation,
    ),
  );
}
