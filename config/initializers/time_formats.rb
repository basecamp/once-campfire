# Used to match JavaScripts (new Date).getTime() for sorting
ActiveSupport::TimeFormats.register(:epoch, ->(time) { (time.to_f * 1000).to_i })
