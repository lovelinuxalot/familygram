-- Device push tokens for FCM (Android directly; iOS via APNs proxied through FCM).
-- token is unique across the table; reinstalling the app yields a fresh token
-- from FCM, and old tokens are pruned when FCM returns 404 UNREGISTERED on send.

CREATE TABLE device_tokens (
  token        TEXT PRIMARY KEY,
  user_id      TEXT NOT NULL,
  platform     TEXT NOT NULL CHECK (platform IN ('ios', 'android')),
  created_at   INTEGER NOT NULL,
  last_seen_at INTEGER NOT NULL,
  FOREIGN KEY (user_id) REFERENCES users(id)
);

CREATE INDEX idx_device_tokens_user ON device_tokens(user_id);
