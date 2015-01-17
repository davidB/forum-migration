
This is my notes about migration from bbpress to discourse.
We used a customized script :
* to includes likes (done by fake users)
* generate files with mapping bbpress id / discourse id, to be able to update some data after main migration
* generate Redirection for Discourse (alternative: to configure an url rewrite rule)
* convert subscriptions into watching (we didn't run it at end)

# SETUP Local Mysql DB to store bbpress data

## Install Mysql and start it

I installed mysql/mariadb on my desktop.
```
# Desktop Archlinux as root (see https://wiki.archlinux.org/index.php/MySQL)
pacman -S mariadb
mysql_secure_installation
systemctl start mysqld
```

To avoid the issue "Cannot load from mysql.proc. The table is probably corrupted", that can be raise by mysql2 + upsert

```
mysql_upgrade -uroot -p
```

## Setup bbpress database

I create a working copy of the bbpress DB to migrate:

```
mysql -u root -p << __EOF__
CREATE USER 'bbpressUser'@'localhost' IDENTIFIED BY 'bbpressPwd';
DROP DATABASE IF EXISTS bbpress;
CREATE DATABASE bbpress;
GRANT ALL PRIVILEGES ON bbpress.* TO 'bbpressUser'@'localhost' WITH GRANT OPTION;
__EOF__

mysql -u bbpressUser --password=bbpressPwd bbpress < latestdump.sql
mysql -u bbpressUser --password=bbpressPwd bbpress < purge.sql
```

# SETUP Local Discourse

## Install docker and start it

see you system doc, for archlinux:

```
# Desktop Archlinux as root
pacman -S docker
systemctl start docker
```

## Install discourse-docker

Install discourse on docker (see https://github.com/discourse/discourse/blob/master/docs/INSTALL-digital-ocean.md )
but don't call "./launcher bootstrap app" before reading the following note to avoid sending email to users during test/migration.

I added discourse.localhost in my /etc/host
```
# Desktop Archlinux as root
echo "127.0.0.1 discourse.localhost" >> /etc/hosts
echo "127.0.0.1 smtp.discourse.localhost" >> /etc/hosts
```

I configured smtp with a invalid server to not send email.
I will configure it right to activate admin, temporary later to avoid send email during migration test
As I use my gmail address, I'll use smtp server from google for initial activation of admin account.
```
# /var/discourse_docker/container/app.yaml:

  DISCOURSE_DEVELOPER_EMAILS: 'me@gmail.com'
  ##
  ## TODO: The domain name this Discourse instance will respond to
  DISCOURSE_HOSTNAME: 'discourse.localhost'

  ##
  ## TODO: The mailserver this Discourse instance will use
  DISCOURSE_SMTP_ADDRESS: smtp.discourse.localhost  # (mandatory)
  #DISCOURSE_SMTP_PORT: 25                        # (optional)
  DISCOURSE_SMTP_PORT: 587                        # (optional)
  DISCOURSE_SMTP_USER_NAME: me@gmail.com      # (optional)
  DISCOURSE_SMTP_PASSWORD: *********             # (optional)
```

to prepare the migration, forward access of container port 3306 to host port 3306 so script in container can access my local mysql (on host):
I replaced a line around 487 in /var/discourse_docker/launcher (to allow docker to access local mysql):

    exec ssh -o StrictHostKeyChecking=no root@${split[0]} -p ${split[1]}

by

    exec ssh -R 3306:localhost:3306 -o StrictHostKeyChecking=no root@${split[0]} -p ${split[1]}

If you boostrap it before made the change, you can call "./launcher rebuild app" (will take few minutes ~10)
```
cd /var/discourse_docker
./launcher boostrap app
./launcher start app
```

Try access `open http://discourse.localhost/`
register an account with the your developer email (eg: me@gmail.com) You should not receive activation email. (see Commands below for an alternative way to activate account, without smtp server).

Open a shell into container
```
./launcher ssh app
cd /var/www/discourse
```


Temporary enable smtp (you should be root inside the container)

```
# set the right smtp conf
sed -i 's/smtp.discourse.localhost/smtp.gmail.com/' /var/www/discourse/config/discourse.conf
sv restart unicorn  # restart discourse service inside the container
```


re-open http://discourse.localhost/, try to log-in and request resend of activation
you should receive it
log-in, open admin panel > email, send a test email
you should receive it

```
# set the wrong smtp conf
sed -i 's/smtp.gmail.com/smtp.discourse.localhost/' /var/www/discourse/config/discourse.conf
sv restart unicorn  # restart discourse service inside the container
```

Re-open http://discourse.localhost/, log-in, open admin panel > email, send a test email
you should NOT receive it, an error notification should nbe display on admin panel

## Setup to speed migration

By default discourse download images on local, including remote image links, gavatar,... This step could take lot of time after the end of the migration script.
I suggest you to **disable download remote images to local** for migration:
[Admin/Settings/Files](http://discourse.localhost/admin/site_settings/category/files). After the migration, you can re-enable it.

## Install stuff for migration from mysql

Installed stuff is available until you detroy / rebuild the container

```
# Container as root
# install mysql2 ruby gem for migration script (take time)
apt-get install libmysqlclient-dev
# bundle exec gem install mysql2
cd /var/www/discourse
echo "gem 'mysql2'" >> Gemfile
echo "gem 'upsert'" >> Gemfile
bundle install --no-deployment
```

## Install stuff to convert post_content

```
# Container as root
cd /var/www/discourse/tmp
git clone https://github.com/nlalonde/ruby-bbcode-to-md.git
cd ruby-bbcode-to-md
gem build ruby-bbcode-to-md.gemspec
gem install ruby-bbcode-to-md-0.0.13.gem
```

## Run ruby scripts

Create the script as script/import_scripts/bbpress_2.rb
by default (security) I commented import_XXX instructions

To copy files (**bbpress_2.rb + base.rb**) from my desktop (host) to container :
see stackoverflow :[copying-files-from-host-to-docker-container](http://stackoverflow.com/questions/22907231/copying-files-from-host-to-docker-container)

```
# desktop as root
docker ps # to find the "CONTAINER ID"
cp *.rb /var/lib/docker/devicemapper/mnt/_CONTAINER_ID_follow_by_some_ hex/rootfs/var/www/discourse/script/import_scripts
```
And I use up arrow (last command shell history) to update file.

```
# Container
su discourse
cd /var/www/discourse

#RAILS_ENV=production bundle exec ruby script/import_scripts/bbpress_2.rb
RAILS_ENV=production ruby script/import_scripts/bbpress_2.rb bbcode-to-md
```

If you change the method redirect(oldpath, post_id) to collect rules instead of making redirection, then you have to import redirection via script (generated by bbpress_2.rb or other):
```
# Container
su discourse
cd /var/www/discourse

RAILS_ENV=production rails c </tmp/bbpress_redirection.rb
```

## Post import

When happy with the import's result:

1. backup in discourse
2. check that backup is not in the container, but on the host hdd (available when container is stopped)
3. restore the backup into your target (production) discourse instance OR into the rebuilded discourse container to have a clean install.
4. personnalize, customize settings
  * visual: colors, logo, css, ...
  * badges, categories, groups, ...
  * ...
5. backup again to keep customization

## Commands

*  to reset your database
  Grant superuser rold to discourse account in postgres to avoid issues like :

  * Peer authentication failed for user "discourse"
  * permission denied to create extension hstore (or pg_trgm )

  ```
  # Container as root
  su postgres
  psql -c 'ALTER ROLE discourse SUPERUSER'
  exit
  ```

  Reset the db with service stopped
  ```
  # Container as root
  sv stop unicorn  # stop discourse service inside the container
  su discourse
  cd /var/www/discourse
  RAILS_ENV=production bundle exec rake db:drop db:create db:migrate
  exit
  sv start unicorn
  ```

* to activate an account without "sending activation email" (or using smtp server)
  ```
  # Container as root
  cd /var/www/discourse
  su discourse
  RAILS_ENV=production bundle exec rails c

  irb> u = User.find_by_username_or_email('myemailaddress@me.com')
  irb> u.password = "azertyuiop"
  irb> u.activate
  irb> u.admin = true
  irb> u.save
  ```

  Wait few minutes, try to log-in on web.
  If discourse say "blabla activation email", wait, reload page, retry (you can do  som ` u.activate`)

* Rewrite rules for nginx, to redirect your old/previous url
  In the container, try rules by editing `/etc/nginx/conf.d/discourse.conf` and restart nginx via 'sv restart nginx'.
  But to keep rules over a container rebuild, you should create a template in `discourse_docker/templates/web.rewriteurl.template.yml` (like the file in this project)
  ```
  params:

  run:
    - replace:
       filename: "/etc/nginx/conf.d/discourse.conf"
       from: /server.+{/
       to: |
         server {
           location /forum/ {
             rewrite ^/forum/topic/([^/]*)/.*$ /t/$1/ permanent;
             rewrite ^/forum/.*$ / permanent;
             return 403;
           }
           rewrite ^/wiki/(.*)$ http://wiki.jmonkeyengine.org/$1 permanent;
  ```
  Then add this file in the list of template in `discourse_docker/containers/app.yml`
  ```
  templates:
    - "templates/postgres.template.yml"
    - "templates/redis.template.yml"
    - "templates/web.template.yml"
    - "templates/sshd.template.yml"
    - "templates/web.ratelimited.template.yml"
    - "templates/web.rewriteurl.template.yml"
  ```
  Now you can rebuild
  ```
  cd discourse_docker
  ./launcher rebuild app
  ```

# Links

* https://meta.discourse.org/t/how-to-run-an-import-script-in-docker/21599/8
* https://meta.discourse.org/t/paid-need-a-vanilla-2-import-tool/14852/23
* https://meta.discourse.org/t/re-importing-data-after-migration/22058/2
* https://meta.discourse.org/t/advanced-troubleshooting-with-docker/15927
* https://meta.discourse.org/t/redirecting-old-forum-urls-to-new-discourse-urls/20930
* https://meta.discourse.org/t/advanced-troubleshooting-with-docker/15927
* https://meta.discourse.org/t/activate-user-on-a-non-configurated-email-server/9494
* https://meta.discourse.org/t/programmatically-adjusting-color-variables-with-sass/18332 to choose your colors
