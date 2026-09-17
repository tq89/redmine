# frozen_string_literal: true

module RedmineApprovalWorkflow
  # Issues whose chain was last refused, shown to whoever has to do something
  # about it.
  #
  # "Whoever has to do something about it" is the person the work is assigned
  # to -- người thực hiện -- or the person who raised it when it is assigned to
  # nobody. The same rule the rejection mail uses, so the bell and the inbox
  # never disagree about who was told.
  #
  # It clears itself. The notice is not a row somebody has to dismiss: it is
  # simply what the newest signature on the chain says. As soon as anybody
  # signs again the newest signature is an approval and the issue drops off,
  # the way the rest of the bell works.
  module RejectedApprovals
    LIMIT = 20

    module_function

    def for_user(user)
      return [] unless user.is_a?(User) && user.logged?

      issues = candidates(user)
      return [] if issues.empty?

      # One query for the lot; the EXISTS above has already thrown out every
      # issue that was never refused, so this list is short.
      signatures = ApprovalSignature.on_issue_chain.
                   where(:issue_id => issues.map(&:id)).
                   sorted.
                   preload(:user).
                   group_by(&:issue_id)

      issues.filter_map do |issue|
        last = signatures[issue.id]&.last
        [issue, last] if last&.rejected?
      end
    end

    # Open issues only, deliberately. A refusal that sends the issue into a
    # CLOSED status -- "Rejected" is one, in stock Redmine -- ends the work
    # rather than handing it back, so it is not a task and does not belong on
    # a to-do list. It would also never clear: nobody signs a closed chain
    # again, so the row would sit there for good. The rejection mail has no
    # such filter, so the person is still told once; it is the bell that stays
    # a list of things to do.
    def candidates(user)
      Issue.visible(user).open.
        where(audience_sql, :ids => [user.id] + user.group_ids, :me => user.id).
        where(rejection_exists_sql, :rejected => ApprovalSignature::REJECTED).
        joins(:project).merge(Project.has_module(:approval_workflow)).
        preload(:project, :tracker, :status).
        order(:id).
        limit(LIMIT).
        to_a
    end

    def audience_sql
      "#{Issue.table_name}.assigned_to_id IN (:ids)" \
      " OR (#{Issue.table_name}.assigned_to_id IS NULL" \
      " AND #{Issue.table_name}.author_id = :me)"
    end

    # Drops every issue that has never been refused, which is nearly all of
    # them, before anything is loaded to look at.
    def rejection_exists_sql
      "EXISTS (SELECT 1 FROM #{ApprovalSignature.table_name} s" \
      " WHERE s.issue_id = #{Issue.table_name}.id" \
      " AND s.issue_extension_id IS NULL" \
      " AND s.action = :rejected)"
    end
  end
end
