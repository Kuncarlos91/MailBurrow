/// Converts the current JSON result's ID to the backend's opaque text form.
/// Numeric JSON IDs remain supported until typed results replace the maps.
/// Never stringify null, booleans or containers into an apparent identifier.
String archiveId(Object? value) {
  if (value is int) return value.toString();
  if (value is String && value.isNotEmpty) return value;
  throw const FormatException('Invalid archive identifier.');
}

/// Shared folder metadata supplied by an archive backend.
class ArchiveFolder {
  const ArchiveFolder(this.name, this.path, this.count, this.depth);
  final String name, path;
  final int count, depth;
}
