import 'dart:io' show HandshakeException;
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mailburrow/archive_models.dart';
import 'package:mailburrow/archive_picker.dart';
import 'package:mailburrow/archive_server_type.dart';
import 'package:mailburrow/archive_trust.dart';
import 'package:mailburrow/certificate_picker.dart';
import 'package:mailburrow/screens/certificate_import_page.dart';
import 'package:mailburrow/screens/certificate_settings_page.dart';
import 'package:mailburrow/screens/setup_view.dart';
import 'package:mailburrow/search_filters.dart';
import 'package:mailburrow/state/archive_session.dart';
import 'package:mailburrow/state/connection_store.dart';

import 'support/fake_archive_backend.dart';
import 'support/lab_certs.dart';

class Entries extends SecureEntries {
  final values = <String, String>{};
  @override
  Future<String?> read({required String key}) async => values[key];
  @override
  Future<Map<String, String>> readAll() async => Map.of(values);
  @override
  Future<void> delete({required String key}) async => values.remove(key);
  @override
  Future<void> write({required String key, required String value}) async =>
      values[key] = value;
}

class TrustBackend extends FakeArchiveBackend {
  TrustBackend(super.server, super.key, this.trust, this.verifies);
  final ArchiveTrust? trust;
  final bool verifies;

  @override
  Future<List<ArchiveAccount>> accounts() async {
    if (!verifies) throw const HandshakeException('CERTIFICATE_VERIFY_FAILED');
    return [const ArchiveAccount(id: '1', name: 'One')];
  }

  @override
  Future<MailPage> emails(
    String accountId,
    String query,
    int page, {
    String? folder,
    SearchFilters filters = const SearchFilters(),
  }) async => const MailPage(items: []);

  @override
  Future<List<ArchiveFolder>> folders(String accountId) async => const [];

  @override
  void close() {}
}

CertificateFilePicker returns(CertificatePick pick) =>
    () async => pick;
CertificateFilePicker file(List<int> bytes) =>
    returns(CertificateFile(Uint8List.fromList(bytes)));

