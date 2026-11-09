import 'package:flutter/material.dart';

import '../archive_errors.dart';
import '../archive_backend.dart';
import '../attachments.dart';
import '../content_safety.dart';
import '../message_body.dart';
import '../message_date.dart';

class MessageReader extends StatefulWidget {
  const MessageReader({super.key, required this.api, required this.id});
  final ArchiveBackend api;
  final int id;
  @override
  State<MessageReader> createState() => _MessageReaderState();
}

class _MessageReaderState extends State<MessageReader> {
  late Future<Map<String, dynamic>> result;
  Future<Map<String, dynamic>> loadMessage() async {
    final mail = await widget.api.message(widget.id);
    final body = await prepareEmailBodyAsync(
      mail['htmlBody'] as String? ?? '',
      mail['textBody'] as String? ?? '',
    );
    return {...mail, '_preparedBody': body};
  }

  @override
  void initState() {
    super.initState();
    result = loadMessage();
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(title: const Text('Message')),
    body: SafeArea(
      child: FutureBuilder<Map<String, dynamic>>(
        future: result,
        builder: (context, snapshot) {
          if (snapshot.connectionState != ConnectionState.done) {
            return const Center(child: CircularProgressIndicator());
          }
          if (snapshot.hasError) {
            return SingleChildScrollView(
              padding: const EdgeInsets.all(24),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(readableError(snapshot.error!)),
                  TextButton(
                    onPressed: () {
                      final retry = loadMessage();
                      setState(() {
                        result = retry;
                      });
                    },
                    child: const Text('Retry'),
                  ),
                ],
              ),
            );
          }
          if (!snapshot.hasData) {
            return const Center(child: CircularProgressIndicator());
          }
          final mail = snapshot.data!;
          final attachments = (mail['attachments'] as List<dynamic>? ?? [])
              .map(
                (value) =>
                    MailAttachment.fromJson(value as Map<String, dynamic>),
              )
              .toList();
          return SingleChildScrollView(
            padding: const EdgeInsets.all(24),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  mail['subject'] as String? ?? '(No subject)',
                  style: Theme.of(context).textTheme.headlineSmall,
                ),
                const SizedBox(height: 20),
                Text(mail['from'] as String? ?? ''),
                const SizedBox(height: 8),
                MessageDate(value: mail['sentDate'], detailed: true),
                if (isCautionFolder(mail['folderName'] as String? ?? ''))
                  Padding(
                    padding: const EdgeInsets.only(top: 16),
                    child: Card(
                      child: Padding(
                        padding: const EdgeInsets.all(16),
                        child: Text(
                          'This message is archived in a Spam/Junk folder. Treat links and attachments with caution.',
                          style: TextStyle(
                            color: Theme.of(context).colorScheme.error,
                          ),
                        ),
                      ),
                    ),
                  ),
                const Divider(height: 36),
                MessageBody(body: mail['_preparedBody'] as PreparedEmailBody),
                if (attachments.isNotEmpty)
                  MessageAttachments(
                    api: widget.api,
                    emailId: widget.id,
                    attachments: attachments,
                  ),
              ],
            ),
          );
        },
      ),
    ),
  );
}
