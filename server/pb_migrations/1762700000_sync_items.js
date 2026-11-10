/// <reference path="../pb_data/types.d.ts" />
// One shared table for every app's synced data. Each row is one item
// (a drawing, a list entry, a settings blob...) owned by one user.
migrate((app) => {
  // Accounts are made by the admin, not by public sign-up.
  const users = app.findCollectionByNameOrId("users");
  users.createRule = null;
  // Stay signed in for 90 days, so a device left offline for a while keeps syncing.
  users.authToken.duration = 7776000;
  app.save(users);

  const items = new Collection({
    type: "base",
    name: "sync_items",
    listRule: "owner = @request.auth.id",
    viewRule: "owner = @request.auth.id",
    createRule: "@request.auth.id != '' && @request.body.owner = @request.auth.id",
    updateRule: "owner = @request.auth.id && (@request.body.owner:isset = false || @request.body.owner = @request.auth.id)",
    deleteRule: "owner = @request.auth.id",
    fields: [
      { name: "owner", type: "relation", required: true, collectionId: users.id, maxSelect: 1, cascadeDelete: true },
      { name: "app", type: "text", required: true, max: 64 },
      { name: "kind", type: "text", required: true, max: 64 },
      { name: "item_key", type: "text", required: true, max: 200 },
      // Client clock, ms since epoch, of the edit this row holds. "Newest wins" compares this.
      { name: "modified", type: "number", onlyInt: true },
      { name: "deleted", type: "bool" },
      { name: "device", type: "text", max: 200 },
      { name: "data", type: "json", maxSize: 2000000 },
      { name: "blob", type: "file", maxSelect: 1, maxSize: 209715200, protected: true },
      { name: "created", type: "autodate", onCreate: true, onUpdate: false },
      { name: "updated", type: "autodate", onCreate: true, onUpdate: true },
    ],
    indexes: [
      "CREATE UNIQUE INDEX idx_sync_items_key ON sync_items (owner, app, kind, item_key)",
      "CREATE INDEX idx_sync_items_updated ON sync_items (owner, app, updated)",
    ],
  });
  app.save(items);
}, (app) => {
  app.delete(app.findCollectionByNameOrId("sync_items"));
  const users = app.findCollectionByNameOrId("users");
  users.createRule = "";
  users.authToken.duration = 604800;
  app.save(users);
});
