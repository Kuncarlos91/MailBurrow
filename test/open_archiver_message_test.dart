import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:mailburrow/archive_api.dart';
import 'package:mailburrow/mime_bodies.dart';
import 'package:mailburrow/open_archiver_api.dart';
import 'package:mailburrow/open_archiver_detail.dart';

// Fictional fixtures shaped like Open Archiver v0.6.2 responses.
const sourceA = 'aaaaaaaa-0000-4000-8000-000000000001';
const sourceKeep = 'bbbbbbbb-0000-4000-8000-000000000002';
const sourceUnknown = 'eeeeeeee-0000-4000-8000-000000000005';
const mailA = 'cccccccc-0000-4000-8000-000000000003';
const mailKeep = 'dddddddd-0000-4000-8000-000000000004';
const mailUnknown = 'ffffffff-0000-4000-8000-000000000006';
const fileA = '11111111-0000-4000-8000-000000000007';

Uint8List bytes(String text) => Uint8List.fromList(utf8.encode(text));

Uint8List wire(Map<String, Object?> fields, List<int> eml) =>
    bytes(jsonEncode({...fields, 'raw': {'type': 'Buffer', 'data': eml}}));

List<List<int>> chunks(Uint8List data, int size) => [
  for (var at = 0; at < data.length; at += size)
    Uint8List.sublistView(
      data,
      at,
      at + size < data.length ? at + size : data.length,
    ),
];

({Map<String, dynamic> fields, Uint8List raw}) readAll(
  Uint8List data, {
  int chunk = 64 * 1024,
  int maxRaw = 1024 * 1024,
  int maxOther = 1024 * 1024,
}) {
  final reader = OpenArchiverDetailReader(
    maxRawBytes: maxRaw,
    maxOtherBytes: maxOther,
  );
  for (final part in chunks(data, chunk)) {
    reader.add(part);
  }
  return reader.close();
}

const eml =
    'From: Garden Club <volunteers@garden.example>\r\n'
    'Subject: Agenda\r\n'
    'MIME-Version: 1.0\r\n'
    'Content-Type: multipart/alternative; boundary="alt"\r\n'
    '\r\n'
    '--alt\r\n'
    'Content-Type: text/plain; charset=utf-8\r\n'
    '\r\n'
    'Meeting at 7. Café afterwards.\r\n'
    '--alt\r\n'
    'Content-Type: text/html; charset=utf-8\r\n'
    'Content-Transfer-Encoding: quoted-printable\r\n'
    '\r\n'
    '<p>Meeting at 7. Caf=C3=A9 afterwards.</p>\r\n'
    '--alt--\r\n';

final detailFields = <String, Object?>{
  'id': mailA,
  'subject': 'Agenda',
  'senderName': 'Garden Club',
  'senderEmail': 'volunteers@garden.example',
  'sentAt': '2026-03-02T10:00:00.000Z',
  'path': 'INBOX',
  'ingestionSourceId': sourceA,
  'thread': [
    {'id': mailA, 'subject': 'Agenda'},
  ],
  'attachments': [
    {
      'id': fileA,
      'filename': 'agenda.txt',
      'mimeType': 'text/plain',
      'sizeBytes': 120,
      'storagePath': 'open-archiver/aaaa/agenda.txt',
    },
  ],
};

class FakeOpenArchiver extends OpenArchiverApi {
  FakeOpenArchiver({
    List<Object?>? sources,
    Uint8List? detail,
    this.declaredLength,
    this.chunkSize = 4096,
  }) : sources =
           sources ??
           [
             {'id': sourceA, 'name': 'Mailbox', 'preserveOriginalFile': false},
             {'id': sourceKeep, 'name': 'Copy', 'preserveOriginalFile': true},
             {'id': sourceUnknown, 'name': 'Odd'},
           ],
       detail = detail ?? wire(detailFields, utf8.encode(eml)),
       super(Uri.parse('https://archive.example'), 'test-only');
  final List<Object?> sources;
  final Uint8List detail;
  final int? declaredLength;
  final int chunkSize;
  var sourceCalls = 0;
  String? sentPath;

