class Accounts::LogosController < ApplicationController
  include ActiveStorage::Streaming, ActionView::Helpers::AssetUrlHelper

  allow_unauthenticated_access only: :show
  before_action :ensure_can_administer, only: :destroy

  def show
    if stale?(etag: Current.account)
      expires_in 5.minutes, public: true, stale_while_revalidate: 1.week

      if Current.account&.logo&.attached?
        send_blob_stream Current.account.logo.variant(logo_variant).processed, disposition: :inline
      else
        send_stock_icon
      end
    end
  end

  def destroy
    Current.account.logo.destroy
    redirect_to edit_account_url
  end

  private
    LARGE_SQUARE_PNG_VARIANT = { resize_to_limit: [ 512, 512 ], format: :png }
    SMALL_SQUARE_PNG_VARIANT = { resize_to_limit: [ 192, 192 ], format: :png }

    def send_png_file(path)
      send_file path, content_type: "image/png", disposition: :inline
    end

    def send_stock_icon
      if small_logo?
        send_png_file logo_path("app-icon-192.png")
      else
        send_png_file logo_path("app-icon.png")
      end
    end

    def logo_variant
      small_logo? ? SMALL_SQUARE_PNG_VARIANT : LARGE_SQUARE_PNG_VARIANT
    end

    def small_logo?
      params[:size] == "small"
    end

    def logo_path(filename)
      Rails.root.join("app/assets/images/logos/#{filename}")
    end
end
