# frozen_string_literal: true

# One step of an approval chain. Approving it moves the issue into
# +issue_status+, which is also what decides who is allowed to sign it.
#
# A step carries an ordered list of approvers and a mode saying what "signed"
# means for it:
#
#   any (OR)  -- one signature from anybody on the list finishes the step; the
#                order is only the order they are listed in.
#   all (AND) -- everybody on the list has to sign, and in the listed order:
#                only the next one who has not signed yet may do so.
#
# An empty list means the step follows the workflow alone: anybody the
# transition allows may sign it. A list never widens that -- somebody the
# workflow denies can never sign, whatever is configured here.
class ApprovalRouteStep < ApplicationRecord
  ANY_MODE = 'any'
  ALL_MODE = 'all'
  MODES = [ANY_MODE, ALL_MODE].freeze

  # Where a refusal of this step sends the issue.
  #
  #   previous -- back down the chain: the status left by the step before the
  #               one being undone, or the route's rejected status at the head.
  #               What every chain did before this was configurable.
  #   keep     -- nowhere. The refusal is recorded and whoever has to act on it
  #               is told, but the issue stays exactly where it is.
  #   status   -- into +reject_status+, whatever the chain is doing.
  REJECT_PREVIOUS = 'previous'
  REJECT_KEEP = 'keep'
  REJECT_STATUS = 'status'
  REJECT_MODES = [REJECT_PREVIOUS, REJECT_KEEP, REJECT_STATUS].freeze

  belongs_to :approval_route, :inverse_of => :steps
  belongs_to :issue_status, :optional => true
  belongs_to :reject_status, :class_name => 'IssueStatus', :optional => true

  has_many :approvers, lambda {order(:position, :id)},
           :class_name => 'ApprovalRouteApprover',
           :dependent => :destroy,
           :autosave => true,
           :inverse_of => :approval_route_step

  validates :name, :presence => true, :length => {:maximum => 255}
  # An extension step names its approvers rather than a status to move into.
  validates :issue_status_id, :presence => true, :unless => :extension_step?
  validate :validate_extension_approver
  validates :button_label, :length => {:maximum => 255}
  validates :approval_mode, :inclusion => {:in => MODES}
  validates :reject_mode, :inclusion => {:in => REJECT_MODES}
  validates :position, :numericality => {:only_integer => true, :greater_than_or_equal_to => 0}
  # A step told to reject into a status has to name one, or the button would
  # vanish again for exactly the reason this setting exists.
  validates :reject_status_id, :presence => true, :if => :reject_into_status?
  before_validation :clear_unused_reject_status

  # Wording of the action button for this step.
  def action_label
    button_label.presence || ::I18n.t(:button_approve)
  end

  # "Nhận việc": the signature that finishes this step also hands the issue to
  # whoever gave it. Only issue steps -- an extension request decides a date and
  # has no business moving the work to somebody else.
  def assigns_signer?
    assign_signer? && !extension_step?
  end

  # A step that may be signed without waiting for the ones before it, when the
  # workflow allows the move from wherever the issue currently is. That is what
  # lets somebody take a job on without being given it first.
  def skippable?
    allow_skip? && !extension_step?
  end

  # "Giao việc": the signature that finishes this step makes the signer the
  # issue's author -- the person who handed the work out. Useful on an issue
  # raised by something other than a person, a recurring-task generator say,
  # where whoever assigns the work is the one who really owns raising it.
  def assigns_author?
    assign_author? && !extension_step?
  end

  # A refusal that moves nothing. There is then no status change to read the
  # signing permission off, so the rule becomes the plain one: whoever may sign
  # this step is who may refuse it.
  def reject_keeps_status?
    reject_mode == REJECT_KEEP && !extension_step?
  end

  # A refusal that sends the issue into one named status, wherever the chain
  # happens to be.
  def reject_into_status?
    reject_mode == REJECT_STATUS && !extension_step?
  end

  def any_mode?
    approval_mode != ALL_MODE
  end

  def all_mode?
    approval_mode == ALL_MODE
  end

  # In form order, with rows the form dropped left out.
  def ordered_approvers
    approvers.reject(&:marked_for_destruction?).sort_by {|a| [a.position.to_i, a.id.to_i]}
  end

  def assigned?
    ordered_approvers.any?
  end

  # The approver list as one ordered list of tokens, which is how the form
  # posts it: a row of chips whose order is the order of the inputs.
  def approver_tokens
    return @approver_tokens if @approver_tokens

    ordered_approvers.map(&:token)
  end

  def approver_tokens=(values)
    @approver_tokens = Array(values).map(&:to_s).reject(&:blank?).uniq
    rebuild_approvers
  end

  # True when +user+ appears anywhere on the list. Used for showing who a step
  # belongs to, not for deciding whether they may sign it now.
  def matches_any_approver?(user, issue)
    return true unless assigned?

    ordered_approvers.any? {|approver| approver.matches?(user, issue)}
  end

  # The approvers who may sign right now, given what has been signed already:
  # everybody in "any" mode, only the next one in "all" mode.
  #
  # +signatures+ is required rather than defaulted: an "all" step answers a
  # different question with an empty list, and a caller that forgot to pass
  # what the step has collected would get a confidently wrong answer.
  def open_approvers(signatures)
    return [] unless assigned?
    return ordered_approvers if any_mode?

    Array(next_approver(signatures))
  end

  # The first entry on the list that has not signed yet.
  def next_approver(signatures)
    signed = Array(signatures).select(&:approved?).filter_map(&:approval_route_approver_id)
    ordered_approvers.detect {|approver| !signed.include?(approver.id)}
  end

  # Authoritative "may this user sign this step now". The caller still has to
  # check the workflow transition separately.
  def signable_by?(user, issue, signatures)
    return true unless assigned?

    open_approvers(signatures).any? {|approver| approver.matches?(user, issue)}
  end

  # Which slot +user+ is filling, so the signature can record it.
  def approver_for(user, issue, signatures)
    open_approvers(signatures).detect {|approver| approver.matches?(user, issue)}
  end

  # Has this step collected everything it needs?
  def satisfied_by?(signatures)
    approved = Array(signatures).select(&:approved?)
    return false if approved.empty?
    # A step filled in from the issue's status history counts as passed whole:
    # the history records that the issue moved, not who filled which slot.
    return true if approved.any?(&:derived?)
    return true unless assigned?
    return true if any_mode?

    signed = approved.filter_map(&:approval_route_approver_id)
    ordered_approvers.all? {|approver| signed.include?(approver.id)}
  end

  def to_s
    name.to_s
  end

  def extension_step?
    approval_route&.extension?
  end

  private

  # Rebuilds the list from the posted tokens, keeping rows that are still
  # there so their id -- and therefore the signatures pointing at it -- survive
  # a reorder.
  def rebuild_approvers
    kept = []
    @approver_tokens.each_with_index do |token, index|
      approver = approvers.detect {|a| a.token == token && !kept.include?(a)}
      approver ||= approvers.build
      approver.token = token
      approver.position = index
      kept << approver
    end
    (approvers.to_a - kept).each(&:mark_for_destruction)
  end

  # A status left over from a mode the step no longer uses would sit in the
  # form looking like it still applied.
  def clear_unused_reject_status
    self.reject_status_id = nil unless reject_into_status?
  end

  # Without a workflow transition behind it, the approver list is the only
  # thing deciding who may sign an extension step.
  def validate_extension_approver
    return unless extension_step?
    return if assigned?

    errors.add(:base, :extension_step_needs_approver)
  end
end
