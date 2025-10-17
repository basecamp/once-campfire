class ZoomController < ApplicationController
  def weekly_call
    @next_tuesday = calculate_next_tuesday
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
end
