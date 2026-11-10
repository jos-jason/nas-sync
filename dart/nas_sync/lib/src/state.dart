import 'dart:convert';

/// What this device knows about one item.
class ItemState {
  /// The server row, once there is one.
  String? recordId;

  /// The server's `updated` stamp of the version this device last synced.
  String? baseUpdated;

  /// When the item was last edited (ms since epoch): the local edit while
  /// [dirty], otherwise the synced version's edit time.
  int modified;

  /// Changed here and not yet sent.
  bool dirty;

  /// Deleted (here, if [dirty]; or the synced version is a deletion).
  bool deleted;

  /// Bumped on every local change, so a change made while sending
  /// isn't mistaken for sent.
  int edits;

  ItemState({
    this.recordId,
    this.baseUpdated,
    required this.modified,
    this.dirty = false,
    this.deleted = false,
    this.edits = 0,
  });

  Map<String, dynamic> toJson() => {
        if (recordId != null) 'r': recordId,
        if (baseUpdated != null) 'u': baseUpdated,
        'm': modified,
        if (dirty) 'd': true,
        if (deleted) 'x': true,
        if (edits != 0) 'e': edits,
      };

  factory ItemState.fromJson(Map<String, dynamic> j) => ItemState(
        recordId: j['r'] as String?,
        baseUpdated: j['u'] as String?,
        modified: j['m'] as int? ?? 0,
        dirty: j['d'] as bool? ?? false,
        deleted: j['x'] as bool? ?? false,
        edits: j['e'] as int? ?? 0,
      );
}

/// Everything this device remembers between syncs.
class SyncState {
  /// The newest server `updated` stamp already pulled.
  String? cursor;

  /// The user these records belong to; a different sign-in starts over.
  String? userId;

  final Map<String, ItemState> items;

  SyncState({this.cursor, this.userId, Map<String, ItemState>? items}) : items = items ?? {};

  static String id(String kind, String key) => '$kind/$key';

  String encode() => jsonEncode({
        'v': 1,
        if (cursor != null) 'cursor': cursor,
        if (userId != null) 'user': userId,
        'items': {for (final e in items.entries) e.key: e.value.toJson()},
      });

  factory SyncState.decode(String? text) {
    if (text == null || text.isEmpty) return SyncState();
    final j = jsonDecode(text) as Map<String, dynamic>;
    return SyncState(
      cursor: j['cursor'] as String?,
      userId: j['user'] as String?,
      items: {
        for (final e in (j['items'] as Map<String, dynamic>? ?? {}).entries)
          e.key: ItemState.fromJson(e.value as Map<String, dynamic>),
      },
    );
  }
}

/// Where the app keeps [SyncState] (a file, app preferences...).
abstract class SyncStateStorage {
  Future<String?> read();
  Future<void> write(String text);
}

class MemorySyncStateStorage implements SyncStateStorage {
  String? text;

  @override
  Future<String?> read() async => text;

  @override
  Future<void> write(String t) async => text = t;
}
