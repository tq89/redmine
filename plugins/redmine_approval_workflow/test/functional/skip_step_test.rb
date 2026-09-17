# frozen_string_literal: true

require_relative '../test_helper'

# Signing a step without working through the ones before it -- taking a job on
# without being given it. A shortcut through the chain, never around the
# workflow.
class SkipStepTest < Redmine::ControllerTest
  include RedmineApprovalWorkflow::TestFixtures

  tests ApprovalsController

  def setup
    User.current = nil
    ApprovalRoute.delete_all
    ApprovalRouteStep.delete_all
    ApprovalRouteApprover.delete_all
    ApprovalSignature.delete_all
    @issue = Issue.find(1)
    # Statuses 2 and 3: "Giao việc" then "Nhận việc". Role 1 holds every
    # transition in the core fixtures, so the workflow allows both moves.
    @route = build_route(:tracker_id => @issue.tracker_id, :statuses => [2, 3],
                         :rejected_status_id => 6)
    @first = @route.step_at(0)
    @second = @route.step_at(1)
    EnabledModule.create!(:project_id => @issue.project_id, :name => 'approval_workflow')
  end

  def sign_step(step, user_id = 2)
    @request.session[:user_id] = user_id
    post :create, :params => {:issue_id => @issue.id, :decision => 'approve',
                              :step_id => step.id}
  end

  # --- the option off -------------------------------------------------------

  def test_a_step_is_not_skippable_by_default
    assert_not @second.skippable?
    assert_not Issue.find(@issue.id).approval_can_skip_to?(User.find(2), @second)
  end

  # Naming a later step that is not skippable is refused. It must NOT fall back
  # to signing whatever step happens to be due: the button named a step, and
  # signing a different one on somebody's behalf is worse than refusing.
  def test_naming_a_later_step_without_the_flag_is_refused
    assert_no_difference 'ApprovalSignature.count' do
      sign_step(@second)
    end

    assert_response :forbidden
    assert_equal 1, @issue.reload.status_id
  end

  def test_an_unknown_step_is_refused
    @request.session[:user_id] = 2

    assert_no_difference 'ApprovalSignature.count' do
      post :create, :params => {:issue_id => @issue.id, :decision => 'approve',
                                :step_id => 999_999}
    end

    assert_response :forbidden
  end

  # --- the option on --------------------------------------------------------

  def test_a_flagged_step_can_be_signed_out_of_turn
    @second.update!(:allow_skip => true)

    sign_step(@second)

    assert_redirected_to "/issues/#{@issue.id}"
    issue = @issue.reload
    assert_equal 3, issue.status_id, 'straight into the second step\'s status'
    assert_equal 2, issue.approval_position, 'the chain is past both steps'
    assert_equal 1, ApprovalSignature.count, 'only the step actually signed is recorded'
    assert_equal 1, ApprovalSignature.last.step_position
  end

  def test_the_skipped_step_is_not_recorded_as_signed
    @second.update!(:allow_skip => true)

    sign_step(@second)

    assert_nil ApprovalSignature.find_by(:step_position => 0),
               'nobody signed the first step, so nothing may claim they did'
  end

  def test_the_notice_says_the_earlier_steps_were_skipped
    @second.update!(:allow_skip => true)

    sign_step(@second)

    assert_include @second.name, flash[:notice].to_s
  end

  # --- it is a shortcut through the chain, not around the workflow ----------

  def test_skipping_still_needs_the_workflow_transition
    @second.update!(:allow_skip => true)
    # Take away the move from the issue's current status into step 2's status.
    WorkflowTransition.where(:tracker_id => @issue.tracker_id, :role_id => 1,
                             :old_status_id => 1, :new_status_id => 3).delete_all

    assert_not Issue.find(@issue.id).approval_can_skip_to?(User.find(2), @second)

    assert_no_difference 'ApprovalSignature.count' do
      sign_step(@second)
    end
    assert_response :forbidden
    assert_equal 1, @issue.reload.status_id
  end

  def test_skipping_still_obeys_the_steps_approver_list
    @second.update!(:allow_skip => true)
    set_step_approvers(@second, ['user:3'])

    assert_not Issue.find(@issue.id).approval_can_skip_to?(User.find(2), @second)

    assert_no_difference 'ApprovalSignature.count' do
      sign_step(@second, 2)
    end
    assert_response :forbidden
  end

  def test_the_named_approver_may_skip
    @second.update!(:allow_skip => true)
    set_step_approvers(@second, ['user:2'])

    sign_step(@second, 2)

    assert_equal 3, @issue.reload.status_id
  end

  # An employee taking the job on: the step is theirs because they are the
  # assignee, and they reach it without anybody handing it to them.
  def test_the_assignee_can_take_the_job_on_without_being_given_it
    @issue.update_columns(:assigned_to_id => 2)
    @second.update!(:allow_skip => true, :assign_signer => true)
    set_step_approvers(@second, ['dynamic:assignee'])

    sign_step(@second, 2)

    issue = @issue.reload
    assert_equal 3, issue.status_id
    assert_equal 2, issue.assigned_to_id
  end

  # --- only forwards --------------------------------------------------------

  def test_a_step_already_passed_cannot_be_signed_again
    @first.update!(:allow_skip => true)
    sign_step(@first)
    assert_equal 1, @issue.reload.approval_position

    # step_id now points backwards: refused, not quietly redirected forwards.
    assert_no_difference 'ApprovalSignature.count' do
      sign_step(@first)
    end
    assert_response :forbidden
  end

  def test_the_pending_step_itself_is_not_a_skip
    @first.update!(:allow_skip => true)

    sign_step(@first)

    assert_equal ::I18n.t(:notice_approval_signed), flash[:notice],
                 'signing the step that was already due is not skipping'
    assert_equal 1, @issue.reload.approval_position
  end

  # --- signing a claim with a comment ---------------------------------------

  # "Ký kèm ý kiến" goes through a second page, so the step has to survive the
  # round trip. Without it the form would post back and sign whatever step
  # happened to be due -- the very substitution the refusal above prevents.
  def test_the_comment_form_for_a_claim_carries_the_step
    @second.update!(:allow_skip => true)
    @request.session[:user_id] = 2

    get :new, :params => {:issue_id => @issue.id, :decision => 'approve',
                          :step_id => @second.id}

    assert_response :success
    assert_select 'input[type=hidden][name=step_id][value=?]', @second.id.to_s
  end

  def test_the_ordinary_comment_form_names_no_step
    @request.session[:user_id] = 2

    get :new, :params => {:issue_id => @issue.id, :decision => 'approve'}

    assert_response :success
    assert_select 'input[type=hidden][name=step_id]', 0
  end

  # --- an extension chain never skips ---------------------------------------

  def test_an_extension_step_is_never_skippable
    route = ApprovalRoute.create!(:name => 'GH', :tracker_ids => [1],
                                  :kind => ApprovalRoute::EXTENSION_KIND)
    step = route.steps.create!(:name => 'Duyệt', :position => 0,
                               :approver_tokens => ['user:2'],
                               :allow_skip => true)

    assert step.allow_skip?
    assert_not step.skippable?
  end
end
