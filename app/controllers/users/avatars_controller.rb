class Users::AvatarsController < ApplicationController
  include ActiveStorage::Streaming

  rescue_from(ActiveSupport::MessageVerifier::InvalidSignature) { head :not_found }

  def show
    @user = User.from_avatar_token(params[:user_id])

    if stale?(etag: @user)
      expires_in 30.minutes, public: true, stale_while_revalidate: 1.week

      if @user.avatar.attached?
        send_webp_blob @user.avatar.variant(SQUARE_WEBP_VARIANT).processed
      elsif @user.bot?
        render_default_bot
      else
        render_initials
      end
    end
  end

  def destroy
    Current.user.avatar.destroy
    redirect_to user_profile_url
  end

  private
    SQUARE_WEBP_VARIANT = { resize_to_limit: [ 512, 512 ], format: :webp }

    def send_webp_blob(blob)
      send_blob_stream blob, disposition: :inline
    end

    def render_default_bot
      send_file Rails.root.join("app/assets/images/default-bot-avatar.svg"), content_type: "image/svg+xml", disposition: :inline
    end

    def render_initials
      render formats: :svg
    end
end
