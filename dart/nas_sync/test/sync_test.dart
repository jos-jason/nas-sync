// Runs against a real PocketBase with the migrations from server/pb_migrations
// and users alice/bob (see the test server reset script). Set NAS_SYNC_TEST_URL,
// e.g. NAS_SYNC_TEST_URL=http://127.0.0.1:18090 dart test
@TestOn('vm')
library;

import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:nas_sync/nas_sync.dart';
import 'package:test/test.dart';

final url = Platform.environment['NAS_SYNC_TEST_URL'];

/// An app's local data, in memory.
class MemorySource extends SyncSource {
  final Map<String, SyncItem> items = {};
  final List<SyncItem> losers = [];
  Future<SyncItem?> Function(SyncItem local, SyncItem remote)? merger;

  @override
  Future<SyncItem?> read(String kind, String key) async => items['$kind/$key'];

  @override
  Future<void> apply(SyncItem item) async {
    if (item.deleted) {
      items.remove('${item.kind}/${item.key}');
    } else {
      items['${item.kind}/${item.key}'] = item;
    }
  }

  @override
  Future<void> keepLoser(SyncItem loser, SyncItem winner) async => losers.add(loser);

  @override
  Future<SyncItem?> merge(SyncItem local, SyncItem remote) async => merger?.call(local, remote);
}

/// A fake clock shared by all devices in a test, so "newer" is exact.
int _now = 1000000;
int tick() => _now += 1000;

class Device {
  final MemorySource source = MemorySource();
  final MemorySyncStateStorage storage = MemorySyncStateStorage();
  late final PbClient client;
  late final NasSync sync;

  Device._(String app, String name) {
    client = PbClient(url!);
    sync = NasSync(client: client, app: app, device: name, source: source, storage: storage, clock: tick);
  }

  static Future<Device> signedIn(String app, String name, String user) async {
    final d = Device._(app, name);
    await d.client.signIn('$user@test.local', 'pw-$user-12345');
    return d;
  }

  /// A local edit, as the app would make it.
  Future<void> put(String key, Map<String, dynamic> data, {Uint8List? blob}) async {
    final m = tick();
    source.items['doc/$key'] = SyncItem(kind: 'doc', key: key, modified: m, data: data, blob: blob);
    await sync.markChanged('doc', key, modified: m);
  }

  Future<void> remove(String key) async {
    source.items.remove('doc/$key');
    await sync.markChanged('doc', key, deleted: true);
  }

  Map<String, dynamic>? data(String key) => source.items['doc/$key']?.data;
}

String newApp() => 'test${Random().nextInt(1 << 32)}';

