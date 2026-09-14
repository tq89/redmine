# frozen_string_literal: true

class PendingApprovalsController < ApplicationController
  helper :issues
  helper :approval_workflow

  before_action :require_login

  def index
    @issues = User.current.pending_approval_issues
    @extensions = User.current.pending_extension_requests
    @capped = @issues.size >= RedmineApprovalWorkflow::PendingApprovals::CANDIDATE_LIMIT
  end
end
