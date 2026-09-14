# frozen_string_literal: true

# One deadline extension ("gia hạn"). The number of days an extension may add
# is capped by the administrator through the plugin settings.
#
# When the project has an extension approval chain, a request is created pending
# and the issue's due date is left alone until the last step approves. Without
# such a chain the request is approved on creation, which is how this behaved
# before chains existed.
class IssueExtension < ApplicationRecord
  PENDING  = 'pending'
  APPROVED = 'approved'
  REJECTED = 'rejected'
  STATUSES = [PENDING, APPROVED, REJECTED].freeze

  belongs_to :issue
  belongs_to :user
  belongs_to :journal, :optional => true
  belongs_to :approval_route, :optional => true
  has_many :approval_signatures, lambda {order(:id)},
           :dependent => :destroy, :inverse_of => :issue_extension

  attr_accessor :skip_limit_validation

  validates :issue_id, :user_id, :presence => true
  validates :new_due_date, :presence => true
  validates :status, :inclusion => {:in => STATUSES}
  validate  :validate_new_due_date

  scope :sorted, lambda {order(:id)}
  scope :pending, lambda {where(:status => PENDING)}
  scope :approved, lambda {where(:status => APPROVED)}
  scope :rejected, lambda {where(:status => REJECTED)}
  # What counts against the per-issue allowance: granted, or still being asked
  # for. A refusal should not use somebody's quota up.
  scope :counted, lambda {where.not(:status => REJECTED)}

  class << self
    # Maximum number of days a single extension may add. 0 or blank means
    # "no limit".
    def max_days
      setting('max_extension_days').to_i
    end

    # Maximum number of extensions allowed per issue. 0 or blank means
    # "no limit". Only approved and pending requests count against it; a
    # rejected one should not use up somebody's allowance.
    def max_count
      setting('max_extension_count').to_i
    end

    def reason_required?
      setting('require_extension_reason').to_s == '1'
    end

    def setting(key)
      values = Setting.plugin_redmine_approval_workflow
      values.is_a?(Hash) ? values[key] : nil
    end
  end

  def pending?
    status == PENDING
  end

  def approved?
    status == APPROVED
  end

  def rejected?
    status == REJECTED
  end

  # The date an extension is measured from: the current deadline, or today when
  # the issue has no deadline yet.
  def base_date
    previous_due_date || User.current.today
  end

  # Same replay as the issue chain: approving advances once the step has what
  # it needs, rejecting sends back one.
  def approval_progress
    RedmineApprovalWorkflow::ChainProgress.compute(approval_route, approval_signatures.to_a)
  end

  # Index of the step awaiting a signature.
  def approval_position
    approval_progress[0]
  end

  # Signatures the pending step has already collected.
  def approval_step_signatures
    approval_progress[1]
  end

  def current_approval_step
    return nil unless approval_route

    approval_route.step_at(approval_position)
  end

  def approval_action_label
    current_approval_step&.action_label || ::I18n.t(:button_approve)
  end

  # An extension step has no workflow transition behind it, so the approver
  # list is the whole rule -- plus being allowed to touch the issue at all.
  def signable_by?(user)
    return false unless pending?

    step = current_approval_step
    return false if step.nil?
    return false unless issue.attributes_editable?(user)
    return false if issue.read_only_attribute_names(user).include?('due_date')

    step.signable_by?(user, issue, approval_step_signatures)
  end

  # The approver slot +user+ is filling on the pending step.
  def approval_approver_for(user)
    current_approval_step&.approver_for(user, issue, approval_step_signatures)
  end

  private

  def validate_new_due_date
    return if new_due_date.blank?

    if new_due_date <= base_date
      errors.add(:new_due_date, :must_be_after_base_date)
      return
    end

    self.days = (new_due_date - base_date).to_i

    limit = self.class.max_days
    if !skip_limit_validation && limit > 0 && days > limit
      errors.add(:new_due_date, :exceeds_max_extension_days, :count => limit)
    end

    if self.class.reason_required? && reason.blank?
      errors.add(:reason, :blank)
    end
  end
end