void main() {
  if (url == null) {
    test('server tests', () {}, skip: 'set NAS_SYNC_TEST_URL to a test PocketBase');
    return;
  }

  late String app;
  setUp(() => app = newApp());

  test('an item made on one device reaches the other, file included', () async {
    final a = await Device.signedIn(app, 'A', 'alice');
    final b = await Device.signedIn(app, 'B', 'alice');
    final bytes = Uint8List.fromList(List.generate(300000, (i) => i % 251));
    await a.put('k1', {'title': 'hello'}, blob: bytes);
    expect((await a.sync.sync()).pushed, 1);

    final r = await b.sync.sync();
    expect(r.pulled, 1);
    expect(b.data('k1'), {'title': 'hello'});
    expect(b.source.items['doc/k1']!.blob, bytes);
    expect(await b.sync.hasPending, isFalse);
  });

  test('edits and deletions go both ways, and nothing repeats', () async {
    final a = await Device.signedIn(app, 'A', 'alice');
    final b = await Device.signedIn(app, 'B', 'alice');
    await a.put('k1', {'v': 1});
    await a.sync.sync();
    await b.sync.sync();

    await b.put('k1', {'v': 2});
    await b.sync.sync();
    expect((await a.sync.sync()).pulled, 1);
    expect(a.data('k1'), {'v': 2});

    // Syncing again changes nothing.
    final again = await a.sync.sync();
    expect([again.pulled, again.pushed, again.conflicts], [0, 0, 0]);

    await a.remove('k1');
    await a.sync.sync();
    await b.sync.sync();
    expect(b.source.items, isEmpty);
  });

  test('both edited offline: newer wins everywhere, the older is kept as a loser', () async {
    final a = await Device.signedIn(app, 'A', 'alice');
    final b = await Device.signedIn(app, 'B', 'alice');
    await a.put('k1', {'v': 0});
    await a.sync.sync();
    await b.sync.sync();

    await a.put('k1', {'v': 'A, older'});
    await b.put('k1', {'v': 'B, newer'});
    await a.sync.sync(); // A's older edit reaches the server first
    final rb = await b.sync.sync();
    expect(rb.conflicts, 1);
    await a.sync.sync();

    expect(a.data('k1'), {'v': 'B, newer'});
    expect(b.data('k1'), {'v': 'B, newer'});
    expect([for (final l in b.source.losers) l.data], [
      {'v': 'A, older'}
    ]);
    expect(a.source.losers, isEmpty);
  });

  test('newer edit synced first: the older device takes it and keeps its own as a loser', () async {
    final a = await Device.signedIn(app, 'A', 'alice');
    final b = await Device.signedIn(app, 'B', 'alice');
    await a.put('k1', {'v': 0});
    await a.sync.sync();
    await b.sync.sync();

    await a.put('k1', {'v': 'A, older'});
    await b.put('k1', {'v': 'B, newer'});
    await b.sync.sync();
    await a.sync.sync();
    await b.sync.sync();

    expect(a.data('k1'), {'v': 'B, newer'});
    expect(b.data('k1'), {'v': 'B, newer'});
    expect([for (final l in a.source.losers) l.data], [
      {'v': 'A, older'}
    ]);
  });

  test('deleted on one, edited later on the other: the edit wins', () async {
    final a = await Device.signedIn(app, 'A', 'alice');
    final b = await Device.signedIn(app, 'B', 'alice');
    await a.put('k1', {'v': 0});
    await a.sync.sync();
    await b.sync.sync();

    await a.remove('k1');
    await b.put('k1', {'v': 'kept'});
    await a.sync.sync();
    await b.sync.sync();
    await a.sync.sync();
    expect(a.data('k1'), {'v': 'kept'});
    expect(b.data('k1'), {'v': 'kept'});
  });

  test('edited on one, deleted later on the other: deleted, the edit kept as a loser', () async {
    final a = await Device.signedIn(app, 'A', 'alice');
    final b = await Device.signedIn(app, 'B', 'alice');
    await a.put('k1', {'v': 0});
    await a.sync.sync();
    await b.sync.sync();

    await a.put('k1', {'v': 'edit'});
    await b.remove('k1');
    await a.sync.sync();
    await b.sync.sync();
    await a.sync.sync();
    expect(a.source.items, isEmpty);
    expect(b.source.items, isEmpty);
    // B found the conflict, so B keeps the losing edit (and syncs it on as a copy, in a real app).
    expect([for (final l in b.source.losers) l.data], [
      {'v': 'edit'}
    ]);
  });

  test('merge hook replaces newest-wins', () async {
    final a = await Device.signedIn(app, 'A', 'alice');
    final b = await Device.signedIn(app, 'B', 'alice');
    b.source.merger = (l, r) async => SyncItem(
          kind: l.kind,
          key: l.key,
          modified: max(l.modified, r.modified),
          data: {...r.data!, ...l.data!},
        );
    await a.put('k1', {'a': 1});
    await b.put('k1', {'b': 2});
    await a.sync.sync();
    await b.sync.sync();
    await a.sync.sync();
    expect(a.data('k1'), {'a': 1, 'b': 2});
    expect(b.data('k1'), {'a': 1, 'b': 2});
    expect(b.source.losers, isEmpty);
  });

  test('adopt sends data made before sync was turned on', () async {
    final a = await Device.signedIn(app, 'A', 'alice');
    a.source.items['doc/old'] = const SyncItem(kind: 'doc', key: 'old', modified: 5, data: {'old': true});
    await a.sync.adopt([(kind: 'doc', key: 'old', modified: 5)]);
    await a.sync.adopt([(kind: 'doc', key: 'old', modified: 5)]); // twice is harmless
    expect((await a.sync.sync()).pushed, 1);
    final b = await Device.signedIn(app, 'B', 'alice');
    await b.sync.sync();
    expect(b.data('old'), {'old': true});
  });

  test("one person's data is invisible to another", () async {
    final a = await Device.signedIn(app, 'A', 'alice');
    await a.put('secret', {'x': 1});
    await a.sync.sync();
    final bob = await Device.signedIn(app, 'B', 'bob');
    expect((await bob.sync.sync()).pulled, 0);
    expect(bob.source.items, isEmpty);
  });

  test('a change made during a sync is not lost', () async {
    final a = await Device.signedIn(app, 'A', 'alice');
    await a.put('k1', {'v': 1});
    final running = a.sync.sync();
    await a.put('k1', {'v': 2}); // lands mid-sync
    await running;
    await a.sync.sync();
    final b = await Device.signedIn(app, 'B', 'alice');
    await b.sync.sync();
    expect(b.data('k1'), {'v': 2});
  });

  test('a token can be refreshed and reused', () async {
    final a = await Device.signedIn(app, 'A', 'alice');
    final saved = a.client.auth!.toJson();
    final c = PbClient(url!, auth: PbAuth.fromJson(saved));
    final fresh = await c.refresh();
    expect(fresh.userId, saved['userId']);
    expect(fresh.email, 'alice@test.local');
  });
}
