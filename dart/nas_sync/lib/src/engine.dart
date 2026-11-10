import 'dart:async';
import 'dart:typed_data';

import 'client.dart';
import 'state.dart';

/// One synced item: a drawing, a list entry, a settings blob...
///
/// [data] is small structured JSON; [blob] is a file (any bytes, up to
/// 200 MB). An app can use either or both.
class SyncItem {
  final String kind;
  final String key;

  /// When it was last edited, ms since epoch. Newest wins.
  final int modified;
  final bool deleted;
  final Map<String, dynamic>? data;
  final Uint8List? blob;

  /// Which device made this version (from the server; informational).
  final String? device;

  const SyncItem({
    required this.kind,
    required this.key,
    required this.modified,
    this.deleted = false,
    this.data,
    this.blob,
    this.device,
  });

  const SyncItem.deletion({required this.kind, required this.key, required this.modified, this.device})
      : deleted = true,
        data = null,
        blob = null;
}

/// An item that exists on this device, for [NasSync.adopt].
typedef LocalItem = ({String kind, String key, int modified});

/// The app's side of syncing: reading and writing its own local data.
/// Extend this (rather than implement it) to get the default hooks.
abstract class SyncSource {
  /// The current local version, or null if it no longer exists here.
  Future<SyncItem?> read(String kind, String key);

  /// Writes a version from the server locally; deletes it if [SyncItem.deleted].
  /// Must not call [NasSync.markChanged] for this item.
  Future<void> apply(SyncItem item);

  /// Called when two devices changed the same item and [loser] lost.
  /// Keep it somewhere (e.g. as a "conflicted copy") so nothing is lost.
  /// Never called with a deletion.
  Future<void> keepLoser(SyncItem loser, SyncItem winner) async {}

  /// Optionally combine two conflicting versions instead of newest-wins.
  /// Return null to use newest-wins. Never called with a deletion.
  Future<SyncItem?> merge(SyncItem local, SyncItem remote) async => null;
}

/// What a [NasSync.sync] did.
class SyncReport {
  int pulled = 0;
  int pushed = 0;
  int conflicts = 0;

  /// Items that couldn't be sent, with the reason. The rest still synced.
  final List<String> problems = [];

  bool get changedLocally => pulled > 0 || conflicts > 0;

  @override
  String toString() => 'pulled $pulled, pushed $pushed, conflicts $conflicts'
      '${problems.isEmpty ? '' : ', problems: ${problems.join('; ')}'}';
}

/// Keeps one app's data on this device in step with the server.
///
/// The app keeps working from its own local copy. It calls [markChanged]
/// whenever it changes something, and [sync] whenever it likes (on start,
/// after edits, every few minutes). Sync pulls what other devices changed,
/// then pushes what this device changed. When the same item changed on
/// both, the newer edit wins and the loser goes to [SyncSource.keepLoser].
class NasSync {
  /// The server connection; may be replaced (e.g. after signing in again).
  PbClient client;

  /// Which app's items these are, e.g. `inkpad`. Each app has its own space.
  final String app;

  /// A name for this device, stored with each version.
  final String device;
  final SyncSource source;
  final SyncStateStorage storage;
  final int Function() _clock;

  SyncState? _state;
  Future<SyncReport>? _running;
  bool _again = false;

  NasSync({
    required this.client,
    required this.app,
    required this.device,
    required this.source,
    required this.storage,
    int Function()? clock,
  }) : _clock = clock ?? (() => DateTime.now().millisecondsSinceEpoch);

  Future<SyncState> _load() async => _state ??= SyncState.decode(await storage.read());

  Future<void> _save() async => storage.write((await _load()).encode());

  /// Records a local change (or deletion) so the next [sync] sends it.
  Future<void> markChanged(String kind, String key, {bool deleted = false, int? modified}) async {
    final s = await _load();
    final st = s.items.putIfAbsent(SyncState.id(kind, key), () => ItemState(modified: 0));
    st
      ..dirty = true
      ..deleted = deleted
      ..modified = modified ?? _clock()
      ..edits += 1;
    await _save();
  }

