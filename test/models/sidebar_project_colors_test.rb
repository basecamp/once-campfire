require "test_helper"

class SidebarProjectColorsTest < ActiveSupport::TestCase
  test "assigns a distinct color to each project id" do
    ids = %w[7 3 12 9]
    map = SidebarProjectColors.map_for(ids)

    assert_equal ids.sort, map.keys
    assert_equal map.values.uniq, map.values
    assert_equal SidebarProjectColors::PALETTE.first(ids.size), map.values
  end

  test "ignores blank project ids" do
    map = SidebarProjectColors.map_for([ "7", nil, "", "7", "3" ])

    assert_equal %w[3 7], map.keys
    assert_equal map.values.uniq.size, 2
  end

  test "generates unique hues when there are more projects than the palette" do
    ids = (1..SidebarProjectColors::PALETTE.size + 3).map(&:to_s)
    map = SidebarProjectColors.map_for(ids)

    assert_equal ids.size, map.values.uniq.size
    assert map.values.all? { |color| color.start_with?("hsl(") }
  end
end
