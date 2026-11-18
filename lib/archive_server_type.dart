/// The kind of archive server a saved connection points at.
///
/// Stored explicitly with every saved connection. The app never works out a
/// server's type by probing it with a saved key, and never falls back to
/// another type: an unknown stored value makes the saved connection unreadable,
/// so the user enters their settings again.
enum ArchiveServerType {
  mailArchiver('mail-archiver', 'Mail-Archiver', 'API key'),

  /// Open Archiver v0.6.2, the tested version.
  openArchiver('open-archiver', 'Open Archiver', 'API key'),

  /// Bichon 2.4.2 Community, the tested version. Bichon calls its credential
  /// an access token.
  bichon('bichon', 'Bichon', 'access token');

  const ArchiveServerType(this.id, this.label, this.credential);

  /// The value written to secure storage. Never rename an existing value.
  final String id;

  /// The name shown to the user.
  final String label;

  /// What the server calls the credential the user enters, in lower case
  /// for use within a sentence, such as "API key" or "access token".
  final String credential;

  /// [credential] starting with a capital letter, for labels and headings.
  String get credentialLabel =>
      credential[0].toUpperCase() + credential.substring(1);

  /// The type for a stored [id], or null when it is not one this build knows.
  static ArchiveServerType? fromId(Object? id) {
    for (final type in values) {
      if (type.id == id) return type;
    }
    return null;
  }
}
