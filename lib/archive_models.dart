/// Shared folder metadata supplied by an archive backend.
class ArchiveFolder {
  const ArchiveFolder(this.name, this.path, this.count, this.depth);
  final String name, path;
  final int count, depth;
}
