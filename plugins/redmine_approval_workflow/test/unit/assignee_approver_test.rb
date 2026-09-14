# frozen_string_literal: true

require_relative '../test_helper'

# A step assigned to "whoever the issue is assigned to". Like every other
# assignment it only ever narrows the workflow -- it can never hand somebody a
# transition the workflow denies them.
class AssigneeApproverTest < ActiveSupport::TestCase
  include RedmineApprovalWorkflow::TestFixtures

  def setup
    User.current = nil
    ApprovalRoute.delete_all
    ApprovalRouteStep.delete_all
    ApprovalSignature.delete_all
    IssueExtension.delete_all
    @issue = Issue.find(1)
    EnabledModule.create!(:project_id => @issue.project_id, :name => 'approval_workflow')
    @route = build_route(:tracker_id => @issue.tracker_id, :statuses => [2, 3])
    @step = @route.step_at(0)
    @step.update!(:approver_dynamic => ApprovalRouteStep::ASSIGNEE)
  end

  # --- the assignment itself ------------------------------------------------

  def test_matches_the_user_the_issue_is_assigned_to
    @issue.update_columns(:assigned_to_id => 2)

    assert @step.assigned_to?(User.find(2), @issue.reload)
    assert_not @step.assigned_to?(User.find(3), @issue)
  end

  def test_matches_a_member_of_the_group_the_issue_is_assigned_to
    group = Group.find(10)
    user = User.find(8)
    group.users << user unless group.users.include?(user)
    @issue.update_columns(:assigned_to_id => group.id)

    assert @step.assigned_to?(user.reload, @issue.reload)
    assert_not @step.assigned_to?(User.find(3), @issue)
  end

  def test_matches_nobody_when_the_issue_is_unassigned
    @issue.update_columns(:assigned_to_id => nil)

    assert_not @step.assigned_to?(User.find(2), @issue.reload)
    assert_not @step.assigned_to?(User.find(3), @issue)
  end

  def test_it_follows_the_issue_when_the_assignee_changes
    @issue.update_columns(:assigned_to_id => 2)
    assert @step.assigned_to?(User.find(2), @issue.reload)

    @issue.update_columns(:assigned_to_id => 3)
    assert_not @step.assigned_to?(User.find(2), @issue.reload)
    assert @step.assigned_to?(User.find(3), @issue)
  end

  # --- it narrows, it never widens ------------------------------------------

  def test_the_assignee_still_needs_the_workflow_transition
    @issue.update_columns(:assigned_to_id => 3)
    # dlopper is a Developer here; take the transition away from that role.
    WorkflowTransition.where(:tracker_id => @issue.tracker_id, :role_id => 2,
                             :old_status_id => 1, :new_status_id => 2).delete_all

    issue = Issue.find(@issue.id)
    assert issue.current_approval_step.assigned_to?(User.find(3), issue),
           'the assignment matches'
    assert_not issue.can_approve?(User.find(3)),
               'but the workflow does not allow the move, so signing is still refused'
  end

  def test_somebody_who_holds_the_transition_but_is_not_the_assignee_cannot_sign
    @issue.update_columns(:assigned_to_id => 3)
    issue = Issue.find(@issue.id)

    assert issue.new_statuses_allowed_to(User.find(2)).include?(IssueStatus.find(2)),
           'jsmith holds this transition'
    assert_not issue.can_approve?(User.find(2)), 'but the step is the assignee\'s'
  end

  def test_the_assignee_who_holds_the_transition_may_sign
    @issue.update_columns(:assigned_to_id => 2)

    assert Issue.find(@issue.id).can_approve?(User.find(2))
  end

  # --- the bell agrees with can_approve? ------------------------------------

  def test_the_reminder_lists_it_only_for_the_assignee
    @issue.update_columns(:assigned_to_id => 2)

    assert_includes RedmineApprovalWorkflow::PendingApprovals.for_user(User.find(2)).map(&:id),
                    @issue.id
    assert_not_includes RedmineApprovalWorkflow::PendingApprovals.for_user(User.find(3)).map(&:id),
                        @issue.id
  end

  # --- the single approver field --------------------------------------------

  def test_approver_token_round_trips
    step = ApprovalRouteStep.new

    step.approver_token = 'dynamic:assignee'
    assert_equal ApprovalRouteStep::ASSIGNEE, step.approver_dynamic
    assert_equal 'dynamic:assignee', step.approver_token

    step.approver_token = 'role:2'
    assert_equal 2, step.approver_role_id
    assert_nil step.approver_dynamic, 'setting one kind must clear the others'
    assert_equal 'role:2', step.approver_token

    step.approver_token = 'user:3'
    assert_equal 3, step.approver_user_id
    assert_nil step.approver_role_id
    assert_equal 'user:3', step.approver_token

    step.approver_token = ''
    assert_nil step.approver_user_id
    assert_equal '', step.approver_token
    assert_not step.assigned?
  end

  def test_only_one_approver_may_be_set_at_a_time
    step = @route.step_at(1)
    step.approver_role_id = 1
    step.approver_dynamic = ApprovalRouteStep::ASSIGNEE

    assert_not step.valid?
    assert_includes step.errors.attribute_names, :approver_user_id
  end

  def test_an_unknown_dynamic_approver_is_rejected
    step = @route.step_at(1)
    step.approver_dynamic = 'whoever'

    assert_not step.valid?
    assert_includes step.errors.attribute_names, :approver_dynamic
  end

  # --- extension chains -----------------------------------------------------

  def test_an_extension_step_may_name_the_assignee
    route = ApprovalRoute.create!(:name => 'GH', :tracker_id => 1,
                                  :kind => ApprovalRoute::EXTENSION_KIND)
    step = route.steps.build(:name => 'Người thực hiện duyệt', :position => 0,
                             :approver_dynamic => ApprovalRouteStep::ASSIGNEE)

    assert step.valid?, step.errors.full_messages.join(', ')
  end

  # --- notifications --------------------------------------------------------

  def test_the_turn_to_sign_mail_goes_to_the_assignee
    ActionMailer::Base.deliveries.clear
    set_plugin_settings('notify_on_pending_approval' => '1')
    Setting.default_language = 'en'
    @issue.update_columns(:assigned_to_id => 3)

    ApprovalMailer.deliver_approval_pending(Issue.find(@issue.id))

    assert_equal [User.find(3).mail], ActionMailer::Base.deliveries.flat_map(&:to).uniq
  end

  def test_no_mail_when_the_issue_is_unassigned
    ActionMailer::Base.deliveries.clear
    set_plugin_settings('notify_on_pending_approval' => '1')
    @issue.update_columns(:assigned_to_id => nil)

    ApprovalMailer.deliver_approval_pending(Issue.find(@issue.id))

    assert_empty ActionMailer::Base.deliveries
  end
end
