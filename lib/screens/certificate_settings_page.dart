import 'package:flutter/material.dart';

import '../certificate_import.dart';
import '../certificate_picker.dart';
import '../state/archive_session.dart';
import '../state/connection_store.dart';
import 'certificate_import_page.dart';

/// Archives › ⋮ › Certificate: what the archive trusts besides the public
/// certificate authorities, with Replace and Remove. Only reads secure
/// storage; changes go through [ArchiveSession.setArchiveCertificate].
class CertificateSettingsPage extends StatefulWidget {
  const CertificateSettingsPage({
    super.key,
    required this.session,
    required this.profile,
    this.picker = pickCertificateFile,
    this.clock = DateTime.now,
  });

  final ArchiveSession session;
  final ConnectionProfile profile;
  final CertificateFilePicker picker;
  final DateTime Function() clock;

  @override
  State<CertificateSettingsPage> createState() =>
      _CertificateSettingsPageState();
}

/// How long before expiry archive settings warn.
const certificateExpiryWarning = Duration(days: 30);

class _CertificateSettingsPageState extends State<CertificateSettingsPage> {
  late final Future<CertificateDetails?> _loaded = _load();
  bool _saving = false;

  Future<CertificateDetails?> _load() async {
    final der = await widget.session.savedCertificate(widget.profile.id);
    if (der == null) return null;
    return switch (readCertificateFile(
      der,
      now: widget.clock(),
      checkValidity: false,
    )) {
      CertificateAccepted(:final details) => details,
      CertificateRejected() => throw const SavedCertificateUnavailable(
        'Saved certificate is damaged.',
      ),
    };
  }

  Future<void> _replace() async {
    final der = await showCertificateImport(
      context,
      destination: widget.profile.server,
      trustLabel: 'Trust',
      picker: widget.picker,
    );
    if (der == null || !mounted) return;
    await _save(der, 'Certificate saved.');
  }

  Future<void> _remove() async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Remove certificate?'),
        content: Text(
          "${widget.profile.label} goes back to trusting only public certificate authorities. It connects only if its server has a publicly trusted certificate. This doesn't revoke the certificate anywhere else.",
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Cancel'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('Remove'),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;
    await _save(null, 'Certificate removed.');
  }

