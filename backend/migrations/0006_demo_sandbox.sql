-- Familygram migration 0006: demo (App Review) sandbox isolation.
--
-- Problem: demo accounts (DEMO_USERS / `demo:` identities, used by Apple/Google
-- App Review) bypassed the allowlist and landed in the SAME feed as the real
-- family, so a reviewer saw real photos and could comment on real posts.
--
-- Fix: tag every user with is_demo and isolate the two worlds in the Worker —
-- demo users only ever see demo content, the family never sees demo content.
-- This migration also (a) purges the leftover demo accounts + their comments
-- from the live feed, and (b) seeds a small, self-contained demo world so a
-- reviewer has something to look at without touching real data.

-- 1. World tag. Existing real users default to 0.
ALTER TABLE users ADD COLUMN is_demo INTEGER NOT NULL DEFAULT 0;

-- 2. Purge existing demo accounts and everything they touched. Scoped to the
--    `demo:` ory_id prefix, which only demo identities ever use. Runs before
--    the seed inserts below, so the new seed users are unaffected. Dependents
--    are deleted explicitly rather than relying on cascade (FK enforcement is
--    not guaranteed during migrations).
DELETE FROM comments WHERE user_id IN (SELECT id FROM users WHERE ory_id LIKE 'demo:%');
DELETE FROM likes    WHERE user_id IN (SELECT id FROM users WHERE ory_id LIKE 'demo:%');
DELETE FROM post_media WHERE post_id IN (SELECT id FROM posts WHERE user_id IN (SELECT id FROM users WHERE ory_id LIKE 'demo:%'));
DELETE FROM comments   WHERE post_id IN (SELECT id FROM posts WHERE user_id IN (SELECT id FROM users WHERE ory_id LIKE 'demo:%'));
DELETE FROM likes      WHERE post_id IN (SELECT id FROM posts WHERE user_id IN (SELECT id FROM users WHERE ory_id LIKE 'demo:%'));
DELETE FROM posts WHERE user_id IN (SELECT id FROM users WHERE ory_id LIKE 'demo:%');
DELETE FROM device_tokens WHERE user_id IN (SELECT id FROM users WHERE ory_id LIKE 'demo:%');
-- Orphaned "Pending" allowlist invite for a demo email (never redeemed).
DELETE FROM allowlist WHERE used_by IS NULL AND email IN (SELECT email FROM users WHERE ory_id LIKE 'demo:%');
DELETE FROM users WHERE ory_id LIKE 'demo:%';

-- 3. Seed the demo world. Two demo users and three posts with bundled seed
--    media (served by the /media `seed/...` path from backend/src/demo_seed.ts,
--    so no R2 objects and no real photos). INSERT OR IGNORE keeps this safe to
--    re-run. Timestamps are fixed unix seconds in June 2026.
INSERT OR IGNORE INTO users (id, ory_id, email, username, display_name, avatar_key, is_demo, created_at) VALUES
  ('seed_user_aaaaaa', 'demo:seed-a@familygram.app', 'seed-a@familygram.app', 'the_demo_family', 'The Demo Family', NULL, 1, 1781913600),
  ('seed_user_bbbbbb', 'demo:seed-b@familygram.app', 'seed-b@familygram.app', 'demo_grandma',    'Grandma',         NULL, 1, 1781913600);

INSERT OR IGNORE INTO posts (id, user_id, caption, created_at) VALUES
  ('seed_post_0000001', 'seed_user_aaaaaa', 'Sunday morning hike — the whole crew made it to the top! 🥾', 1781913600),
  ('seed_post_0000002', 'seed_user_aaaaaa', 'Beach day. Nobody wanted to leave. 🌊',                        1782086400),
  ('seed_post_0000003', 'seed_user_aaaaaa', 'Grandma''s birthday dinner 🎂',                                1782259200);

INSERT OR IGNORE INTO post_media (post_id, idx, image_key, thumb_key, width, height) VALUES
  ('seed_post_0000001', 0, 'seed/demo/g1.png', 'seed/demo/g1.png', 1000, 1000),
  ('seed_post_0000002', 0, 'seed/demo/g2.png', 'seed/demo/g2.png', 1000, 1000),
  ('seed_post_0000003', 0, 'seed/demo/g3.png', 'seed/demo/g3.png', 1000, 1000);

INSERT OR IGNORE INTO comments (id, post_id, user_id, body, created_at) VALUES
  ('seed_cmt_0000001', 'seed_post_0000001', 'seed_user_bbbbbb', 'Wish I could have joined! Looks beautiful. ❤️', 1781920000),
  ('seed_cmt_0000002', 'seed_post_0000002', 'seed_user_aaaaaa', 'Best day of the summer so far.',                1782090000),
  ('seed_cmt_0000003', 'seed_post_0000003', 'seed_user_bbbbbb', 'Thank you all for the lovely evening!',         1782260000),
  ('seed_cmt_0000004', 'seed_post_0000003', 'seed_user_aaaaaa', 'Love you @demo_grandma 🎉',                     1782270000);

INSERT OR IGNORE INTO likes (post_id, user_id, created_at) VALUES
  ('seed_post_0000001', 'seed_user_bbbbbb', 1781920000),
  ('seed_post_0000002', 'seed_user_bbbbbb', 1782090000),
  ('seed_post_0000003', 'seed_user_aaaaaa', 1782260000),
  ('seed_post_0000003', 'seed_user_bbbbbb', 1782270000);
