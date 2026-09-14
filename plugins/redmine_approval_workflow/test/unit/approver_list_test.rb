# frozen_string_literal: true

require_relative '../test_helper'

# A step holds an ordered list of approvers and a mode: one signature is enough
# (OR), or every name has to sign in the listed order (AND).
class ApproverListTest < ActiveSupport::TestCase
  include RedmineApprovalWorkflow::TestFixtures

  def setup
    User.current = nil
    ApprovalRoute.delete_all
    ApprovalRouteStep.delete_all
    ApprovalRouteApprover.delete_all
    ApprovalSignature.delete_all
    IssueExtension.delete_all
    @issue = Issue.find(1)
    EnabledModule.create!(:project_id => @issue.project_id, :name => 'approval_workflow')
    @route = build_route(:tracker_id => @issue.tracker_id, :statuses => [2, 3])
    @step = @route.step_at(0)
  end

  def sign(user, approver = nil, approved: true)
    issue = Issue.find(@issue.id)
    approver ||= issue.approval_approver_for(user)
    ApprovalSignature.create!(
      :issue => issue, :approval_route => @route,
      :approval_route_step => issue.current_approval_step,
      :approval_route_approver => approver,
      :step_position => issue.approval_position,
      :user => user,
      :action => approved ? ApprovalSignature::APPROVED : ApprovalSignature::REJECTED
    )
  end

  # --- the list -------------------------------------------------------------

  def test_tokens_are_stored_in_the_order_they_are_given
    step = set_step_approvers(@step, ['user:3', 'role:1', 'dynamic:assignee'])

    assert_equal ['user:3', 'role:1', 'dynamic:assignee'], step.approver_tokens
    assert_equal [0, 1, 2], step.ordered_approvers.map(&:position)
  end

  def test_reordering_keeps_the_rows_so_signatures_still_point_at_them
    step = set_step_approvers(@step, ['user:2', 'user:3'])
    ids = step.ordered_approvers.map(&:id)

    step = set_step_approvers(step, ['user:3', 'user:2'])

    assert_equal ['user:3', 'user:2'], step.approver_tokens
    assert_equal ids.sort, step.ordered_approvers.map(&:id).sort,
                 'a reorder must move rows, not replace them'
  end

  def test_dropping_a_token_removes_its_row
    step = set_step_approvers(@step, ['user:2', 'user:3'])

    assert_difference 'ApprovalRouteApprover.count', -1 do
      set_step_approvers(step, ['user:2'])
    end
    assert_equal ['user:2'], step.reload.approver_tokens
  end

  def test_an_empty_list_leaves_the_step_to_the_workflow
    step = set_step_approvers(@step, [])

    assert_not step.assigned?
    assert step.signable_by?(User.find(3), @issue, []), 'no list means anybody the workflow allows'
  end

  def test_the_same_approver_twice_is_stored_once
    step = set_step_approvers(@step, ['user:2', 'user:2'])

    assert_equal ['user:2'], step.approver_tokens
  end

  # --- OR: any one of them --------------------------------------------------

  def test_any_mode_lets_everybody_on_the_list_sign
    step = set_step_approvers(@step, ['user:2', 'user:3'], :mode => ApprovalRouteStep::ANY_MODE)

    assert step.signable_by?(User.find(2), @issue, [])
    assert step.signable_by?(User.find(3), @issue, [])
  end

  def test_any_mode_is_finished_by_one_signature
    set_step_approvers(@step, ['user:2', 'user:3'], :mode => ApprovalRouteStep::ANY_MODE)
    sign(User.find(2))

    assert_equal 1, Issue.find(@issue.id).approval_position,
                 'one signature is all an "any" step asks for'
  end

  def test_somebody_off_the_list_cannot_sign_even_holding_the_transition
    set_step_approvers(@step, ['user:3'])
    issue = Issue.find(@issue.id)

    assert issue.new_statuses_allowed_to(User.find(2)).include?(IssueStatus.find(2)),
           'jsmith holds this transition'
    assert_not issue.can_approve?(User.find(2))
  end

  # --- AND: all of them, in order -------------------------------------------

  def test_all_mode_asks_the_first_name_first
    step = set_step_approvers(@step, ['user:2', 'user:3'], :mode => ApprovalRouteStep::ALL_MODE)

    assert step.signable_by?(User.find(2), @issue, [])
    assert_not step.signable_by?(User.find(3), @issue, []),
               'user 3 is second on the list, so not yet'
  end

  def test_all_mode_does_not_move_the_issue_until_every_name_has_signed
    set_step_approvers(@step, ['user:2', 'user:3'], :mode => ApprovalRouteStep::ALL_MODE)
    sign(User.find(2))

    issue = Issue.find(@issue.id)
    assert_equal 0, issue.approval_position, 'the step is not finished yet'
    assert_equal 1, issue.approval_step_signatures.size
    collected = issue.approval_step_signatures
    assert_not issue.current_approval_step.signable_by?(User.find(2), issue, collected),
               'user 2 has already signed this step'
    assert issue.current_approval_step.signable_by?(User.find(3), issue, collected),
           'it is user 3\'s turn now'

    sign(User.find(3))
    assert_equal 1, Issue.find(@issue.id).approval_position
  end

  def test_all_mode_names_who_is_still_missing
    step = set_step_approvers(@step, ['user:2', 'user:3'], :mode => ApprovalRouteStep::ALL_MODE)
    sign(User.find(2))

    issue = Issue.find(@issue.id)
    waiting = issue.current_approval_step.next_approver(issue.approval_step_signatures)
    assert_equal 3, waiting.approver_user_id
    assert_equal step.ordered_approvers.last.id, waiting.id
  end

  def test_rejecting_part_way_through_clears_what_the_step_collected
    set_step_approvers(@route.step_at(0), ['user:2'], :mode => ApprovalRouteStep::ALL_MODE)
    set_step_approvers(@route.step_at(1), ['user:2', 'user:3'],
                       :mode => ApprovalRouteStep::ALL_MODE)
    sign(User.find(2))
    assert_equal 1, Issue.find(@issue.id).approval_position

    sign(User.find(2))
    assert_equal 1, Issue.find(@issue.id).approval_position, 'step 2 has one of two'

    sign(User.find(3), nil, :approved => false)

    issue = Issue.find(@issue.id)
    assert_equal 0, issue.approval_position, 'a rejection sends the chain back one step'
    assert_equal [], issue.approval_step_signatures,
                 'and what the rejected step had collected no longer counts'
  end

  def test_a_step_filled_in_from_history_counts_as_passed_whole
    set_step_approvers(@step, ['user:2', 'user:3'], :mode => ApprovalRouteStep::ALL_MODE)
    ApprovalSignature.create!(:issue => @issue, :approval_route => @route,
                              :step_position => 0, :user_id => 2,
                              :action => ApprovalSignature::APPROVED,
                              :derived => true)

    assert_equal 1, Issue.find(@issue.id).approval_position,
                 'the history records that the issue moved, not who filled which slot'
  end

  # --- ordering is what "in order" means ------------------------------------

  def test_changing_the_order_changes_who_signs_first
    set_step_approvers(@step, ['user:3', 'user:2'], :mode => ApprovalRouteStep::ALL_MODE)

    step = Issue.find(@issue.id).current_approval_step
    assert step.signable_by?(User.find(3), @issue, [])
    assert_not step.signable_by?(User.find(2), @issue, [])
  end

  # --- notifications --------------------------------------------------------

  def test_all_mode_mails_only_the_next_name
    ActionMailer::Base.deliveries.clear
    set_plugin_settings('notify_on_pending_approval' => '1')
    Setting.default_language = 'en'
    set_step_approvers(@step, ['user:2', 'user:3'], :mode => ApprovalRouteStep::ALL_MODE)

    ApprovalMailer.deliver_approval_pending(Issue.find(@issue.id))

    assert_equal [User.find(2).mail], ActionMailer::Base.deliveries.flat_map(&:to).uniq
  end

  def test_any_mode_mails_everybody_on_the_list
    ActionMailer::Base.deliveries.clear
    set_plugin_settings('notify_on_pending_approval' => '1')
    Setting.default_language = 'en'
    set_step_approvers(@step, ['user:2', 'user:3'], :mode => ApprovalRouteStep::ANY_MODE)

    ApprovalMailer.deliver_approval_pending(Issue.find(@issue.id))

    assert_equal [User.find(2).mail, User.find(3).mail].sort,
                 ActionMailer::Base.deliveries.flat_map(&:to).uniq.sort
  end

  # --- the bell agrees with can_approve? ------------------------------------

  def test_the_reminder_follows_the_same_rule_as_the_buttons
    set_step_approvers(@step, ['user:2', 'user:3'], :mode => ApprovalRouteStep::ALL_MODE)

    [2, 3].each do |user_id|
      user = User.find(user_id)
      fast = RedmineApprovalWorkflow::PendingApprovals.for_user(user).map(&:id).include?(@issue.id)
      slow = Issue.find(@issue.id).can_approve?(user)
      assert_equal slow, fast, "the reminder and can_approve? disagree for user #{user_id}"
    end
  end
end
