class ReliableWork::ReadinessController < ActionController::Base
  def show
    pending_deletions = BanCleanupIntent.pending.count
    if pending_deletions.zero?
      render json: { status: "ready", pending_required_deletions: 0 }
    else
      render json: { status: "not_ready", pending_required_deletions: pending_deletions },
        status: :service_unavailable
    end
  rescue ActiveRecord::ActiveRecordError
    render json: { status: "not_ready" }, status: :service_unavailable
  end
end
