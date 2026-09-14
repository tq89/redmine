# frozen_string_literal: true

require_relative '../test_helper'

class PendingApprovalsTest < ActiveSupport::TestCase
  include RedmineApprovalWorkflow::TestFixtures

  def setup
    User.current = nil
    ApprovalRoute.delete_all
    ApprovalRouteStep.delete_all
    ApprovalSignature.delete_all
    @user = User.find(2)
    @issue = Issue.find(1)
    EnabledModule.create!(:project_id => @issue.project_id, :name => 'approval_workflow')
  end

  def pending_ids(user = @user)
    RedmineApprovalWorkflow::PendingApprovals.for_user(user).map(&:id)
  end

  def test_lists_an_issue_waiting_for_the_user
    build_route(:tracker_id => @issue.tracker_id, :statuses => [2, 3])

    assert_includes pending_ids, @issue.id
  end

  def test_lists_nothing_without_a_route
    assert_equal [], pending_ids
  end

  def test_excludes_issues_the_user_cannot_transition
    build_route(:tracker_id => @issue.tracker_id, :statuses => [2, 3])
    WorkflowTransition.where(:tracker_id => @issue.tracker_id, :old_status_id => 1).delete_all

    assert_not_includes pending_ids, @issue.id
  end

  def test_excludes_issues_whose_project_lacks_the_module
    build_route(:tracker_id => @issue.tracker_id, :statuses => [2, 3])
    EnabledModule.where(:project_id => @issue.project_id, :name => 'approval_workflow').delete_all

    assert_not_includes pending_ids, @issue.id
  end

  def test_excludes_a_completed_chain
    route = build_route(:tracker_id => @issue.tracker_id, :statuses => [2, 3])
    [0, 1].each do |position|
      ApprovalSignature.create!(:issue => @issue, :approval_route => route,
                                :step_position => position, :user_id => 2,
                                :action => ApprovalSignature::APPROVED)
    end

    assert @issue.reload.approval_completed?
    assert_not_includes pending_ids, @issue.id
  end

  def test_excludes_closed_issues
    build_route(:tracker_id => @issue.tracker_id, :statuses => [2, 3])
    @issue.update_columns(:status_id => 5) # Closed

    assert_not_includes pending_ids, @issue.id
  end

  def test_returns_nothing_for_anonymous
    build_route(:tracker_id => @issue.tracker_id, :statuses => [2, 3])

    assert_equal [], pending_ids(User.anonymous)
  end

  def test_advancing_a_step_moves_the_issue_out_of_the_list_for_that_step
    route = build_route(:tracker_id => @issue.tracker_id, :statuses => [2, 3])
    assert_includes pending_ids, @issue.id

    # Sign step 0 but leave the issue in a status with no outgoing transition
    # for this user: it must drop off the list.
    ApprovalSignature.create!(:issue => @issue, :approval_route => route,
                              :step_position => 0, :user_id => 2,
                              :action => ApprovalSignature::APPROVED)
    @issue.update_columns(:status_id => 2)
    WorkflowTransition.where(:tracker_id => @issue.tracker_id, :old_status_id => 2).delete_all

    assert_not_includes pending_ids(User.find(2)), @issue.id
  end

  # A step that names its approver must not reach anybody else: not the panel,
  # not the bell, not the mail.
  def test_step_assigned_to_a_role_reaches_only_that_role
    route = build_route(:tracker_id => @issue.tracker_id, :statuses => [2, 3])
    route.step_at(0).update!(:approver_tokens => ['role:1'])

    assert_includes pending_ids(User.find(2)), @issue.id, 'jsmith holds role 1'

    route.step_at(0).update!(:approver_tokens => ['role:2'])
    assert_not_includes pending_ids(User.find(2)), @issue.id,
                        'jsmith does not hold role 2 on this project'
  end

  def test_step_assigned_to_a_person_reaches_only_them
    route = build_route(:tracker_id => @issue.tracker_id, :statuses => [2, 3])
    route.step_at(0).update!(:approver_tokens => ['user:2'])

    assert_includes pending_ids(User.find(2)), @issue.id

    route.step_at(0).update!(:approver_tokens => ['user:3'])
    assert_not_includes pending_ids(User.find(2)), @issue.id
  end

  def test_assignment_narrows_and_never_widens
    route = build_route(:tracker_id => @issue.tracker_id, :statuses => [2, 3])
    # Name a user who has no workflow transition into the step's status.
    route.step_at(0).update!(:approver_tokens => ['user:2'])
    WorkflowTransition.where(:tracker_id => @issue.tracker_id, :old_status_id => 1,
                             :new_status_id => 2).delete_all

    assert_not_includes pending_ids(User.find(2)), @issue.id,
                        'being named cannot grant a transition the workflow denies'
  end

  def test_unassigned_step_is_open_to_anyone_the_workflow_allows
    build_route(:tracker_id => @issue.tracker_id, :statuses => [2, 3])

    assert_includes pending_ids(User.find(2)), @issue.id
  end

  def test_agrees_with_can_approve_for_an_assigned_step
    route = build_route(:tracker_id => @issue.tracker_id, :statuses => [2, 3])
    route.step_at(0).update!(:approver_tokens => ['role:2'])

    assert_agrees_with_can_approve 'step assigned to a role the user lacks'
  end

  # The bulk lookup reimplements Issue#can_approve? for speed, so it has to
  # keep agreeing with it. These cases cover the branches that differ most:
  # author/assignee transitions, closed targets and subtasks.
  def assert_agrees_with_can_approve(message)
    helper = RedmineApprovalWorkflow::PendingApprovals
    fast = helper.for_user(@user).map(&:id).sort
    slow = helper.
           candidates(@user, ApprovalRouteTracker.distinct.pluck(:tracker_id),
                      helper.workflow_role_ids(@user)).
           select {|issue| issue.can_approve?(@user)}.map(&:id).sort

    assert_equal slow, fast, message
  end

  def test_agrees_with_can_approve_for_a_plain_issue
    build_route(:tracker_id => @issue.tracker_id, :statuses => [2, 3])

    assert_agrees_with_can_approve 'plain issue'
  end

  def test_agrees_with_can_approve_when_user_is_author
    build_route(:tracker_id => @issue.tracker_id, :statuses => [2, 3])
    @issue.update_columns(:author_id => @user.id, :assigned_to_id => nil)

    assert_agrees_with_can_approve 'user is author'
  end

  def test_agrees_with_can_approve_when_user_is_assignee
    build_route(:tracker_id => @issue.tracker_id, :statuses => [2, 3])
    @issue.update_columns(:author_id => 3, :assigned_to_id => @user.id)

    assert_agrees_with_can_approve 'user is assignee'
  end

  def test_agrees_with_can_approve_when_target_status_is_closed
    build_route(:tracker_id => @issue.tracker_id, :statuses => [5, 3])

    assert IssueStatus.find(5).is_closed?
    assert_agrees_with_can_approve 'closed target status'
  end

  def test_agrees_with_can_approve_for_an_issue_with_open_subtasks
    build_route(:tracker_id => @issue.tracker_id, :statuses => [5, 3])
    Issue.generate!(:project_id => @issue.project_id, :tracker_id => @issue.tracker_id,
                    :status_id => 1, :subject => 'Con', :parent_issue_id => @issue.id)

    assert_not @issue.reload.closable?, 'fixture must have an open subtask'
    assert_agrees_with_can_approve 'parent with an open subtask cannot close'
  end

  def test_agrees_with_can_approve_for_a_transition_restricted_to_the_author
    build_route(:tracker_id => @issue.tracker_id, :statuses => [2, 3])
    WorkflowTransition.where(:tracker_id => @issue.tracker_id, :old_status_id => 1,
                             :new_status_id => 2).update_all(:author => true)
    @issue.update_columns(:author_id => 3)

    assert_agrees_with_can_approve 'author-only transition, user is not the author'
  end

  # The reminder renders on every page, so its cost must not scale with the
  # number of issues in the instance.
  def test_query_count_does_not_grow_with_issue_volume
    build_route(:tracker_id => @issue.tracker_id, :statuses => [2, 3])

    baseline = count_queries {RedmineApprovalWorkflow::PendingApprovals.for_user(User.find(2))}

    20.times do |i|
      Issue.generate!(:project_id => @issue.project_id, :tracker_id => @issue.tracker_id,
                      :status_id => 1, :subject => "Ho so #{i}")
    end

    grown = count_queries {RedmineApprovalWorkflow::PendingApprovals.for_user(User.find(2))}

    assert grown <= baseline + 21,
           "expected the lookup to stay bounded, went from #{baseline} to #{grown} queries"
  end

  def count_queries(&)
    count = 0
    counter = lambda do |_name, _start, _finish, _id, payload|
      count += 1 unless payload[:name].in?(%w[CACHE SCHEMA]) || payload[:sql] =~ /^\s*(BEGIN|COMMIT|ROLLBACK|SAVEPOINT|RELEASE)/i
    end
    ActiveSupport::Notifications.subscribed(counter, 'sql.active_record', &)
    count
  end
end
