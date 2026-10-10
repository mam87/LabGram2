-- Synthetic staging data (no real users). Runs as superuser (auth.uid() is null).
insert into auth.users (id, email, raw_user_meta_data, email_confirmed_at) values
 ('00000000-0000-0000-0000-00000000000a','owner@test.local','{"username":"owner1","display_name":"Owner"}',now()),
 ('00000000-0000-0000-0000-00000000000b','alice@test.local','{"username":"alice","display_name":"Alice"}',now()),
 ('00000000-0000-0000-0000-00000000000c','bob@test.local','{"username":"bob","display_name":"Bob"}',now()),
 ('00000000-0000-0000-0000-00000000000d','carol@test.local','{"username":"carol","display_name":"Carol"}',now());
update public.lg_profiles set role='owner' where username='owner1';
update public.lg_profiles set banned=true where username='carol';
insert into public.lg_posts (id, user_id, body, category) values
 ('10000000-0000-0000-0000-000000000001','00000000-0000-0000-0000-00000000000b','Alice post about Gram stain','Microbiology'),
 ('10000000-0000-0000-0000-000000000002','00000000-0000-0000-0000-00000000000c','Bob post about IQC','Laboratory Quality');
insert into public.lg_comments (id, post_id, user_id, body) values
 ('20000000-0000-0000-0000-000000000001','10000000-0000-0000-0000-000000000001','00000000-0000-0000-0000-00000000000c','Bob comments on Alice');
insert into public.lg_likes (post_id, user_id) values ('10000000-0000-0000-0000-000000000001','00000000-0000-0000-0000-00000000000c');
insert into public.lg_follows (follower_id, following_id) values ('00000000-0000-0000-0000-00000000000c','00000000-0000-0000-0000-00000000000b');
