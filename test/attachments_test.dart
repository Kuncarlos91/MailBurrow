import 'package:flutter_test/flutter_test.dart';
import 'package:mailburrow/attachments.dart';

void main() {
  test('server filenames cannot escape the private temporary folder', () {
    expect(safeAttachmentName('../../notes.pdf'), 'notes.pdf');
    expect(safeAttachmentName(r'C:\private\notes.pdf'), 'notes.pdf');
    expect(safeAttachmentName('..'), 'attachment');
    expect(safeAttachmentName('bad\u0000name.txt'), 'badname.txt');
  });
  test('reads attachment metadata and displays useful sizes', () {
    final attachment = MailAttachment.fromJson({
      'id': 3,
      'fileName': 'report.pdf',
      'size': 2048,
    });
    expect(attachment.id, '3');
    expect(attachment.name, 'report.pdf');
    expect(attachmentSize(attachment.size), '2.0 KB');
    expect(attachmentSize(-1), 'Size unknown');
  });
}
