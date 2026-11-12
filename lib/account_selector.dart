import 'package:flutter/material.dart';
import 'archive_models.dart';
import 'archive_errors.dart';
import 'archive_backend.dart';

String accountAddress(Map<String, dynamic> account) {
  final value = account['emailAddress'];
  return value is String && value.trim().isNotEmpty
      ? value.trim()
      : 'Email address not reported';
}

Future<Map<String, dynamic>?> showAccountSelector(
  BuildContext context, {
  required ArchiveBackend api,
  required String currentAccountId,
}) => showModalBottomSheet<Map<String, dynamic>>(
  context: context,
  showDragHandle: true,
  isScrollControlled: true,
  builder: (_) => SizedBox(
    height: MediaQuery.sizeOf(context).height * .8,
    child: _AccountSelector(api: api, currentAccountId: currentAccountId),
  ),
);

class _AccountSelector extends StatefulWidget {
  const _AccountSelector({required this.api, required this.currentAccountId});
  final ArchiveBackend api;
  final String currentAccountId;
  @override
  State<_AccountSelector> createState() => _AccountSelectorState();
}

class _AccountSelectorState extends State<_AccountSelector> {
  bool _isCurrent(Map<String, dynamic> account) =>
      archiveIdOrNull(account['id']) == widget.currentAccountId;

  late Future<List<Map<String, dynamic>>> result;

  Future<List<Map<String, dynamic>>> fetch() async {
    final accounts = await widget.api.accounts();
    return accounts
        .map((value) {
          if (value is! Map<String, dynamic> ||
              archiveIdOrNull(value['id']) == null) {
            throw const FormatException('Invalid account response');
          }
          return value;
        })
        .toList(growable: false);
  }

  @override
  void initState() {
    super.initState();
    result = fetch();
  }

  void retry() => setState(() {
    result = fetch();
  });

  @override
  Widget build(BuildContext context) => SafeArea(
    child: FutureBuilder<List<Map<String, dynamic>>>(
      future: result,
      builder: (context, snapshot) => ListView(
        padding: const EdgeInsets.fromLTRB(16, 0, 16, 24),
        children: [
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 12),
            child: Text(
              'Email accounts',
              style: Theme.of(context).textTheme.titleLarge,
            ),
          ),
          if (snapshot.connectionState != ConnectionState.done)
            const Padding(
              padding: EdgeInsets.all(24),
              child: Center(child: CircularProgressIndicator()),
            )
          else if (snapshot.hasError) ...[
            Text(readableError(snapshot.error!)),
            TextButton(onPressed: retry, child: const Text('Retry')),
          ] else if (snapshot.data?.isEmpty ?? true) ...[
            const Text('No accessible email accounts.'),
            TextButton(onPressed: retry, child: const Text('Retry')),
          ] else
            for (final account in snapshot.data!)
              ListTile(
                key: ValueKey('account-choice-${account['id']}'),
                leading: const Icon(Icons.account_circle_outlined),
                title: Text(accountAddress(account)),
                subtitle: _isCurrent(account)
                    ? const Text('Currently browsing')
                    : null,
                trailing: _isCurrent(account)
                    ? const Icon(Icons.check)
                    : null,
                selected: _isCurrent(account),
                onTap: () => Navigator.pop(context, account),
              ),
        ],
      ),
    ),
  );
}
