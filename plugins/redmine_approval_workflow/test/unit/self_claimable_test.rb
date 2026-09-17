# frozen_string_literal: true

require_relative '../test_helper'

# The bell's second list: work nobody has handed you, that you may take on
# anyway because the administrator marked the step skippable and the workflow
# lets you make the move from where the issue stands.
class SelfClaimableTest < ActiveSupport::TestCase
  include RedmineApprovalWorkflow::TestFixtures

  def setup
    User.current = nil
    ApprovalRoute.delete_all
    ApprovalRouteStep.delete_all
    ApprovalRouteApprover.delete_all
    ApprovalSignature.delete_all
    IssueExtension.delete_all
    @user = User.find(2)
    @issue = Issue.find(1)
    EnabledModule.create!(:project_id => @issue.project_id, :name => 'approval_workflow')
    # Statuses 2 then 3: "Giao việc" then "Nhận việc".
    @route = build_route(:tracker_id => @issue.tracker_id, :statuses => [2, 3])
    @first = @route.step_at(0)
    @second = @route.step_at(1)
  end

  def claimable(user = @user)
    RedmineApprovalWorkflow::PendingApprovals.claimable_for_user(user)
  end

  def claimable_ids(user = @user)
    claimable(user).map {|issue, _step| issue.id}
  end

  # The core fixtures put several issues on this tracker, and the route covers
  # all of them, so assertions name the issue they are about.
  def claimed_step(user = @user, issue_id = @issue.id)
    entry = claimable(user).detect {|issue, _step| issue.id == issue_id}
    entry && entry.last
  end

  def pending_ids(user = @user)
    RedmineApprovalWorkflow::PendingApprovals.for_user(user).map(&:id)
  end

  # --- the option off -------------------------------------------------------

  def test_lists_nothing_when_no_step_is_skippable
    assert_equal [], claimable_ids
  end

  def test_lists_nothing_without_a_route
    ApprovalRoute.delete_all

    assert_equal [], claimable_ids
  end

  def test_returns_nothing_for_anonymous
    @second.update!(:allow_skip => true)

    assert_equal [], claimable_ids(User.anonymous)
  end

  # --- the option on --------------------------------------------------------

  def test_lists_a_skippable_step_ahead_of_the_cursor
    @second.update!(:allow_skip => true)
    # The step that is actually due belongs to somebody else, so nothing is
    # waiting for this user -- and yet they can take the job on.
    set_step_approvers(@first, ['user:3'])

    assert_equal @second.id, claimed_step&.id
    assert_not_includes pending_ids, @issue.id, 'it is not waiting on them'
  end

  # Two lists, not the same reminder twice: an issue whose due step this user
  # can already sign belongs under "waiting for me", not under "can take on".
  def test_an_issue_already_waiting_on_the_user_is_not_listed_twice
    @second.update!(:allow_skip => true)

    assert_includes pending_ids, @issue.id
    assert_not_includes claimable_ids, @issue.id
  end

  def test_the_nearest_skippable_step_is_the_one_offered
    route = build_route(:tracker_id => @issue.tracker_id, :statuses => [2, 3, 5])
    ApprovalRoute.where.not(:id => route.id).destroy_all
    set_step_approvers(route.step_at(0), ['user:3'])
    route.step_at(1).update!(:allow_skip => true)
    route.step_at(2).update!(:allow_skip => true)

    assert_equal route.step_at(1).id, claimed_step&.id
  end

  def test_a_finished_chain_offers_nothing
    @second.update!(:allow_skip => true)
    set_step_approvers(@first, ['user:3'])
    [0, 1].each do |position|
      ApprovalSignature.create!(:issue => @issue, :approval_route => @route,
                                :step_position => position, :user_id => 3,
                                :action => ApprovalSignature::APPROVED)
    end

    assert @issue.reload.approval_completed?
    assert_not_includes claimable_ids, @issue.id
  end

  def test_a_step_already_passed_is_not_offered
    @first.update!(:allow_skip => true)
    set_step_approvers(@second, ['user:3'])
    ApprovalSignature.create!(:issue => @issue, :approval_route => @route,
                              :step_position => 0, :user_id => 3,
                              :action => ApprovalSignature::APPROVED)
    @issue.update_columns(:status_id => 2)

    assert_not_includes claimable_ids, @issue.id, 'the chain is already past it'
  end

  # --- it narrows, it never widens ------------------------------------------

  def test_the_step_approver_list_still_applies
    @second.update!(:allow_skip => true)
    # Neither step belongs to jsmith, so nothing puts this issue in front of
    # them; dlopper is named on the skippable one and may take it on.
    set_step_approvers(@first, ['user:4'])
    set_step_approvers(@second, ['user:3'])

    assert_not_includes claimable_ids, @issue.id, 'the step is listed to somebody else'
    assert_includes claimable_ids(User.find(3)), @issue.id
  end

  def test_the_workflow_transition_still_applies
    @second.update!(:allow_skip => true)
    set_step_approvers(@first, ['user:3'])
    # Take away the move from where the issue stands into the step's status.
    WorkflowTransition.where(:tracker_id => @issue.tracker_id, :old_status_id => 1,
                             :new_status_id => 3).delete_all

    assert_equal [], claimable_ids
  end

  def test_the_assignee_slot_reaches_the_assignee_only
    @second.update!(:allow_skip => true)
    set_step_approvers(@first, ['user:3'])
    set_step_approvers(@second, ['dynamic:assignee'])
    @issue.update_columns(:assigned_to_id => @user.id)

    assert_includes claimable_ids, @issue.id
    assert_not_includes claimable_ids(User.find(3)), @issue.id
  end

  def test_excludes_issues_whose_project_lacks_the_module
    @second.update!(:allow_skip => true)
    set_step_approvers(@first, ['user:3'])
    EnabledModule.where(:project_id => @issue.project_id, :name => 'approval_workflow').delete_all

    assert_equal [], claimable_ids
  end

  def test_excludes_closed_issues
    @second.update!(:allow_skip => true)
    set_step_approvers(@first, ['user:3'])
    @issue.update_columns(:status_id => 5)

    assert_not_includes claimable_ids, @issue.id
  end

  # --- it agrees with the controller's authority ----------------------------

  # The bulk lookup reimplements Issue#approval_can_skip_to? for speed, so it
  # has to keep agreeing with it -- that is what ApprovalsController enforces.
  def assert_agrees_with_can_skip_to(message)
    helper = RedmineApprovalWorkflow::PendingApprovals
    fast = helper.claimable_for_user(@user).map {|issue, step| [issue.id, step.id]}.sort

    slow = helper.
           candidates(@user, ApprovalRouteTracker.distinct.pluck(:tracker_id),
                      helper.workflow_role_ids(@user)).
           reject {|issue| issue.can_approve?(@user)}.
           filter_map do |issue|
             step = issue.approval_skippable_steps(@user).min_by(&:position)
             [issue.id, step.id] if step
           end.sort

    assert_equal slow, fast, message
  end

  def test_agrees_with_can_skip_to_for_a_plain_issue
    @second.update!(:allow_skip => true)
    set_step_approvers(@first, ['user:3'])

    assert_agrees_with_can_skip_to 'plain issue'
  end

  def test_agrees_with_can_skip_to_when_the_user_is_the_assignee
    @second.update!(:allow_skip => true)
    set_step_approvers(@first, ['user:3'])
    @issue.update_columns(:author_id => 3, :assigned_to_id => @user.id)

    assert_agrees_with_can_skip_to 'user is assignee'
  end

  def test_agrees_with_can_skip_to_when_the_target_status_is_closed
    route = build_route(:tracker_id => @issue.tracker_id, :statuses => [2, 5])
    ApprovalRoute.where.not(:id => route.id).destroy_all
    set_step_approvers(route.step_at(0), ['user:3'])
    route.step_at(1).update!(:allow_skip => true)

    assert IssueStatus.find(5).is_closed?
    assert_agrees_with_can_skip_to 'closed target status'
  end

  def test_agrees_with_can_skip_to_for_an_issue_with_open_subtasks
    route = build_route(:tracker_id => @issue.tracker_id, :statuses => [2, 5])
    ApprovalRoute.where.not(:id => route.id).destroy_all
    set_step_approvers(route.step_at(0), ['user:3'])
    route.step_at(1).update!(:allow_skip => true)
    Issue.generate!(:project_id => @issue.project_id, :tracker_id => @issue.tracker_id,
                    :status_id => 1, :subject => 'Con', :parent_issue_id => @issue.id)

    assert_not @issue.reload.closable?, 'fixture must have an open subtask'
    assert_agrees_with_can_skip_to 'parent with an open subtask cannot close'
  end

  # --- extension chains -----------------------------------------------------

  def test_an_extension_chain_is_never_offered
    ApprovalRoute.delete_all
    route = build_extension_route(:tracker_id => @issue.tracker_id, :approvers => ['user:3'])
    route.step_at(0).update!(:allow_skip => true)

    assert_equal [], claimable_ids,
                 'extension steps carry no status, so there is nothing to claim into'
  end

  # --- cost -----------------------------------------------------------------

  # The bell renders on every page and now evaluates two lists, so the second
  # one must not reintroduce a per-issue query.
  def test_query_count_does_not_grow_with_issue_volume
    @second.update!(:allow_skip => true)
    set_step_approvers(@first, ['user:3'])

    baseline = count_queries {RedmineApprovalWorkflow::PendingApprovals.evaluate(User.find(2))}

    20.times do |i|
      Issue.generate!(:project_id => @issue.project_id, :tracker_id => @issue.tracker_id,
                      :status_id => 1, :subject => "Ho so #{i}")
    end

    grown = count_queries {RedmineApprovalWorkflow::PendingApprovals.evaluate(User.find(2))}

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
