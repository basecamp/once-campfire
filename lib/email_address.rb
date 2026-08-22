module EmailAddress
  module_function

  def normalize(value)
    value&.downcase&.strip
  end
end
