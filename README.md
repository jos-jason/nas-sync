# nas-sync

Backups and sync for my own apps, through a PocketBase server on my Synology NAS,
reachable only on my tailnet at `https://<nas-name>.<tailnet>.ts.net:8443`.

**Access.** This repo is only code. The server isn't on the internet: only devices on my own
tailnet can reach it, public sign-up is off, and every account is made by me in the admin page.

- `server/`: what runs on the NAS. Container Manager project `nas-sync` in `docker/nas-sync`.
  `pb_migrations/` defines the `sync_items` table; it is applied when the container starts.
- `dart/nas_sync/`: the client package every app uses (pure Dart; works in Flutter).

## How sync works
Every app keeps working from its own local copy. One table holds every app's items,
tagged with the app name and the owner; each person sees only their own.
On sync a device pulls what changed on the server since last time, then pushes its own changes.
If the same item changed on two devices, the newer edit wins and the app is handed the losing
version to keep (Inkpad saves it as a "conflicted copy").

Accounts: one per person, made in the admin page (`/_/` → users → New record, tick "verified").
Public sign-up is off.

## Using it from an app
```dart
final client = PbClient('https://<nas-name>.<tailnet>.ts.net:8443');
await client.signIn(email, password);          // store client.auth.toJson() securely
final sync = NasSync(client: client, app: 'myapp', device: 'Omac',
    source: MySource(), storage: MyStateStorage());
await sync.markChanged('note', id);            // after every local change
await sync.sync();                             // on start, after edits, every few minutes
```
`MySource` extends `SyncSource`: `read`, `apply`, and optionally `keepLoser` / `merge`.

## Testing
Run a local PocketBase with these migrations and users `alice`/`bob`
(passwords `pw-<name>-12345`), then:
`NAS_SYNC_TEST_URL=http://127.0.0.1:18090 dart test` in `dart/nas_sync`.

## Backups
PocketBase backs up nightly at 03:00 (keeps 14) into `pb_data/backups`; Btrfs snapshots of the
`docker` folder daily, kept 30 days. No off-NAS copy yet.
