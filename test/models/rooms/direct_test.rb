require "test_helper"

class Rooms::DirectTest < ActiveSupport::TestCase
  test "create room for same users" do
    room = Rooms::Direct.find_or_create_for([ users(:david), users(:kevin) ])
    assert room.users.include?(users(:david))
    assert room.users.include?(users(:kevin))
    assert_not room.users.include?(users(:jason))
  end

  test "only one room will exist for the same users" do
    room1 = Rooms::Direct.find_or_create_for([ users(:david), users(:kevin) ])
    room2 = Rooms::Direct.find_or_create_for([ users(:kevin), users(:david) ])
    assert_equal room1, room2
  end

  test "default involvement for new users" do
    room = Rooms::Direct.find_or_create_for([ users(:david), users(:kevin) ])
    assert room.memberships.all? { |m| m.involved_in_everything? }
  end

  test "find the room with exactly the same users" do
    Current.user = users(:david)
    group = Rooms::Direct.find_or_create_for([ users(:david), users(:kevin), users(:jason) ])

    assert_equal rooms(:david_and_kevin), Rooms::Direct.find_or_create_for([ users(:kevin), users(:david) ])
    assert_equal group, Rooms::Direct.find_or_create_for(User.where(id: [ users(:jason), users(:kevin), users(:david) ]))
    assert_equal [ users(:david), users(:jz) ].to_set, Rooms::Direct.find_or_create_for([ users(:david), users(:jz) ]).users.to_set
    assert_equal [ users(:jason), users(:kevin) ].to_set, Rooms::Direct.find_or_create_for([ users(:jason), users(:kevin) ]).users.to_set
  end

  test "finding a room takes the same queries however many direct rooms the account has" do
    Current.user = users(:david)
    Rooms::Direct.create_for({}, users: [ users(:david), users(:jz) ])
    before = queries_during { Rooms::Direct.find_or_create_for(User.where(id: [ users(:david), users(:jz) ])) }

    5.times { |i| Rooms::Direct.create_for({}, users: [ users(:jason), User.create!(name: "Guest #{i}", email_address: "guest#{i}@example.com", password: "secret123456") ]) }
    Rooms::Direct.create_for({}, users: [ users(:kevin), users(:jz) ])

    assert_equal before, queries_during { Rooms::Direct.find_or_create_for(User.where(id: [ users(:kevin), users(:jz) ])) }
  end

  private
    def queries_during(&block)
      count = 0
      counter = ->(*, payload) { count += 1 unless payload[:name] == "SCHEMA" || payload[:cached] }
      ActiveSupport::Notifications.subscribed(counter, "sql.active_record", &block)
      count
    end
end
