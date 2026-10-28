import 'dart:io';

typedef FolderTrackMetadata = ({String? artist, String? album});

FolderTrackMetadata musicFolderMetadataFromPath(
  String trackPath,
  String libraryRoot,
) {
  final rootPath = Directory(libraryRoot).absolute.path;
  final parentPath = File(trackPath).absolute.parent.path;
  final prefix = '$rootPath${Platform.pathSeparator}';
  final folders = parentPath.toLowerCase().startsWith(prefix.toLowerCase())
      ? parentPath
            .substring(prefix.length)
            .split(Platform.pathSeparator)
            .where((folder) => folder.trim().isNotEmpty)
            .toList()
      : <String>[];
  if (folders.isEmpty) {
    if (parentPath.toLowerCase() != rootPath.toLowerCase()) {
      return (artist: null, album: null);
    }
    final rootName = rootPath
        .split(RegExp(r'[\\/]'))
        .where((part) => part.isNotEmpty)
        .lastOrNull;
    return (artist: null, album: rootName);
  }

  if (RegExp(
    r'^(?:cd|disc|disk)\s*\d+$',
    caseSensitive: false,
  ).hasMatch(folders.last.trim())) {
    folders.removeLast();
  }
  if (folders.isEmpty) return (artist: null, album: null);
  return (
    artist: folders.length > 1 ? folders[folders.length - 2] : null,
    album: folders.last,
  );
}
