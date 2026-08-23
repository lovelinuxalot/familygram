-- Familygram migration 0007: multi-tenancy ("family tenants").
--
-- One deployment now hosts multiple isolated families. Users can belong to
-- several tenants (tenant_members is many-to-many); every post belongs to
-- exactly one tenant. "Post to both families" creates sibling post rows that
-- share the same R2 keys, so each family keeps its own like/comment thread.
--
-- Backfill strategy: the existing family becomes tenant 'default' and the
-- App Review sandbox becomes tenant 'demo', so tenant scoping subsumes the
-- old users.is_demo isolation (the column stays for the demo-token auth path).

-- 1. Tenants + memberships.
CREATE TABLE tenants (
  id         TEXT PRIMARY KEY,                    -- nanoid; 'default'/'demo' are fixed seeds
  name       TEXT NOT NULL,
  created_at INTEGER NOT NULL
);

CREATE TABLE tenant_members (
  tenant_id  TEXT NOT NULL,
  user_id    TEXT NOT NULL,
  role       TEXT NOT NULL DEFAULT 'member',      -- 'admin' | 'member' (stored, not yet enforced)
  created_at INTEGER NOT NULL,
  PRIMARY KEY (tenant_id, user_id),
  FOREIGN KEY (tenant_id) REFERENCES tenants(id),
  FOREIGN KEY (user_id)  REFERENCES users(id)
);
CREATE INDEX idx_tenant_members_user ON tenant_members(user_id);

-- 2. Seed the two tenants BEFORE anything references them (FKs are enforced
--    here), then backfill memberships.
INSERT INTO tenants (id, name, created_at) VALUES
  ('default', 'Family', strftime('%s', 'now')),
  ('demo',    'Demo',   strftime('%s', 'now'));

INSERT INTO tenant_members (tenant_id, user_id, role, created_at)
  SELECT CASE WHEN is_demo = 1 THEN 'demo' ELSE 'default' END,
         id,
         CASE WHEN is_admin = 1 THEN 'admin' ELSE 'member' END,
         created_at
  FROM users;

-- 3. Posts gain a tenant scope.
ALTER TABLE posts ADD COLUMN tenant_id TEXT;
CREATE INDEX idx_posts_tenant_created ON posts(tenant_id, created_at DESC);

UPDATE posts SET tenant_id = (
  SELECT CASE WHEN u.is_demo = 1 THEN 'demo' ELSE 'default' END
  FROM users u WHERE u.id = posts.user_id
);

-- 4. Allowlist becomes tenant-scoped. The old PK was email alone, which made
--    inviting the same email into two tenants impossible — rebuild the table
--    with PK (tenant_id, email).
CREATE TABLE allowlist_new (
  tenant_id   TEXT NOT NULL,
  email       TEXT NOT NULL COLLATE NOCASE,
  added_by    TEXT,                               -- admin user id; NULL if seeded from ADMIN_EMAILS
  added_at    INTEGER NOT NULL,
  used_by     TEXT,                               -- user id once redeemed
  used_at     INTEGER,
  PRIMARY KEY (tenant_id, email),
  FOREIGN KEY (tenant_id) REFERENCES tenants(id),
  FOREIGN KEY (added_by)  REFERENCES users(id),
  FOREIGN KEY (used_by)   REFERENCES users(id)
);

INSERT INTO allowlist_new (tenant_id, email, added_by, added_at, used_by, used_at)
  SELECT 'default', email, added_by, added_at, used_by, used_at FROM allowlist;

DROP INDEX IF EXISTS idx_allowlist_unused;
DROP TABLE allowlist;
ALTER TABLE allowlist_new RENAME TO allowlist;
CREATE INDEX idx_allowlist_unused ON allowlist(used_by) WHERE used_by IS NULL;
