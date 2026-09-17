# frozen_string_literal: true

module RedmineApprovalWorkflow
  # Approval-chain and extension helpers mixed into Issue.
  #
  # Position semantics used throughout: +approval_position+ is the 0-based index
  # of the step that is *pending*, i.e. steps 0..position-1 have been approved.
  module IssuePatch
    # reload is how callers ask for fresh state, so the memoised route has to go
    # with it, or a route edited in the meantime stays invisible.
    #
    # Issue defines reload itself (app/models/issue.rb:285), which sits ahead of
    # an included module in the ancestor chain, so this has to be prepended --
    # putting it in IssuePatch alongside everything else would never run.
    module Reload
      def reload(*)
        remove_instance_variable(:@approval_route) if defined?(@approval_route)
        super
      end
    end

    def self.included(base)
      base.class_eval do
        # Scoped to the issue's own chain: an extension request's signatures
        # live in the same table and carry this issue_id, and counting them
        # here would advance the issue chain by somebody approving a deadline.
        # They are destroyed through issue_extensions, which owns them.
        has_many :approval_signatures,
                 lambda {where(:issue_extension_id => nil).order(:id)},
                 :dependent => :destroy
        has_many :issue_extensions, lambda {order(:id)}, :dependent => :destroy

        # A new issue on a routed tracker puts step 0 in front of somebody
        # straight away; later turns are announced by ApprovalsController.
        after_create :notify_first_approval_step
        # Declared here, so it is appended after Redmine's own create_journal
        # and the journal for this very change already exists when it runs.
        after_save :sync_approval_chain_with_status
      end
    end

    # Set by ApprovalsController around its own save: a signature already
    # records itself, and reconciling on top of it would count the move twice.
    attr_accessor :skip_approval_sync

    # Keeps the chain honest when the status moves by some other route: the
    # ordinary issue form, the API, a bulk edit, an import.
    def sync_approval_chain_with_status
      return if skip_approval_sync
      return unless saved_change_to_status_id?

      RedmineApprovalWorkflow::HistorySync.backfill(self)
    rescue StandardError => e
      # Reconciliation is bookkeeping; it must never take the issue down with it.
      Rails.logger.error("Approval chain sync failed for issue #{id}: #{e.message}")
    end

    def notify_first_approval_step
      ApprovalMailer.deliver_approval_pending(self, author)
    rescue StandardError => e
      # Never let a notification failure roll back the issue itself.
      Rails.logger.error("Approval notification failed for issue #{id}: #{e.message}")
    end

    # The chain governing this issue, or nil when none is configured.
    def approval_route
      return @approval_route if defined?(@approval_route)

      @approval_route = ApprovalRoute.for_issue(self)
    end

    def approval_route?
      approval_route.present? && approval_route.step_count > 0
    end

    # Where the chain stands: the step awaiting a signature and what that step
    # has collected so far. Not memoised -- callers sign and ask again within
    # the same request, and a stale answer there would be a wrong one.
    def approval_progress
      RedmineApprovalWorkflow::ChainProgress.compute(approval_route, approval_signatures.to_a)
    end

    # Index of the step awaiting a signature.
    def approval_position
      approval_progress[0]
    end

    # Signatures the pending step has already collected. Empty unless the step
    # is in "all" mode and is part-way through its list.
    def approval_step_signatures
      approval_progress[1]
    end

    # Every step has been approved.
    def approval_completed?
      approval_route? && approval_position >= approval_route.step_count
    end

    def current_approval_step
      return nil unless approval_route?

      approval_route.step_at(approval_position)
    end

    # Status the issue moves to when the pending step is approved.
    def approval_target_status
      current_approval_step&.issue_status
    end

    # Status the issue moves to when the pending step is rejected.
    #
    # The step decides. Only when it has nothing to say does this fall back to
    # the route: the status left behind by the step before the one being
    # undone, or the route's dedicated rejected status at the head of the
    # chain. That fallback is what every chain did before the setting existed,
    # and it answers nil for a route with no rejected status configured -- the
    # reason the reject button was nowhere to be seen on such a route.
    def approval_reject_target_status
      return nil unless approval_route?

      step = current_approval_step
      return status if step&.reject_keeps_status?
      return step.reject_status if step&.reject_into_status?

      position = approval_position
      if position <= 1
        approval_route.rejected_status
      else
        approval_route.step_at(position - 2)&.issue_status
      end
    end

    # Signing is deliberately not governed by a permission of its own: a user
    # may sign a step exactly when Redmine's workflow lets them move the issue
    # into that step's status.
    #
    # When +step+ lists approvers, that narrows the result further; it can
    # never let somebody sign a transition the workflow denies them.
    # +signatures+ is what the step being signed has already collected. It
    # defaults to the pending step's, which is right for the ordinary path; a
    # step being skipped to has collected nothing, so the caller passes [].
    def approval_signable_by?(user, target_status, step = nil, signatures = approval_step_signatures)
      return false if target_status.nil?
      return false unless attributes_editable?(user)
      return false if step && !step.signable_by?(user, self, signatures)

      new_statuses_allowed_to(user).include?(target_status)
    end

    # Steps further along the chain that may be signed right now without
    # working through the ones in between. A step has to be marked skippable,
    # and the workflow still has to allow the move from where the issue is --
    # skipping is a shortcut through the chain, never around the workflow.
    def approval_skippable_steps(user = User.current)
      return [] unless approval_route?

      position = approval_position
      approval_route.steps.select do |step|
        step.position > position && step.skippable? &&
          approval_signable_by?(user, step.issue_status, step, [])
      end
    end

    def approval_can_skip_to?(user, step)
      return false unless approval_route? && step&.skippable?
      return false unless step.position > approval_position

      approval_signable_by?(user, step.issue_status, step, [])
    end

    # The approver slot +user+ is filling on the pending step, recorded on the
    # signature so an "all" step knows who is still missing.
    def approval_approver_for(user)
      current_approval_step&.approver_for(user, self, approval_step_signatures)
    end

    def can_approve?(user = User.current)
      return false unless approval_route?
      return false if approval_completed?

      approval_signable_by?(user, approval_target_status, current_approval_step)
    end

    def can_reject_approval?(user = User.current)
      return false unless approval_route?

      step = current_approval_step
      # A refusal that keeps the status moves nothing, so there is no
      # transition to read the permission off. The rule becomes the plain one:
      # whoever may sign this step is who may refuse it.
      return approval_signable_by?(user, approval_target_status, step) if step&.reject_keeps_status?

      target = approval_reject_target_status
      # Nowhere to send it means there is nothing to offer. approval_reject_hint
      # is what tells an administrator why, instead of leaving them hunting for
      # a button that was never going to appear.
      return false if target.nil?

      # Rejecting is the pending step's decision too, so the same person holds it.
      approval_signable_by?(user, target, step)
    end

    # Why the reject button is not being offered, when the user could otherwise
    # act on this step. nil when there is nothing to explain.
    def approval_reject_hint(user = User.current)
      return nil unless approval_route?
      return nil if can_reject_approval?(user)
      return nil unless can_approve?(user)
      return nil unless approval_reject_target_status.nil?

      :warning_no_reject_status
    end

    # Wording of the approve button for the step awaiting a signature.
    def approval_action_label
      current_approval_step&.action_label || ::I18n.t(:button_approve)
    end

    # True when the issue status drifted away from the chain, e.g. because
    # somebody edited it by hand. The panel surfaces this rather than silently
    # signing from an unexpected state.
    def approval_out_of_sync?
      return false unless approval_route?

      position = approval_position
      return false if position.zero?

      expected = approval_route.step_at(position - 1)&.issue_status_id
      expected.present? && expected != status_id
    end

    # Counts towards the per-issue limit. A rejected request is not an
    # extension the issue got, so it does not use the allowance up.
    def extension_count
      issue_extensions.count {|extension| !extension.rejected?}
    end

    def extendable_by?(user = User.current)
      return false unless attributes_editable?(user)
      return false unless user.allowed_to?(:extend_issue_due_date, project)
      # Mirrors how signing follows status transitions: extending writes
      # due_date, so it obeys the field permissions set per role, tracker and
      # status in Administration -> Workflow -> Fields permissions. The check is
      # explicit because the extension assigns due_date directly rather than
      # through safe_attributes=, which would drop a read-only field silently.
      return false if read_only_attribute_names(user).include?('due_date')

      limit = IssueExtension.max_count
      limit.zero? || extension_count < limit
    end
  end
end
