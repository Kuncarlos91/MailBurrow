import 'package:flutter/material.dart';

class SearchFilters {
  const SearchFilters({
    this.from,
    this.to,
    this.direction = '',
    this.sortBy = 'sentDate',
    this.sortOrder = 'desc',
  });
  final DateTime? from, to;
  final String direction, sortBy, sortOrder;
  bool get active =>
      from != null ||
      to != null ||
      direction.isNotEmpty ||
      sortBy != 'sentDate' ||
      sortOrder != 'desc';
  String? get validationError =>
      from != null && to != null && from!.isAfter(to!)
      ? 'Start date must be on or before end date.'
      : null;
  Map<String, String> get parameters => {
    if (from != null) 'from': dateLabel(from!),
    if (to != null) 'to': dateLabel(to!),
    if (direction.isNotEmpty) 'direction': direction,
    'sortBy': sortBy,
    'sortOrder': sortOrder,
  };
}

String dateLabel(DateTime value) =>
    '${value.year.toString().padLeft(4, '0')}-${value.month.toString().padLeft(2, '0')}-${value.day.toString().padLeft(2, '0')}';

class SearchFiltersSheet extends StatefulWidget {
  const SearchFiltersSheet({super.key, required this.filters});
  final SearchFilters filters;
  @override
  State<SearchFiltersSheet> createState() => _SearchFiltersSheetState();
}

class _SearchFiltersSheetState extends State<SearchFiltersSheet> {
  DateTime? from, to;
  late String direction, sortBy, sortOrder;
  String? error;
  @override
  void initState() {
    super.initState();
    reset(widget.filters);
  }

  void reset(SearchFilters value) {
    from = value.from;
    to = value.to;
    direction = value.direction;
    sortBy = value.sortBy;
    sortOrder = value.sortOrder;
    error = null;
  }

  Future<void> chooseDate(bool start) async {
    final chosen = await showDatePicker(
      context: context,
      initialDate: (start ? from : to) ?? DateTime.now(),
      firstDate: DateTime(1),
      lastDate: DateTime(9999, 12, 31),
    );
    if (chosen == null || !mounted) return;
    setState(() {
      if (start) {
        from = chosen;
      } else {
        to = chosen;
      }
      error = null;
    });
  }

  Widget dateField(String label, DateTime? value, bool start) => ListTile(
    contentPadding: EdgeInsets.zero,
    leading: const Icon(Icons.calendar_month_outlined),
    title: Text(label),
    subtitle: Text(value == null ? 'Any date' : dateLabel(value)),
    onTap: () => chooseDate(start),
    trailing: value == null
        ? const Icon(Icons.chevron_right)
        : IconButton(
            tooltip: 'Clear $label',
            icon: const Icon(Icons.close),
            onPressed: () => setState(() {
              if (start) {
                from = null;
              } else {
                to = null;
              }
              error = null;
            }),
          ),
  );
  Widget choice(
    String label,
    String value,
    Map<String, String> options,
    ValueChanged<String> change,
  ) => Column(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      Text(label, style: Theme.of(context).textTheme.labelLarge),
      const SizedBox(height: 8),
      InputDecorator(
        decoration: const InputDecoration(
          border: OutlineInputBorder(),
          contentPadding: EdgeInsets.symmetric(horizontal: 12, vertical: 4),
        ),
        child: DropdownButtonHideUnderline(
          child: DropdownButton<String>(
            value: value,
            isExpanded: true,
            itemHeight: null,
            items: options.entries
                .map(
                  (entry) => DropdownMenuItem(
                    value: entry.key,
                    child: Padding(
                      padding: const EdgeInsets.symmetric(vertical: 8),
                      child: Text(entry.value),
                    ),
                  ),
                )
                .toList(),
            onChanged: (selected) {
              if (selected != null) setState(() => change(selected));
            },
          ),
        ),
      ),
      const SizedBox(height: 20),
    ],
  );
  @override
  Widget build(BuildContext context) => SafeArea(
    child: SingleChildScrollView(
      padding: EdgeInsets.fromLTRB(
        24,
        8,
        24,
        24 + MediaQuery.viewInsetsOf(context).bottom,
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(
                child: Text(
                  'Search filters',
                  style: Theme.of(context).textTheme.headlineSmall,
                ),
              ),
              IconButton(
                tooltip: 'Cancel',
                onPressed: () => Navigator.pop(context),
                icon: const Icon(Icons.close),
              ),
            ],
          ),
          const Text('Sent date range · inclusive'),
          dateField('From', from, true),
          dateField('To', to, false),
          choice('Direction', direction, {
            '': 'All mail',
            'incoming': 'Incoming',
            'outgoing': 'Outgoing',
          }, (value) => direction = value),
          choice('Sort by', sortBy, {
            'sentDate': 'Sent date',
            'receivedDate': 'Received date',
            'subject': 'Subject',
            'from': 'Sender',
            'to': 'Recipient',
          }, (value) => sortBy = value),
          choice('Order', sortOrder, {
            'desc': 'Descending',
            'asc': 'Ascending',
          }, (value) => sortOrder = value),
          if (error != null)
            Text(
              error!,
              style: TextStyle(color: Theme.of(context).colorScheme.error),
            ),
          OverflowBar(
            alignment: MainAxisAlignment.spaceBetween,
            overflowAlignment: OverflowBarAlignment.end,
            spacing: 12,
            overflowSpacing: 12,
            children: [
              TextButton(
                onPressed: () => setState(() => reset(const SearchFilters())),
                child: const Text('Reset'),
              ),
              FilledButton(
                onPressed: () {
                  final result = SearchFilters(
                    from: from,
                    to: to,
                    direction: direction,
                    sortBy: sortBy,
                    sortOrder: sortOrder,
                  );
                  if (result.validationError != null) {
                    setState(() => error = result.validationError);
                    return;
                  }
                  Navigator.pop(context, result);
                },
                child: const Text('Apply'),
              ),
            ],
          ),
        ],
      ),
    ),
  );
}
