class Rooms::OpensController < RoomsController
  before_action :set_room, only: %i[ show edit update ]
  before_action :ensure_can_administer, only: %i[ update ]
  before_action :remember_last_room_visited, only: :show
  before_action :ensure_room_type_can_change, only: %i[ edit update ]
  before_action :force_room_type, only: %i[ edit update ]
  before_action :ensure_permission_to_create_rooms, only: %i[ new create ]

  DEFAULT_ROOM_NAME = "New room"

  def show
    redirect_to room_url(@room)
  end

  def new
    @room = Rooms::Open.new(name: DEFAULT_ROOM_NAME)
    @users = User.active.ordered
  end

  def create
    room = Rooms::Open.create_for(room_params, users: Current.user, actor: Current.user)

    broadcast_create_room(room)
    redirect_to room_url(room)
  end

  def edit
    @users = User.active.ordered
  end

  def update
    @room.update_as_open! room_params, actor: Current.user

    broadcast_update_room
    redirect_to room_url(@room)
  end

  private
    # Allows us to edit a closed room and turn it into an open one on saving.
    def force_room_type
      @room = @room.becomes!(Rooms::Open)
    end

    # Open and closed rooms convert into each other, so both are in reach here. Direct
    # rooms never are: promoting one would republish its history to the whole account.
    def room_scope
      Current.user.rooms.without_directs
    end

    def broadcast_create_room(room)
      broadcast_prepend_to :rooms, target: :shared_rooms, partial: "users/sidebars/rooms/shared", locals: { room: room }
    end

    def broadcast_update_room
      broadcast_replace_to :rooms, target: [ @room, :list ], partial: "users/sidebars/rooms/shared", locals: { room: @room }
    end
end
