# frozen_string_literal: true

module RedmineApprovalWorkflow
  # The top menu asks for the count twice per page (once to decide whether to
  # show the item, once for its caption), and User.current is a fresh instance
  # per request, so memoising on the user makes the lookup run once per request.
  module UserPatch
    # Both lists come out of one pass over the same routes and issues, so they
    # are memoised together rather than one lookup each.
    def approval_reminders
      @approval_reminders ||= PendingApprovals.evaluate(self)
    end

    def pending_approval_issues
      approval_reminders[:pending]
    end

    # [issue, step] pairs: work this user can take on without waiting for
    # somebody to hand it over.
    def self_claimable_approvals
      approval_reminders[:claimable]
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

    # [issue, rejecting signature] pairs: work of this user's that somebody
    # refused. Memoised like the rest; the bell asks once, the page asks again.
    def rejected_approval_issues
      @rejected_approval_issues ||= RejectedApprovals.for_user(self)
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