  /// Marks items that exist here but that sync has never seen as changed,
  /// so they get sent. Call before syncing with everything the app has;
  /// it's cheap, and catches data made before sync was turned on.
  Future<void> adopt(Iterable<LocalItem> local) async {
    final s = await _load();
    var changed = false;
    for (final l in local) {
      final id = SyncState.id(l.kind, l.key);
      if (s.items.containsKey(id)) continue;
      s.items[id] = ItemState(modified: l.modified, dirty: true, edits: 1);
      changed = true;
    }
    if (changed) await _save();
  }

  /// Whether anything is waiting to be sent.
  Future<bool> get hasPending async => (await _load()).items.values.any((s) => s.dirty);

  /// Pulls, then pushes. Runs one at a time: calling it while a sync is
  /// running schedules one more run straight after.
  Future<SyncReport> sync() {
    if (_running != null) {
      _again = true;
      return _running!;
    }
    final run = _syncLoop();
    _running = run;
    return run.whenComplete(() => _running = null);
  }

  Future<SyncReport> _syncLoop() async {
    late SyncReport report;
    do {
      _again = false;
      report = await _syncOnce();
    } while (_again);
    return report;
  }

  Future<SyncReport> _syncOnce() async {
    final auth = client.auth;
    if (auth == null) throw StateError('Not signed in');
    final s = await _load();
    if (s.userId != auth.userId) {
      // A different account: everything here goes up as new to that account.
      if (s.userId != null) {
        s.cursor = null;
        for (final st in s.items.values) {
          st
            ..recordId = null
            ..baseUpdated = null
            ..dirty = !st.deleted
            ..edits += 1;
        }
        s.items.removeWhere((_, st) => st.deleted);
      }
      s.userId = auth.userId;
      await _save();
    }
    final report = SyncReport();
    // A push can find that another device changed an item since the pull;
    // then pull again (resolving the conflict) and push once more.
    for (var round = 0; round < 3; round++) {
      await _pull(s, report);
      if (!await _push(s, auth, report)) break;
    }
    await _save();
    return report;
  }

  // ---- Pull ------------------------------------------------------------------

  Future<void> _pull(SyncState s, SyncReport report) async {
    final records = await client.listSince(app, s.cursor);
    String? fileToken;
    Future<String> token() async => fileToken ??= await client.fileToken();
    var unsaved = 0;
    for (final r in records) {
      final id = SyncState.id(r['kind'] as String, r['item_key'] as String);
      final updated = r['updated'] as String;
      final st = s.items[id];
      if (!(st != null && st.recordId == r['id'] && st.baseUpdated == updated)) {
        if (st == null || !st.dirty) {
          await _applyRemote(s, id, r, await _remoteItem(r, token));
          report.pulled++;
        } else {
          await _resolve(s, st, r, await _remoteItem(r, token));
          report.conflicts++;
        }
      }
      s.cursor = updated;
      if (++unsaved >= 25) {
        await _save();
        unsaved = 0;
      }
    }
    if (unsaved > 0) await _save();
  }

  Future<SyncItem> _remoteItem(Map<String, dynamic> r, Future<String> Function() token) async {
    final deleted = r['deleted'] as bool? ?? false;
    final file = r['blob'] as String? ?? '';
    final data = r['data'];
    return SyncItem(
      kind: r['kind'] as String,
      key: r['item_key'] as String,
      modified: (r['modified'] as num?)?.toInt() ?? 0,
      deleted: deleted,
      data: !deleted && data is Map ? data.cast<String, dynamic>() : null,
      blob: !deleted && file.isNotEmpty ? await client.download(r['id'] as String, file, await token()) : null,
      device: r['device'] as String?,
    );
  }

