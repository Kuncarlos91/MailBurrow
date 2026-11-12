/// The kind of archive server a saved connection points at.
///
/// Stored explicitly with every saved connection. The app never works out a
/// server's type by probing it with a saved key, and never falls back to
/// another type: an unknown stored value makes the saved connection unreadable,
/// so the user enters their settings again.
enum ArchiveServerType {
  mailArchiver('mail-archiver');

  const ArchiveServerType(this.id);

  /// The value written to secure storage. Never rename an existing value.
  final String id;

  /// The type for a stored [id], or null when it is not one this build knows.
  static ArchiveServerType? fromId(Object? id) {
    for (final type in values) {
      if (type.id == id) return type;
    }
    return null;
  }
}
