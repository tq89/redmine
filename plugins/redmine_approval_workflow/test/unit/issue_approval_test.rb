# frozen_string_literal: true

require_relative '../test_helper'

class IssueApprovalTest < ActiveSupport::TestCase
  include RedmineApprovalWorkflow::TestFixtures

  def setup
    User.current = nil
    ApprovalRoute.delete_all
    ApprovalRouteStep.delete_all
    ApprovalSignature.delete_all
    @issue = Issue.find(1)
    @route = build_route(:tracker_id => @issue.tracker_id, :statuses => [2, 3], :rejected_status_id => 6)
  end

  def sign(action, position, status_id)
    ApprovalSignature.create!(
      :issue => @issue,
      :approval_route => @route,
      :approval_route_step => @route.step_at(position),
      :step_position => position,
      :user_id => 2,
      :action => action,
      :to_status_id => status_id
    )
    @issue.reload
  end

  def test_position_starts_at_zero
    assert_equal 0, @issue.approval_position
    assert_equal @route.step_at(0), @issue.current_approval_step
  end

  def test_approving_advances_position
    sign(ApprovalSignature::APPROVED, 0, 2)

    assert_equal 1, @issue.approval_position
    assert_equal 3, @issue.approval_target_status.id
  end

  def test_chain_is_completed_after_last_step
    sign(ApprovalSignature::APPROVED, 0, 2)
    sign(ApprovalSignature::APPROVED, 1, 3)

    assert_equal 2, @issue.approval_position
    assert @issue.approval_completed?
    assert_nil @issue.current_approval_step
  end

  def test_rejecting_sends_back_one_step
    sign(ApprovalSignature::APPROVED, 0, 2)
    sign(ApprovalSignature::REJECTED, 1, 2)

    assert_equal 0, @issue.approval_position
  end

  def test_rejecting_at_first_step_stays_at_zero
    sign(ApprovalSignature::REJECTED, 0, 6)

    assert_equal 0, @issue.approval_position
  end

  def test_reject_target_at_head_is_the_routes_rejected_status
    assert_equal 6, @issue.approval_reject_target_status.id
  end

  def test_reject_target_mid_chain_is_previous_step_status
    sign(ApprovalSignature::APPROVED, 0, 2)
    sign(ApprovalSignature::APPROVED, 1, 3)

    # Position 2: undoing step 1 must land on the status left by step 0.
    assert_equal 2, @issue.approval_position
    assert_equal 2, @issue.approval_reject_target_status.id
  end

  def test_out_of_sync_detects_manual_status_change
    sign(ApprovalSignature::APPROVED, 0, 2)
    @issue.update_column(:status_id, 2)
    assert_not @issue.reload.approval_out_of_sync?, 'issue status 2 matches step 0'

    @issue.update_column(:status_id, 4)
    assert @issue.reload.approval_out_of_sync?
  end

  def test_signable_requires_workflow_transition
    manager = User.find(2)
    assert_equal 1, @issue.status_id

    allowed = @issue.new_statuses_allowed_to(manager).map(&:id)
    assert_includes allowed, 2, 'fixture workflow should allow 1 -> 2 for this user'

    assert @issue.approval_signable_by?(manager, IssueStatus.find(2))
  end

  def test_signable_is_false_for_a_user_without_the_transition
    anonymous = User.anonymous
    assert_not @issue.approval_signable_by?(anonymous, IssueStatus.find(2))
  end

  def test_signable_is_false_without_a_target_status
    assert_not @issue.approval_signable_by?(User.find(2), nil)
  end

  def test_action_label_defaults_and_can_be_overridden
    assert_equal ::I18n.t(:button_approve), @issue.approval_action_label

    @route.step_at(0).update!(:button_label => 'Trình ký')
    assert_equal 'Trình ký', @issue.reload.approval_action_label
  end

  def test_assigned_step_blocks_a_user_outside_the_assignment
    manager = User.find(2)
    assert @issue.can_approve?(manager)

    @route.step_at(0).update!(:approver_user_id => 3)
    assert_not @issue.reload.can_approve?(manager)
  end

  def test_rejecting_is_held_by_the_same_person_as_signing
    @route.step_at(0).update!(:approver_user_id => 3)

    assert_not @issue.reload.can_reject_approval?(User.find(2))
  end

  def test_a_step_cannot_name_both_a_role_and_a_person
    step = @route.step_at(0)
    step.approver_role_id = 1
    step.approver_user_id = 2

    assert_not step.valid?
    assert_includes step.errors.attribute_names, :approver_user_id
  end

  def test_no_route_means_no_approval
    ApprovalRoute.delete_all
    issue = Issue.find(1)

    assert_not issue.approval_route?
    assert_not issue.can_approve?(User.find(2))
  end
end
