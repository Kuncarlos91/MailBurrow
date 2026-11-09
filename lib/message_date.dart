import 'package:flutter/material.dart';

// Mail-Archiver's list and detail responses use sentDate (ISO 8601).
// Do not invent a timezone when an older server omits it.
class MessageTimestamp {
  const MessageTimestamp(
    this.date, {
    required this.hasTime,
    required this.hasZone,
  });
  final DateTime date;
  final bool hasTime, hasZone;

  static MessageTimestamp? parse(Object? value) {
    if (value is! String) return null;
    final match = RegExp(
      r'^(\d{4})-(\d{2})-(\d{2})(?:T([01]\d|2[0-3]):([0-5]\d):([0-5]\d)(?:\.\d{1,9})?(Z|[+-](?:[01]\d|2[0-3]):[0-5]\d)?)?$',
    ).firstMatch(value.trim());
    if (match == null) return null;
    final year = int.parse(match[1]!);
    final month = int.parse(match[2]!);
    final day = int.parse(match[3]!);
    final calendar = DateTime.utc(year, month, day);
    if (year <= 1 ||
        calendar.year != year ||
        calendar.month != month ||
        calendar.day != day) {
      return null;
    }
    final hasZone = match[7] != null;
    final hasTime = match[4] != null;
    // Use a UTC container for unspecified wall-clock components, so device
    // daylight-saving gaps cannot silently change an archived time.
    final parseValue = hasZone
        ? value.trim()
        : '${value.trim()}${hasTime ? 'Z' : 'T00:00:00Z'}';
    final parsed = DateTime.tryParse(parseValue);
    if (parsed == null) return null;
    return MessageTimestamp(
      hasZone ? parsed.toLocal() : parsed,
      hasTime: hasTime,
      hasZone: hasZone,
    );
  }
}

class MessageDate extends StatelessWidget {
  const MessageDate({super.key, required this.value, this.detailed = false});
  final Object? value;
  final bool detailed;

  @override
  Widget build(BuildContext context) {
    final timestamp = MessageTimestamp.parse(value);
    final localizations = MaterialLocalizations.of(context);
    String label;
    if (timestamp == null) {
      label = detailed ? 'Sent date unavailable' : 'Date unavailable';
    } else if (!detailed) {
      label = localizations.formatShortDate(timestamp.date);
    } else {
      label = 'Sent: ${localizations.formatFullDate(timestamp.date)}';
      if (timestamp.hasTime) {
        final time = localizations.formatTimeOfDay(
          TimeOfDay.fromDateTime(timestamp.date),
          alwaysUse24HourFormat: MediaQuery.alwaysUse24HourFormatOf(context),
        );
        label +=
            ' · $time · ${timestamp.hasZone ? 'local time' : 'time zone unspecified'}';
      }
    }
    return Text(
      label,
      style: Theme.of(context).textTheme.bodySmall,
      semanticsLabel: detailed || timestamp == null ? label : 'Sent: $label',
    );
  }
}
