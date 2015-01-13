
#delete Silent users that never had activity (spam bots)
delete from wp_users where ID in (select * from(select u.ID from wp_users u where u.ID not in(select post_author from wp_posts) and u.ID not in (select u2.ID from wp_bp_activity a, wp_users u2 where a.type='last_activity' and u2.ID=a.user_id)) spamBots);

#delete users that are true spammers (only post spams)
delete from wp_users where ID in (select * from (select id from (select u.ID id, count(p.id) spams, (select count(*) from wp_posts p2 where p2.post_author = u.ID ) posts from wp_users u, wp_posts p where p.post_author = u.ID  and p.post_status='spam' group by u.user_login having spams = posts) spammers) spammerss);

#delete orphan user meta data
delete from wp_usermeta where user_id not in (select ID from wp_users);

#delete all trash
delete from wp_posts where post_status='trash';

#delete all hidden
delete from wp_posts where post_status='hidden';

#delete all drafts (IDK if we shoudl so it's commented for now)
#delete from from wp_posts where post_status='draft';

#delete all spam
delete from wp_posts where post_status='spam' ;

#delete orphan post meta data
delete from wp_postmeta where post_id not in (select ID from wp_posts);

#delete posts with empty content
delete from wp_posts where post_type in ('topic', 'reply') and (post_content = '' OR post_content IS NULL);

#select users whose last activity was before 01/01/2013 (around 3K users) Shall we delete them?
#select u.user_login, a.date_recorded from wp_bp_activity a, wp_users u where a.type='last_activity' and u.ID=a.user_id and a.date_recorded<'2012-01-01' order by a.date_recorded desc;


commit;
