class QrCodeController < ApplicationController
  allow_unauthenticated_access
  content_security_policy false

  def show
    url = Base64.urlsafe_decode64(params[:id])
    qr_code = RQRCode::QRCode.new(url).as_svg(viewbox: true, fill: :white, color: :black)

    expires_in 1.year, public: true
    render plain: qr_code, content_type: "image/svg+xml"
  end
end
