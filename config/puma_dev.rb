require File.expand_path("../config/environment", File.dirname(__FILE__))

Signal.trap :SIGPROF do
  Thread.list.each do |t|
    puts t
    puts t.backtrace
    puts
  end
end
