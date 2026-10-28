bool matchesLibrarySearch({
  required String query,
  required String title,
  required String artist,
  String? album,
  Iterable<String> playlists = const [],
}) {
  final normalizedQuery = query.trim().toLowerCase();
  if (normalizedQuery.isEmpty) return true;

  return [
    title,
    artist,
    album ?? '',
    ...playlists,
  ].any((value) => value.toLowerCase().contains(normalizedQuery));
}