void main() {
  late LabCert root;
  late LabCert selfShort;

  setUpAll(() {
    root = labCert(cn: 'Home Lab Root CA', key: LabKey.ec(), ca: true);
    selfShort = labCert(
      cn: 'lab server',
      key: LabKey.ec(),
      ca: false,
      notBefore: const Duration(days: -1),
      notAfter: const Duration(days: 10),
    );
  });

  Future<List<int>?> runImport(
    WidgetTester tester,
    CertificateFilePicker picker, {
    Future<void> Function()? steps,
  }) async {
    List<int>? result;
    var done = false;
    await tester.pumpWidget(
      MaterialApp(
        home: Builder(
          builder: (context) => TextButton(
            onPressed: () async {
              result = await showCertificateImport(
                context,
                destination: 'archive.home.arpa',
                trustLabel: 'Trust and connect',
                picker: picker,
              );
              done = true;
            },
            child: const Text('start'),
          ),
        ),
      ),
    );
    await tester.tap(find.text('start'));
    await tester.pumpAndSettle();
    expect(find.text('Choose your certificate file'), findsOneWidget);
    await tester.tap(find.text('Choose file'));
    await tester.pumpAndSettle();
    await steps?.call();
    return done ? result : null;
  }

  group('import flow', () {
    testWidgets('a root CA is shown for checking, then trusted', (
      tester,
    ) async {
      final der = await runImport(
        tester,
        file(root.pemBytes),
        steps: () async {
          expect(find.text('Check before you trust it'), findsOneWidget);
          expect(find.text('Home Lab Root CA'), findsOneWidget);
          expect(find.text('Certificate authority (root)'), findsOneWidget);
          expect(find.text('archive.home.arpa only'), findsOneWidget);
          expect(
            find.textContaining('Only trust a certificate'),
            findsOneWidget,
          );
          await tester.ensureVisible(find.text('Trust and connect'));
          await tester.tap(find.text('Trust and connect'));
          await tester.pumpAndSettle();
        },
      );
      expect(der, labDer(root));
    });

    testWidgets('a private key is refused with a fix', (tester) async {
      await runImport(tester, file(root.keyBytes));
      expect(find.text('This file contains a private key'), findsOneWidget);
      expect(find.text('Choose another file'), findsOneWidget);
      expect(find.text('Check before you trust it'), findsNothing);
    });

    testWidgets('a server certificate from a CA is refused', (tester) async {
      final caKey = LabKey.ec();
      final ca = labCert(cn: 'CA', key: caKey, ca: true);
      final leaf = labCert(
        cn: 'lab server',
        key: LabKey.ec(),
        issuerCn: ca.cn,
        issuerKey: caKey,
        ca: false,
      );
      await runImport(tester, file(leaf.pemBytes));
      expect(
        find.text('This server certificate was issued by a CA'),
        findsOneWidget,
      );
      expect(find.text('Trust this one'), findsNothing);
    });

    testWidgets('cancelling the picker changes nothing', (tester) async {
      await runImport(tester, returns(const CertificatePickCancelled()));
      expect(find.text('Choose file'), findsOneWidget);
      expect(find.byType(Card), findsNothing);
    });

    testWidgets('large and unreadable files are explained', (tester) async {
      await runImport(tester, returns(const CertificateFileTooLarge()));
      expect(find.text('This file is too large'), findsOneWidget);
      await tester.pumpWidget(const SizedBox());
      await runImport(tester, returns(const CertificatePickFailed()));
      expect(find.text("The file couldn't be read"), findsOneWidget);
    });

    testWidgets('a short-lived self-signed certificate is warned about', (
      tester,
    ) async {
      final der = await runImport(
        tester,
        file(selfShort.pemBytes),
        steps: () async {
          expect(find.textContaining('expires on'), findsOneWidget);
          await tester.ensureVisible(find.text('Trust this one'));
          expect(find.text('Choose another file'), findsOneWidget);
          await tester.tap(find.text('Trust this one'));
          await tester.pumpAndSettle();
        },
      );
      expect(der, labDer(selfShort));
    });

    testWidgets('Back from step 2 returns to step 1', (tester) async {
      await runImport(tester, file(root.pemBytes));
      expect(find.text('Check before you trust it'), findsOneWidget);
      await tester.pageBack();
      await tester.pumpAndSettle();
      expect(find.text('Choose your certificate file'), findsOneWidget);
    });
  });

  group('setup', () {
    late Entries entries;
    late ConnectionStore store;
    late List<TrustBackend> created;
    late bool Function(ArchiveTrust?) verifies;

    setUp(() {
      entries = Entries();
      store = ConnectionStore(entries: entries);
      created = [];
      verifies = (trust) => true;
    });

    ArchiveSession session() => ArchiveSession(
      store: store,
      backendFactory: (type, uri, key, {trust}) {
        final b = TrustBackend(uri, key, trust, verifies(trust));
        created.add(b);
        return b;
      },
    )..busy = false;

    Future<void> pumpSetup(
      WidgetTester tester,
      ArchiveSession s,
      CertificateFilePicker picker,
    ) async {
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: ListenableBuilder(
              listenable: s,
              builder: (_, _) =>
                  SetupView(session: s, certificatePicker: picker),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
    }

    testWidgets('a failed verification offers the certificate flow', (
      tester,
    ) async {
      verifies = (trust) => trust != null;
      final s = session();
      addTearDown(s.dispose);
      await pumpSetup(tester, s, file(root.pemBytes));
      s.server.text = 'archive.home.arpa';
      s.keyInput.text = 'k';
      await tester.tap(find.text('Connect to archive'));
      await tester.pumpAndSettle();
      expect(s.certificateNotVerified, isTrue);
      final help = find.byKey(const ValueKey('certificate-help'));
      expect(help, findsOneWidget);
      await tester.tap(help);
      await tester.pumpAndSettle();
      await tester.tap(find.text('Choose file'));
      await tester.pumpAndSettle();
      await tester.ensureVisible(find.text('Trust and connect'));
      await tester.tap(find.text('Trust and connect'));
      await tester.pumpAndSettle();
      expect(s.api, isNotNull);
      expect(created.last.trust!.der, labDer(root));
      expect((await store.read())!.certificate, labDer(root));
    });

    testWidgets('the setup entry needs an address first', (tester) async {
      final s = session();
      addTearDown(s.dispose);
      await pumpSetup(tester, s, file(root.pemBytes));
      final row = find.byKey(const ValueKey('setup-own-certificate'));
      await tester.ensureVisible(row);
      await tester.tap(row);
      await tester.pump();
      expect(
        find.text('Enter the HTTPS server address first.'),
        findsOneWidget,
      );
      expect(find.text('Choose your certificate file'), findsNothing);
    });
  });

  group('archive settings', () {
    late Entries entries;
    late ConnectionStore store;

    setUp(() {
      entries = Entries();
      store = ConnectionStore(entries: entries);
    });

    ArchiveSession session() => ArchiveSession(
      store: store,
      backendFactory: (type, uri, key, {trust}) =>
          TrustBackend(uri, key, trust, true),
    )..busy = false;

    Future<ConnectionProfile> saved(List<int>? der) async {
      await store.add(
        serverType: ArchiveServerType.mailArchiver,
        server: 'https://archive.home.arpa',
        key: 'k',
        accountId: '1',
        certificate: der == null
            ? const CertificateChange.keep()
            : CertificateChange.set(der),
      );
      return (await store.overview()).profiles.single;
    }

    Future<void> pumpPage(
      WidgetTester tester,
      ArchiveSession s,
      ConnectionProfile profile,
    ) async {
      await tester.pumpWidget(
        MaterialApp(
          home: CertificateSettingsPage(
            session: s,
            profile: profile,
            picker: file(root.pemBytes),
          ),
        ),
      );
      await tester.pumpAndSettle();
    }

    testWidgets('shows the trusted certificate and removes it', (tester) async {
      final profile = await saved(labDer(root));
      expect(archiveDetails(profile), endsWith('Own certificate'));
      final s = session();
      addTearDown(s.dispose);
      await s.restore();
      await pumpPage(tester, s, profile);
      expect(find.text('Trusted for this archive only'), findsOneWidget);
      expect(find.text('Home Lab Root CA'), findsOneWidget);
      await tester.ensureVisible(find.text('Remove certificate'));
      await tester.tap(find.text('Remove certificate'));
      await tester.pumpAndSettle();
      expect(find.text('Remove certificate?'), findsOneWidget);
      await tester.tap(find.text('Remove'));
      await tester.pumpAndSettle();
      expect((await store.read())!.certificate, isNull);
    });

    testWidgets('an archive without one can add it', (tester) async {
      final profile = await saved(null);
      final s = session();
      addTearDown(s.dispose);
      await s.restore();
      await pumpPage(tester, s, profile);
      expect(
        find.textContaining('uses the public certificate'),
        findsOneWidget,
      );
      await tester.tap(find.text('Use your own certificate'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Choose file'));
      await tester.pumpAndSettle();
      await tester.ensureVisible(find.text('Trust'));
      await tester.tap(find.text('Trust'));
      await tester.pumpAndSettle();
      expect((await store.read())!.certificate, labDer(root));
    });

    testWidgets('a damaged record is explained, not hidden', (tester) async {
      final profile = await saved(labDer(root));
      entries.values['connection.trust.${profile.id}'] = 'damaged';
      final s = session();
      addTearDown(s.dispose);
      await pumpPage(tester, s, profile);
      expect(find.text("Its saved certificate can't be used"), findsOneWidget);
      expect(find.text('Replace certificate'), findsOneWidget);
    });
  });
}
