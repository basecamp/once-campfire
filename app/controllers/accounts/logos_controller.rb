class Accounts::LogosController < ApplicationController
  include ActiveStorage::Streaming, ActionView::Helpers::AssetUrlHelper

  allow_unauthenticated_access only: :show
  before_action :ensure_can_administer, only: :destroy

  def show
    if stale?(etag: Current.account)
      expires_in 5.minutes, public: true, stale_while_revalidate: 1.week

      if (logo_variant = Current.account&.logo_variant(logo_size))
        send_png_file ActiveStorage::Blob.service.path_for(logo_variant.key)
      else
        send_stock_icon
      end
    end
  end

  def destroy
    Current.account.remove_logo! actor: Current.user
    redirect_to edit_account_url
  end

  private
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

    def logo_size
      small_logo? ? :small : :large
    end

    def small_logo?
      params[:size] == "small"
    end

    def logo_path(filename)
      Rails.root.join("app/assets/images/logos/#{filename}")
    end
end
