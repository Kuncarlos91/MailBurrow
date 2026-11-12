import 'package:flutter/material.dart';
import 'archive_errors.dart';
import 'archive_models.dart';
import 'archive_backend.dart';
import 'account_selector.dart';

export 'archive_models.dart' show ArchiveStats;

class ArchiveInformation extends StatefulWidget {
  const ArchiveInformation({
    super.key,
    required this.api,
    required this.account,
    this.onRefreshed,
    this.onAccountSelected,
  });
  final ArchiveBackend api;
  final ArchiveAccount account;
  final VoidCallback? onRefreshed;
  final ValueChanged<ArchiveAccount>? onAccountSelected;
  @override
  State<ArchiveInformation> createState() => _ArchiveInformationState();
}

class _ArchiveInformationState extends State<ArchiveInformation> {
  ArchiveStats? stats;
  List<ArchiveAccount> accessibleAccounts = [];
  late ArchiveAccount account;
  bool busy = true;
  String? error;
  @override
  void initState() {
    super.initState();
    account = widget.account;
    refresh();
  }

  Future<void> refresh() async {
    setState(() {
      busy = true;
      error = null;
    });
    try {
      final totals = await widget.api.stats();
      final available = await widget.api.accounts();
      final updated = available
          .where((item) => item.id == widget.account.id)
          .firstOrNull;
      if (updated == null) throw const ArchiveFailure(404);
      if (mounted) {
        setState(() {
          stats = totals;
          accessibleAccounts = available;
          account = updated;
        });
        widget.onRefreshed?.call();
      }
    } catch (failure) {
      if (mounted) {
        setState(() {
          stats = null;
          accessibleAccounts = [];
          error = readableError(failure);
        });
      }
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  String syncLabel(BuildContext context) {
    final value = account.lastSync;
    if (value == null || value.isEmpty) return 'Not reported';
    final parsed = DateTime.tryParse(
      value.endsWith('Z') || RegExp(r'[+-]\d\d:\d\d$').hasMatch(value)
          ? value
          : '${value}Z',
    );
    if (parsed == null) return 'Not reported';
    final local = parsed.toLocal();
    return '${MaterialLocalizations.of(context).formatMediumDate(local)} · ${MaterialLocalizations.of(context).formatTimeOfDay(TimeOfDay.fromDateTime(local))} (local)';
  }

  @override
  Widget build(BuildContext context) => Card(
    child: Padding(
      padding: const EdgeInsets.all(16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(
                child: Text(
                  'Archive information',
                  style: Theme.of(context).textTheme.titleMedium,
                ),
              ),
              IconButton(
                tooltip: 'Refresh archive information',
                onPressed: busy ? null : refresh,
                icon: const Icon(Icons.refresh),
              ),
            ],
          ),
          if (busy) const LinearProgressIndicator(),
          if (error != null)
            Text(
              error!,
              style: TextStyle(color: Theme.of(context).colorScheme.error),
            ),
          if (!busy && error == null) ...[
            ListTile(
              contentPadding: EdgeInsets.zero,
              title: const Text('Last account sync'),
              subtitle: Text(syncLabel(context)),
            ),
            Text(
              'Archiving: ${switch (account.archivingEnabled) {
                true => 'Enabled',
                false => 'Disabled',
                null => 'Not reported',
              }}',
            ),
            const Divider(height: 28),
            const Text('Totals across all accounts accessible to this API key'),
            if (stats != null) ...[
              ListTile(
                contentPadding: EdgeInsets.zero,
                leading: const Icon(Icons.mail_outline),
                title: const Text('Archived messages'),
                trailing: Text('${stats!.emails}'),
              ),
              ListTile(
                contentPadding: EdgeInsets.zero,
                leading: const Icon(Icons.attach_file),
                title: const Text('Attachments'),
                trailing: Text('${stats!.attachments}'),
              ),
              ListTile(
                contentPadding: EdgeInsets.zero,
                leading: const Icon(Icons.account_circle_outlined),
                title: const Text('Accessible accounts'),
                trailing: Text('${stats!.accounts}'),
              ),
            ],
            const Divider(height: 28),
            Text(
              'Email accounts',
              style: Theme.of(context).textTheme.titleMedium,
            ),
            const SizedBox(height: 8),
            const Text('Accounts accessible to this API key.'),
            const SizedBox(height: 12),
            for (final item in accessibleAccounts)
              Padding(
                padding: const EdgeInsets.only(bottom: 16),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    if (widget.onAccountSelected != null)
                      TextButton(
                        onPressed: () => widget.onAccountSelected!(item),
                        style: TextButton.styleFrom(
                          alignment: Alignment.centerLeft,
                        ),
                        child: Text(accountAddress(item)),
                      )
                    else
                      Text(accountAddress(item)),
                    if (item.id == account.id)
                      Text(
                        'Currently browsing',
                        style: Theme.of(context).textTheme.bodySmall,
                      ),
                  ],
                ),
              ),
          ],
        ],
      ),
    ),
  );
}
