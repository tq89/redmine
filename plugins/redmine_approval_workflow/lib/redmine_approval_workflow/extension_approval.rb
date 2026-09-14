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

    # Pending requests waiting on +user+, for the bell and the pending page.
    #
    # Extension chains are gated by the named approver rather than by a workflow
    # transition, so there is no cheap SQL pre-filter to lean on here as there is
    # for issue chains; the pending set is naturally small, being only requests
    # nobody has finished deciding.
    def pending_for(user)
      return [] unless user.is_a?(User) && user.logged?

      IssueExtension.pending.
        where.not(:approval_route_id => nil).
        includes(:approval_signatures, :approval_route, :issue => [:project, :tracker, :status]).
        order(:id).
        select {|extension| extension.issue && extension.issue.visible?(user) && extension.signable_by?(user)}
    end
  end
end
