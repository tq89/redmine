# frozen_string_literal: true

# One entry in a step's approver list: a role, one person, or a slot the issue
# fills in ("whoever it is assigned to").
#
# Exactly one of the three is set. Which one is chosen never widens what the
# workflow allows -- it only narrows who, among those the workflow already
# permits, is being asked.
class ApprovalRouteApprover < ApplicationRecord
  ASSIGNEE = 'assignee'
  AUTHOR = 'author'
  DYNAMIC_APPROVERS = [ASSIGNEE, AUTHOR].freeze

  belongs_to :approval_route_step, :inverse_of => :approvers
  belongs_to :approver_role, :class_name => 'Role', :optional => true
  belongs_to :approver_user, :class_name => 'User', :optional => true

  validates :position, :numericality => {:only_integer => true, :greater_than_or_equal_to => 0}
  validates :approver_dynamic, :inclusion => {:in => DYNAMIC_APPROVERS}, :allow_blank => true
  validate :validate_exactly_one

  # How this entry is written in a form field and compared for equality.
  def token
    return "user:#{approver_user_id}" if approver_user_id.present?
    return "role:#{approver_role_id}" if approver_role_id.present?
    return "dynamic:#{approver_dynamic}" if approver_dynamic.present?

    ''
  end

  def token=(value)
    kind, id = value.to_s.split(':', 2)
    self.approver_user_id = kind == 'user' ? id.presence : nil
    self.approver_role_id = kind == 'role' ? id.presence : nil
    self.approver_dynamic = kind == 'dynamic' ? id.presence : nil
  end

  def set?
    token.present?
  end

  # True when +user+ is this approver, on this issue. A group in the assigned-to
  # field stands for its members, as it does everywhere else in Redmine.
  def matches?(user, issue)
    return false unless user.is_a?(User) && user.logged?
    return user.id == approver_user_id if approver_user_id.present?

    case approver_dynamic
    when ASSIGNEE
      return issue.assigned_to_id.present? &&
             (user.id == issue.assigned_to_id || user.group_ids.include?(issue.assigned_to_id))
    when AUTHOR
      return issue.author_id.present? && user.id == issue.author_id
    end

    return false if approver_role_id.blank?

    user.roles_for_project(issue.project).any? {|role| role.id == approver_role_id}
  end

  # The users this entry stands for, for notifications. A role means every
  # member of the project holding it.
  def users_for(issue)
    return Array(User.active.find_by_id(approver_user_id)) if approver_user_id.present?
    return assignee_users(issue) if approver_dynamic == ASSIGNEE
    return Array(issue.author).select(&:active?) if approver_dynamic == AUTHOR
    return [] if approver_role_id.blank?

    User.active.
      joins(:members => :member_roles).
      where(:members => {:project_id => issue.project_id}).
      where(:member_roles => {:role_id => approver_role_id}).
      distinct.
      to_a
  end

  def to_s
    label
  end

  def label
    return approver_user.name if approver_user
    return approver_role.name if approver_role
    return ::I18n.t(:"label_approver_#{approver_dynamic}") if approver_dynamic.present?

    ''
  end

  private

  def assignee_users(issue)
    assignee = issue.assigned_to
    return [] if assignee.nil?
    return assignee.users.active.to_a if assignee.is_a?(Group)

    assignee.active? ? [assignee] : []
  end

  def validate_exactly_one
    chosen = [approver_role_id, approver_user_id, approver_dynamic].count(&:present?)
    return if chosen == 1

    errors.add(:base, chosen.zero? ? :approver_missing : :approver_ambiguous)
  end
end
