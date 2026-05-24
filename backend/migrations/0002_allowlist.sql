-- Replace the invite-code mechanism with an admin-curated email allowlist.
-- Existing users keep their accounts; their admin status is granted at request
-- time if their email matches ADMIN_EMAILS (see Worker requireUser middleware).

DROP INDEX IF EXISTS idx_invites_unused;
DROP TABLE IF EXISTS invites;

ALTER TABLE users ADD COLUMN is_admin INTEGER NOT NULL DEFAULT 0;

CREATE TABLE allowlist (
  email       TEXT PRIMARY KEY COLLATE NOCASE,
  added_by    TEXT,                              -- admin user id; NULL if seeded from ADMIN_EMAILS
  added_at    INTEGER NOT NULL,
  used_by     TEXT,                              -- user id once redeemed
  used_at     INTEGER,
  FOREIGN KEY (added_by) REFERENCES users(id),
  FOREIGN KEY (used_by)  REFERENCES users(id)
);

CREATE INDEX idx_allowlist_unused ON allowlist(used_by) WHERE used_by IS NULL;