  @override
  Future<dynamic> get(String path, [Map<String, String>? query]) async {
    if (path == 'ingestion-sources') {
      sourceCalls++;
      return sources;
    }
    final source = path.split('/').last;
    final id = switch (source) {
      sourceKeep => mailKeep,
      sourceUnknown => mailUnknown,
      _ => mailA,
    };
    return {
      'items': [
        {'id': id, 'subject': 'Listed'},
      ],
      'total': 1,
      'page': 1,
      'limit': 25,
    };
  }

  @override
  Future<T> send<T>(
    String path,
    Map<String, String>? query,
    Future<T> Function(Stream<List<int>> body, int contentLength) read, {
    Duration? timeout,
  }) {
    sentPath = path;
    return read(
      Stream.fromIterable(chunks(detail, chunkSize)),
      declaredLength ?? detail.length,
    );
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('streaming detail reader', () {
    final documents = <Map<String, Object?>>[
      {'a': 1},
      {
        'subject': 'Café \u{1F600} "quoted" \\ / \n\t',
        'numbers': [0, -1, 1.5, 2.5e3, -0.25, 12345678901234],
        'flags': [true, false, null],
        'empty': {'list': <Object>[], 'map': <String, Object>{}},
        'nested': [
          [
            {'deep': 'yes'},
          ],
        ],
      },
      {'data': 'not raw at the top level', 'type': 'x'},
    ];
    final raws = [
      <int>[],
      [0],
      [255, 0, 10, 13, 128],
      utf8.encode('Café \u{1F600}'),
    ];

    test('matches jsonDecode at every chunk size', () {
      for (final doc in documents) {
        for (final raw in raws) {
          final data = wire(doc, raw);
          for (final size in [1, 2, 7, 64, data.length]) {
            final result = readAll(data, chunk: size);
            expect(result.fields, jsonDecode(jsonEncode(doc)), reason: '$size');
            expect(result.raw, raw, reason: '$size');
          }
        }
      }
    });

    test('finds raw before other keys, with type after data', () {
      final data = bytes(
        ' { "raw" : { "data" : [ 1 , 2 ,3 ] , "type" : "Buffer" } ,'
        ' "subject" : "x\\u00e9\\ud83d\\ude00" } ',
      );
      for (final size in [1, 3, data.length]) {
        final result = readAll(data, chunk: size);
        expect(result.raw, [1, 2, 3]);
        expect(result.fields, {'subject': 'xé\u{1F600}'});
      }
    });

    test('rejects ambiguous raw JSON across chunk boundaries', () {
      for (final invalid in [
        '{"raw":{"type":"Buffer","data":[1 2]}}',
        '{"raw":{"type":"Buffer","data":[01]}}',
        '{"raw":{"type":"Buffer","data":[0 0]}}',
        '{"raw":{"type":"Buffer","data":[1]},"raw":{"type":"Buffer"}}',
        '{"raw":{"type":"Buffer","data":[1],"data":false}}',
        '{"raw":{"type":"Buffer","data":[1],"type":"Buffer"}}',
      ]) {
        for (final chunk in [1, 3, 4096]) {
          expect(() => readAll(bytes(invalid), chunk: chunk),
              throwsFormatException, reason: invalid);
        }
      }
    });

    test('bounds metadata nesting and value allocation', () {
      for (final metadata in [
        '${'[' * 64}0${']' * 64}',
        '[${List.filled(100000, '0').join(',')}]',
      ]) {
        expect(() => readAll(bytes(
          '{"raw":{"type":"Buffer","data":[]},"metadata":$metadata}',
        )), throwsA(isA<ArchiveResponseTooLarge>()));
      }
    });

    test('rejects malformed responses', () {
      for (final bad in [
        '',
        '{"raw":{"type":"Buffer","data":[1,2',
        '{"raw":{"type":"Buffer","data":[1]}} x',
        '{"subject":"no raw"}',
        '{"raw":{"type":"String","data":[1]}}',
        '{"raw":{"type":"Buffer","data":[256]}}',
        '{"raw":{"type":"Buffer","data":[1,,2]}}',
        '{"raw":{"type":"Buffer","data":[1,]}}',
        '{"raw":{"type":"Buffer","data":[1]},"a":tru}',
        '{"raw":{"type":"Buffer","data":[1]},"a":01}',
        '{"raw":{"type":"Buffer","data":[1]},"a":"line\nbreak"}',
        '{"raw":{"type":"Buffer","data":[1]},"a":"\\x"}',
        '{"raw":{"type":"Buffer","data":[1]},"a":"\\u12"}',
        '{"raw":{"type":"Buffer","data":[1]},"a":1,}',
        '{"raw":{"type":"Buffer","data":[1]}, "raw":{"type":"Buffer","data":[2]}}',
        '[{"raw":{"type":"Buffer","data":[1]}}]',
        '{"raw":{"type":"Buffer","data":[1]}]',
      ]) {
        expect(() => readAll(bytes(bad), chunk: 3), throwsFormatException, reason: bad);
      }
    });

    test('enforces the raw and other-field limits while reading', () {
      expect(
        () => readAll(wire({}, List.filled(101, 65)), maxRaw: 100),
        throwsA(isA<ArchiveResponseTooLarge>()),
      );
      expect(readAll(wire({}, List.filled(100, 65)), maxRaw: 100).raw, hasLength(100));
      expect(
        () => readAll(wire({'big': 'x' * 2000}, [1]), maxOther: 1000),
        throwsA(isA<ArchiveResponseTooLarge>()),
      );
    });

    test('stops at the wire cap even when nothing else grows', () async {
      // Whitespace inside the byte array adds wire bytes only.
      final spaces = Uint8List(1024 * 1024)..fillRange(0, 1024 * 1024, 0x20);
      Stream<List<int>> body() async* {
        yield bytes('{"raw":{"type":"Buffer","data":[');
        for (var i = 0; i < 41; i++) {
          yield spaces;
        }
      }

      await expectLater(
        readOpenArchiverDetail(body(), -1),
        throwsA(isA<ArchiveResponseTooLarge>()),
      );
      await expectLater(
        readOpenArchiverDetail(
          const Stream.empty(),
          openArchiverMaxMessageWireBytes + 1,
        ),
        throwsA(isA<ArchiveResponseTooLarge>()),
      );
    });
  });

  group('MIME bodies', () {
    test('keeps text that only resembles a multipart delimiter', () {
      final body = readMimeBodies(bytes(
        'Content-Type: multipart/mixed; boundary=b\r\n\r\n'
        '--b\r\nContent-Type: text/plain\r\n\r\n'
        'start\r\n--b-not-a-boundary\r\n--b--suffix\r\n'
        '--b extra text\r\nend\r\n--b-- \t\r\n',
      ));
      expect(body.text, contains('end'));
      expect(body.text, contains('--b-not-a-boundary'));
      expect(body.text, contains('--b--suffix'));
      expect(body.text, contains('--b extra text'));
      expect(body.problems, isEmpty);
    });

    MimeBodies read(String text, [MimeBodyLimits limits = const MimeBodyLimits()]) =>
        readMimeBodies(Uint8List.fromList(latin1.encode(text)), limits: limits);

    test('takes the first text and HTML bodies of an alternative', () {
      final bodies = readMimeBodies(bytes(eml));
      expect(bodies.text, 'Meeting at 7. Café afterwards.');
      expect(bodies.html, '<p>Meeting at 7. Café afterwards.</p>');
      expect(bodies.problems, isEmpty);
      expect(bodies.parts, 3);
    });

    test('decodes base64, ISO-8859-1 and Windows-1252', () {
      final html = base64Encode(utf8.encode('<b>Résumé</b>'));
      final bodies = read(
        'Content-Type: text/html; charset="UTF-8"\r\n'
        'Content-Transfer-Encoding: base64\r\n\r\n$html\r\n',
      );
      expect(bodies.html, '<b>Résumé</b>');
      expect(
        read('Content-Type: text/plain; charset=iso-8859-1\r\n\r\nna\xefve').text,
        'naïve',
      );
      expect(
        read('Content-Type: text/plain; charset=windows-1252\r\n\r\n\x80 5').text,
        '€ 5',
      );
      final odd = read('Content-Type: text/plain; charset=x-unknown\r\n\r\nhi');
      expect(odd.text, 'hi');
      expect(odd.problems, contains('unknown-charset'));
    });

    test('skips attachments, counts inline resources, handles bare parts', () {
      final bodies = read(
        'Content-Type: multipart/mixed; boundary=b\r\n\r\n'
        '--b\r\n'
        'Content-Type: text/plain\r\n'
        'Content-Disposition: attachment; filename="notes.txt"\r\n\r\n'
        'attached text\r\n'
        '--b\r\n'
        'Content-Type: image/png\r\n'
        'Content-ID: <img1>\r\n'
        'Content-Transfer-Encoding: base64\r\n\r\n'
        'iVBORw0KGgo=\r\n'
        '--b\r\n'
        '\r\n'
        'headerless body\r\n'
        '--b--\r\n',
      );
      expect(bodies.text, 'headerless body');
      expect(bodies.inlineParts, 1);
      expect(bodies.problems, isEmpty);
    });

    test('checks part, depth, header and decoded limits before the work', () {
      final many = StringBuffer('Content-Type: multipart/mixed; boundary=m\r\n\r\n');
      for (var i = 0; i < 600; i++) {
        many.write('--m\r\nContent-Type: image/gif\r\n\r\nx\r\n');
      }
      many.write('--m--\r\n');
      final parts = read(many.toString());
      expect(parts.parts, 500);
      expect(parts.problems, contains('part-limit'));

      final nested = StringBuffer('Content-Type: multipart/mixed; boundary=n0\r\n\r\n');
      for (var i = 0; i < 40; i++) {
        nested.write('--n$i\r\nContent-Type: multipart/mixed; boundary=n${i + 1}\r\n\r\n');
      }
      expect(read(nested.toString()).problems, contains('depth-limit'));

      // A boundary that prefixes another is not mistaken for it.
      final prefixed = read(
        'Content-Type: multipart/mixed; boundary=b\r\n\r\n'
        '--b\r\n'
        'Content-Type: multipart/alternative; boundary=b2\r\n\r\n'
        '--b2\r\nContent-Type: text/plain\r\n\r\ninner\r\n--b2--\r\n'
        '--b--\r\n',
      );
      expect(prefixed.text, 'inner');
      expect(prefixed.problems, isEmpty);

      final header = read('X-Long: ${'a' * 300000}\r\nSubject: x');
      expect(header.problems, contains('header-limit'));
      expect(header.text, isEmpty);

      final large = read(
        'Content-Type: text/plain\r\n\r\n${'z' * 2000}',
        const MimeBodyLimits(maxDecodedBytes: 1000),
      );
      expect(large.problems, contains('decoded-limit'));
      expect(large.text, isEmpty);
    });

    test('records structural problems without throwing', () {
      expect(
        read('Content-Type: multipart/mixed\r\n\r\nbody').problems,
        contains('missing-boundary'),
      );
      final open = read(
        'Content-Type: multipart/mixed; boundary=o\r\n\r\n'
        '--o\r\nContent-Type: text/plain\r\n\r\nstill readable',
      );
      expect(open.text, 'still readable');
      expect(open.problems, contains('unclosed-multipart'));
      final bad = read(
        'Content-Type: text/plain\r\nContent-Transfer-Encoding: base64\r\n\r\n!!aGk=',
      );
      expect(bad.text, 'hi');
      expect(bad.problems, contains('bad-base64'));
    });
  });

  group('opening messages', () {
    Future<FakeOpenArchiver> listed(FakeOpenArchiver api) async {
      await api.accounts();
      for (final source in [sourceA, sourceKeep, sourceUnknown]) {
        await api.emails(source, '', 1);
      }
      return api;
    }

    test('opens a listed message within its source policy', () async {
      final api = await listed(FakeOpenArchiver(chunkSize: 7));
      final mail = await api.message(mailA);
      expect(api.sentPath, 'archived-emails/$mailA');
      expect(mail.subject, 'Agenda');
      expect(mail.from, 'Garden Club <volunteers@garden.example>');
      expect(mail.sentDate, '2026-03-02T10:00:00.000Z');
      expect(mail.folderName, 'INBOX');
      expect(mail.textBody, 'Meeting at 7. Café afterwards.');
      expect(mail.htmlBody, '<p>Meeting at 7. Café afterwards.</p>');
      expect(mail.attachments.single.id, fileA);
      expect(mail.attachments.single.name, 'agenda.txt');
      expect(mail.attachments.single.size, 120);
      expect(mail.attachments.single.contentType, 'text/plain');
      expect(api.attachmentStoragePath(fileA), 'open-archiver/aaaa/agenda.txt');
    });

    test('refuses before any request when the policy forbids or is unknown', () async {
      final api = await listed(FakeOpenArchiver());
      for (final id in [mailKeep, mailUnknown]) {
        final failure = await api.message(id).then<Object?>((_) => null, onError: (Object e) => e);
        expect(failure, isA<ArchiveMessageRefused>(), reason: id);
        expect(readableError(failure!), isNot(contains('server')), reason: id);
      }
      expect(api.sentPath, isNull);
      // An unknown policy is re-checked once before refusing.
      expect(api.sourceCalls, 2);

      final fresh = FakeOpenArchiver();
      await expectLater(fresh.message(mailA), throwsA(isA<ArchiveMessageRefused>()));
      await expectLater(fresh.message('../$mailA'), throwsFormatException);
      expect(fresh.sentPath, isNull);
    });

    test('loads the policy on demand for a listed message', () async {
      final api = FakeOpenArchiver();
      await api.emails(sourceA, '', 1);
      expect(api.sourceCalls, 0);
      await api.message(mailA);
      expect(api.sourceCalls, 1);
      expect(api.sentPath, 'archived-emails/$mailA');
    });

    test('rejects oversized, mismatched and malformed detail responses', () async {
      Future<Object?> open(FakeOpenArchiver api) async {
        await listed(api);
        return api.message(mailA).then<Object?>((_) => null, onError: (Object e) => e);
      }

      expect(
        await open(FakeOpenArchiver(declaredLength: openArchiverMaxMessageWireBytes + 1)),
        isA<ArchiveResponseTooLarge>(),
      );
      expect(
        await open(FakeOpenArchiver(
          detail: wire({...detailFields, 'ingestionSourceId': sourceKeep}, utf8.encode(eml)),
        )),
        isFormatException,
      );
      for (final attachments in [
        'none',
        [
          {'id': fileA, 'sizeBytes': -1, 'storagePath': 'p'},
        ],
        [
          {'id': fileA, 'sizeBytes': 1},
        ],
        [
          {'id': null, 'sizeBytes': 1, 'storagePath': 'p'},
        ],
      ]) {
        expect(
          await open(FakeOpenArchiver(
            detail: wire({...detailFields, 'attachments': attachments}, utf8.encode(eml)),
          )),
          isFormatException,
          reason: '$attachments',
        );
      }
      expect(
        await open(FakeOpenArchiver(detail: bytes('{"subject":"no raw"}'))),
        isFormatException,
      );
    });
  });
}
