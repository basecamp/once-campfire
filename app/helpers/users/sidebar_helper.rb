module Users::SidebarHelper
  def sidebar_turbo_frame_tag(src: nil, &)
    turbo_frame_tag :user_sidebar, src: src, target: "_top", data: {
      turbo_permanent: true,
      controller: "rooms-list read-rooms turbo-frame",
      rooms_list_unread_class: "unread",
      action: "presence:present@window->rooms-list#read read-rooms:read->rooms-list#read turbo:frame-load->rooms-list#loaded refresh-room:visible@window->turbo-frame#reload".html_safe # otherwise -> is escaped
    }, &
  end

  # Unique soft background per Backlit project among the current user's shared rooms.
  def sidebar_project_color_map(memberships = nil)
    memberships ||= Current.user.memberships.visible.with_ordered_room.without_direct_rooms.includes(:room)
    project_ids = memberships.filter_map { |membership| membership.room.backlit_project_id }
    SidebarProjectColors.map_for(project_ids)
  end

  def room_project_background(room, color_map = nil)
    return if room.backlit_project_id.blank?

    (color_map || sidebar_project_color_map)[room.backlit_project_id]
  end
end

