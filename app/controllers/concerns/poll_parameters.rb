module PollParameters
  extend ActiveSupport::Concern

  private
    def poll_params
      params.require(:poll).permit(:question, :multi_select, options_attributes: [ :id, :body, :position, :_destroy ])
    end
end
