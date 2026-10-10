# LabGram 🧪

شبكة اجتماعية عربية لأخصائيي المختبرات والمهنيين الصحيين — صفحة واحدة ثابتة (HTML/JS) تعمل على GitHub Pages مع Supabase.
Arabic social network for laboratory professionals — a single static page on GitHub Pages backed by Supabase.

## Features
- Email/password sign-up, login, logout, password reset and change (Supabase Auth)
- Posts with text and/or an image (client-side compression, 5 MB limit), 10 lab specialties
- Likes (incl. double-tap), comments, share link, follows, "following" feed, suggestions
- Profiles with avatar, colour cover, bio, specialty; search and specialty filters
- Automatic notifications (like / comment / follow), unread badge
- Reports on posts; owner dashboard: stats, verify/suspend/promote users, review reports, pin posts
- Light/dark theme, responsive mobile layout, Arabic RTL

**Not implemented:** editing an existing post, threaded replies, saved posts, English/LTR interface.

## Repository layout
| Path | Purpose |
|---|---|
| `index.html` | The whole app (markup, styles, script) |
| `vendor/supabase-js-2.117.3.js` | Pinned Supabase client, self-hosted, loaded with an SRI hash |
| `schema.sql` | Complete database setup, safe to re-run |
| `tests/` | Headless UI test suite (see `tests/README.md`) |

There is no build step, bundler, type checker or linter: the files are served as-is.

## Configuration
No environment variables or secrets. The Supabase **project URL** and **publishable key** are set at the top of the script in `index.html` (`SUPABASE_URL`, `SUPABASE_KEY`). The publishable key is public by design; all protection comes from Row Level Security. **Never** put a `service_role` / secret key in this repo.

If you move to another Supabase project, also update `lg_media_prefix()` in `schema.sql` (the allowed image URL prefix).

## Database migrations
Run `schema.sql` in **Supabase → SQL Editor** (idempotent). Sections, in order:

1. Tables `lg_profiles`, `lg_posts`, `lg_likes`, `lg_comments`, `lg_follows`, `lg_notifications`
2. Owner role and role guard · 3. Auto-create profile on sign-up · 4. Notification triggers
5. Grants and RLS policies · 6. `lg-media` storage bucket and policies · 7. Make yourself owner (manual)
8. Owner dashboard: `verified`, `banned`, `pinned`, `lg_reports`, admin RPC
9. Pre-launch hardening: server timestamps, image-origin checks, field limits, rate limits, notification de-duplication, case-insensitive usernames
10. *(this project only)* lock down legacy tables and storage buckets from the earlier prototype

## Deployment checklist
1. **Supabase → Authentication → URL Configuration** — set **Site URL** to the live address (e.g. `https://mam87.github.io/LabGram2/`) and add it to **Redirect URLs**. Without this, confirmation and password-reset emails link to `localhost` and fail.
2. **Supabase → Authentication → Providers → Email / Password security** — enable *Leaked password protection*.
3. **Custom SMTP** (Supabase → Authentication → SMTP) before real launch: the built-in sender is rate-limited to a few emails per hour.
4. **GitHub → Settings → Pages** — deploy from branch `main`, root folder.
5. Make your account owner (section 7 of `schema.sql`).

## Security model (verified 2026-10-10)
Tested directly against the database with rolled-back transactions acting as a normal user and as anonymous:
users cannot edit/delete others' posts or profiles, comment or upload as someone else, read others' notifications or any reports, change their own role / verified / banned flags, pin posts, spoof timestamps, use external or other users' image URLs, exceed field limits, or post more than 10 times per 10 minutes. Suspended users cannot post, comment, like, follow or report. Anonymous visitors can only read public content.

Rate limits: 10 posts / 10 min, 30 comments / 10 min, 20 reports / hour (owner exempt).
