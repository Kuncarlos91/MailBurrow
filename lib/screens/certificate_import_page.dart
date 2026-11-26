import 'package:flutter/material.dart';

import '../certificate_import.dart';
import '../certificate_picker.dart';

/// Shows the two-step "use your own certificate" flow for [destination]
/// (the archive's address, shown as what the certificate will be trusted
/// for). Returns the checked certificate's DER bytes when the user trusts
/// it, or null when they leave.
Future<List<int>?> showCertificateImport(
  BuildContext context, {
  required String destination,
  required String trustLabel,
  CertificateFilePicker picker = pickCertificateFile,
}) => Navigator.of(context).push<List<int>>(
  MaterialPageRoute(
    builder: (_) => CertificateImportPage(
      destination: destination,
      trustLabel: trustLabel,
      picker: picker,
    ),
  ),
);

/// A plain explanation of why a file can't be trusted, and what to do.
({String title, String body}) certificateProblemText(
  CertificateRejection reason,
) => switch (reason) {
  CertificateRejection.tooLarge => (
    title: 'This file is too large',
    body:
        'Certificate files are small. Choose the certificate file itself, at most 64 KB.',
  ),
  CertificateRejection.privateKey => (
    title: 'This file contains a private key',
    body:
        "MailBurrow never needs a key and didn't import this file. Export just the certificate and choose that instead.",
  ),
  CertificateRejection.multipleCertificates => (
    title: 'This file has more than one certificate',
    body:
        "Choose a file with just your root certificate, or the server's own certificate if it's self-signed.",
  ),
  CertificateRejection.notACertificate => (
    title: "This isn't a certificate file MailBurrow can read",
    body:
        "Choose a .pem, .crt or .cer file with one certificate. Encrypted files and bundles such as .p12 aren't supported.",
  ),
  CertificateRejection.caIssuedServerCertificate => (
    title: 'This server certificate was issued by a CA',
    body:
        "Choose your certificate authority's root certificate instead. Server certificates a CA issues renew often (daily with step-ca), so they aren't accepted here.",
  ),
  CertificateRejection.expired => (
    title: 'This certificate has expired',
    body: 'Renew it on your server, then choose the new file.',
  ),
  CertificateRejection.notYetValid => (
    title: "This certificate isn't valid yet",
    body: 'Check the date on this phone and on your server, then try again.',
  ),
  CertificateRejection.weakSignature => (
    title: 'This certificate uses weak security',
    body:
        "It's signed with SHA-1 or MD5, which are no longer safe. Use a certificate signed with SHA-256 or stronger.",
  ),
  CertificateRejection.weakKey => (
    title: "This certificate's key is too short",
    body: 'Use an RSA key of at least 2048 bits, or an EC key.',
  ),
  CertificateRejection.unsupportedAlgorithm => (
    title: "MailBurrow doesn't support this kind of certificate",
    body:
        'Use RSA (2048 to 8192 bits) or EC P-256, P-384 or P-521, signed with SHA-256 or stronger.',
  ),
  CertificateRejection.unsupportedCriticalExtension => (
    title: "This certificate has a rule MailBurrow can't check",
    body:
        "It's marked with a critical extension MailBurrow doesn't understand, so it can't be trusted safely. Use a certificate without it.",
  ),
  CertificateRejection.caCannotSignCertificates => (
    title: "This CA isn't allowed to sign certificates",
    body:
        "Its key usage doesn't include certificate signing. Choose the CA certificate that issues your server's certificate.",
  ),
  CertificateRejection.rejectedByTls => (
    title: "This certificate couldn't be loaded",
    body:
        "The phone's secure-connection layer refused it. Choose another file.",
  ),
};

/// How a certificate is described on screen.
String certificateKindLabel(CertificateKind kind) => switch (kind) {
  CertificateKind.rootCa => 'Certificate authority (root)',
  CertificateKind.intermediateCa => 'Certificate authority (intermediate)',
  CertificateKind.selfSignedServer => 'Self-signed server certificate',
};

/// The fingerprint in four lines of eight byte pairs, for comparing.
String groupedFingerprint(CertificateDetails details) {
  final pairs = details.fingerprint.split(':');
  return [
    for (var i = 0; i < pairs.length; i += 8) pairs.skip(i).take(8).join(':'),
  ].join('\n');
}

class CertificateImportPage extends StatefulWidget {
  const CertificateImportPage({
    super.key,
    required this.destination,
    required this.trustLabel,
    this.picker = pickCertificateFile,
    this.clock = DateTime.now,
  });

  final String destination;
  final String trustLabel;
  final CertificateFilePicker picker;
  final DateTime Function() clock;

  @override
  State<CertificateImportPage> createState() => _CertificateImportPageState();
}

