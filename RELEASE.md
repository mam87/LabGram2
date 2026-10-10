# LabGram public beta — release checklist

Status legend: ✅ verified (test actually run) · ⚠️ needs owner action / not yet verified · ❌ not done

## 1. Authentication and password recovery
- ✅ Sign-up, login, logout, password change — UI flows (tests/audit.py) and database triggers (staging).
- ✅ Case-insensitive unique usernames; 8+ char passwords with letters and digits (app-side).
- ⚠️ **Password reset end-to-end** — Supabase Auth settings were saved twice on 2026-10-10 (11:56 and 12:04 UTC, seen in auth logs), but no reset has been run since. Owner is testing on the live site. Unresolved until confirmed.
- ⚠️ Supabase Auth: Minimum password length 8 + "letters and digits" should match the app (set in dashboard; not verifiable from here).
- ⚠️ Leaked-password protection requires the Pro plan (Free plan rejected it).

## 2. Email delivery and SMTP
- ⚠️ Using Supabase's built-in sender: limited to a few emails per hour and not meant for production. Configure custom SMTP (Authentication → SMTP) before inviting users at scale.
- ⚠️ Delivery has not been tested by us (no mailbox access); confirm by receiving a reset and a sign-up confirmation email.

## 3. Database security
- ✅ 46/46 permission and abuse checks on staging (staging/test_permissions.sql), including a mutation test proving the suite catches weakened rules.
- ✅ Staging verified structurally identical to production (161/164 objects byte-identical; 3 differ only in code comments).
- ✅ Legacy prototype tables and buckets closed to the API.
- ✅ Production verification limited to read-only catalog checks — no penetration tests on production.

## 4. Post and comment permissions
- ✅ Only authors edit post content; admins can pin/delete but never rewrite; "edited" marker cannot be faked.
- ✅ Replies: one level, same post only, cannot impersonate; author/post-owner/admin delete; deleting a comment removes its replies.
- ✅ Saved posts are private (not even admins can read them); anonymous has no access.
- ✅ Suspended users cannot post, edit, comment, reply, like, follow or report.
- ✅ Rate limits: 10 posts / 10 min, 30 comments / 10 min, 20 reports / hour.

## 5. Image upload restrictions
- ✅ Bucket `lg-media`: 5 MB limit; JPEG/PNG/WebP/GIF only (no SVG); users write only to their own folder.
- ✅ Posts and avatars may only reference images in the uploader's own folder (external URLs rejected).
- ⚠️ No automated scanning for patient identifiers in images — relies on the privacy reminder and user reports.

## 6. Reporting and moderation
- ✅ Report reasons incl. "contains patient-identifying data"; owner dashboard to review, dismiss or delete.
- ✅ Verify, suspend, promote users; pin posts.
- ⚠️ Single owner account; consider a second trusted moderator before public launch.

## 7. Mobile usability
- ✅ No horizontal overflow at 375/390 px on all tested screens; tap targets ≥ 36 px (menus ≥ 44 px).
- ✅ Post actions consolidated in an accessible "⋯" menu (keyboard, Escape, focus).
- ✅ Colour contrast: the 5 elements measured below WCAG AA now pass (white on button/active-chip gradient ≥ 5.36:1, chip text 5.82:1 light / 6.95:1 dark, like count and unread badge 6.04:1). Computed styles checked in Chromium in light and dark mode.
- ⚠️ Not tested on real devices or with a screen reader.

## 8. Backup and recovery
- Project is on the **Supabase Free plan: no managed or downloadable backups.**
- Before every migration: run `migrations/20261010_backup.sql` (in-database snapshot schema, hidden from the API; prints live vs backup row counts — they must match).
- ⚠️ Off-site backup: download a `pg_dump` from a computer (Supabase → Settings → Database → connection string) or upgrade to Pro for daily backups. The in-database snapshot does not protect against loss of the project.
- Uploaded images live in Storage and are not touched by migrations.

## 9. Deployment (approved and run 2026-10-10)
Order matters — the new frontend reads columns that only exist after the migration.
1. Run `migrations/20261010_backup.sql`; confirm counts match.
2. Apply `migrations/20261010_beta_features.up.sql` (additive only; current live site keeps working).
3. Re-run `staging/fingerprint.sql` on production; compare with staging (expect identical apart from comments).
4. Merge `beta/features` → `main` (GitHub Pages redeploys in ~1–2 minutes).
5. Smoke test on the live site: login, feed, open a post, reply, edit own post, save/unsave, admin dashboard.

## 10. Rollback
- **Frontend (non-destructive, preferred):** revert `main` to the previous commit (`0dfd78d`). The old frontend works with the new schema because the migration only adds optional columns/tables.
- **Database (destructive for new-feature data):** `migrations/20261010_beta_features.down.sql` restores the exact previous schema (proven on staging). It drops saved-post lists, reply links (replies become normal comments) and "edited" markers. Take a backup first; requires owner approval.
- **Data restore:** `insert … select … from lg_backup_20261010.<table> on conflict do nothing` (see backup script).

## Known gaps (not in this release)
- English / LTR interface (the one expected failure in tests/audit.py).
- Figma proposals awaiting approval (need new database columns): structured case fields, professional title/workplace, post types.
