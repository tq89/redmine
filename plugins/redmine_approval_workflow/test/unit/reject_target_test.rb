# frozen_string_literal: true

require_relative '../test_helper'

# Where a refusal sends the issue, and who is allowed to make it.
class RejectTargetTest < ActiveSupport::TestCase
  include RedmineApprovalWorkflow::TestFixtures

  def setup
    User.current = nil
    ApprovalRoute.delete_all
    ApprovalRouteStep.delete_all
    ApprovalRouteApprover.delete_all
    ApprovalSignature.delete_all
    @issue = Issue.find(1)
    EnabledModule.create!(:project_id => @issue.project_id, :name => 'approval_workflow')
    @route = build_route(:tracker_id => @issue.tracker_id, :statuses => [2, 3])
    @first = @route.step_at(0)
    @second = @route.step_at(1)
    @user = User.find(2)
  end

  def issue
    Issue.find(@issue.id)
  end

  def sign(position, user_id = 2)
    ApprovalSignature.create!(:issue => @issue, :approval_route => @route,
                              :step_position => position, :user_id => user_id,
                              :action => ApprovalSignature::APPROVED)
  end

  # --- the bug: a route with no rejected status had no reject button ---------

  # This is what the chains in the field looked like: nobody filled in the
  # route's "Trạng thái khi bị từ chối", so at the first two positions there
  # was nowhere to send a refusal and the button simply never rendered.
  def test_without_a_reject_target_there_is_no_reject_button
    assert_nil @route.rejected_status
    assert_nil issue.approval_reject_target_status
    assert_not issue.can_reject_approval?(@user)
  end

  # ...and the panel says why, instead of leaving an administrator hunting for
  # a button that was never going to appear.
  def test_the_panel_explains_the_missing_button
    assert issue.can_approve?(@user), 'the user can act on this step'
    assert_equal :warning_no_reject_status, issue.approval_reject_hint(@user)
  end

  def test_no_hint_once_the_step_says_where_a_refusal_goes
    @first.update!(:reject_mode => ApprovalRouteStep::REJECT_KEEP)

    assert issue.can_reject_approval?(@user)
    assert_nil issue.approval_reject_hint(@user)
  end

  def test_no_hint_for_somebody_who_cannot_act_on_the_step_at_all
    set_step_approvers(@first, ['user:3'])

    assert_nil issue.approval_reject_hint(@user),
               'nothing is missing for them; the step is simply not theirs'
  end

  # --- "trả về bước trước": unchanged -----------------------------------------

  def test_the_route_status_is_still_used_at_the_head_of_the_chain
    @route.update!(:rejected_status_id => 6)

    assert_equal IssueStatus.find(6), issue.approval_reject_target_status
  end

  def test_further_down_the_chain_it_is_still_the_earlier_step
    sign(0)
    sign(1)
    @issue.update_columns(:status_id => 3)

    assert_equal 2, issue.approval_position
    assert_equal @first.issue_status, issue.approval_reject_target_status
  end

  # --- "giữ nguyên trạng thái" ------------------------------------------------

  def test_keep_targets_the_status_the_issue_is_already_in
    @first.update!(:reject_mode => ApprovalRouteStep::REJECT_KEEP)

    assert_equal issue.status, issue.approval_reject_target_status
  end

  # Nothing moves, so there is no transition to read the permission off. The
  # rule becomes the plain one: whoever may sign the step may refuse it.
  def test_keep_is_allowed_to_whoever_may_sign_the_step
    @first.update!(:reject_mode => ApprovalRouteStep::REJECT_KEEP)
    set_step_approvers(@first, ['user:2'])

    assert issue.can_reject_approval?(@user)
    assert_not issue.can_reject_approval?(User.find(3)),
               'the step belongs to somebody else'
  end

  def test_keep_still_needs_the_step_transition
    @first.update!(:reject_mode => ApprovalRouteStep::REJECT_KEEP)
    WorkflowTransition.where(:tracker_id => @issue.tracker_id, :role_id => 1,
                             :old_status_id => 1, :new_status_id => 2).delete_all

    assert_not issue.can_approve?(@user)
    assert_not issue.can_reject_approval?(@user),
               'refusing a step you could never sign is not a refusal, it is an edit'
  end

  # --- "chuyển sang trạng thái đã chọn" ---------------------------------------

  def test_a_named_status_is_used_wherever_the_chain_is
    @first.update!(:reject_mode => ApprovalRouteStep::REJECT_STATUS,
                   :reject_status_id => 6)

    assert_equal IssueStatus.find(6), issue.approval_reject_target_status
  end

  def test_a_named_status_still_needs_the_workflow_transition
    @first.update!(:reject_mode => ApprovalRouteStep::REJECT_STATUS,
                   :reject_status_id => 6)
    WorkflowTransition.where(:tracker_id => @issue.tracker_id, :role_id => 1,
                             :old_status_id => 1, :new_status_id => 6).delete_all

    assert_not issue.can_reject_approval?(@user)
  end

  def test_the_step_overrides_the_route_status
    @route.update!(:rejected_status_id => 6)
    @first.update!(:reject_mode => ApprovalRouteStep::REJECT_STATUS,
                   :reject_status_id => 5)

    assert_equal IssueStatus.find(5), issue.approval_reject_target_status
  end

  # --- the model --------------------------------------------------------------

  def test_a_step_rejecting_into_a_status_must_name_one
    @first.reject_mode = ApprovalRouteStep::REJECT_STATUS

    assert_not @first.valid?
    assert_includes @first.errors.attribute_names, :reject_status_id
  end

  def test_an_unknown_reject_mode_is_refused
    @first.reject_mode = 'whenever'

    assert_not @first.valid?
    assert_includes @first.errors.attribute_names, :reject_mode
  end

  def test_switching_away_from_status_mode_clears_the_status
    @first.update!(:reject_mode => ApprovalRouteStep::REJECT_STATUS,
                   :reject_status_id => 6)
    @first.update!(:reject_mode => ApprovalRouteStep::REJECT_KEEP)

    assert_nil @first.reload.reject_status_id,
               'a status left behind would read as if it still applied'
  end

  def test_steps_default_to_the_behaviour_they_already_had
    assert_equal ApprovalRouteStep::REJECT_PREVIOUS, @first.reject_mode
    assert_not @first.reject_keeps_status?
    assert_not @first.reject_into_status?
  end

  # An extension request is decided by ExtensionApproval and never touches the
  # issue status, so these settings have nothing to act on there.
  def test_an_extension_step_ignores_the_reject_mode
    route = build_extension_route(:approvers => ['user:2'])
    step = route.step_at(0)
    step.update_columns(:reject_mode => ApprovalRouteStep::REJECT_KEEP)

    assert_not step.reload.reject_keeps_status?
    assert_not step.reject_into_status?
  end
end