class _CertificateImportPageState extends State<CertificateImportPage> {
  CertificateDetails? _details;
  ({String title, String body})? _problem;
  bool _reading = false;

  Future<void> _choose() async {
    setState(() {
      _reading = true;
      _problem = null;
    });
    final pick = await widget.picker();
    if (!mounted) return;
    CertificateDetails? details;
    ({String title, String body})? problem;
    switch (pick) {
      case CertificateFile(:final bytes):
        switch (readCertificateFile(bytes, now: widget.clock())) {
          case CertificateAccepted(details: final accepted):
            details = accepted;
          case CertificateRejected(:final reason):
            problem = certificateProblemText(reason);
        }
      case CertificateFileTooLarge():
        problem = certificateProblemText(CertificateRejection.tooLarge);
      case CertificatePickFailed():
        problem = (
          title: "The file couldn't be read",
          body: 'Try again, or move the file to this phone first.',
        );
      case CertificatePickCancelled():
        break;
    }
    setState(() {
      _reading = false;
      _details = details;
      _problem = problem;
    });
  }

  @override
  Widget build(BuildContext context) {
    final details = _details;
    return PopScope(
      // Back from step 2 returns to step 1 rather than leaving.
      canPop: details == null,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop) setState(() => _details = null);
      },
      child: Scaffold(
        appBar: AppBar(title: const Text('Your own certificate')),
        body: SafeArea(
          child: details == null
              ? _stepOne(context)
              : _stepTwo(context, details),
        ),
      ),
    );
  }

  Widget _step(BuildContext context, String text) => Text(
    text,
    style: Theme.of(context).textTheme.labelLarge?.copyWith(
      color: Theme.of(context).colorScheme.primary,
    ),
  );

  Widget _stepOne(BuildContext context) {
    final theme = Theme.of(context);
    final problem = _problem;
    return _Scroll(
      children: [
        _step(context, 'Step 1 of 2'),
        const SizedBox(height: 8),
        Text(
          'Choose your certificate file',
          style: theme.textTheme.headlineSmall,
        ),
        const SizedBox(height: 12),
        const Text(
          "Pick your certificate authority's root certificate, or the server's own certificate if it's self-signed. A .pem, .crt or .cer file.",
        ),
        const SizedBox(height: 16),
        _Notice(
          icon: Icons.info_outline,
          warning: true,
          text:
              "If you run a certificate authority, choose its root, not a server certificate it issued. Those renew often (daily with step-ca) and aren't accepted.",
        ),
        const SizedBox(height: 8),
        const ExpansionTile(
          tilePadding: EdgeInsets.zero,
          title: Text('Where do I find it?'),
          childrenPadding: EdgeInsets.only(bottom: 8),
          expandedCrossAxisAlignment: CrossAxisAlignment.start,
          children: [
            _Help('step-ca', 'Run: step ca root root_ca.crt'),
            _Help(
              'OPNsense',
              'System › Trust › Authorities, then export the CA certificate.',
            ),
            _Help(
              'TrueNAS',
              'Credentials › Certificates › Certificate Authorities, then download it.',
            ),
            _Help(
              'Self-signed server',
              'The certificate file your server uses (never its key).',
            ),
          ],
        ),
        if (problem != null) ...[
          const SizedBox(height: 8),
          _ProblemCard(title: problem.title, body: problem.body),
        ],
        const SizedBox(height: 16),
        Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Icon(Icons.lock_outline, size: 18, color: theme.hintColor),
            const SizedBox(width: 8),
            const Expanded(
              child: Text(
                'Your original file stays where it is. MailBurrow saves only the certificate, with this archive.',
              ),
            ),
          ],
        ),
        const SizedBox(height: 16),
        FilledButton.icon(
          onPressed: _reading ? null : _choose,
          icon: const Icon(Icons.description_outlined),
          label: Text(problem == null ? 'Choose file' : 'Choose another file'),
        ),
      ],
    );
  }

  Widget _stepTwo(BuildContext context, CertificateDetails details) {
    final theme = Theme.of(context);
    final dates = MaterialLocalizations.of(context);
    final shortLived = details.isShortLived(widget.clock());
    String date(DateTime d) => dates.formatMediumDate(d.toLocal());
    return _Scroll(
      children: [
        _step(context, 'Step 2 of 2'),
        const SizedBox(height: 8),
        Text('Check before you trust it', style: theme.textTheme.headlineSmall),
        const SizedBox(height: 16),
        Card(
          margin: EdgeInsets.zero,
          child: Padding(
            padding: const EdgeInsets.all(16),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Wrap(
                  spacing: 8,
                  runSpacing: 8,
                  children: [
                    Chip(label: Text(certificateKindLabel(details.kind))),
                    const Chip(label: Text('Within validity dates')),
                  ],
                ),
                const SizedBox(height: 8),
                CertificateDetailRows(
                  rows: [
                    ('Name', details.subject),
                    (
                      'Issued by',
                      details.isCa && details.kind == CertificateKind.rootCa
                          ? 'Itself (a root certificate)'
                          : details.issuer,
                    ),
                    (
                      'Valid',
                      '${date(details.notBefore)} – ${date(details.notAfter)}',
                    ),
                    if (details.dnsNames.isNotEmpty ||
                        details.ipAddresses.isNotEmpty)
                      (
                        'Server names',
                        [
                          ...details.dnsNames,
                          ...details.ipAddresses,
                        ].join(', '),
                      ),
                    (
                      'Key',
                      '${details.keyDescription}, ${details.signatureAlgorithm}',
                    ),
                    ('Trusted for', '${widget.destination} only'),
                  ],
                ),
                const Divider(height: 24),
                Text('SHA-256 fingerprint', style: theme.textTheme.labelMedium),
                const SizedBox(height: 4),
                SelectableText(
                  groupedFingerprint(details),
                  style: const TextStyle(fontFamily: 'monospace', height: 1.5),
                ),
                const SizedBox(height: 8),
                Text(
                  "Compare it with the fingerprint from your server's console or admin page, never from this connection. For step-ca: step certificate fingerprint root_ca.crt",
                  style: theme.textTheme.bodySmall,
                ),
              ],
            ),
          ),
        ),
        const SizedBox(height: 16),
        const _Notice(
          icon: Icons.warning_amber_outlined,
          warning: true,
          text:
              "Only trust a certificate you made for your own server. Whoever holds its key could read this archive's traffic, including your API key. It adds an authority; it doesn't lock the archive to one certificate.",
        ),
        if (shortLived) ...[
          const SizedBox(height: 12),
          _Notice(
            icon: Icons.schedule,
            warning: true,
            text:
                'This self-signed certificate expires on ${date(details.notAfter)}. After that the archive stops connecting until you import its replacement. All other checks passed.',
          ),
        ],
        const SizedBox(height: 24),
        Row(
          children: [
            Expanded(
              child: OutlinedButton(
                onPressed: () => setState(() => _details = null),
                child: Text(shortLived ? 'Choose another file' : 'Cancel'),
              ),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: FilledButton(
                onPressed: () => Navigator.of(context).pop(details.der),
                child: Text(shortLived ? 'Trust this one' : widget.trustLabel),
              ),
            ),
          ],
        ),
      ],
    );
  }
}

