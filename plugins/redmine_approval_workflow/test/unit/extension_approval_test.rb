# frozen_string_literal: true

require_relative '../test_helper'

# The extension chain: asking for a new deadline is not the same as getting it.
# Until the last step approves, the issue's due_date must not move.
class ExtensionApprovalTest < ActiveSupport::TestCase
  include RedmineApprovalWorkflow::TestFixtures

  def setup
    User.current = nil
    IssueExtension.delete_all
    ApprovalSignature.delete_all
    ApprovalRoute.delete_all
    @issue = Issue.find(1)
    # Core fixtures date the issue relative to today and Issue refuses a due
    # date before its start date, so everything hangs off start_date.
    @due = @issue.start_date + 30
    @issue.update_columns(:due_date => @due)
    @issue.reload
    EnabledModule.create!(:project_id => @issue.project_id, :name => 'approval_workflow')
    Role.find(1).add_permission!(:extend_issue_due_date)
    Role.find(2).add_permission!(:extend_issue_due_date)
    set_plugin_settings('max_extension_days' => '60')
  end

  def request_extension(days: 15, user_id: 2, reason: 'Chờ vật tư')
    route = ApprovalRoute.extension_for_issue(@issue)
    extension = IssueExtension.new(
      :issue => @issue, :user_id => user_id,
      :previous_due_date => @issue.due_date,
      :new_due_date => @issue.due_date + days,
      :reason => reason
    )
    if route && route.step_count > 0
      extension.approval_route = route
      extension.status = IssueExtension::PENDING
    else
      extension.status = IssueExtension::APPROVED
    end
    extension.save!
    extension
  end

  # --- route and step configuration -----------------------------------------

  def test_extension_step_without_an_approver_is_invalid
    route = ApprovalRoute.create!(:name => 'GH', :tracker_id => 1,
                                  :kind => ApprovalRoute::EXTENSION_KIND)
    step = route.steps.build(:name => 'Duyệt', :position => 0)

    assert_not step.valid?
    assert step.errors.added?(:base, :extension_step_needs_approver)
    # The key has to resolve, or the form shows a bare symbol.
    assert_no_match(/translation missing/i, step.errors.full_messages.join(' '))
  end

  def test_extension_step_needs_no_status
    route = ApprovalRoute.create!(:name => 'GH', :tracker_id => 1,
                                  :kind => ApprovalRoute::EXTENSION_KIND)
    step = route.steps.build(:name => 'Duyệt', :position => 0, :approver_user_id => 2)

    assert step.valid?, step.errors.full_messages.join(', ')
    assert_nil step.issue_status_id
  end

  def test_issue_step_still_requires_a_status
    route = ApprovalRoute.create!(:name => 'CV', :tracker_id => 1)
    step = route.steps.build(:name => 'Ký', :position => 0, :approver_user_id => 2)

    assert_not step.valid?
    assert_includes step.errors.attribute_names, :issue_status_id
  end

  def test_extension_route_is_not_used_as_an_issue_route
    build_extension_route

    assert_nil ApprovalRoute.for_issue(@issue)
    assert_not @issue.reload.approval_route?
    assert_not_nil ApprovalRoute.extension_for_issue(@issue)
  end

  # --- the chain ------------------------------------------------------------

  def test_request_with_a_chain_leaves_the_due_date_alone
    build_extension_route
    extension = request_extension

    assert extension.pending?
    assert_equal @due, @issue.reload.due_date
    assert_equal 0, extension.approval_position
    assert_equal 'Duyệt 1', extension.current_approval_step.name
  end

  def test_intermediate_approval_does_not_move_the_due_date
    build_extension_route
    extension = request_extension

    signature = RedmineApprovalWorkflow::ExtensionApproval.
                decide(extension, User.find(2), :approve => true)

    assert_not_nil signature
    assert extension.reload.pending?
    assert_equal @due, @issue.reload.due_date
    assert_equal 1, extension.approval_position
    assert_equal 'Duyệt 2', extension.current_approval_step.name
  end

  def test_last_approval_moves_the_due_date
    build_extension_route
    extension = request_extension(:days => 15)

    RedmineApprovalWorkflow::ExtensionApproval.decide(extension, User.find(2), :approve => true)
    RedmineApprovalWorkflow::ExtensionApproval.decide(extension, User.find(3), :approve => true)

    assert extension.reload.approved?
    assert_not_nil extension.decided_at
    assert_equal @due + 15, @issue.reload.due_date
  end

  def test_final_approval_journals_the_change_without_a_generated_note
    build_extension_route
    extension = request_extension

    assert_difference 'Journal.count', 1 do
      RedmineApprovalWorkflow::ExtensionApproval.decide(extension, User.find(2), :approve => true)
      RedmineApprovalWorkflow::ExtensionApproval.decide(extension, User.find(3), :approve => true)
    end

    journal = Journal.order(:id).last
    assert journal.notes.blank?, "expected no generated note, got #{journal.notes.inspect}"
    assert journal.details.any? {|d| d.prop_key == 'due_date'}
  end

  def test_rejection_drops_the_request_and_keeps_the_due_date
    build_extension_route
    extension = request_extension

    RedmineApprovalWorkflow::ExtensionApproval.decide(extension, User.find(2), :approve => false,
                                                      :comments => 'Không đủ lý do')

    assert extension.reload.rejected?
    assert_equal @due, @issue.reload.due_date
    assert_equal 'Không đủ lý do', extension.approval_signatures.last.comments
  end

  def test_a_rejected_request_cannot_be_signed_again
    build_extension_route
    extension = request_extension
    RedmineApprovalWorkflow::ExtensionApproval.decide(extension, User.find(2), :approve => false)

    assert_nil RedmineApprovalWorkflow::ExtensionApproval.
               decide(extension.reload, User.find(2), :approve => true)
    assert_equal @due, @issue.reload.due_date
  end

  # --- who may sign ---------------------------------------------------------

  def test_only_the_named_approver_of_the_current_step_may_sign
    build_extension_route
    extension = request_extension

    assert extension.signable_by?(User.find(2)), 'step 1 belongs to user 2'
    assert_not extension.signable_by?(User.find(3)), 'user 3 holds step 2, not step 1'

    RedmineApprovalWorkflow::ExtensionApproval.decide(extension, User.find(2), :approve => true)
    extension.reload

    assert_not extension.signable_by?(User.find(2))
    assert extension.signable_by?(User.find(3))
  end

  def test_a_role_step_is_signable_by_any_member_holding_that_role
    build_extension_route(:approvers => [{:approver_role_id => 2}])
    extension = request_extension

    assert extension.signable_by?(User.find(3)), 'user 3 is a Developer on project 1'
    assert_not extension.signable_by?(User.find(2)), 'user 2 is a Manager, not a Developer'
  end

  def test_signing_obeys_the_due_date_field_permission
    build_extension_route
    extension = request_extension
    WorkflowPermission.create!(:tracker_id => @issue.tracker_id, :role_id => 1,
                               :old_status_id => @issue.status_id,
                               :field_name => 'due_date', :rule => 'readonly')

    assert_not extension.signable_by?(User.find(2)),
               'due_date is read-only for this role, so approving a new one must not be offered'
  end

  def test_a_decision_from_somebody_else_records_nothing
    build_extension_route
    extension = request_extension

    assert_no_difference 'ApprovalSignature.count' do
      assert_nil RedmineApprovalWorkflow::ExtensionApproval.
                 decide(extension, User.find(3), :approve => true)
    end
    assert extension.reload.pending?
  end

  # --- without a chain ------------------------------------------------------

  def test_without_a_chain_the_request_applies_immediately
    extension = request_extension(:days => 10)
    RedmineApprovalWorkflow::ExtensionApproval.apply(extension, User.find(2))

    assert extension.reload.approved?
    assert_equal @due + 10, @issue.reload.due_date
  end

  # --- limits ---------------------------------------------------------------

  def test_the_day_limit_is_enforced_when_the_request_is_made
    build_extension_route
    set_plugin_settings('max_extension_days' => '10')
    route = ApprovalRoute.extension_for_issue(@issue)
    extension = IssueExtension.new(:issue => @issue, :user_id => 2,
                                   :approval_route => route,
                                   :status => IssueExtension::PENDING,
                                   :previous_due_date => @due,
                                   :new_due_date => @due + 20)

    assert_not extension.valid?
    assert_includes extension.errors.attribute_names, :new_due_date
  end

  def test_a_lowered_limit_does_not_block_deciding_a_request_already_made
    build_extension_route
    extension = request_extension(:days => 30)
    set_plugin_settings('max_extension_days' => '5')

    RedmineApprovalWorkflow::ExtensionApproval.decide(extension, User.find(2), :approve => true)
    RedmineApprovalWorkflow::ExtensionApproval.decide(extension, User.find(3), :approve => true)

    assert extension.reload.approved?
    assert_equal @due + 30, @issue.reload.due_date
  end

  def test_a_rejected_request_does_not_use_up_the_allowance
    build_extension_route
    set_plugin_settings('max_extension_count' => '1')
    extension = request_extension
    RedmineApprovalWorkflow::ExtensionApproval.decide(extension, User.find(2), :approve => false)

    assert_equal 0, @issue.reload.extension_count
    assert @issue.extendable_by?(User.find(2))
  end

  def test_a_pending_request_uses_the_allowance_while_it_waits
    build_extension_route
    set_plugin_settings('max_extension_count' => '1')
    request_extension

    assert_equal 1, @issue.reload.extension_count
    assert_not @issue.extendable_by?(User.find(2))
  end

  # --- separation from the issue chain --------------------------------------

  def test_extension_signatures_do_not_advance_the_issue_chain
    build_route
    build_extension_route
    extension = request_extension

    RedmineApprovalWorkflow::ExtensionApproval.decide(extension, User.find(2), :approve => true)

    issue = Issue.find(@issue.id)
    assert_equal 0, issue.approval_position,
                 'approving a deadline must not sign a step of the issue chain'
    assert_equal [], issue.approval_signatures.to_a
  end

  def test_destroying_the_issue_removes_extension_signatures
    build_extension_route
    extension = request_extension
    RedmineApprovalWorkflow::ExtensionApproval.decide(extension, User.find(2), :approve => true)

    assert_difference 'ApprovalSignature.count', -1 do
      assert_difference 'IssueExtension.count', -1 do
        Issue.find(@issue.id).destroy
      end
    end
  end

  # --- the pending list -----------------------------------------------------

  def test_pending_for_lists_only_what_the_user_may_sign
    build_extension_route
    extension = request_extension

    assert_equal [extension.id],
                 RedmineApprovalWorkflow::ExtensionApproval.pending_for(User.find(2)).map(&:id)
    assert_equal [], RedmineApprovalWorkflow::ExtensionApproval.pending_for(User.find(3)).map(&:id)
  end

  def test_pending_for_drops_a_request_once_it_is_decided
    build_extension_route(:approvers => [{:approver_user_id => 2}])
    extension = request_extension

    assert_equal 1, RedmineApprovalWorkflow::ExtensionApproval.pending_for(User.find(2)).size

    RedmineApprovalWorkflow::ExtensionApproval.decide(extension, User.find(2), :approve => true)

    assert_equal [], RedmineApprovalWorkflow::ExtensionApproval.pending_for(User.find(2))
    assert_equal @due + 15, @issue.reload.due_date
  end

  def test_pending_for_ignores_requests_that_never_had_a_chain
    request_extension

    assert_equal [], RedmineApprovalWorkflow::ExtensionApproval.pending_for(User.find(2))
  end

  def test_pending_for_is_empty_for_anonymous
    build_extension_route
    request_extension

    assert_equal [], RedmineApprovalWorkflow::ExtensionApproval.pending_for(User.anonymous)
  end
end
