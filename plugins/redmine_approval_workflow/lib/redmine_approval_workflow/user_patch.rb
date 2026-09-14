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

    # Extension requests waiting on this user's signature. Memoised for the same
    # reason as above: the bell asks for it more than once per page.
    def pending_extension_requests
      @pending_extension_requests ||= ExtensionApproval.pending_for(self)
    end

    # Open issues assigned to this user, or to one of their groups, whose due
    # date has passed. One query, capped, shown alongside the signing queue.
    OVERDUE_LIMIT = 20

    def overdue_issues
      return @overdue_issues if defined?(@overdue_issues)
      return (@overdue_issues = []) unless logged?

      @overdue_issues =
        Issue.visible(self).open.
        where(:assigned_to_id => [id] + group_ids).
        where("#{Issue.table_name}.due_date < ?", today).
        order(:due_date).
        limit(OVERDUE_LIMIT).
        preload(:project, :tracker, :status).
        to_a
    end
  end
end
