-- Permission / abuse test-suite for STAGING ONLY. Everything runs in one transaction and is rolled back.
-- Prints one line per check: PASS|FAIL <name> [detail]
begin;
create temp table results(n serial, ok boolean, name text, detail text);
grant insert, select on results to anon, authenticated; grant usage on sequence results_n_seq to anon, authenticated;

create or replace function pg_temp.as_user(u uuid) returns void language plpgsql as $$
begin
  perform set_config('role', case when u is null then 'anon' else 'authenticated' end, true);
  perform set_config('request.jwt.claims', case when u is null then '' else json_build_object('sub',u,'role','authenticated')::text end, true);
end $$;
create or replace function pg_temp.as_admin() returns void language plpgsql as $$
begin perform set_config('role','postgres',true); perform set_config('request.jwt.claims','',true); end $$;
create or replace function pg_temp.chk(ok boolean, name text, detail text default '') returns void language sql as $$
  insert into results(ok,name,detail) values (coalesce(ok,false), name, detail) $$;

do $$
declare
  owner uuid := '00000000-0000-0000-0000-00000000000a';
  alice uuid := '00000000-0000-0000-0000-00000000000b';
  bob   uuid := '00000000-0000-0000-0000-00000000000c';
  carol uuid := '00000000-0000-0000-0000-00000000000d';  -- banned
  apost uuid := '10000000-0000-0000-0000-000000000001';  -- Alice's post
  bpost uuid := '10000000-0000-0000-0000-000000000002';  -- Bob's post
  bcom  uuid := '20000000-0000-0000-0000-000000000001';  -- Bob's comment on Alice's post
  n int; t timestamptz; v text; rid uuid; rid2 uuid; ok boolean;
  pfx text := public.lg_media_prefix();
