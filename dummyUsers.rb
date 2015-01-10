#create dummy users 

# script/import_scripts/bbpress_2.rb
require File.expand_path(File.dirname(__FILE__) + "/base.rb")

class ImportScripts::DummyUsers < ImportScripts::Base
	def initialize
		super
	end
	
	def execute
		user = {}
		user[:username]="ILikeWhatYouDo"		
		user[:name]="ILikeWhatYouDo"		
		user[:website]="hub.jmonkeyengine.org"
      	user[:email]="contact@jmonkeyengine.org"
      	user[:created_at]="2015-01-09 00:00:00"      	

		new_user = create_user(user, -1);
	end
end

ImportScripts::DummyUsers.new.perform