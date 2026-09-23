# frozen_string_literal: true

class PendingApprovalsController < ApplicationController
  helper :issues
  helper :approval_workflow

  before_action :require_login

  def index
    # [issue, step] pairs; the step is carried so the table does not have to
    # ask each row for it again.
    @issues = User.current.pending_approvals
    @claimable = User.current.self_claimable_approvals
    @rejected = User.current.rejected_approval_issues
    @extensions = User.current.pending_extension_requests
    @capped = @issues.size >= RedmineApprovalWorkflow::PendingApprovals::CANDIDATE_LIMIT
    # Both lookups stop at a fixed number of rows so the bell cannot grow with
    # the instance; say so rather than quietly showing a short list.
    @extensions_capped =
      @extensions.size >= RedmineApprovalWorkflow::ExtensionApproval::CANDIDATE_LIMIT
  end
end
