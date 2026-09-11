# frozen_string_literal: true

require_relative '../test_helper'

class ApprovalsControllerTest < Redmine::ControllerTest
  include RedmineApprovalWorkflow::TestFixtures

  tests ApprovalsController

  def setup
    User.current = nil
    ApprovalRoute.delete_all
    ApprovalRouteStep.delete_all
    ApprovalSignature.delete_all
    @issue = Issue.find(1)
    @route = build_route(:tracker_id => @issue.tracker_id, :statuses => [2, 3], :rejected_status_id => 6)
    EnabledModule.create!(:project_id => @issue.project_id, :name => 'approval_workflow')
  end

  def test_approve_moves_issue_into_the_step_status
    @request.session[:user_id] = 2

    assert_difference 'ApprovalSignature.count', 1 do
      assert_difference 'Journal.count', 1 do
        post :create, :params => {:issue_id => @issue.id, :decision => 'approve',
                                  :comments => 'Đồng ý'}
      end
    end

    assert_redirected_to "/issues/#{@issue.id}"
    assert_equal 2, @issue.reload.status_id

    signature = ApprovalSignature.last
    assert signature.approved?
    assert_equal 0, signature.step_position
    assert_equal 1, signature.from_status_id
    assert_equal 2, signature.to_status_id
    assert_equal 2, signature.user_id
    assert_equal 'Đồng ý', signature.comments
    assert_not_nil signature.journal_id
  end

  def test_approve_is_denied_without_the_status_transition
    # A user who cannot move the issue into the step's status must not be able
    # to sign it, since signing rights are the transition rights.
    @request.session[:user_id] = 2
    WorkflowTransition.where(:tracker_id => @issue.tracker_id, :old_status_id => 1,
                             :new_status_id => 2).delete_all

    assert_no_difference 'ApprovalSignature.count' do
      post :create, :params => {:issue_id => @issue.id, :decision => 'approve'}
    end

    assert_response :forbidden
    assert_equal 1, @issue.reload.status_id
  end

  def test_approve_is_denied_for_anonymous
    assert_no_difference 'ApprovalSignature.count' do
      post :create, :params => {:issue_id => @issue.id, :decision => 'approve'}
    end

    assert_equal 1, @issue.reload.status_id
  end

  def test_second_approval_advances_to_the_next_step
    @request.session[:user_id] = 2
    post :create, :params => {:issue_id => @issue.id, :decision => 'approve'}
    assert_equal 2, @issue.reload.status_id

    post :create, :params => {:issue_id => @issue.id, :decision => 'approve'}

    assert_equal 3, @issue.reload.status_id
    assert @issue.approval_completed?
  end

  def test_approving_a_completed_chain_is_refused
    @request.session[:user_id] = 2
    2.times {post :create, :params => {:issue_id => @issue.id, :decision => 'approve'}}
    assert @issue.reload.approval_completed?

    assert_no_difference 'ApprovalSignature.count' do
      post :create, :params => {:issue_id => @issue.id, :decision => 'approve'}
    end
    assert_redirected_to "/issues/#{@issue.id}"
  end

  def test_reject_at_head_moves_to_the_rejected_status
    @request.session[:user_id] = 2

    assert_difference 'ApprovalSignature.count', 1 do
      post :create, :params => {:issue_id => @issue.id, :decision => 'reject',
                                :comments => 'Thiếu hồ sơ'}
    end

    assert_equal 6, @issue.reload.status_id
    assert ApprovalSignature.last.rejected?
    assert_equal 0, @issue.approval_position
  end

  def test_new_renders_the_signing_form
    @request.session[:user_id] = 2

    get :new, :params => {:issue_id => @issue.id, :decision => 'approve'}

    assert_response :success
    assert_select 'input[name=decision][value=approve]'
  end

  def test_index_lists_signatures
    @request.session[:user_id] = 2
    post :create, :params => {:issue_id => @issue.id, :decision => 'approve'}

    get :index, :params => {:issue_id => @issue.id}

    assert_response :success
    assert_select 'table.list tbody tr', 1
  end

  def test_returns_404_when_no_route_is_configured
    ApprovalRoute.delete_all
    @request.session[:user_id] = 2

    post :create, :params => {:issue_id => @issue.id, :decision => 'approve'}

    assert_response :not_found
  end

  def test_returns_404_for_an_unknown_issue
    @request.session[:user_id] = 2

    get :index, :params => {:issue_id => 999_999}

    assert_response :not_found
  end
end
