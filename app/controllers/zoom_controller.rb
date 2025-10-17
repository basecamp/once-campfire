class ZoomController < ApplicationController
  def weekly_call
    @next_tuesday = calculate_next_tuesday
    @meeting_times = calculate_meeting_times
    @meeting_link = ENV['ZOOM_MEETING_LINK']
    @meeting_id = ENV['ZOOM_MEETING_ID']
    @passcode = ENV['ZOOM_PASSCODE']
  end

  private

  def calculate_next_tuesday
    today = Date.current
    days_until_tuesday = (2 - today.wday) % 7
    days_until_tuesday = 7 if days_until_tuesday == 0 && today.wday != 2
    next_tuesday = today + days_until_tuesday.days
    
    {
      day: next_tuesday.strftime('%A'),
      date: next_tuesday.strftime('%B %d, %Y')
    }
  end

  def calculate_meeting_times
    # Get the meeting time from environment variable (default to 18:00 GMT)
    meeting_time_gmt = ENV.fetch('ZOOM_MEETING_TIME_GMT', '18:00')
    next_tuesday = calculate_next_tuesday_date
    
    # Parse the GMT time for the next Tuesday
    meeting_time = Time.zone.parse("#{next_tuesday} #{meeting_time_gmt}").in_time_zone('Europe/London')
    
    {
      gmt: meeting_time.strftime('%H:%M %Z'),
      est: meeting_time.in_time_zone('America/New_York').strftime('%H:%M %Z'),
      ksa: "#{meeting_time.in_time_zone('Asia/Riyadh').strftime('%H:%M')} KSA"
    }
  end

  def calculate_next_tuesday_date
    today = Date.current
    days_until_tuesday = (2 - today.wday) % 7
    days_until_tuesday = 7 if days_until_tuesday == 0 && today.wday != 2
    today + days_until_tuesday.days
  end
end
