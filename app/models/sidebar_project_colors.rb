# frozen_string_literal: true

# Soft fills inspired by Dashkit theme colors (badge-soft style). Assigned 1:1 to
# Backlit project ids visible in a user's sidebar so two projects never share a
# color in that list. Extra projects past the palette get evenly spaced light hues.
class SidebarProjectColors
  # Approximate Dashkit soft badge backgrounds from primary/success/info/warning/
  # danger plus indigo, purple, pink, orange, teal.
  PALETTE = [
    "#E8F1FC", # primary blue
    "#D6F9EB", # success green
    "#E0F4FA", # info cyan
    "#FDF3D9", # warning yellow
    "#FCE4E9", # danger red
    "#E8E9FE", # indigo
    "#E9E6F4", # purple
    "#FFE5EF", # pink
    "#FFEFE0", # orange
    "#D6F3F5", # teal
    "#E9ECEF", # secondary gray
    "#F3E8FF"  # violet
  ].freeze

  def self.map_for(project_ids)
    ids = Array(project_ids).map(&:presence).compact.uniq.sort
    total = ids.size

    ids.each_with_index.to_h do |project_id, index|
      [ project_id, color_at(index, total) ]
    end
  end

  def self.color_at(index, total)
    if total <= PALETTE.size
      PALETTE.fetch(index)
    else
      hue = (360.0 * index / total).round(1)
      "hsl(#{hue} 42% 92%)"
    end
  end
  private_class_method :color_at
end
