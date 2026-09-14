# frozen_string_literal: true

# Audit record of one signature. The chain's progress is derived from these
# rows rather than from the issue status, so that a status edited by hand
# outside the chain cannot silently skip a step.
class ApprovalSignature < ApplicationRecord
  APPROVED = 'approved'
  REJECTED = 'rejected'
  ACTIONS = [APPROVED, REJECTED].freeze

  belongs_to :issue
  belongs_to :issue_extension, :optional => true
  belongs_to :approval_route
  belongs_to :approval_route_step, :optional => true
  belongs_to :user
  belongs_to :from_status, :class_name => 'IssueStatus', :optional => true
  belongs_to :to_status, :class_name => 'IssueStatus', :optional => true
  belongs_to :journal, :optional => true

  validates :action, :inclusion => {:in => ACTIONS}
  validates :issue_id, :approval_route_id, :user_id, :presence => true

  scope :sorted, lambda {order(:id)}
  # Signatures on the issue's own chain. An extension request keeps its
  # signatures in the same table and carries the issue_id for context, so the
  # issue chain has to say explicitly that it does not want them.
  scope :on_issue_chain, lambda {where(:issue_extension_id => nil)}

  def for_extension?
    issue_extension_id.present?
  end

  def approved?
    action == APPROVED
  end

  def rejected?
    action == REJECTED
  end

  # Reconciled from the issue's status history rather than signed by hand.
  def derived?
    derived == true
  end

  def signed?
    !derived?
  end
end
