# frozen_string_literal: true

module RedmineApprovalWorkflow
  # Approval-chain and extension helpers mixed into Issue.
  #
  # Position semantics used throughout: +approval_position+ is the 0-based index
  # of the step that is *pending*, i.e. steps 0..position-1 have been approved.
  module IssuePatch
    def self.included(base)
      base.class_eval do
        has_many :approval_signatures, lambda {order(:id)}, :dependent => :destroy
        has_many :issue_extensions, lambda {order(:id)}, :dependent => :destroy
      end
    end

    # The chain governing this issue, or nil when none is configured.
    def approval_route
      return @approval_route if defined?(@approval_route)

      @approval_route = ApprovalRoute.for_issue(self)
    end

    def approval_route?
      approval_route.present? && approval_route.step_count > 0
    end

    # Index of the step awaiting a signature.
    def approval_position
      last = approval_signatures.last
      return 0 if last.nil?

      last.approved? ? last.step_position + 1 : [last.step_position - 1, 0].max
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

    # Status the issue falls back to when the pending step is rejected: the
    # status left behind by the step before the one being undone, or the
    # route's dedicated rejected status at the head of the chain.
    def approval_reject_target_status
      return nil unless approval_route?

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
    def approval_signable_by?(user, target_status)
      return false if target_status.nil?
      return false unless attributes_editable?(user)

      new_statuses_allowed_to(user).include?(target_status)
    end

    def can_approve?(user = User.current)
      return false unless approval_route?
      return false if approval_completed?

      approval_signable_by?(user, approval_target_status)
    end

    def can_reject_approval?(user = User.current)
      return false unless approval_route?
      return false if approval_position.zero? && approval_signatures.empty? &&
                      approval_route.rejected_status.nil?

      approval_signable_by?(user, approval_reject_target_status)
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

    def extension_count
      issue_extensions.size
    end

    def extendable_by?(user = User.current)
      return false unless attributes_editable?(user)
      return false unless user.allowed_to?(:extend_issue_due_date, project)

      limit = IssueExtension.max_count
      limit.zero? || extension_count < limit
    end
  end
end
