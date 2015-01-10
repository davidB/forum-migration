CREATE TABLE IF NOT EXISTS mig_users
  (
   ID bigint NOT NULL,
   discourse_ID bigint NOT NULL,
   CONSTRAINT pk_mig_usersID PRIMARY KEY (ID),
   CONSTRAINT ext_mig_usersID UNIQUE INDEX (discourse_ID)
   )
;

CREATE TABLE IF NOT EXISTS mig_posts
  (
   ID bigint NOT NULL,
   discourse_ID bigint NOT NULL,
   CONSTRAINT pk_mig_postsID PRIMARY KEY (ID),
   CONSTRAINT ext_mig_postsID UNIQUE INDEX (discourse_ID)
   )
;
