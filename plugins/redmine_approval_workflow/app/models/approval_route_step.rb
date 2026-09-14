# frozen_string_literal: true

# One step of an approval chain. Approving it moves the issue into
# +issue_status+, which is also what decides who is allowed to sign it.
#
# A step may additionally name the approver, either a role or one person. That
# only ever *narrows* the workflow: someone the transition does not allow can
# never sign, whatever is configured here.
class ApprovalRouteStep < ApplicationRecord
  belongs_to :approval_route, :inverse_of => :steps
  belongs_to :issue_status, :optional => true
  belongs_to :approver_role, :class_name => 'Role', :optional => true
  belongs_to :approver_user, :class_name => 'User', :optional => true

  validates :name, :presence => true, :length => {:maximum => 255}
  # An extension step names its approver rather than a status to move into.
  validates :issue_status_id, :presence => true, :unless => :extension_step?
  validate :validate_extension_approver
  validates :button_label, :length => {:maximum => 255}
  validates :position, :numericality => {:only_integer => true, :greater_than_or_equal_to => 0}
  validate :validate_single_approver

  # Wording of the action button for this step.
  def action_label
    button_label.presence || ::I18n.t(:button_approve)
  end

  def assigned?
    approver_role_id.present? || approver_user_id.present?
  end

  # True when +user+ matches the step's assignment. Callers still have to check
  # the workflow transition separately; this only answers "is this their step".
  def assigned_to?(user, project)
    return true unless assigned?
    return false unless user.is_a?(User) && user.logged?
    return user.id == approver_user_id if approver_user_id.present?

    user.roles_for_project(project).any? {|role| role.id == approver_role_id}
  end

  def to_s
    name.to_s
  end

  def extension_step?
    approval_route&.extension?
  end

  private

  # Without a workflow transition behind it, the named approver is the only
  # thing deciding who may sign an extension step.
  def validate_extension_approver
    return unless extension_step?
    return if approver_role_id.present? || approver_user_id.present?

    errors.add(:base, :extension_step_needs_approver)
  end

  def validate_single_approver
    return unless approver_role_id.present? && approver_user_id.present?

    errors.add(:approver_user_id, :only_one_approver_allowed)
  end
end