  /// Writes the server's version locally and remembers it as synced, unless
  /// the app changed the item while it was being written.
  Future<void> _applyRemote(SyncState s, String id, Map<String, dynamic> r, SyncItem remote) async {
    final editsBefore = s.items[id]?.edits ?? 0;
    await source.apply(remote);
    final now = s.items[id];
    if (now != null && now.edits != editsBefore) {
      // Edited meanwhile: the local edit is newer; send it over this version.
      now
        ..recordId = r['id'] as String
        ..baseUpdated = r['updated'] as String;
      return;
    }
    s.items[id] = ItemState(
      recordId: r['id'] as String,
      baseUpdated: r['updated'] as String,
      modified: remote.modified,
      deleted: remote.deleted,
      edits: editsBefore,
    );
  }

  Future<void> _resolve(SyncState s, ItemState st, Map<String, dynamic> r, SyncItem remote) async {
    final (kind, key) = (remote.kind, remote.key);
    final local = st.deleted
        ? SyncItem.deletion(kind: kind, key: key, modified: st.modified)
        : await source.read(kind, key) ?? SyncItem.deletion(kind: kind, key: key, modified: st.modified);
    final id = SyncState.id(kind, key);

    if (local.deleted && remote.deleted) {
      await _applyRemote(s, id, r, remote);
      return;
    }
    if (!local.deleted && !remote.deleted) {
      final merged = await source.merge(local, remote);
      if (merged != null) {
        await source.apply(merged);
        st
          ..recordId = r['id'] as String
          ..baseUpdated = r['updated'] as String
          ..modified = merged.modified
          ..deleted = merged.deleted
          ..dirty = true;
        return;
      }
    }
    if (remote.modified >= local.modified) {
      if (!local.deleted) await source.keepLoser(local, remote);
      await _applyRemote(s, id, r, remote);
    } else {
      if (!remote.deleted) await source.keepLoser(remote, local);
      // Stays dirty: the push sends the local version over the remote one.
      st
        ..recordId = r['id'] as String
        ..baseUpdated = r['updated'] as String;
    }
  }

  // ---- Push ------------------------------------------------------------------

  /// Sends local changes. Returns true if some item changed on the server
  /// meanwhile and needs another pull first.
  Future<bool> _push(SyncState s, PbAuth auth, SyncReport report) async {
    var retry = false;
    final dirty = [for (final e in s.items.entries) if (e.value.dirty) e];
    for (final MapEntry(key: id, value: st) in dirty) {
      final edits = st.edits;
      final slash = id.indexOf('/');
      final (kind, key) = (id.substring(0, slash), id.substring(slash + 1));
      final item = st.deleted ? null : await source.read(kind, key);
      final deleted = item == null;

      if (st.recordId == null && deleted) {
        // Made and deleted here before it ever reached the server.
        if (st.edits == edits) s.items.remove(id);
        continue;
      }
      if (st.recordId != null) {
        final current = await client.getRecord(st.recordId!);
        if (current == null) {
          st
            ..recordId = null
            ..baseUpdated = null;
          if (deleted) {
            if (st.edits == edits) s.items.remove(id);
            continue;
          }
        } else if (current['updated'] != st.baseUpdated) {
          retry = true;
          continue;
        }
      }

      final Map<String, dynamic> saved;
      try {
        saved = await client.saveRecord(
          id: st.recordId,
          fields: {
            'owner': auth.userId,
            'app': app,
            'kind': kind,
            'item_key': key,
            'modified': st.modified,
            'deleted': deleted,
            'device': device,
            'data': item?.data,
          },
          blob: item?.blob,
          clearBlob: st.recordId != null && item?.blob == null,
        );
      } on PbException catch (e) {
        if (e.isAuth) rethrow;
        if (e.isNotUnique) {
          // Another device made the same item meanwhile.
          retry = true;
        } else {
          report.problems.add('$id: ${e.message}');
        }
        continue;
      }
      st
        ..recordId = saved['id'] as String
        ..baseUpdated = saved['updated'] as String;
      if (st.edits == edits) {
        st
          ..dirty = false
          ..deleted = deleted;
      }
      report.pushed++;
      await _save();
    }
    return retry;
  }
}
