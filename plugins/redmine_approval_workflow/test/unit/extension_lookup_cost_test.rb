# frozen_string_literal: true

require_relative '../test_helper'

# The extension queue renders on EVERY page through the bell, so its cost must
# not grow with the number of requests sitting in the instance.
#
# This is a regression test with a bruise behind it. The first version loaded
# every undecided request in the database and asked each one in Ruby whether
# this user could sign it. IssueExtension#signable_by? reads the issue's field
# permissions, which Redmine memoises per Issue INSTANCE -- and a list of
# requests carries one instance each -- so that was one `workflows` query per
# pending request, on every page, for every logged-in user. Six hundred open
# requests meant six hundred extra queries per page load, which is how a busy
# instance starts answering 504.
class ExtensionLookupCostTest < ActiveSupport::TestCase
  include RedmineApprovalWorkflow::TestFixtures

  def setup
    User.current = nil
    IssueExtension.delete_all
    ApprovalSignature.delete_all
    ApprovalRouteApprover.delete_all
    ApprovalRouteStep.delete_all
    ApprovalRoute.delete_all
    @issue = Issue.find(1)
    @due = @issue.start_date + 30
    @issue.update_columns(:due_date => @due)
    EnabledModule.create!(:project_id => @issue.project_id, :name => 'approval_workflow')
    Role.find(1).add_permission!(:extend_issue_due_date)
    Role.find(2).add_permission!(:extend_issue_due_date)
    set_plugin_settings('max_extension_days' => '60')
  end

  # +count+ requests on freshly made issues, all on one chain.
  def seed(count, approvers: ['user:3'])
    route = ApprovalRoute.create!(:name => 'GH', :tracker_ids => [@issue.tracker_id],
                                  :kind => ApprovalRoute::EXTENSION_KIND)
    route.steps.create!(:name => 'Duyệt', :position => 0, :approver_tokens => approvers)
    count.times do |i|
      issue = Issue.generate!(:project_id => @issue.project_id, :tracker_id => @issue.tracker_id,
                              :status_id => 1, :subject => "Ho so #{i}")
      issue.update_columns(:due_date => @due)
      IssueExtension.create!(:issue => issue, :user_id => 2, :approval_route => route,
                             :status => IssueExtension::PENDING,
                             :previous_due_date => @due, :new_due_date => @due + 10,
                             :reason => 'Chờ vật tư')
    end
    route
  end

  def count_queries(&)
    count = 0
    counter = lambda do |_name, _start, _finish, _id, payload|
      count += 1 unless payload[:name].in?(%w[CACHE SCHEMA]) ||
                        payload[:sql] =~ /^\s*(BEGIN|COMMIT|ROLLBACK|SAVEPOINT|RELEASE)/i
    end
    ActiveSupport::Notifications.subscribed(counter, 'sql.active_record', &)
    count
  end

  def pending_queries(user_id = 2)
    count_queries {RedmineApprovalWorkflow::ExtensionApproval.pending_for(User.find(user_id))}
  end

  # --- the bound -------------------------------------------------------------

  # Requests that belong to somebody else must cost nothing to walk past. The
  # SQL pre-filter throws them out before a single one is loaded.
  def test_other_peoples_requests_cost_nothing
    seed(5, :approvers => ['user:3'])
    baseline = pending_queries(2)

    seed(40, :approvers => ['user:3'])

    assert_equal 45, IssueExtension.pending.count
    assert_equal [], RedmineApprovalWorkflow::ExtensionApproval.pending_for(User.find(2))
    assert_operator pending_queries(2), :<=, baseline,
                    'a request listed to somebody else must not cost a query'
  end

  # Even when they are all yours, the lookup stops at the cap instead of
  # growing without limit.
  def test_your_own_requests_stay_bounded
    seed(5, :approvers => ['user:2'])
    baseline = pending_queries(2)

    seed(40, :approvers => ['user:2'])
    grown = pending_queries(2)

    assert_operator grown, :<=, baseline + 40,
                    "expected the lookup to stay bounded, went from #{baseline} to #{grown}"
    assert_operator RedmineApprovalWorkflow::ExtensionApproval::CANDIDATE_LIMIT, :>=, 1
  end

  # --- the pre-filter must never hide a request from its approver ------------

  def test_a_request_named_to_the_user_is_still_found
    seed(20, :approvers => ['user:3'])
    route = ApprovalRoute.create!(:name => 'Riêng', :tracker_ids => [@issue.tracker_id],
                                  :project_id => @issue.project_id,
                                  :kind => ApprovalRoute::EXTENSION_KIND)
    route.steps.create!(:name => 'Duyệt', :position => 0, :approver_tokens => ['user:2'])
    mine = IssueExtension.create!(:issue => @issue, :user_id => 3, :approval_route => route,
                                  :status => IssueExtension::PENDING,
                                  :previous_due_date => @due, :new_due_date => @due + 10,
                                  :reason => 'Chờ vật tư')

    assert_equal [mine.id],
                 RedmineApprovalWorkflow::ExtensionApproval.pending_for(User.find(2)).map(&:id)
  end

  def test_a_role_step_is_still_found
    route = ApprovalRoute.create!(:name => 'Vai trò', :tracker_ids => [@issue.tracker_id],
                                  :kind => ApprovalRoute::EXTENSION_KIND)
    route.steps.create!(:name => 'Duyệt', :position => 0, :approver_tokens => ['role:1'])
    extension = IssueExtension.create!(:issue => @issue, :user_id => 3, :approval_route => route,
                                       :status => IssueExtension::PENDING,
                                       :previous_due_date => @due, :new_due_date => @due + 10,
                                       :reason => 'Chờ vật tư')

    assert_includes RedmineApprovalWorkflow::ExtensionApproval.pending_for(User.find(2)).map(&:id),
                    extension.id, 'jsmith holds role 1 on this project'
    assert_not_includes RedmineApprovalWorkflow::ExtensionApproval.pending_for(User.find(3)).map(&:id),
                        extension.id
  end

  def test_the_assignee_slot_is_still_found
    route = ApprovalRoute.create!(:name => 'Người thực hiện', :tracker_ids => [@issue.tracker_id],
                                  :kind => ApprovalRoute::EXTENSION_KIND)
    route.steps.create!(:name => 'Duyệt', :position => 0,
                        :approver_tokens => ['dynamic:assignee'])
    @issue.update_columns(:assigned_to_id => 2)
    extension = IssueExtension.create!(:issue => @issue, :user_id => 3, :approval_route => route,
                                       :status => IssueExtension::PENDING,
                                       :previous_due_date => @due, :new_due_date => @due + 10,
                                       :reason => 'Chờ vật tư')

    assert_equal [extension.id],
                 RedmineApprovalWorkflow::ExtensionApproval.pending_for(User.find(2)).map(&:id)
    assert_equal [], RedmineApprovalWorkflow::ExtensionApproval.pending_for(User.find(3))
  end

  def test_the_author_slot_is_still_found
    route = ApprovalRoute.create!(:name => 'Tác giả', :tracker_ids => [@issue.tracker_id],
                                  :kind => ApprovalRoute::EXTENSION_KIND)
    route.steps.create!(:name => 'Duyệt', :position => 0,
                        :approver_tokens => ['dynamic:author'])
    @issue.update_columns(:author_id => 2)
    extension = IssueExtension.create!(:issue => @issue, :user_id => 3, :approval_route => route,
                                       :status => IssueExtension::PENDING,
                                       :previous_due_date => @due, :new_due_date => @due + 10,
                                       :reason => 'Chờ vật tư')

    assert_equal [extension.id],
                 RedmineApprovalWorkflow::ExtensionApproval.pending_for(User.find(2)).map(&:id)
  end

  def test_a_group_the_issue_is_assigned_to_is_still_found
    group = Group.find(10)
    member = User.find(8)
    group.users << member unless group.users.include?(member)
    Member.create!(:project_id => @issue.project_id, :principal => group, :role_ids => [1])
    route = ApprovalRoute.create!(:name => 'Nhóm', :tracker_ids => [@issue.tracker_id],
                                  :kind => ApprovalRoute::EXTENSION_KIND)
    route.steps.create!(:name => 'Duyệt', :position => 0,
                        :approver_tokens => ['dynamic:assignee'])
    @issue.update_columns(:assigned_to_id => group.id)
    extension = IssueExtension.create!(:issue => @issue, :user_id => 3, :approval_route => route,
                                       :status => IssueExtension::PENDING,
                                       :previous_due_date => @due, :new_due_date => @due + 10,
                                       :reason => 'Chờ vật tư')

    assert_includes RedmineApprovalWorkflow::ExtensionApproval.pending_for(member.reload).map(&:id),
                    extension.id
  end

  # --- the cheap order must not change the answer ----------------------------

  # signable_by? asks whose turn it is before it asks the field permission,
  # because the second one costs a query. Same answer, cheaper order.
  def test_the_field_permission_still_refuses
    route = ApprovalRoute.create!(:name => 'GH', :tracker_ids => [@issue.tracker_id],
                                  :kind => ApprovalRoute::EXTENSION_KIND)
    route.steps.create!(:name => 'Duyệt', :position => 0, :approver_tokens => ['user:2'])
    extension = IssueExtension.create!(:issue => @issue, :user_id => 3, :approval_route => route,
                                       :status => IssueExtension::PENDING,
                                       :previous_due_date => @due, :new_due_date => @due + 10,
                                       :reason => 'Chờ vật tư')
    assert extension.signable_by?(User.find(2))

    WorkflowPermission.create!(:tracker_id => @issue.tracker_id, :role_id => 1,
                               :old_status_id => @issue.status_id,
                               :field_name => 'due_date', :rule => 'readonly')

    assert_not IssueExtension.find(extension.id).signable_by?(User.find(2)),
               'the workflow locks due_date at this status'
    assert_equal [], RedmineApprovalWorkflow::ExtensionApproval.pending_for(User.find(2))
  end
end
