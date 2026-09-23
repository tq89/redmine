# frozen_string_literal: true

module RedmineApprovalWorkflow
  # Drives an extension request through its approval chain.
  #
  # The request holds the proposed date; the issue's own due_date is not touched
  # until the last step approves. That is the whole point of putting a chain in
  # front of it -- asking is not the same as being granted.
  module ExtensionApproval
    module_function

    # Records a decision on +extension+ by +user+ and applies it if that was the
    # last step. Returns the signature, or nil when the user may not sign.
    def decide(extension, user, approve:, comments: nil)
      return nil unless extension.signable_by?(user)

      step = extension.current_approval_step
      position = extension.approval_position

      signature = nil
      IssueExtension.transaction do
        signature = ApprovalSignature.create!(
          :issue_id => extension.issue_id,
          :issue_extension_id => extension.id,
          :approval_route_id => extension.approval_route_id,
          :approval_route_step_id => step.id,
          :approval_route_approver => extension.approval_approver_for(user),
          :step_position => position,
          :step_name => step.name,
          :user_id => user.id,
          :action => approve ? ApprovalSignature::APPROVED : ApprovalSignature::REJECTED,
          :comments => comments.presence
        )
        extension.approval_signatures.reset

        if approve
          # A step that wants every signature on its list keeps the request
          # where it is until it has them, so this only fires at the very end.
          apply(extension, user) if extension.approval_position >= extension.approval_route.step_count
        else
          # update_columns, not update!: the limit validation would run again,
          # and an administrator lowering the cap between request and decision
          # must not make a rejection impossible to record.
          extension.update_columns(:status => IssueExtension::REJECTED,
                                   :decided_at => Time.current)
        end
      end

      # Outside the transaction: a signature that is already committed must not
      # be undone because a mail server was unreachable.
      notify_current_step(extension, user)

      signature
    end

    # Tells whoever the request now waits on that it is their turn. Silent when
    # the request is finished, one way or the other.
    def notify_current_step(extension, actor = nil)
      ApprovalMailer.deliver_extension_pending(extension, actor)
    rescue StandardError => e
      Rails.logger.error("Extension notification failed for extension #{extension.id}: #{e.message}")
    end

    # The last approval is what actually moves the deadline.
    def apply(extension, user)
      issue = extension.issue
      # No generated note: Redmine journals the due_date change itself, and the
      # reason lives on the request where the panel shows it.
      journal = issue.init_journal(user, '')
      issue.due_date = extension.new_due_date
      issue.skip_approval_sync = true
      issue.save!
      extension.update_columns(
        :status => IssueExtension::APPROVED,
        :decided_at => Time.current,
        :journal_id => journal&.persisted? ? journal.id : extension.journal_id
      )
    end

    # How many requests one page load will look at. A backstop only: the SQL
    # below has already narrowed the set to chains that name this user.
    CANDIDATE_LIMIT = 100

    # Pending requests waiting on +user+, for the bell and the pending page.
    #
    # This runs on EVERY page through the bell, so it must not grow with the
    # instance. The first version leaned on "the pending set is naturally
    # small" and loaded every undecided request in the database, then asked
    # each one in Ruby. IssueExtension#signable_by? reads the issue's field
    # permissions, and those are memoised per Issue INSTANCE -- a different
    # instance per request -- so that was one workflows query per pending
    # request, on every page, for every user. Six hundred open requests meant
    # six hundred extra queries per page load.
    #
    # An extension step always names its approvers (the model refuses to save
    # one that does not), so there is a cheap pre-filter after all: keep only
    # the chains that mention this user at all. Whose turn it actually is
    # stays an in-memory question, on a handful of rows instead of all of them.
    def pending_for(user)
      return [] unless user.is_a?(User) && user.logged?

      IssueExtension.pending.
        where.not(:approval_route_id => nil).
        where(named_approver_sql,
              :me => user.id,
              :ids => [user.id] + user.group_ids,
              :role_ids => RedmineApprovalWorkflow::PendingApprovals.workflow_role_ids(user)).
        includes(:approval_signatures,
                 {:approval_route => {:steps => [:issue_status, {:approvers => [:approver_role, :approver_user]}]}},
                 :issue => [:project, :tracker, :status]).
        order(:id).
        limit(CANDIDATE_LIMIT).
        select {|extension| extension.issue && extension.issue.visible?(user) && extension.signable_by?(user)}
    end

    # The three ways ApprovalRouteApprover#matches? can name somebody, asked in
    # SQL. It only ever widens -- being named here does not mean it is your
    # turn, which is what signable_by? decides afterwards -- so nobody's
    # request can be filtered away from them by this.
    def named_approver_sql
      "EXISTS (SELECT 1 FROM #{ApprovalRouteApprover.table_name} a" \
      " JOIN #{ApprovalRouteStep.table_name} s ON s.id = a.approval_route_step_id" \
      " WHERE s.approval_route_id = #{IssueExtension.table_name}.approval_route_id" \
      " AND (a.approver_user_id = :me" \
      "      OR a.approver_role_id IN (:role_ids)" \
      "      OR (a.approver_dynamic IS NOT NULL AND EXISTS (" \
      "            SELECT 1 FROM #{Issue.table_name} i" \
      "            WHERE i.id = #{IssueExtension.table_name}.issue_id" \
      "            AND (i.assigned_to_id IN (:ids) OR i.author_id = :me)))))"
    end
  end
end
