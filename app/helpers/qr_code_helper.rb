module QrCodeHelper
  def link_to_zoom_qr_code(url, &)
    image_url = inline_qr_code_url(url)

    link_to image_url, class: "btn", data: {
      lightbox_target: "image", action: "lightbox#open", lightbox_url_value: image_url }, &
  end

  private
    def inline_qr_code_url(url)
      svg = RQRCode::QRCode.new(url).as_svg(viewbox: true, fill: :white, color: :black)
      "data:image/svg+xml;base64,#{Base64.strict_encode64(svg)}"
    end
end
