#!/usr/bin/env bash
# Proves the beta migration is reversible on staging:
#   fingerprint(before) == fingerprint(after up + down), data kept, re-apply == first apply.
set -euo pipefail
cd "$(dirname "$0")/.."
export PATH=/usr/lib/postgresql/16/bin:$PATH
P="psql -h /tmp -p 54329 -U postgres -d labgram_staging -v ON_ERROR_STOP=1 -q"
fp() { $P -Atf staging/fingerprint.sql | md5sum | cut -c1-12; }
counts() { $P -Atc "select (select count(*) from lg_profiles)||'/'||(select count(*) from lg_posts)||'/'||(select count(*) from lg_comments)||'/'||(select count(*) from lg_likes)||'/'||(select count(*) from lg_follows)||'/'||(select count(*) from lg_notifications)"; }

staging/reset.sh staging/seed.sql >/dev/null 2>&1
A=$(fp); CA=$(counts); echo "before:        fingerprint=$A  rows(profiles/posts/comments/likes/follows/notifs)=$CA"
$P -f migrations/20261010_backup.sql >/dev/null
$P -f migrations/20261010_beta_features.up.sql >/dev/null
B=$(fp); echo "after up:      fingerprint=$B  rows=$(counts)"
# add a reply + an edit + a save so rollback has new-feature data to deal with
$P -c "insert into lg_comments(post_id,user_id,body,parent_id) values ('10000000-0000-0000-0000-000000000001','00000000-0000-0000-0000-00000000000b','reply','20000000-0000-0000-0000-000000000001');
       insert into lg_saves(user_id,post_id) values ('00000000-0000-0000-0000-00000000000b','10000000-0000-0000-0000-000000000002');" >/dev/null
CR=$(counts); echo "with new data: rows=$CR"
$P -f migrations/20261010_beta_features.down.sql >/dev/null
C=$(fp); CC=$(counts); echo "after down:    fingerprint=$C  rows=$CC"
$P -f migrations/20261010_beta_features.up.sql >/dev/null
D=$(fp); echo "re-applied:    fingerprint=$D"
# backup schema must not be reachable by API roles
BK=$($P -Atc "select has_schema_privilege('anon','lg_backup_20261010','USAGE')||'/'||has_schema_privilege('authenticated','lg_backup_20261010','USAGE')")
echo "backup schema usage for anon/authenticated: $BK"
[ "$A" = "$C" ] && echo "PASS structure restored exactly by rollback" || echo "FAIL rollback structure differs"
[ "$CR" = "$CC" ] && echo "PASS rollback kept all rows (reply kept as comment)" || echo "FAIL rows changed by rollback ($CR -> $CC)"
[ "$B" = "$D" ] && echo "PASS re-apply identical to first apply" || echo "FAIL re-apply differs"
[ "$BK" = "false/false" ] && echo "PASS backup schema hidden from API" || echo "FAIL backup schema visible"
