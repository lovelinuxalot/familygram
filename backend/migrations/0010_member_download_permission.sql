-- 0010: per-family download permission.
--
-- Admins decide, per member per family, who may save photos out of the app.
-- Default 0 — nobody can save unless an admin grants it.
--
-- Scope note: this gates the in-app save/share action, not access to the
-- bytes. Signed /media URLs are bearer capabilities handed to every client
-- that can view the post, so this is a deliberate UI-level control.
ALTER TABLE tenant_members ADD COLUMN can_download INTEGER NOT NULL DEFAULT 0;

-- Family admins keep the ability they already had.
UPDATE tenant_members SET can_download = 1 WHERE role = 'admin';
