# frozen_string_literal: true

require_relative '../test_helper'

# "Nhận việc": a step flagged to hand the issue over sets the signer as the
# assignee when their signature finishes it.
class AssignSignerTest < Redmine::ControllerTest
  include RedmineApprovalWorkflow::TestFixtures

  tests ApprovalsController

  def setup
    User.current = nil
    ApprovalRoute.delete_all
    ApprovalRouteStep.delete_all
    ApprovalRouteApprover.delete_all
    ApprovalSignature.delete_all
    @issue = Issue.find(1)
    @issue.update_columns(:assigned_to_id => nil)
    @route = build_route(:tracker_id => @issue.tracker_id, :statuses => [2, 3],
                         :rejected_status_id => 6)
    @step = @route.step_at(0)
    EnabledModule.create!(:project_id => @issue.project_id, :name => 'approval_workflow')
  end

  def approve(user_id = 2, params = {})
    @request.session[:user_id] = user_id
    post :create, :params => {:issue_id => @issue.id, :decision => 'approve'}.merge(params)
  end

  # --- the option itself ----------------------------------------------------

  def test_signing_a_flagged_step_makes_the_signer_the_assignee
    @step.update!(:assign_signer => true)

    approve(2)

    assert_redirected_to "/issues/#{@issue.id}"
    assert_equal 2, @issue.reload.assigned_to_id
    assert_equal 2, @issue.status_id, 'the status still moves as usual'
  end

  def test_an_unflagged_step_leaves_the_assignee_alone
    approve(2)

    assert_nil @issue.reload.assigned_to_id
    assert_equal 2, @issue.status_id
  end

  def test_the_handover_shares_the_journal_with_the_status_change
    @step.update!(:assign_signer => true)

    assert_difference 'Journal.count', 1 do
      approve(2)
    end

    journal = Journal.order(:id).last
    keys = journal.details.map(&:prop_key)
    assert_includes keys, 'status_id'
    assert_includes keys, 'assigned_to_id',
                    'the handover belongs in the same history entry, not a second edit'
  end

  def test_whoever_presses_the_button_is_the_one_who_gets_it
    @step.update!(:assign_signer => true)
    set_step_approvers(@step, ['user:2', 'user:3'], :mode => ApprovalRouteStep::ANY_MODE)
    WorkflowTransition.create!(:tracker_id => @issue.tracker_id, :role_id => 2,
                               :old_status_id => 1, :new_status_id => 2)

    approve(3)

    assert_equal 3, @issue.reload.assigned_to_id
  end

  def test_rejecting_a_flagged_step_does_not_hand_the_issue_over
    @step.update!(:assign_signer => true)
    @request.session[:user_id] = 2

    post :create, :params => {:issue_id => @issue.id, :decision => 'reject'}

    assert_nil @issue.reload.assigned_to_id
  end

  def test_an_already_assigned_issue_moves_to_the_signer
    @step.update!(:assign_signer => true)
    @issue.update_columns(:assigned_to_id => 3)

    approve(2)

    assert_equal 2, @issue.reload.assigned_to_id
  end

  # --- with several signatures on one step ----------------------------------

  def test_an_all_step_hands_over_only_when_it_is_finished
    @step.update!(:assign_signer => true)
    set_step_approvers(@step, ['user:2', 'user:3'], :mode => ApprovalRouteStep::ALL_MODE)
    WorkflowTransition.create!(:tracker_id => @issue.tracker_id, :role_id => 2,
                               :old_status_id => 1, :new_status_id => 2)

    approve(2)
    assert_nil @issue.reload.assigned_to_id, 'the step is not finished yet'

    approve(3)
    assert_equal 3, @issue.reload.assigned_to_id,
                 'the signature that finishes the step is the one that takes the job'
  end

  # --- it obeys the workflow, and says so when it cannot --------------------

  def test_a_readonly_assignee_field_blocks_the_handover_and_warns
    @step.update!(:assign_signer => true)
    WorkflowPermission.create!(:tracker_id => @issue.tracker_id, :role_id => 1,
                               :old_status_id => @issue.status_id,
                               :field_name => 'assigned_to_id', :rule => 'readonly')

    approve(2)

    assert_redirected_to "/issues/#{@issue.id}"
    assert_nil @issue.reload.assigned_to_id
    assert_equal 2, @issue.status_id, 'the signature itself still counts'
    assert_equal 1, ApprovalSignature.count
    assert flash[:warning].present?, 'a handover that did not happen must not be silent'
  end

  def test_a_signer_the_issue_cannot_be_assigned_to_is_warned_about
    @step.update!(:assign_signer => true)
    @request.session[:user_id] = 2
    # Nobody is assignable once the role loses the permission Redmine uses to
    # build that list.
    Role.find(1).remove_permission!(:add_issues, :edit_issues)
    Role.find(1).add_permission!(:edit_issues)
    Issue.any_instance.stubs(:assignable_users).returns([])

    post :create, :params => {:issue_id => @issue.id, :decision => 'approve'}

    assert_nil @issue.reload.assigned_to_id
    assert_equal 2, @issue.status_id
    assert flash[:warning].present?
  end

  # --- making the signer the author ------------------------------------------

  def test_signing_a_flagged_step_makes_the_signer_the_author
    # The fixture issue is authored by user 2, the one who signs below, so the
    # change has to start from somebody else to mean anything.
    @issue.update_columns(:author_id => 3)
    @step.update!(:assign_author => true)

    approve(2)

    assert_redirected_to "/issues/#{@issue.id}"
    assert_equal 2, @issue.reload.author_id
    assert_equal 2, @issue.status_id, 'the status still moves as usual'
  end

  def test_an_unflagged_step_leaves_the_author_alone
    author = @issue.author_id

    approve(2)

    assert_equal author, @issue.reload.author_id
  end

  # author_id is in Issue#journalized_attribute_names, so the change is part of
  # the record rather than a silent rewrite of who raised the issue.
  def test_the_author_change_is_recorded_in_the_history
    @issue.update_columns(:author_id => 3)
    @step.update!(:assign_author => true)

    assert_difference 'Journal.count', 1 do
      approve(2)
    end

    detail = Journal.order(:id).last.details.detect {|d| d.prop_key == 'author_id'}
    assert_not_nil detail, 'the handover of authorship must be in the history'
    assert_equal '3', detail.old_value
    assert_equal '2', detail.value
  end

  def test_rejecting_a_flagged_step_does_not_change_the_author
    @issue.update_columns(:author_id => 3)
    @step.update!(:assign_author => true)
    @request.session[:user_id] = 2

    post :create, :params => {:issue_id => @issue.id, :decision => 'reject'}

    assert_equal 3, @issue.reload.author_id
  end

  def test_an_all_step_changes_the_author_only_when_it_is_finished
    @issue.update_columns(:author_id => 1)
    @step.update!(:assign_author => true)
    # User 3 signs first, user 2 finishes -- so the author must end up as 2.
    set_step_approvers(@step, ['user:3', 'user:2'], :mode => ApprovalRouteStep::ALL_MODE)
    WorkflowTransition.create!(:tracker_id => @issue.tracker_id, :role_id => 2,
                               :old_status_id => 1, :new_status_id => 2)

    approve(3)
    assert_equal 1, @issue.reload.author_id, 'the step is not finished yet'

    approve(2)
    assert_equal 2, @issue.reload.author_id,
                 'the signature that finishes the step is the one that takes it'
  end

  def test_both_options_can_be_set_on_one_step
    @issue.update_columns(:author_id => 3, :assigned_to_id => nil)
    @step.update!(:assign_signer => true, :assign_author => true)

    approve(2)

    issue = @issue.reload
    assert_equal 2, issue.author_id
    assert_equal 2, issue.assigned_to_id
  end

  def test_an_extension_step_never_changes_the_author
    route = ApprovalRoute.create!(:name => 'GH', :tracker_ids => [1],
                                  :kind => ApprovalRoute::EXTENSION_KIND)
    step = route.steps.create!(:name => 'Duyệt', :position => 0,
                               :approver_tokens => ['user:2'],
                               :assign_author => true)

    assert step.assign_author?
    assert_not step.assigns_author?
  end

  # --- configuration --------------------------------------------------------

  def test_the_option_is_saved_from_the_route_form
    Role.find(1).add_permission!(:manage_approval_routes)
    @request.session[:user_id] = 2

    route = ApprovalRoute.create!(:name => 'Giao việc', :tracker_ids => [1],
                                  :project_id => @issue.project_id)
    route.steps.create!(:name => 'Nhận việc', :position => 0, :issue_status_id => 2,
                        :assign_signer => true)

    assert route.reload.step_at(0).assigns_signer?
  end

  def test_an_extension_step_never_hands_the_issue_over
    route = ApprovalRoute.create!(:name => 'GH', :tracker_ids => [1],
                                  :kind => ApprovalRoute::EXTENSION_KIND)
    step = route.steps.create!(:name => 'Duyệt', :position => 0,
                               :approver_tokens => ['user:2'],
                               :assign_signer => true)

    assert step.assign_signer?, 'the column is set'
    assert_not step.assigns_signer?,
               'but an extension decides a date; it does not move the work'
  end
end
