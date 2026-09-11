# frozen_string_literal: true

module RedmineApprovalWorkflow
  # The top menu asks for the count twice per page (once to decide whether to
  # show the item, once for its caption), and User.current is a fresh instance
  # per request, so memoising on the user makes the lookup run once per request.
  module UserPatch
    def pending_approval_issues
      @pending_approval_issues ||= PendingApprovals.for_user(self)
    end

    def pending_approval_count
      pending_approval_issues.size
    end

    def pending_approvals?
      pending_approval_count > 0
    end
  end
end
