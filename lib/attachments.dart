import 'dart:io';
import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter/foundation.dart';
import 'package:path_provider/path_provider.dart';
import 'archive_errors.dart';
import 'archive_backend.dart';
import 'archive_models.dart';
import 'content_safety.dart';
import 'saved_files.dart';
import 'attachment_download.dart';

class MailAttachment {
  const MailAttachment(
    this.id,
    this.name,
    this.size, [
    this.contentType = 'application/octet-stream',
  ]);
  factory MailAttachment.fromJson(Map<String, dynamic> value) => MailAttachment(
    archiveId(value['id']),
    value['fileName'] as String? ?? 'attachment',
    (value['size'] as num?)?.toInt() ?? 0,
    value['contentType'] as String? ?? 'application/octet-stream',
  );
  final String id;
  final int size;
  final String name;
  final String contentType;
}

String safeAttachmentName(String value) {
  final name = value
      .split(RegExp(r'[/\\]'))
      .last
      .replaceAll(RegExp(r'[\x00-\x1f\x7f\u202a-\u202e\u2066-\u2069]'), '')
      .trim();
  return name.isEmpty || name == '.' || name == '..' ? 'attachment' : name;
}

String attachmentSize(int size) {
  if (size < 0) return 'Size unknown';
  if (size < 1024) return '$size B';
  if (size < 1024 * 1024) return '${(size / 1024).toStringAsFixed(1)} KB';
  return '${(size / (1024 * 1024)).toStringAsFixed(1)} MB';
}

class MessageAttachments extends StatefulWidget {
  const MessageAttachments({
    super.key,
    required this.api,
    required this.emailId,
    required this.attachments,
  });
  final ArchiveBackend api;
  final String emailId;
  final List<MailAttachment> attachments;
  @override
  State<MessageAttachments> createState() => _MessageAttachmentsState();
}

class _MessageAttachmentsState extends State<MessageAttachments> {
  bool saving = false;
  bool choosingDestination = false;
  AttachmentDownload? download;
  String? status;
  final savedLocations = <String, String>{};
  final needsReselection = <String>{};
  bool opening = false;

  @override
  void dispose() {
    download?.cancel();
    for (final location in savedLocations.values) {
      unawaited(releaseSavedFile(location));
    }
    super.dispose();
  }

