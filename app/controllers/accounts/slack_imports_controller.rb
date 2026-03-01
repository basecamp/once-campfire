class Accounts::SlackImportsController < ApplicationController
  before_action :ensure_can_administer

  def new
  end

  def create
    archive = params.dig(:slack_import, :archive)

    return redirect_to(new_account_slack_import_url, alert: "Choose a Slack export ZIP file.") if archive.blank?

    result = Slack::Import.new(
      archive:,
      importer: Current.user,
      user_mappings: params.dig(:slack_import, :user_mappings)
    ).call

    redirect_to edit_account_url, notice: "Imported #{result.messages_imported} messages into #{result.rooms_touched} rooms."
  rescue Slack::Import::InvalidArchiveError, Slack::Import::InvalidMappingsError => e
    redirect_to new_account_slack_import_url, alert: e.message
  end
end
