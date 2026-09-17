# frozen_string_literal: true

require_relative '../test_helper'

# Acting straight from the bell, without losing the page the user is on.
#
# The buttons are ordinary form posts, so with no JavaScript they still work and
# land on the issue. The bell's script intercepts them and posts in the
# background asking for JSON, and these are the answers it gets.
class BellQuickApprovalTest < Redmine::ControllerTest
  include RedmineApprovalWorkflow::TestFixtures

  tests ApprovalsController

  def setup
    User.current = nil
    ApprovalRoute.delete_all
    ApprovalRouteStep.delete_all
    ApprovalRouteApprover.delete_all
    ApprovalSignature.delete_all
    @issue = Issue.find(1)
    @route = build_route(:tracker_id => @issue.tracker_id, :statuses => [2, 3])
    EnabledModule.create!(:project_id => @issue.project_id, :name => 'approval_workflow')
  end

  # Exactly what the bell's fetch sends: the ordinary URL, asking for JSON.
  def quick_post(params, user_id: 2)
    @request.session[:user_id] = user_id
    @request.headers['Accept'] = 'application/json'
    post :create, :params => {:issue_id => @issue.id, :decision => 'approve'}.merge(params)
  end

  def body
    ActiveSupport::JSON.decode(response.body)
  end

  # --- signing the step that is due -----------------------------------------

  def test_a_background_post_signs_without_redirecting
    assert_difference 'ApprovalSignature.count', 1 do
      quick_post({})
    end

    assert_response :success
    assert_equal 'application/json', response.media_type
    assert_equal 2, @issue.reload.status_id
    assert_equal ::I18n.t(:notice_approval_signed), body['message']
  end

  # A flash set here would not be read by the bell -- it would surface on some
  # unrelated page the user opens later, announcing something they already saw.
  def test_a_background_post_leaves_no_flash_behind
    quick_post({})

    assert_response :success
    assert_nil flash[:notice]
    assert_nil flash[:error]
  end

  def test_the_plain_form_post_still_redirects
    @request.session[:user_id] = 2

    post :create, :params => {:issue_id => @issue.id, :decision => 'approve'}

    assert_redirected_to "/issues/#{@issue.id}"
    assert_equal ::I18n.t(:notice_approval_signed), flash[:notice]
  end

  # --- taking a job on from the bell ----------------------------------------

  def test_a_background_claim_signs_the_step_it_names
    second = @route.step_at(1)
    second.update!(:allow_skip => true)
    set_step_approvers(@route.step_at(0), ['user:3'])

    quick_post({:step_id => second.id})

    assert_response :success
    assert_equal 3, @issue.reload.status_id, 'straight into the claimed step'
    assert_include second.name, body['message']
  end

  def test_a_background_claim_of_an_unflagged_step_is_refused
    assert_no_difference 'ApprovalSignature.count' do
      quick_post({:step_id => @route.step_at(1).id})
    end

    assert_response :forbidden
    assert_equal 1, @issue.reload.status_id
  end

  # --- refusals -------------------------------------------------------------

  def test_a_background_post_on_somebody_elses_step_is_refused
    set_step_approvers(@route.step_at(0), ['user:3'])

    assert_no_difference 'ApprovalSignature.count' do
      quick_post({})
    end

    assert_response :forbidden
  end

  # Two people can be looking at the same bell entry. Whoever gets there second
  # has to be told, in the bell, not by a flash on a page they never asked for.
  def test_a_chain_somebody_else_finished_answers_an_error_in_the_body
    [0, 1].each do |position|
      ApprovalSignature.create!(:issue => @issue, :approval_route => @route,
                                :step_position => position, :user_id => 3,
                                :action => ApprovalSignature::APPROVED)
    end

    assert_no_difference 'ApprovalSignature.count' do
      quick_post({})
    end

    assert_response :unprocessable_entity
    assert_equal 'error', body['level']
    assert_equal ::I18n.t(:error_approval_already_completed), body['message']
    assert_nil flash[:error]
  end

  # --- handing the job over -------------------------------------------------

  def test_an_assignment_that_could_not_be_made_is_reported_in_the_body
    @route.step_at(0).update!(:assign_signer => true)
    # Role 1 may sign, but the workflow locks assigned_to at this status, so
    # the signature stands and the handover does not.
    WorkflowPermission.create!(:tracker_id => @issue.tracker_id, :role_id => 1,
                               :old_status_id => @issue.status_id,
                               :field_name => 'assigned_to_id', :rule => 'readonly')

    quick_post({})

    assert_response :success
    assert_equal ::I18n.t(:warning_signer_not_assigned_readonly), body['warning']
    assert_nil @issue.reload.assigned_to_id
  end
end

# The same, for the extension requests the bell lists.
class BellQuickExtensionTest < Redmine::ControllerTest
  include RedmineApprovalWorkflow::TestFixtures

  tests IssueExtensionsController

  def setup
    User.current = nil
    IssueExtension.delete_all
    ApprovalSignature.delete_all
    ApprovalRoute.delete_all
    @issue = Issue.find(1)
    @due = @issue.start_date + 30
    @issue.update_columns(:due_date => @due)
    EnabledModule.create!(:project_id => @issue.project_id, :name => 'approval_workflow')
    Role.find(1).add_permission!(:extend_issue_due_date)
    set_plugin_settings('max_extension_days' => '30')
    build_extension_route(:approvers => ['user:2'])
    @extension = IssueExtension.create!(
      :issue => @issue, :user_id => 2,
      :approval_route => ApprovalRoute.extension_for_issue(@issue),
      :status => IssueExtension::PENDING,
      :previous_due_date => @due, :new_due_date => @due + 15,
      :reason => 'Chờ vật tư'
    )
  end

  def test_a_background_approval_answers_without_redirecting
    @request.session[:user_id] = 2
    @request.headers['Accept'] = 'application/json'

    assert_difference 'ApprovalSignature.count', 1 do
      post :approve, :params => {:issue_id => @issue.id, :id => @extension.id}
    end

    assert_response :success
    assert_equal 'application/json', response.media_type
    assert @extension.reload.approved?
    assert_equal @due + 15, @issue.reload.due_date
    assert_not_nil ActiveSupport::JSON.decode(response.body)['message']
    assert_nil flash[:notice]
  end

  def test_the_plain_form_post_still_redirects
    @request.session[:user_id] = 2

    post :approve, :params => {:issue_id => @issue.id, :id => @extension.id}

    assert_redirected_to "/issues/#{@issue.id}"
    assert_not_nil flash[:notice]
  end

  def test_a_background_approval_by_somebody_else_is_refused
    Role.find(2).add_permission!(:extend_issue_due_date)
    @request.session[:user_id] = 3
    @request.headers['Accept'] = 'application/json'

    assert_no_difference 'ApprovalSignature.count' do
      post :approve, :params => {:issue_id => @issue.id, :id => @extension.id}
    end

    assert_response :forbidden
    assert @extension.reload.pending?
  end
end