  Future<void> _save(List<int>? der, String done) async {
    setState(() => _saving = true);
    final saved = await widget.session.setArchiveCertificate(
      widget.profile.id,
      der,
    );
    if (!mounted) return;
    setState(() => _saving = false);
    final messenger = ScaffoldMessenger.of(context);
    messenger.showSnackBar(
      SnackBar(
        content: Text(
          saved ? done : "Couldn't change the certificate. Try again.",
        ),
      ),
    );
    if (saved) Navigator.of(context).pop();
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(
      title: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text('Certificate'),
          Text(
            widget.profile.label,
            style: Theme.of(context).textTheme.bodySmall,
          ),
        ],
      ),
    ),
    body: SafeArea(
      child: FutureBuilder<CertificateDetails?>(
        future: _loaded,
        builder: (context, snapshot) {
          if (snapshot.connectionState != ConnectionState.done) {
            return const Center(child: CircularProgressIndicator());
          }
          final children = snapshot.hasError
              ? _unusable(context)
              : snapshot.data == null
              ? _none(context)
              : _trusted(context, snapshot.data!);
          return _Scroll(children: children);
        },
      ),
    ),
  );

  bool get _ready =>
      !_saving && widget.session.canSwitchArchive && !widget.session.demo;

  List<Widget> _none(BuildContext context) => [
    Text(
      '${widget.profile.label} uses the public certificate authorities this phone trusts.',
    ),
    const SizedBox(height: 8),
    Text(
      'Add your own certificate only if its server uses your own certificate authority or a self-signed certificate. Tailscale Serve and publicly trusted certificates need nothing here.',
      style: Theme.of(context).textTheme.bodySmall,
    ),
    const SizedBox(height: 24),
    FilledButton(
      onPressed: _ready ? _replace : null,
      child: const Text('Use your own certificate'),
    ),
  ];

  List<Widget> _unusable(BuildContext context) => [
    _Status(
      icon: Icons.gpp_bad_outlined,
      error: true,
      title: "Its saved certificate can't be used",
      body:
          "It's missing, damaged or from a newer version of MailBurrow. The archive won't connect without it. Replace it or remove it.",
    ),
    const SizedBox(height: 24),
    ..._actions(),
  ];

  List<Widget> _trusted(BuildContext context, CertificateDetails details) {
    final now = widget.clock();
    final dates = MaterialLocalizations.of(context);
    String date(DateTime d) => dates.formatMediumDate(d.toLocal());
    final expired = now.toUtc().isAfter(details.notAfter);
    return [
      const _Status(
        icon: Icons.verified_user_outlined,
        title: 'Trusted for this archive only',
        body: 'Other archives never use it, even on the same server.',
      ),
      if (expired) ...[
        const SizedBox(height: 12),
        _Status(
          icon: Icons.event_busy_outlined,
          error: true,
          title: 'This certificate has expired',
          body:
              "It expired on ${date(details.notAfter)}. The archive can't connect until you replace it.",
        ),
      ] else if (details.expiresWithin(certificateExpiryWarning, now)) ...[
        const SizedBox(height: 12),
        _Status(
          icon: Icons.schedule,
          warning: true,
          title: 'This certificate expires soon',
          body:
              'It expires on ${date(details.notAfter)}. Renew it on your server, then replace it here.',
        ),
      ],
      const SizedBox(height: 16),
      Card(
        margin: EdgeInsets.zero,
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              CertificateDetailRows(
                rows: [
                  ('Name', details.subject),
                  ('Type', certificateKindLabel(details.kind)),
                  ('Valid until', date(details.notAfter)),
                  (
                    'Key',
                    '${details.keyDescription}, ${details.signatureAlgorithm}',
                  ),
                ],
              ),
              const Divider(height: 24),
              Text(
                'SHA-256 fingerprint',
                style: Theme.of(context).textTheme.labelMedium,
              ),
              const SizedBox(height: 4),
              SelectableText(
                groupedFingerprint(details),
                style: const TextStyle(fontFamily: 'monospace', height: 1.5),
              ),
            ],
          ),
        ),
      ),
      const SizedBox(height: 12),
      Text(
        "A warning appears here 30 days before it expires. Revocation isn't checked: if your CA's key is ever exposed, remove it here and replace this archive's API key on your server.",
        style: Theme.of(context).textTheme.bodySmall,
      ),
      const SizedBox(height: 24),
      ..._actions(),
    ];
  }

  List<Widget> _actions() => [
    OutlinedButton(
      onPressed: _ready ? _replace : null,
      child: const Text('Replace certificate'),
    ),
    const SizedBox(height: 8),
    TextButton(
      onPressed: _ready ? _remove : null,
      style: TextButton.styleFrom(
        foregroundColor: Theme.of(context).colorScheme.error,
      ),
      child: const Text('Remove certificate'),
    ),
  ];
}

class _Status extends StatelessWidget {
  const _Status({
    required this.icon,
    required this.title,
    required this.body,
    this.error = false,
    this.warning = false,
  });
  final IconData icon;
  final String title, body;
  final bool error, warning;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final (background, foreground) = error
        ? (scheme.errorContainer, scheme.onErrorContainer)
        : warning
        ? (scheme.tertiaryContainer, scheme.onTertiaryContainer)
        : (scheme.secondaryContainer, scheme.onSecondaryContainer);
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: background,
        borderRadius: BorderRadius.circular(16),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(icon, color: foreground),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  title,
                  style: Theme.of(
                    context,
                  ).textTheme.titleSmall?.copyWith(color: foreground),
                ),
                const SizedBox(height: 4),
                Text(body, style: TextStyle(color: foreground)),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

/// A short page built in full, so every control exists for accessibility
/// services wherever the user has scrolled.
class _Scroll extends StatelessWidget {
  const _Scroll({required this.children});
  final List<Widget> children;

  @override
  Widget build(BuildContext context) => SingleChildScrollView(
    padding: const EdgeInsets.all(24),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: children,
    ),
  );
}
