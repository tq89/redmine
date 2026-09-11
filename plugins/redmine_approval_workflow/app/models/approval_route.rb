# frozen_string_literal: true

# An ordered chain of approval steps ("lưu trình ký") attached to a tracker,
# optionally narrowed to a single project.
class ApprovalRoute < ApplicationRecord
  belongs_to :tracker
  belongs_to :project, :optional => true
  belongs_to :rejected_status, :class_name => 'IssueStatus', :optional => true

  has_many :steps, lambda {order(:position, :id)},
           :class_name => 'ApprovalRouteStep',
           :foreign_key => 'approval_route_id',
           :dependent => :destroy,
           :inverse_of => :approval_route
  has_many :signatures,
           :class_name => 'ApprovalSignature',
           :foreign_key => 'approval_route_id',
           :dependent => :nullify

  accepts_nested_attributes_for :steps, :allow_destroy => true,
                                :reject_if => proc {|attrs| attrs['issue_status_id'].blank?}

  # Redmine leaves belongs_to_required_by_default unset, so a belongs_to is
  # optional here regardless of the Rails 5+ default. These presence rules are
  # what actually keeps the foreign keys populated.
  validates :name, :presence => true, :length => {:maximum => 255}
  validates :tracker_id, :presence => true

  scope :active, lambda {where(:active => true)}
  scope :sorted, lambda {order(:name, :id)}

  # Returns the route that governs +issue+, or nil.
  #
  # A route bound to the issue's project wins over a global one for the same
  # tracker, so a project can override the organisation-wide chain.
  def self.for_issue(issue)
    return nil if issue.nil? || issue.tracker_id.nil?

    active.
      where(:tracker_id => issue.tracker_id).
      where(:project_id => [nil, issue.project_id]).
      order(Arel.sql('CASE WHEN project_id IS NULL THEN 1 ELSE 0 END'), :id).
      first
  end

  def step_at(position)
    steps.detect {|s| s.position == position}
  end

  def step_count
    steps.size
  end

  def global?
    project_id.nil?
  end

  def to_s
    name.to_s
  end
end
