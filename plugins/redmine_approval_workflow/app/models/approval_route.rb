# frozen_string_literal: true

# An ordered chain of approval steps ("lưu trình ký") covering one or more
# trackers, optionally narrowed to a single project.
class ApprovalRoute < ApplicationRecord
  belongs_to :project, :optional => true
  belongs_to :rejected_status, :class_name => 'IssueStatus', :optional => true

  has_many :approval_route_trackers, :dependent => :delete_all
  has_many :trackers, :through => :approval_route_trackers

  has_many :steps, lambda {order(:position, :id)},
           :class_name => 'ApprovalRouteStep',
           :dependent => :destroy,
           :inverse_of => :approval_route
  has_many :signatures,
           :class_name => 'ApprovalSignature',
           :dependent => :nullify,
           :inverse_of => :approval_route

  # An extension step has no status, so a blank one cannot be the test for an
  # empty row; a row with no name at all is the empty one.
  accepts_nested_attributes_for :steps, :allow_destroy => true,
                                :reject_if => proc {|attrs| attrs['name'].blank?}

  # Redmine leaves belongs_to_required_by_default unset, so a belongs_to is
  # optional here regardless of the Rails 5+ default. These presence rules are
  # what actually keeps the foreign keys populated.
  validates :name, :presence => true, :length => {:maximum => 255}
  validate :validate_trackers

  ISSUE_KIND = 'issue'
  EXTENSION_KIND = 'extension'
  KINDS = [ISSUE_KIND, EXTENSION_KIND].freeze

  validates :kind, :inclusion => {:in => KINDS}

  scope :active, lambda {where(:active => true)}
  scope :sorted, lambda {order(:name, :id)}
  scope :of_kind, lambda {|kind| where(:kind => kind)}

  def extension?
    kind == EXTENSION_KIND
  end

  def covers_tracker?(tracker_id)
    tracker_ids.include?(tracker_id)
  end

  def tracker_names
    trackers.sorted.map(&:name)
  end

  # The chain that governs extension requests on +issue+, or nil.
  def self.extension_for_issue(issue)
    for_issue(issue, EXTENSION_KIND)
  end

  # Returns the route of +kind+ that governs +issue+, or nil.
  #
  # A route bound to the issue's project wins over a global one covering the
  # same tracker, so a project can override the organisation-wide chain.
  def self.for_issue(issue, kind = ISSUE_KIND)
    return nil if issue.nil? || issue.tracker_id.nil?

    active.
      of_kind(kind).
      joins(:approval_route_trackers).
      where(:approval_route_trackers => {:tracker_id => issue.tracker_id}).
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

  private

  # A route covering nothing would silently govern no issue at all.
  def validate_trackers
    errors.add(:tracker_ids, :blank) if trackers.reject(&:marked_for_destruction?).empty?
  end
end