/// Label and value rows for certificate details.
class CertificateDetailRows extends StatelessWidget {
  const CertificateDetailRows({super.key, required this.rows});
  final List<(String, String)> rows;

  @override
  Widget build(BuildContext context) {
    final label = Theme.of(context).textTheme.bodyMedium?.copyWith(
      color: Theme.of(context).colorScheme.onSurfaceVariant,
    );
    return Column(
      children: [
        for (final (name, value) in rows)
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 4),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                SizedBox(width: 104, child: Text(name, style: label)),
                Expanded(child: Text(value)),
              ],
            ),
          ),
      ],
    );
  }
}

class _Help extends StatelessWidget {
  const _Help(this.where, this.how);
  final String where, how;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.only(bottom: 8),
    child: Text.rich(
      TextSpan(
        children: [
          TextSpan(
            text: '$where: ',
            style: const TextStyle(fontWeight: FontWeight.w500),
          ),
          TextSpan(text: how),
        ],
      ),
    ),
  );
}

class _Notice extends StatelessWidget {
  const _Notice({required this.icon, required this.text, this.warning = false});
  final IconData icon;
  final String text;
  final bool warning;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: warning ? scheme.tertiaryContainer : scheme.surfaceContainerHigh,
        borderRadius: BorderRadius.circular(12),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(
            icon,
            color: warning
                ? scheme.onTertiaryContainer
                : scheme.onSurfaceVariant,
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Text(
              text,
              style: TextStyle(
                color: warning ? scheme.onTertiaryContainer : null,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _ProblemCard extends StatelessWidget {
  const _ProblemCard({required this.title, required this.body});
  final String title, body;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Semantics(
      liveRegion: true,
      child: Container(
        padding: const EdgeInsets.all(16),
        decoration: BoxDecoration(
          color: scheme.errorContainer,
          borderRadius: BorderRadius.circular(12),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              title,
              style: Theme.of(
                context,
              ).textTheme.titleMedium?.copyWith(color: scheme.onErrorContainer),
            ),
            const SizedBox(height: 6),
            Text(body, style: TextStyle(color: scheme.onErrorContainer)),
          ],
        ),
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
