# frozen_string_literal: true

require_relative '../test_helper'

# The bell's notice that your work came back.
class RejectedApprovalsTest < ActiveSupport::TestCase
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
    @user = User.find(2)
  end

  def record(action, position: 0, user_id: 3)
    ApprovalSignature.create!(:issue => @issue, :approval_route => @route,
                              :step_position => position, :user_id => user_id,
                              :action => action, :step_name => 'Duyệt')
  end

  def rejected_ids(user = @user)
    RedmineApprovalWorkflow::RejectedApprovals.for_user(user).map {|issue, _sig| issue.id}
  end

  # --- who is told ------------------------------------------------------------

  def test_the_assignee_sees_their_refused_work
    @issue.update_columns(:assigned_to_id => @user.id)
    record(ApprovalSignature::REJECTED)

    assert_includes rejected_ids, @issue.id
    assert_not_includes rejected_ids(User.find(3)), @issue.id
  end

  def test_a_member_of_the_assigned_group_sees_it
    group = Group.find(10)
    member = User.find(8)
    group.users << member unless group.users.include?(member)
    @issue.update_columns(:assigned_to_id => group.id)
    record(ApprovalSignature::REJECTED)

    assert_includes rejected_ids(member.reload), @issue.id
  end

  # Somebody has to be told, and an unassigned issue still has an author.
  def test_an_unassigned_issue_falls_back_to_the_author
    @issue.update_columns(:assigned_to_id => nil, :author_id => @user.id)
    record(ApprovalSignature::REJECTED)

    assert_includes rejected_ids, @issue.id
  end

  def test_the_author_of_an_assigned_issue_is_not_told
    @issue.update_columns(:assigned_to_id => 3, :author_id => @user.id)
    record(ApprovalSignature::REJECTED)

    assert_not_includes rejected_ids, @issue.id,
                        'it is the assignee who has to act on it'
  end

  def test_returns_nothing_for_anonymous
    @issue.update_columns(:assigned_to_id => @user.id)
    record(ApprovalSignature::REJECTED)

    assert_equal [], rejected_ids(User.anonymous)
  end

  # --- it clears itself -------------------------------------------------------

  def test_nothing_is_listed_without_a_refusal
    @issue.update_columns(:assigned_to_id => @user.id)
    record(ApprovalSignature::APPROVED)

    assert_equal [], rejected_ids
  end

  # No row to dismiss and nothing to remember: the notice is simply what the
  # newest signature says.
  def test_signing_again_clears_the_notice
    @issue.update_columns(:assigned_to_id => @user.id)
    record(ApprovalSignature::REJECTED)
    assert_includes rejected_ids, @issue.id

    record(ApprovalSignature::APPROVED)
    assert_not_includes rejected_ids, @issue.id
  end

  def test_an_older_refusal_under_a_newer_signature_is_not_listed
    @issue.update_columns(:assigned_to_id => @user.id)
    record(ApprovalSignature::REJECTED)
    record(ApprovalSignature::APPROVED)
    record(ApprovalSignature::APPROVED, :position => 1)

    assert_equal [], rejected_ids
  end

  def test_a_second_refusal_brings_it_back
    @issue.update_columns(:assigned_to_id => @user.id)
    record(ApprovalSignature::REJECTED)
    record(ApprovalSignature::APPROVED)
    record(ApprovalSignature::REJECTED, :position => 1)

    assert_includes rejected_ids, @issue.id
  end

  # --- scope ------------------------------------------------------------------

  def test_closed_issues_are_not_listed
    @issue.update_columns(:assigned_to_id => @user.id, :status_id => 5)
    record(ApprovalSignature::REJECTED)

    assert_equal [], rejected_ids
  end

  def test_a_project_without_the_module_is_not_listed
    @issue.update_columns(:assigned_to_id => @user.id)
    record(ApprovalSignature::REJECTED)
    EnabledModule.where(:project_id => @issue.project_id, :name => 'approval_workflow').delete_all

    assert_equal [], rejected_ids
  end

  # An extension request keeps its signatures in the same table; refusing a
  # deadline is not the issue chain refusing the work.
  def test_a_refused_extension_is_not_a_refused_issue
    @issue.update_columns(:assigned_to_id => @user.id)
    extension_route = build_extension_route(:approvers => ['user:3'])
    extension = IssueExtension.create!(
      :issue => @issue, :user_id => @user.id, :approval_route => extension_route,
      :status => IssueExtension::PENDING, :reason => 'Chờ vật tư',
      :previous_due_date => @issue.due_date, :new_due_date => (@issue.start_date + 40)
    )
    ApprovalSignature.create!(:issue => @issue, :issue_extension => extension,
                              :approval_route => extension_route,
                              :step_position => 0, :user_id => 3,
                              :action => ApprovalSignature::REJECTED)

    assert_equal [], rejected_ids
  end

  # --- what the row carries ---------------------------------------------------

  def test_the_refusing_signature_comes_with_the_issue
    @issue.update_columns(:assigned_to_id => @user.id)
    signature = record(ApprovalSignature::REJECTED)

    issue, found = RedmineApprovalWorkflow::RejectedApprovals.for_user(@user).first

    assert_equal @issue.id, issue.id
    assert_equal signature.id, found.id
    assert_equal 'Duyệt', found.step_name
  end

  # --- cost -------------------------------------------------------------------

  # It renders on every page with the rest of the bell.
  def test_query_count_does_not_grow_with_issue_volume
    @issue.update_columns(:assigned_to_id => @user.id)
    record(ApprovalSignature::REJECTED)

    baseline = count_queries {RedmineApprovalWorkflow::RejectedApprovals.for_user(User.find(2))}

    20.times do |i|
      other = Issue.generate!(:project_id => @issue.project_id, :tracker_id => @issue.tracker_id,
                              :status_id => 1, :subject => "Ho so #{i}")
      other.update_columns(:assigned_to_id => @user.id)
      ApprovalSignature.create!(:issue => other, :approval_route => @route,
                                :step_position => 0, :user_id => 3,
                                :action => ApprovalSignature::REJECTED)
    end

    grown = count_queries {RedmineApprovalWorkflow::RejectedApprovals.for_user(User.find(2))}

    assert grown <= baseline + 2,
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
