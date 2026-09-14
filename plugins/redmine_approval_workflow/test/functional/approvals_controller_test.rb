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

  # "Khi duyệt đơn không tự thêm bình luận": signing records the status change
  # in the journal and writes nothing into the notes. Anything in the notes has
  # to have been typed by the signer.
  def test_approving_writes_no_generated_note
    @request.session[:user_id] = 2

    post :create, :params => {:issue_id => @issue.id, :decision => 'approve'}

    journal = Journal.order(:id).last
    assert journal.notes.blank?, "expected no generated note, got #{journal.notes.inspect}"
    assert journal.details.any? {|detail| detail.prop_key == 'status_id'},
           'the status change must still be journalled'
  end

  def test_rejecting_writes_no_generated_note
    @request.session[:user_id] = 2

    post :create, :params => {:issue_id => @issue.id, :decision => 'reject'}

    assert Journal.order(:id).last.notes.blank?
  end

  def test_a_typed_comment_is_kept_as_the_note
    @request.session[:user_id] = 2

    post :create, :params => {:issue_id => @issue.id, :decision => 'approve',
                              :comments => 'Đồng ý'}

    assert_equal 'Đồng ý', Journal.order(:id).last.notes
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

  # Signing is an issue update, so Redmine sends its own notification too.
  # These assertions look only at the approval mail this plugin adds.
  def approval_mail_recipients
    subject = ::I18n.t(:mail_subject_approval_pending, :locale => :en)
    ActionMailer::Base.deliveries.
      select {|mail| mail.subject.to_s.include?(subject)}.
      flat_map(&:to).uniq.sort
  end

  # Lets dlopper (role 2) sign step 1, so approving step 0 as jsmith hands the
  # issue to somebody who is not the actor.
  def let_another_role_sign_the_second_step
    WorkflowTransition.create!(:tracker_id => @issue.tracker_id, :role_id => 2,
                               :old_status_id => 2, :new_status_id => 3)
  end

  def test_signing_notifies_whoever_may_sign_the_next_step
    set_plugin_settings('notify_on_pending_approval' => '1')
    let_another_role_sign_the_second_step
    Setting.default_language = 'en'
    ActionMailer::Base.deliveries.clear
    @request.session[:user_id] = 2

    post :create, :params => {:issue_id => @issue.id, :decision => 'approve'}

    assert_equal 2, @issue.reload.status_id
    expected = ApprovalMailer.recipients(@issue, @route.step_at(1), User.find(2))
    assert expected.any?, 'fixture must leave somebody able to sign step 1'
    assert_equal expected.flat_map(&:mails).uniq.sort, approval_mail_recipients
    assert_not_includes approval_mail_recipients, User.find(2).mail
  end

  def test_signing_sends_no_approval_mail_when_the_option_is_off
    set_plugin_settings('notify_on_pending_approval' => '0')
    let_another_role_sign_the_second_step
    Setting.default_language = 'en'
    ActionMailer::Base.deliveries.clear
    @request.session[:user_id] = 2

    post :create, :params => {:issue_id => @issue.id, :decision => 'approve'}

    assert_equal 2, @issue.reload.status_id
    assert_empty approval_mail_recipients
    # Redmine's own issue-update notification is unaffected by this option.
    assert ActionMailer::Base.deliveries.any?
  end

  def test_rejecting_notifies_the_step_it_hands_back_to
    set_plugin_settings('notify_on_pending_approval' => '1')
    Setting.default_language = 'en'
    @request.session[:user_id] = 2
    post :create, :params => {:issue_id => @issue.id, :decision => 'approve'}
    ActionMailer::Base.deliveries.clear

    post :create, :params => {:issue_id => @issue.id, :decision => 'reject'}

    assert_equal 0, @issue.reload.approval_position
    assert approval_mail_recipients.any?, 'handing an issue back starts somebody new turn'
  end

  # The chain must follow a status changed by any other means, and must not
  # count a real signature twice.
  def test_status_changed_outside_the_chain_advances_it
    set_plugin_settings('sync_status_from_history' => '1')
    # Core fixtures already move issue 1 from status 1 to 2 in a journal by user
    # 1. Clearing it leaves this test about the edit it actually makes.
    @issue.journals.delete_all
    issue = Issue.find(@issue.id)
    issue.init_journal(User.find(2))
    issue.status_id = 2
    issue.save!

    assert_equal 1, issue.reload.approval_position
    signature = ApprovalSignature.where(:issue_id => issue.id).last
    assert signature.derived?, 'an ordinary edit is not a signature'
    assert_equal 2, signature.user_id
  end

  def test_signing_is_not_also_recorded_as_derived
    set_plugin_settings('sync_status_from_history' => '1')
    @request.session[:user_id] = 2

    assert_difference 'ApprovalSignature.count', 1 do
      post :create, :params => {:issue_id => @issue.id, :decision => 'approve'}
    end

    assert_equal 1, @issue.reload.approval_position
    assert ApprovalSignature.last.signed?, 'a real signature must stay a real signature'
  end

  def test_sync_action_fills_the_chain_on_demand
    Role.find(1).add_permission!(:sync_approval_history)
    set_plugin_settings('sync_status_from_history' => '0') # automatic sync off
    issue = Issue.find(@issue.id)
    issue.init_journal(User.find(2))
    issue.status_id = 2
    issue.save!
    assert_equal 0, issue.reload.approval_position, 'automatic sync is off'

    @request.session[:user_id] = 2
    assert_difference 'ApprovalSignature.count', 1 do
      post :sync, :params => {:issue_id => @issue.id}
    end

    assert_redirected_to "/issues/#{@issue.id}"
    assert_equal 1, @issue.reload.approval_position
  end

  def test_sync_action_is_denied_without_the_permission
    Role.find(1).remove_permission!(:sync_approval_history)
    @request.session[:user_id] = 2

    post :sync, :params => {:issue_id => @issue.id}

    assert_response :forbidden
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
