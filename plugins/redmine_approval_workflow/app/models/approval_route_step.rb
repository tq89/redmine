# frozen_string_literal: true

# One step of an approval chain. Approving it moves the issue into
# +issue_status+, which is also what decides who is allowed to sign it.
#
# A step may additionally name the approver: a role, one person, or a role the
# issue itself fills in -- currently "whoever the issue is assigned to". That
# only ever *narrows* the workflow: someone the transition does not allow can
# never sign, whatever is configured here.
class ApprovalRouteStep < ApplicationRecord
  # Approvers the issue decides rather than the configuration.
  ASSIGNEE = 'assignee'
  DYNAMIC_APPROVERS = [ASSIGNEE].freeze

  belongs_to :approval_route, :inverse_of => :steps
  belongs_to :issue_status, :optional => true
  belongs_to :approver_role, :class_name => 'Role', :optional => true
  belongs_to :approver_user, :class_name => 'User', :optional => true

  validates :name, :presence => true, :length => {:maximum => 255}
  # An extension step names its approver rather than a status to move into.
  validates :issue_status_id, :presence => true, :unless => :extension_step?
  validate :validate_extension_approver
  validates :button_label, :length => {:maximum => 255}
  validates :approver_dynamic, :inclusion => {:in => DYNAMIC_APPROVERS},
            :allow_blank => true
  validates :position, :numericality => {:only_integer => true, :greater_than_or_equal_to => 0}
  validate :validate_single_approver

  # Wording of the action button for this step.
  def action_label
    button_label.presence || ::I18n.t(:button_approve)
  end

  def assigned?
    approver_role_id.present? || approver_user_id.present? || approver_dynamic.present?
  end

  # True when +user+ matches the step's assignment. Callers still have to check
  # the workflow transition separately; this only answers "is this their step".
  #
  # +issue+ rather than a project, because a dynamic approver is read off the
  # issue -- there is nothing in the configuration to compare against.
  def assigned_to?(user, issue)
    return true unless assigned?
    return false unless user.is_a?(User) && user.logged?
    return user.id == approver_user_id if approver_user_id.present?
    return matches_dynamic?(user, issue) if approver_dynamic.present?

    user.roles_for_project(issue.project).any? {|role| role.id == approver_role_id}
  end

  # The approver as one value, for a single form field. Keeping the columns
  # separate underneath means an assignment stays a real foreign key.
  def approver_token
    return "user:#{approver_user_id}" if approver_user_id.present?
    return "role:#{approver_role_id}" if approver_role_id.present?
    return "dynamic:#{approver_dynamic}" if approver_dynamic.present?

    ''
  end

  # Setting one kind of approver clears the others: a step has exactly one.
  def approver_token=(value)
    kind, id = value.to_s.split(':', 2)
    self.approver_user_id = kind == 'user' ? id.presence : nil
    self.approver_role_id = kind == 'role' ? id.presence : nil
    self.approver_dynamic = kind == 'dynamic' ? id.presence : nil
  end

  def to_s
    name.to_s
  end

  def extension_step?
    approval_route&.extension?
  end

  private

  # A group in the assigned-to field stands for its members, the same way
  # Redmine treats an issue assigned to a group everywhere else.
  def matches_dynamic?(user, issue)
    case approver_dynamic
    when ASSIGNEE
      issue.assigned_to_id.present? &&
        (user.id == issue.assigned_to_id || user.group_ids.include?(issue.assigned_to_id))
    else
      false
    end
  end

  # Without a workflow transition behind it, the named approver is the only
  # thing deciding who may sign an extension step.
  def validate_extension_approver
    return unless extension_step?
    return if assigned?

    errors.add(:base, :extension_step_needs_approver)
  end

  def validate_single_approver
    chosen = [approver_role_id, approver_user_id, approver_dynamic].count(&:present?)
    return if chosen <= 1

    errors.add(:approver_user_id, :only_one_approver_allowed)
  end
end
