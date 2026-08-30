-- Familygram migration 0008: remember which family each device was last
-- browsing.
--
-- Why: a post cross-posted to two families creates sibling post rows (0007),
-- and a recipient who belongs to both families gets exactly one push. Before
-- this column the fan-out picked whichever sibling row D1 happened to return
-- first, so tapping the notification could yank the user into the *other*
-- family. Recording the active tenant at device-registration time lets the
-- fan-out prefer the family that device was actually looking at.
--
-- Nullable: pre-existing rows (and devices registered before /me resolves a
-- tenant) have no recorded preference, and the fan-out falls back to a
-- deterministic pick.

ALTER TABLE device_tokens ADD COLUMN last_tenant_id TEXT REFERENCES tenants(id);
