namespace :imports do
  desc "Import Slack standard export from PATH"
  task slack_export: :environment do
    path = ENV["PATH"]
    
    if path.blank?
      puts "Usage: rake imports:slack_export PATH=/path/to/slack/export"
      puts "Example: rake imports:slack_export PATH=/tmp/slack-export"
      exit 1
    end
    
    unless File.exist?(path)
      puts "Error: Path #{path} does not exist"
      exit 1
    end
    
    creator = User.first
    unless creator
      puts "Error: No users found. Please create at least one user first."
      exit 1
    end
    
    puts "Starting Slack import from: #{path}"
    puts "Import will be performed by: #{creator.name}"
    puts "Starting import..."
    
    start_time = Time.current
    
    begin
      importer = Imports::Slack::Importer.new(path: path, creator: creator)
      stats = importer.run
      
      end_time = Time.current
      duration = (end_time - start_time).round(2)
      
      puts "\n" + "="*50
      puts "SLACK IMPORT COMPLETED"
      puts "="*50
      puts "Duration: #{duration} seconds"
      puts "Users created: #{stats[:users_created]}"
      puts "Users updated: #{stats[:users_updated]}"
      puts "Rooms created: #{stats[:rooms_created]}"
      puts "Messages created: #{stats[:messages_created]}"
      puts "Messages skipped: #{stats[:messages_skipped]}"
      
      if stats[:errors].any?
        puts "\nErrors encountered:"
        stats[:errors].each { |error| puts "  - #{error}" }
      else
        puts "\nNo errors encountered!"
      end
      
      puts "\nPost-import recommendations:"
      puts "1. Clear unread flags: Membership.update_all(unread_at: nil)"
      puts "2. Rebuild search index if applicable"
      puts "3. Review imported rooms and messages in the UI"
      
    rescue => e
      puts "ERROR: Import failed with exception: #{e.message}"
      puts e.backtrace.first(5).join("\n") if ENV["VERBOSE"]
      exit 1
    end
  end
end