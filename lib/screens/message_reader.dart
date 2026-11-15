import 'package:flutter/material.dart';

import '../archive_errors.dart';
import '../archive_backend.dart';
import '../archive_models.dart';
import '../attachments.dart';
import '../content_safety.dart';
import '../demo/demo_banner.dart';
import '../message_body.dart';
import '../message_date.dart';
import '../message_load.dart';

class MessageReader extends StatefulWidget {
  const MessageReader({
    super.key,
    required this.api,
    required this.id,
    this.onExitDemo,
  });
  final ArchiveBackend api;
  final String id;

  /// Set while the built-in demo is open: shows the demo banner, whose Exit
  /// closes this message and then leaves the demo.
  final VoidCallback? onExitDemo;
  @override
  State<MessageReader> createState() => _MessageReaderState();
}

class _MessageReaderState extends State<MessageReader> {
  MessageLoad _load = MessageLoad();
  late Future<(MailMessage, PreparedEmailBody)> result;
  Future<(MailMessage, PreparedEmailBody)> loadMessage() async {
    final load = _load;
    final api = widget.api;
    final mail = await (api is CancellableMessageBackend
        ? (api as CancellableMessageBackend).messageWithCancellation(
            widget.id,
            load,
          )
        : load.wait(api.message(widget.id)));
    load.throwIfCancelled();
    if (!mounted) throw const MessageLoadCancelled();
    final body = await prepareEmailBodyAsync(mail.htmlBody, mail.textBody);
    load.throwIfCancelled();
    return (mail, body);
  }

  @override
  void dispose() {
    _load.cancel();
    super.dispose();
  }

  @override
  void initState() {
    super.initState();
    result = loadMessage();
  }

  @override
  Widget build(BuildContext context) => PopScope<Object?>(
    onPopInvokedWithResult: (didPop, _) {
      if (didPop) _load.cancel();
    },
    child: Scaffold(
      appBar: AppBar(title: const Text('Message')),
      body: SafeArea(
        child: Column(
          children: [
            if (widget.onExitDemo case final exit?)
              DemoBanner(
                onExit: () {
                  Navigator.of(context).pop();
                  exit();
                },
              ),
            Expanded(child: _message(context)),
          ],
        ),
      ),
    ),
  );

  Widget _message(
    BuildContext context,
  ) => FutureBuilder<(MailMessage, PreparedEmailBody)>(
    future: result,
    builder: (context, snapshot) {
      if (snapshot.connectionState != ConnectionState.done) {
        return const Center(child: CircularProgressIndicator());
      }
      if (snapshot.error is MessageLoadCancelled) {
        return const SizedBox.shrink();
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
                  _load.cancel();
                  _load = MessageLoad();
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
      final (mail, body) = snapshot.data!;
      final attachments = mail.attachments;
      return SingleChildScrollView(
        padding: const EdgeInsets.all(24),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              mail.subject ?? '(No subject)',
              style: Theme.of(context).textTheme.headlineSmall,
            ),
            const SizedBox(height: 20),
            Text(mail.from ?? ''),
            const SizedBox(height: 8),
            MessageDate(value: mail.sentDate, detailed: true),
            if (isCautionFolder(mail.folderName ?? ''))
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
            MessageBody(body: body),
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
  );
}