begin
  ------------------------------------------------------------ EDIT POSTS
  perform pg_temp.as_user(alice);
  update lg_posts set body='Alice edited' where id=apost; get diagnostics n=row_count;
  select edited_at into t from lg_posts where id=apost;
  perform pg_temp.chk(n=1 and t is not null, 'edit: author edits own post, edited_at set', 'rows='||n);
  update lg_posts set category='Hematology' where id=apost; get diagnostics n=row_count;
  perform pg_temp.chk(n=1, 'edit: author changes category');
  begin update lg_posts set image_url='https://evil.example/x.png' where id=apost; perform pg_temp.chk(false,'edit: external image blocked');
  exception when others then perform pg_temp.chk(true,'edit: external image blocked'); end;
  begin update lg_posts set user_id=bob where id=apost; perform pg_temp.chk(false,'edit: change owner blocked');
  exception when others then perform pg_temp.chk(true,'edit: change owner blocked'); end;
  begin update lg_posts set body=repeat('x',2001) where id=apost; perform pg_temp.chk(false,'edit: body >2000 chars blocked');
  exception when others then perform pg_temp.chk(true,'edit: body >2000 chars blocked'); end;
  begin update lg_posts set body='', image_url=null where id=apost; perform pg_temp.chk(false,'edit: emptying post blocked');
  exception when others then perform pg_temp.chk(true,'edit: emptying post blocked'); end;

  perform pg_temp.as_user(bob);
  update lg_posts set body='hacked by bob' where id=apost; get diagnostics n=row_count;
  perform pg_temp.chk(n=0, 'edit: other user cannot edit', 'rows='||n);
  update lg_posts set edited_at=null, body=body where id=bpost; get diagnostics n=row_count;
  select edited_at into t from lg_posts where id=bpost;
  perform pg_temp.chk(t is null, 'edit: no-content update keeps edited_at untouched');
  update lg_posts set edited_at='2000-01-01' where id=bpost;
  select edited_at into t from lg_posts where id=bpost;
  perform pg_temp.chk(t is null, 'edit: client cannot fake edited_at', coalesce(t::text,'null'));

  perform pg_temp.as_user(owner);
  begin update lg_posts set body='owner rewrite' where id=apost; perform pg_temp.chk(false,'edit: admin cannot rewrite others content');
  exception when others then perform pg_temp.chk(true,'edit: admin cannot rewrite others content'); end;
  update lg_posts set pinned=true where id=bpost; get diagnostics n=row_count;
  select edited_at into t from lg_posts where id=bpost;
  perform pg_temp.chk(n=1 and t is null, 'edit: admin can still pin, not marked edited');

  perform pg_temp.as_admin(); insert into lg_posts(id,user_id,body) values ('10000000-0000-0000-0000-0000000000cc', carol, 'carol old post');
  perform pg_temp.as_user(carol);
  update lg_posts set body='banned edit' where id='10000000-0000-0000-0000-0000000000cc'; get diagnostics n=row_count;
  perform pg_temp.chk(n=0, 'edit: suspended user cannot edit own post', 'rows='||n);

  ------------------------------------------------------------ REPLIES
  perform pg_temp.as_user(alice);
  insert into lg_comments(post_id,user_id,body,parent_id) values (apost, alice, 'Alice replies to Bob', bcom) returning id into rid;
  perform pg_temp.chk(rid is not null, 'reply: reply to a comment');
  perform pg_temp.as_admin();
  select count(*) into n from lg_notifications where user_id=bob and actor_id=alice and comment_id=rid;
  perform pg_temp.chk(n=1, 'reply: parent author notified with comment link');
  select count(*) into n from lg_notifications where user_id=alice and actor_id=alice;
  perform pg_temp.chk(n=0, 'reply: no self-notification to post author');

  perform pg_temp.as_user(bob);
  insert into lg_comments(post_id,user_id,body,parent_id) values (apost, bob, 'reply to reply', rid) returning id into rid2;
  select parent_id::text into v from lg_comments where id=rid2;
  perform pg_temp.chk(v = bcom::text, 'reply: reply-to-reply flattened to one level', v);
  begin insert into lg_comments(post_id,user_id,body,parent_id) values (bpost, bob, 'cross-post', bcom); perform pg_temp.chk(false,'reply: parent on another post blocked');
  exception when others then perform pg_temp.chk(true,'reply: parent on another post blocked'); end;
  begin insert into lg_comments(post_id,user_id,body,parent_id) values (apost, bob, 'ghost', gen_random_uuid()); perform pg_temp.chk(false,'reply: missing parent blocked');
  exception when others then perform pg_temp.chk(true,'reply: missing parent blocked'); end;
  begin insert into lg_comments(post_id,user_id,body,parent_id) values (apost, alice, 'impersonated', bcom); perform pg_temp.chk(false,'reply: cannot reply as someone else');
  exception when others then perform pg_temp.chk(true,'reply: cannot reply as someone else'); end;
  perform pg_temp.as_user(carol);
  begin insert into lg_comments(post_id,user_id,body,parent_id) values (apost, carol, 'banned reply', bcom); perform pg_temp.chk(false,'reply: suspended user blocked');
  exception when others then perform pg_temp.chk(true,'reply: suspended user blocked'); end;
  perform pg_temp.as_user(alice);
  delete from lg_comments where id=rid2; get diagnostics n=row_count;
  perform pg_temp.chk(n=1, 'reply: post author can delete a reply on own post');
  perform pg_temp.as_user(bob);
  delete from lg_comments where id=rid; get diagnostics n=row_count;
  perform pg_temp.chk(n=0, 'reply: cannot delete someone else''s reply on someone else''s post', 'rows='||n);
  perform pg_temp.as_admin();
  delete from lg_comments where id=bcom;
  select count(*) into n from lg_comments where id=rid;
  perform pg_temp.chk(n=0, 'reply: deleting parent removes its replies');

  ------------------------------------------------------------ SAVES
  perform pg_temp.as_user(alice);
  insert into lg_saves(user_id,post_id) values (alice,bpost);
  perform pg_temp.chk(true, 'save: user saves a post');
  begin insert into lg_saves(user_id,post_id) values (bob,apost); perform pg_temp.chk(false,'save: cannot save on behalf of another user');
  exception when others then perform pg_temp.chk(true,'save: cannot save on behalf of another user'); end;
  begin insert into lg_saves(user_id,post_id) values (alice,bpost); perform pg_temp.chk(false,'save: duplicate rejected');
  exception when others then perform pg_temp.chk(true,'save: duplicate rejected'); end;
  perform pg_temp.as_user(bob);
  select count(*) into n from lg_saves; perform pg_temp.chk(n=0, 'save: other users cannot see my saves', 'visible='||n);
  delete from lg_saves where user_id=alice; get diagnostics n=row_count; perform pg_temp.chk(n=0, 'save: cannot delete others saves');
  perform pg_temp.as_user(owner);
  select count(*) into n from lg_saves; perform pg_temp.chk(n=0, 'save: even admin cannot see others saves (private)');
  perform pg_temp.as_user(null);
  begin select count(*) into n from lg_saves; perform pg_temp.chk(false,'save: anonymous has no access');
  exception when others then perform pg_temp.chk(true,'save: anonymous has no access'); end;
  perform pg_temp.as_user(alice);
  begin update lg_saves set created_at=now() where user_id=alice; perform pg_temp.chk(false,'save: update not permitted');
  exception when others then perform pg_temp.chk(true,'save: update not permitted'); end;
  delete from lg_saves where user_id=alice and post_id=bpost; get diagnostics n=row_count;
  perform pg_temp.chk(n=1, 'save: user unsaves own save');

  ------------------------------------------------------------ REGRESSION (existing protections)
  perform pg_temp.as_user(bob);
  delete from lg_posts where id=apost; get diagnostics n=row_count; perform pg_temp.chk(n=0, 'regression: cannot delete others posts');
  update lg_profiles set bio='x' where id=alice; get diagnostics n=row_count; perform pg_temp.chk(n=0, 'regression: cannot edit others profiles');
  begin update lg_profiles set role='owner' where id=bob; perform pg_temp.chk(false,'regression: cannot self-promote');
  exception when others then perform pg_temp.chk(true,'regression: cannot self-promote'); end;
  begin update lg_profiles set verified=true where id=bob; perform pg_temp.chk(false,'regression: cannot self-verify');
  exception when others then perform pg_temp.chk(true,'regression: cannot self-verify'); end;
  begin insert into lg_notifications(user_id,actor_id,type) values (alice,bob,'follow'); perform pg_temp.chk(false,'regression: cannot forge notifications');
  exception when others then perform pg_temp.chk(true,'regression: cannot forge notifications'); end;
  select count(*) into n from lg_notifications where user_id<>bob; perform pg_temp.chk(n=0,'regression: cannot read others notifications');
  select count(*) into n from lg_reports; perform pg_temp.chk(n=0,'regression: non-admin cannot read reports');
  begin insert into storage.objects(bucket_id,name,owner) values ('lg-media', alice::text||'/x.jpg', bob); perform pg_temp.chk(false,'regression: cannot upload into others folder');
  exception when others then perform pg_temp.chk(true,'regression: cannot upload into others folder'); end;
  insert into lg_posts(user_id,body,created_at) values (bob,'future','2099-01-01') returning created_at into t;
  perform pg_temp.chk(t < now()+interval '1 minute','regression: created_at cannot be spoofed');
  begin update lg_profiles set avatar_url='https://evil.example/a.png' where id=bob; perform pg_temp.chk(false,'regression: external avatar blocked');
  exception when others then perform pg_temp.chk(true,'regression: external avatar blocked'); end;
  begin for i in 1..12 loop insert into lg_posts(user_id,body) values (bob,'spam '||i); end loop; perform pg_temp.chk(false,'regression: post rate limit');
  exception when others then perform pg_temp.chk(true,'regression: post rate limit'); end;
  perform pg_temp.as_user(null);
  begin perform public.lg_admin_users(); perform pg_temp.chk(false,'regression: anonymous cannot call admin RPC');
  exception when others then perform pg_temp.chk(true,'regression: anonymous cannot call admin RPC'); end;
  begin insert into lg_posts(user_id,body) values (bob,'anon'); perform pg_temp.chk(false,'regression: anonymous cannot post');
  exception when others then perform pg_temp.chk(true,'regression: anonymous cannot post'); end;
  begin perform 1 from public.profiles limit 1; perform pg_temp.chk(false,'regression: legacy tables closed');
  exception when others then perform pg_temp.chk(true,'regression: legacy tables closed'); end;
  perform pg_temp.as_admin();
end $$;

select (case when ok then 'PASS ' else 'FAIL ' end)||name||case when detail<>'' then '  ['||detail||']' else '' end from results order by n;
select count(*) filter (where ok)||'/'||count(*)||' checks passed' from results;
rollback;
