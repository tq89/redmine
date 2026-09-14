# frozen_string_literal: true

require_relative '../test_helper'

# Every way an issue can stop needing a given user, and the assertion that it
# then leaves that user's bell. A reminder that keeps showing work already done
# is worse than no reminder: people stop reading it.
class NotificationClearingTest < ActiveSupport::TestCase
  include RedmineApprovalWorkflow::TestFixtures

  Pending = RedmineApprovalWorkflow::PendingApprovals

  def setup
    User.current = nil
    ApprovalRoute.delete_all
    ApprovalRouteStep.delete_all
    ApprovalSignature.delete_all
    IssueExtension.delete_all
    @user = User.find(2)
    @issue = Issue.find(1)
    @issue.journals.delete_all
    EnabledModule.create!(:project_id => @issue.project_id, :name => 'approval_workflow')
    set_plugin_settings('sync_status_from_history' => '1')
    @route = build_route(:tracker_id => @issue.tracker_id, :statuses => [2, 3])
  end

  def pending?(user = @user)
    Pending.for_user(User.find(user.id)).map(&:id).include?(@issue.id)
  end

  # The core fixtures give role 1 a transition between every pair of statuses,
  # jsmith included, so "this step is not mine" has to be created deliberately.
  def revoke_transition!(from_status, to_status, role_id = 1)
    WorkflowTransition.where(:tracker_id => @issue.tracker_id, :role_id => role_id,
                             :old_status_id => from_status,
                             :new_status_id => to_status).delete_all
  end

  def sign_step!(position, status_id, user_id = 2)
    ApprovalSignature.create!(:issue => @issue, :approval_route => @route,
                              :approval_route_step => @route.step_at(position),
                              :step_position => position, :user_id => user_id,
                              :action => ApprovalSignature::APPROVED,
                              :to_status_id => status_id)
    @issue.update_columns(:status_id => status_id)
    @issue.reload
  end

  def test_it_is_there_to_begin_with
    assert pending?, 'the fixture must start with something to sign'
  end

  def test_clears_after_signing_when_the_next_step_is_not_theirs
    revoke_transition!(2, 3)
    sign_step!(0, 2)

    assert_not pending?, 'a signed step must leave the signer alone'
  end

  # The other half of the same rule, and the reason the case above needs the
  # revoke: while the next step is still theirs, it must keep showing.
  def test_stays_when_the_next_step_is_also_theirs
    sign_step!(0, 2)

    assert pending?, 'consecutive steps held by one person must keep showing'
  end

  def test_clears_when_the_chain_completes
    sign_step!(0, 2)
    sign_step!(1, 3)

    assert @issue.reload.approval_completed?
    assert_not pending?
  end

  def test_clears_when_the_issue_is_closed
    @issue.update_columns(:status_id => 5) # Closed
    assert_not pending?
  end

  def test_clears_when_somebody_else_signs_it
    revoke_transition!(2, 3)
    sign_step!(0, 2, 3) # dlopper signs step 0

    assert_not pending?, 'work taken by a colleague must stop nagging'
  end

  # The reconciler is what makes this work: an ordinary edit advances the chain,
  # so the bell follows a status changed outside the approval screen.
  def test_clears_when_the_status_moves_by_an_ordinary_edit
    assert pending?
    revoke_transition!(2, 3)

    issue = Issue.find(@issue.id)
    issue.init_journal(User.find(2))
    issue.status_id = 2
    issue.save!

    assert_equal 1, issue.reload.approval_position
    assert_not pending?
  end

  def test_clears_when_the_step_is_reassigned_to_someone_else
    assert pending?
    @route.step_at(0).update!(:approver_tokens => ['user:3'])

    assert_not pending?, 'a step handed to somebody else is no longer mine'
  end

  def test_clears_when_the_route_is_deactivated
    assert pending?
    @route.update!(:active => false)

    assert_not pending?
  end

  def test_clears_when_the_project_module_is_switched_off
    assert pending?
    EnabledModule.where(:project_id => @issue.project_id,
                        :name => 'approval_workflow').delete_all

    assert_not pending?
  end

  def test_clears_when_the_user_loses_the_transition
    assert pending?
    WorkflowTransition.where(:tracker_id => @issue.tracker_id, :old_status_id => 1,
                             :new_status_id => 2).delete_all

    assert_not pending?
  end

  def test_clears_when_the_issue_is_deleted
    assert pending?
    @issue.destroy

    assert_equal [], Pending.for_user(User.find(2)).map(&:id) & [@issue.id]
    assert_equal 0, ApprovalSignature.where(:issue_id => @issue.id).count,
                 'signatures must go with the issue'
  end

  # The overdue half of the bell has its own "handled" condition.
  def test_overdue_clears_once_the_due_date_is_extended
    @issue.update_columns(:assigned_to_id => 2, :due_date => Date.today - 3)
    assert_includes User.find(2).overdue_issues.map(&:id), @issue.id

    @issue.update_columns(:due_date => Date.today + 7)
    assert_not_includes User.find(2).overdue_issues.map(&:id), @issue.id
  end

  def test_overdue_clears_once_the_issue_is_closed
    @issue.update_columns(:assigned_to_id => 2, :due_date => Date.today - 3)
    assert_includes User.find(2).overdue_issues.map(&:id), @issue.id

    @issue.update_columns(:status_id => 5)
    assert_not_includes User.find(2).overdue_issues.map(&:id), @issue.id
  end

  def test_overdue_clears_once_reassigned
    @issue.update_columns(:assigned_to_id => 2, :due_date => Date.today - 3)
    assert_includes User.find(2).overdue_issues.map(&:id), @issue.id

    @issue.update_columns(:assigned_to_id => 3)
    assert_not_includes User.find(2).overdue_issues.map(&:id), @issue.id
  end
end
