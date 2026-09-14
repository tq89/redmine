# frozen_string_literal: true

require_relative '../test_helper'

class IssueExtensionsControllerTest < Redmine::ControllerTest
  include RedmineApprovalWorkflow::TestFixtures

  tests IssueExtensionsController

  def setup
    User.current = nil
    IssueExtension.delete_all
    ApprovalSignature.delete_all
    ApprovalRoute.delete_all
    @issue = Issue.find(1)
    # Core fixtures use dates relative to today, and Issue rejects a due date
    # before its start date, so every date here hangs off start_date.
    @due = @issue.start_date + 30
    @issue.update_columns(:due_date => @due)
    EnabledModule.create!(:project_id => @issue.project_id, :name => 'approval_workflow')
    Role.find(1).add_permission!(:extend_issue_due_date)
    set_plugin_settings('max_extension_days' => '30')
  end

  def test_extend_within_limit_updates_the_due_date
    @request.session[:user_id] = 2

    assert_difference 'IssueExtension.count', 1 do
      assert_difference 'Journal.count', 1 do
        post :create, :params => {
          :issue_id => @issue.id,
          :issue_extension => {:new_due_date => (@due + 15).to_s, :reason => 'Chờ vật tư'}
        }
      end
    end

    assert_redirected_to "/issues/#{@issue.id}"
    assert_equal @due + 15, @issue.reload.due_date

    extension = IssueExtension.last
    assert_equal 15, extension.days
    assert_equal @due, extension.previous_due_date
    assert_equal 'Chờ vật tư', extension.reason
    assert_not_nil extension.journal_id
  end

  def test_extend_beyond_the_admin_limit_is_refused
    @request.session[:user_id] = 2

    assert_no_difference 'IssueExtension.count' do
      post :create, :params => {
        :issue_id => @issue.id,
        :issue_extension => {:new_due_date => (@due + 60).to_s, :reason => 'Quá hạn mức'}
      }
    end

    assert_response :success
    assert_equal @due, @issue.reload.due_date
    assert_select '#errorExplanation'
  end

  def test_extend_is_denied_without_the_permission
    Role.find(1).remove_permission!(:extend_issue_due_date)
    @request.session[:user_id] = 2

    assert_no_difference 'IssueExtension.count' do
      post :create, :params => {
        :issue_id => @issue.id,
        :issue_extension => {:new_due_date => (@due + 15).to_s}
      }
    end

    assert_response :forbidden
    assert_equal @due, @issue.reload.due_date
  end

  def test_earlier_date_is_refused
    @request.session[:user_id] = 2

    assert_no_difference 'IssueExtension.count' do
      post :create, :params => {
        :issue_id => @issue.id,
        :issue_extension => {:new_due_date => (@due - 5).to_s}
      }
    end

    assert_response :success
    assert_equal @due, @issue.reload.due_date
  end

  # Extending writes due_date, so the workflow's field permissions decide who
  # may do it, the same way status transitions decide who may sign.
  def test_extend_is_denied_when_workflow_marks_due_date_readonly
    WorkflowPermission.create!(:tracker_id => @issue.tracker_id, :role_id => 1,
                               :old_status_id => @issue.status_id,
                               :field_name => 'due_date', :rule => 'readonly')
    @request.session[:user_id] = 2

    assert_not Issue.find(@issue.id).extendable_by?(User.find(2))

    assert_no_difference 'IssueExtension.count' do
      post :create, :params => {
        :issue_id => @issue.id,
        :issue_extension => {:new_due_date => (@due + 15).to_s, :reason => 'Thu'}
      }
    end

    assert_response :forbidden
    assert_equal @due, @issue.reload.due_date
  end

  def test_extend_is_allowed_when_readonly_applies_to_another_status
    WorkflowPermission.create!(:tracker_id => @issue.tracker_id, :role_id => 1,
                               :old_status_id => 5,
                               :field_name => 'due_date', :rule => 'readonly')
    @request.session[:user_id] = 2

    assert Issue.find(@issue.id).extendable_by?(User.find(2))
  end

  def test_new_renders_the_form_with_the_limit
    @request.session[:user_id] = 2

    get :new, :params => {:issue_id => @issue.id}

    assert_response :success
    assert_select 'input[name=?]', 'issue_extension[new_due_date]'
  end

  # --- with an approval chain -----------------------------------------------

  def test_request_with_a_chain_waits_instead_of_moving_the_due_date
    build_extension_route
    Role.find(2).add_permission!(:extend_issue_due_date)
    @request.session[:user_id] = 2

    assert_difference 'IssueExtension.count', 1 do
      assert_no_difference 'Journal.count' do
        post :create, :params => {
          :issue_id => @issue.id,
          :issue_extension => {:new_due_date => (@due + 15).to_s, :reason => 'Chờ vật tư'}
        }
      end
    end

    assert_redirected_to "/issues/#{@issue.id}"
    assert_equal @due, @issue.reload.due_date, 'the deadline must not move on a request alone'
    assert IssueExtension.last.pending?
  end

  def test_new_shows_the_chain_when_the_tracker_has_one
    build_extension_route
    @request.session[:user_id] = 2

    get :new, :params => {:issue_id => @issue.id}

    assert_response :success
    assert_select 'ol.extension-steps li', 2
  end

  def test_approve_by_the_named_approver_signs_the_step
    build_extension_route
    extension = create_pending_extension
    @request.session[:user_id] = 2

    assert_difference 'ApprovalSignature.count', 1 do
      post :approve, :params => {:issue_id => @issue.id, :id => extension.id}
    end

    assert_redirected_to "/issues/#{@issue.id}"
    assert extension.reload.pending?, 'one of two steps signed, still waiting'
    assert_equal @due, @issue.reload.due_date
  end

  def test_approve_by_somebody_else_is_refused
    build_extension_route
    extension = create_pending_extension
    Role.find(2).add_permission!(:extend_issue_due_date)
    # User 3 holds the second step, not the one awaiting a signature.
    @request.session[:user_id] = 3

    assert_no_difference 'ApprovalSignature.count' do
      post :approve, :params => {:issue_id => @issue.id, :id => extension.id}
    end

    assert_response :forbidden
    assert extension.reload.pending?
  end

  def test_the_last_approval_moves_the_due_date
    build_extension_route(:approvers => [{:approver_user_id => 2}])
    extension = create_pending_extension
    @request.session[:user_id] = 2

    post :approve, :params => {:issue_id => @issue.id, :id => extension.id}

    assert_redirected_to "/issues/#{@issue.id}"
    assert extension.reload.approved?
    assert_equal @due + 15, @issue.reload.due_date
  end

  def test_reject_leaves_the_due_date_where_it_was
    build_extension_route
    extension = create_pending_extension
    @request.session[:user_id] = 2

    post :reject, :params => {:issue_id => @issue.id, :id => extension.id,
                              :comments => 'Không đủ lý do'}

    assert_redirected_to "/issues/#{@issue.id}"
    assert extension.reload.rejected?
    assert_equal @due, @issue.reload.due_date
  end

  def test_deciding_an_unknown_request_is_a_404
    @request.session[:user_id] = 2

    post :approve, :params => {:issue_id => @issue.id, :id => 999_999}

    assert_response :not_found
  end

  private

  def create_pending_extension(days: 15)
    route = ApprovalRoute.extension_for_issue(@issue)
    IssueExtension.create!(:issue => @issue, :user_id => 2,
                           :approval_route => route,
                           :status => IssueExtension::PENDING,
                           :previous_due_date => @due,
                           :new_due_date => @due + days,
                           :reason => 'Chờ vật tư')
  end
end