  Future<void> open(MailAttachment attachment) async {
    final location = savedLocations[attachment.id];
    if (location == null || saving || opening) return;
    final caution = attachmentCaution(attachment.name, attachment.contentType);
    final approved = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Open saved attachment?'),
        content: SingleChildScrollView(
          child: Text(
            '${safeAttachmentName(attachment.name)}\n\nThis file has not been scanned. Another app will handle it.${caution == null ? '' : '\n\n$caution'}',
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('Open file'),
          ),
        ],
      ),
    );
    if (approved != true || !mounted || opening) return;
    setState(() => opening = true);
    try {
      final outcome = await openSavedFile(location);
      if (mounted) {
        if (outcome == 'opened' || outcome == 'no_app') {
          needsReselection.remove(attachment.id);
        } else {
          needsReselection.add(attachment.id);
        }
        setState(
          () => status = switch (outcome) {
            'opened' => 'Open request sent. Choose a viewer if prompted.',
            'session_expired' =>
              'Saved-file access ended for this reader. Choose the existing saved file to reconnect it.',
            'permission_denied' =>
              'The file provider denied read access. Choose the existing saved file to grant access again.',
            'file_unavailable' =>
              'The file provider could not find or load this copy. Check Files or choose it again.',
            'provider_error' =>
              'The file provider could not read this copy. Check its connection or choose the saved file again.',
            'viewer_permission_denied' =>
              'Android blocked this viewer from reading the file. Try opening it from Files.',
            'viewer_error' =>
              'Android could not launch the viewer. Try opening the saved file from Files.',
            'no_app' => 'No app is available to open this file type.',
            _ =>
              'The saved file is unavailable or permission expired. Find it in Files or save it again.',
          },
        );
      }
    } catch (_) {
      if (mounted) {
        needsReselection.add(attachment.id);
        setState(
          () => status =
              'Could not open the saved file. Try opening it from Files.',
        );
      }
    } finally {
      if (mounted) setState(() => opening = false);
    }
  }

  Future<void> reconnectSavedFile(MailAttachment attachment) async {
    if (saving || opening) return;
    setState(() {
      saving = true;
      choosingDestination = true;
      status = 'Select the copy you already saved. Nothing will be downloaded.';
    });
    try {
      final location = await chooseSavedFile();
      if (!mounted) {
        if (location != null) unawaited(releaseSavedFile(location));
        return;
      }
      if (location == null) {
        setState(
          () => status =
              'File selection cancelled. Your existing saved-file reference is unchanged.',
        );
      } else {
        final previous = savedLocations[attachment.id];
        savedLocations[attachment.id] = location;
        needsReselection.remove(attachment.id);
        if (previous != null) unawaited(releaseSavedFile(previous));
        setState(
          () => status = 'Saved file selected. Use Open saved file when ready.',
        );
      }
    } catch (_) {
      if (mounted) {
        setState(
          () => status =
              'Could not select the saved file. You can still open it from Files.',
        );
      }
    } finally {
      if (mounted) {
        setState(() {
          saving = false;
          choosingDestination = false;
        });
      }
    }
  }

  Future<void> save(MailAttachment attachment) async {
    if (saving || opening) return;
    if (attachment.size > maxAttachmentDownloadBytes) {
      setState(
        () => status =
            'This attachment exceeds the 50 MiB download limit. Use your archive website for larger files.',
      );
      return;
    }
    final caution = attachmentCaution(attachment.name, attachment.contentType);
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Save unscanned attachment?'),
        content: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              SelectableText(safeAttachmentName(attachment.name)),
              const SizedBox(height: 12),
              Text(
                '${attachmentSize(attachment.size)} · ${attachment.contentType}',
              ),
              const SizedBox(height: 16),
              const Text(
                'Not scanned for malware. Archived mail can include spam or phishing. Download only if you expected this file and trust its source. Downloads are limited to 50 MiB and 2 minutes.',
              ),
              if (caution != null)
                Padding(
                  padding: const EdgeInsets.only(top: 16),
                  child: Text(
                    caution,
                    style: TextStyle(
                      color: Theme.of(context).colorScheme.error,
                    ),
                  ),
                ),
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: Text(
              caution == null ? 'Download and save' : 'Download anyway',
            ),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted || saving) return;
    final active = AttachmentDownload();
    final progressClock = Stopwatch()..start();
    var lastProgress = Duration.zero;
    setState(() {
      download = active;
      choosingDestination = false;
      saving = true;
      status = 'Downloading attachment…';
    });
    Directory? temporary;
    var phase = 'storage';
    try {
      final cache = await getTemporaryDirectory();
      active.throwIfStopped();
      temporary = await createAttachmentDirectory(cache);
      active.throwIfStopped();
      final file = File(
        '${temporary.path}/${safeAttachmentName(attachment.name)}',
      );
      phase = 'download';
      await widget.api.downloadAttachment(
        widget.emailId,
        attachment.id,
        file,
        transfer: active,
        onProgress: (received) {
          if (!mounted ||
              active.isStopped ||
              progressClock.elapsed - lastProgress <
                  const Duration(milliseconds: 200)) {
            return;
          }
          lastProgress = progressClock.elapsed;
          setState(
            () =>
                status = 'Downloading attachment… ${attachmentSize(received)}',
          );
        },
      );
      active.throwIfStopped();
      if (!mounted) return;
      setState(() {
        choosingDestination = true;
        status = 'Choose where to save the attachment.';
      });
      phase = 'save';
      final location = await saveDownloadedFile(
        file.path,
        safeAttachmentName(attachment.name),
        attachment.contentType,
      );
      if (mounted) {
        if (location != null) {
          final previous = savedLocations[attachment.id];
          savedLocations[attachment.id] = location;
          needsReselection.remove(attachment.id);
          if (previous != null) unawaited(releaseSavedFile(previous));
        }
        setState(
          () => status = location == null
              ? 'Save cancelled.'
              : 'Attachment saved.',
        );
      } else if (location != null) {
        unawaited(releaseSavedFile(location));
      }
    } catch (error) {
      if (mounted) {
        setState(
          () => status = error is AttachmentDownloadCancelled
              ? 'Download cancelled.'
              : error is AttachmentTooLarge
              ? 'This attachment exceeds the 50 MiB download limit. Use your archive website for larger files.'
              : error is ArchiveFailure && error.status == 403
              ? 'Attachment downloads are disabled or not permitted by this server.'
              : error is ArchiveFailure
              ? readableError(error)
              : error is HandshakeException
              ? 'The server certificate could not be verified. Check the HTTPS server configuration.'
              : error is TimeoutException || error is SocketException
              ? 'The download connection failed or timed out. Check your private network and retry.'
              : phase == 'save'
              ? 'The file picker could not save the attachment. Try a different destination; an incomplete file may remain.'
              : 'Could not prepare or write the private download file. Check available device storage and retry.',
        );
      }
    } finally {
      if (temporary != null) {
        try {
          await temporary.delete(recursive: true);
        } catch (_) {}
      }
      progressClock.stop();
      if (mounted) {
        setState(() {
          saving = false;
          choosingDestination = false;
          download = null;
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) => PopScope(
    canPop: !saving || !choosingDestination,
    onPopInvokedWithResult: (didPop, _) {
      if (didPop) download?.cancel();
    },
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const SizedBox(height: 24),
        Text(
          '${widget.attachments.length} attachment${widget.attachments.length == 1 ? '' : 's'}',
          style: Theme.of(context).textTheme.titleMedium,
        ),
        for (final attachment in widget.attachments)
          Card(
            child: ListTile(
              leading: const Icon(Icons.attach_file),
              title: Text(attachment.name),
              subtitle: Text(attachmentSize(attachment.size)),
              trailing: TextButton(
                onPressed: saving || opening ? null : () => save(attachment),
                child: const Text('Save'),
              ),
            ),
          ),
        for (final attachment in widget.attachments)
          if (savedLocations.containsKey(attachment.id))
            TextButton.icon(
              onPressed: saving || opening ? null : () => open(attachment),
              icon: const Icon(Icons.open_in_new),
              label: Text(
                'Open saved file: ${safeAttachmentName(attachment.name)}',
              ),
            ),
        if (defaultTargetPlatform == TargetPlatform.android)
          for (final attachment in widget.attachments)
            if (needsReselection.contains(attachment.id))
              TextButton.icon(
                onPressed: saving || opening
                    ? null
                    : () => reconnectSavedFile(attachment),
                icon: const Icon(Icons.folder_open),
                label: Text(
                  'Choose saved file: ${safeAttachmentName(attachment.name)}',
                ),
              ),
        if (saving) const LinearProgressIndicator(),
        if (saving && !choosingDestination)
          TextButton.icon(
            onPressed: () => download?.cancel(),
            icon: const Icon(Icons.close),
            label: const Text('Cancel download'),
          ),
        if (status != null) Semantics(liveRegion: true, child: Text(status!)),
      ],
    ),
  );
}
