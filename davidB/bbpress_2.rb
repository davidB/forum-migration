# script/import_scripts/bbpress_2.rb
require File.expand_path(File.dirname(__FILE__) + "/base.rb")

BB_PRESS_DB = "bbpress"

require 'mysql2'
require 'upsert'

class ImportScripts::Bbpress < ImportScripts::Base

  def initialize
    super

    @client = Mysql2::Client.new(
      host: "127.0.0.1",
      port: 3306,
      username: "bbpressUser",
      password: "bbpressPwd",
      database: BB_PRESS_DB
    )
    @test = false
    @dummyUsers = []
    @redirections = []
    @redirections_collect = false
  end

  def execute
    ##create_admin({:email => "me@gmail.com", :username => "myAdmin"})
    @dummyUsers = create_dummyUsers(60)
    import_users
    store_users_mapping
    import_categories
    import_posts
    store_posts_mapping
    #import_likes
    import_subscriptions
    # using rewrite on http front end seems to work better than creating Permalink
    #  location ~ ^/forum/ {
    #    rewrite ^/forum/topic/([^/]*)/.*$ /t/$1/ permanent;
    #    return 403;
    #  }
    #generate_redirect
  end


  def create_dummyUsers(nb)
    puts '', "create #{nb} dummy users (for Likes)"
    users = nb.times.map{ |it|
      suffix = (it + 1).to_s.rjust(3, '0')
      # email should be unique
      user = {
        :username => "ILikeWhatYouDo_#{suffix}",
        :name => "ILikeWhatYouDo_#{suffix}",
        :website => "hub.jmonkeyengine.org",
        :email => "contact+#{suffix}@jmonkeyengine.org",
        :created_at => "2015-01-09 00:00:00",
        :id => -1 * (it + 1),
        :password => SecureRandom.uuid,
      }
    }
    create_users(users) do |u|
      ActiveSupport::HashWithIndifferentAccess.new(u)
    end
    nb.times.map{|it| User.find(user_id_from_imported_user_id(-1 * (it + 1)))}

  end


  def set_likes(post, nb)
    [nb, @dummyUsers.length].min.times.each{ |it|
      #user = User.find(-1 * it) # the dummyUsers
      user = @dummyUsers[it]
      suppress(PostAction::AlreadyActed) do
        PostAction.act(user, post, PostActionType.types[:like])
      end
    }
  end


  def import_users
    puts '', "creating users"
    batch_size = @test ? 100 : 1000

    batches(batch_size) do |offset|
      results = @client.query("
        select id,
          user_login username,
          display_name name,
          user_url website,
          user_email email,
          user_registered created_at
        from wp_users
        order by id
        limit #{batch_size} offset #{offset}", cache_rows: false)

      break if results.size < 1
      create_users(results) do |u|
        ActiveSupport::HashWithIndifferentAccess.new(u)
      end
      break if @test # run only once
    end
  end


  def store_users_mapping
    store_mapping(@existing_users, "mig_users")
  end


  def import_categories
    create_categories(@client.query("select id, post_name from wp_posts where post_type = 'forum' and post_name != ''")) do |c|
      {id: c['id'], name: c['post_name']}
    end
  end


  def import_posts
    puts '', "creating topics and posts"

    total_count = @client.query("
      select count(*) count
        from wp_posts
       where post_status <> 'spam'
         and post_type in ('topic', 'reply')").first['count']

    batch_size = @test ? 100 : 1000

    batches(batch_size) do |offset|
      # where post_status <> 'spam'
      results = @client.query("
        select p.id,
          p.post_author,
          p.post_date,
          p.post_content,
          p.post_title,
          p.post_type,
          p.post_name,
          p.post_parent,
          CASE WHEN  m.meta_value IS NOT NULL
		       THEN GREATEST( CONVERT(m.meta_value,SIGNED INTEGER),0)
		       ELSE 0
			 END AS thumbs
        from wp_posts p LEFT OUTER JOIN wp_postmeta m ON m.post_id = p.ID and m.meta_key ='bbpress_post_ratings_rating'
        where post_type in ('topic', 'reply')
        order by id
        limit #{batch_size} offset #{offset}", cache_rows: false)

      break if results.size < 1

      create_posts(results, total: total_count, offset: offset) do |post|
        skip = false
        mapped = {}

        mapped[:id] = post["id"]
        mapped[:user_id] = user_id_from_imported_user_id(post["post_author"]) || find_user_by_import_id(post["post_author"]).try(:id) || -1
        mapped[:raw] = post["post_content"]
        #puts "raw #{@bbcode_to_md}: #{post["post_title"]}/pc/ #{post["post_content"]} /mr/ #{mapped[:raw]}\n"
        mapped[:created_at] = post["post_date"]
        mapped[:custom_fields] = {import_id: post["id"]}

        if post["post_type"] == "topic"
          mapped[:category] = category_from_imported_category_id(post["post_parent"]).try(:name)
          mapped[:title] = CGI.unescapeHTML post["post_title"]
        else
          parent = topic_lookup_from_imported_post_id(post["post_parent"])
          if parent
            mapped[:topic_id] = parent[:topic_id]
            mapped[:reply_to_post_number] = parent[:post_number] if parent[:post_number] > 1
          else
            puts "Skipping #{post["id"]}: #{post["post_content"][0..40]}"
            skip = true
          end
        end

        skip ? nil : mapped
      end
      break if @test # run only once
    end
  end

  def created_post(post, map)
	  if (map['thumbs'] || 0 ) > 0
      set_likes(post, map['thumbs'])
    end
    #redirect_post(post.id, map)
  end


  def store_posts_mapping
    store_mapping(@existing_posts, "mig_posts")
  end


  def import_likes
    puts '', "creating likes (from dummyUsers)"

    total = @client.query("
      select count(*) count
      from wp_postmeta m
      where m.meta_key ='bbpress_post_ratings_rating'
        and m.meta_value > 0
      ").first['count']
    skipped = 0
    created = 0

    batch_size = @test ? 100 : 1000

    batches(batch_size) do |offset|
      # where post_status <> 'spam'
      results = @client.query("
        select
          m.post_id post_id,
          CONVERT(m.meta_value,SIGNED INTEGER) thumbs
        from wp_postmeta m
        where m.meta_key ='bbpress_post_ratings_rating'
          and m.meta_value > 0
        order by post_id
        limit #{batch_size} offset #{offset}", cache_rows: false)

      break if results.size < 1
      results.each do |r|
        post_id = post_id_from_imported_post_id(r['post_id'])
        nb_likes = r['thumbs']
        if post_id
          set_likes(Post.find(post_id), nb_likes)
          created += 1
        else
          skipped += 1
        end
        print_status created + (offset || 0), total, skipped
      end
      break if @test # run only once
    end
  end

  def import_subscriptions
    puts '', "creating subscriptions"

    total = @client.query("
      select count(*) count
      from wp_bp_notifications
      where component_name = 'messages'").first['count']
    skipped = 0
    created = 0

    batch_size = @test ? 10 : 1000

    batches(batch_size) do |offset|
      # where post_status <> 'spam'
      results = @client.query("
        select
          id,
          user_id,
          item_id as topic_id
        from wp_bp_notifications
        where component_name = 'messages'
        order by id
        limit #{batch_size} offset #{offset}", cache_rows: false)

      break if results.size < 1
      results.each do |r|
        user_id = user_id_from_imported_user_id(r['user_id'])
        topic = topic_lookup_from_imported_post_id(r['topic_id'])
        if topic and user_id
          set_watching(user_id, topic[:topic_id])
          created += 1
        else
          skipped += 1
        end
        print_status created, total, skipped
      end
      break if @test # run only once
    end
  end


  def set_watching(user_id, topic_id)
    #from TopicNotifier(topic).change_level(user_id, :watching)
    attrs = {notification_level: levels[:watching]}
    TopicUser.change(user_id, topic_id, attrs)
  end

  def generate_redirect
    puts '', "generate redirect for topics and posts"
    created = 0
    skipped = 0
    failure = 0
    total = @client.query("
      select count(*) count
        from wp_posts
       where post_status <> 'spam'
         and post_type in ('topic', 'reply')").first['count']

    batch_size = @test ? 1000 : 1000

    batches(batch_size) do |offset|
      # where post_status <> 'spam'
      results = @client.query("
        select id,
          post_type,
          post_name
        from wp_posts
        where post_type in ('topic', 'reply')
        order by id
        limit #{batch_size} offset #{offset}", cache_rows: false)

      break if results.size < 1
      results.each do |r|
        post_id = post_id_from_imported_post_id(r['id'])
        if post_id
          case redirect_post(post_id, r)
          when :done
            created += 1
          when :skipped
            skipped += 1
          else
            failure += 1
          end
        else
          # no post_id
          skipped += 1
        end
      end
      print_status created, total, skipped, failure
      break if @test # run only once
    end
    if @redirections_collect
      File.open("/tmp/redirection_#{BB_PRESS_DB}.rb", 'w') { |file|
        @redirections.each { |l|
          file.puts(l)
        }
      }
    end
  end


  def redirect_post(post_id, map)
    #puts "redirect_post : #{map['id']} // #{map['post_name']} // #{map[:post_name]}"
    if map['post_type'] == 'topic'
      # remove ending '/' : redirection ending by '/' doesn't works with discourse
      # remove starting '/' : automaticly done by Permalink.create but not by Permalink.where
      redirect("forum/topic/#{map['post_name']}", post_id)
      redirect("forum/topic/#{map['post_name']}/#post-#{map['id']}", post_id)
    else
      if map['post_name'] =~ /^reply-to-(.*)?$/
        topic_name = $1
        reply_nb = 1
        if map['post_name'] =~ /^reply-to-(.*)(-(\d+))$/
          topic_name = $1
          reply_nb = $3.to_i
        end
        page = ((reply_nb+1) / 15) + 1
        if page < 2
          redirect("forum/topic/#{topic_name}/page/#{page}/#post-#{map['id']}", post_id)
        else
          redirect("forum/topic/#{topic_name}/#post-#{map['id']}", post_id)
        end
      else
        :failed
      end
    end
  end


  # see https://meta.discourse.org/t/redirecting-old-forum-urls-to-new-discourse-urls/20930
  def redirect(oldpath, post_id)
    if @redirections_collect
      # Collect redirections (eg: for later store in file)
      cmd = "unless Permalink.where(url:  \"#{oldpath}\", post_id: #{post_id}).exists? ; Permalink.create(url: \"#{oldpath}\", post_id: #{post_id}) ; end"
      @redirections.push(cmd)
      :done
    else
      # Apply Redirection
      if Permalink.where(url: oldpath, post_id: post_id).exists?
        :skipped
      else
        Permalink.create(url: oldpath, post_id: post_id)
        :done
      end
    end
  end


  def store_mapping(kv, tableName)
    puts '', "store mapping in #{tableName}"

    @client.query("CREATE TABLE IF NOT EXISTS #{tableName}
      (
       ID bigint NOT NULL,
       discourse_ID bigint NOT NULL,
       CONSTRAINT pk_#{tableName}ID PRIMARY KEY (ID),
       CONSTRAINT ext_#{tableName}ID UNIQUE INDEX (discourse_ID)
       )
    ;")
    Upsert.batch(@client, tableName) do |upsert|
      kv.each { |k, v|
        upsert.row({:ID => k}, :discourse_ID => v)
      }
    end
  end

end

ImportScripts::Bbpress.new.perform
