# frozen_string_literal: true

require_relative '../test_helper'

# Refusing a step: where the issue lands, and who hears about it.
class RejectStepTest < Redmine::ControllerTest
  include RedmineApprovalWorkflow::TestFixtures

  tests ApprovalsController

  def setup
    User.current = nil
    ApprovalRoute.delete_all
    ApprovalRouteStep.delete_all
    ApprovalRouteApprover.delete_all
    ApprovalSignature.delete_all
    ActionMailer::Base.deliveries.clear
    Setting.default_language = 'en'
    @issue = Issue.find(1)
    EnabledModule.create!(:project_id => @issue.project_id, :name => 'approval_workflow')
    @route = build_route(:tracker_id => @issue.tracker_id, :statuses => [2, 3])
    @first = @route.step_at(0)
    @second = @route.step_at(1)
  end

  def reject(user_id: 2, comments: nil)
    @request.session[:user_id] = user_id
    post :create, :params => {:issue_id => @issue.id, :decision => 'reject',
                              :comments => comments}
  end

  # --- "giữ nguyên trạng thái" ----------------------------------------------

  def test_rejecting_with_keep_records_the_refusal_and_moves_nothing
    @first.update!(:reject_mode => ApprovalRouteStep::REJECT_KEEP)

    assert_difference 'ApprovalSignature.count', 1 do
      reject
    end

    assert_redirected_to "/issues/#{@issue.id}"
    issue = @issue.reload
    assert_equal 1, issue.status_id, 'the issue stays exactly where it was'
    assert ApprovalSignature.last.rejected?
    assert_equal 1, ApprovalSignature.last.from_status_id
    assert_equal 1, ApprovalSignature.last.to_status_id
  end

  def test_the_notice_does_not_claim_the_issue_went_back
    @first.update!(:reject_mode => ApprovalRouteStep::REJECT_KEEP)

    reject

    assert_equal ::I18n.t(:notice_approval_rejected_kept), flash[:notice]
  end

  # Redmine does not save an empty journal, and the plugin does not invent a
  # note; a refusal that changes nothing leaves the chain to record it.
  def test_a_refusal_that_changes_nothing_writes_no_empty_journal
    @first.update!(:reject_mode => ApprovalRouteStep::REJECT_KEEP)

    assert_no_difference 'Journal.count' do
      reject
    end
  end

  def test_a_typed_comment_still_reaches_the_history
    @first.update!(:reject_mode => ApprovalRouteStep::REJECT_KEEP)

    assert_difference 'Journal.count', 1 do
      reject(:comments => 'Thiếu thuyết minh')
    end

    assert_equal 'Thiếu thuyết minh', Journal.last.notes
  end

  def test_keep_by_somebody_the_step_is_not_listed_to_is_refused
    @first.update!(:reject_mode => ApprovalRouteStep::REJECT_KEEP)
    set_step_approvers(@first, ['user:3'])

    assert_no_difference 'ApprovalSignature.count' do
      reject(:user_id => 2)
    end

    assert_response :forbidden
  end

  # --- "chuyển sang trạng thái đã chọn" -------------------------------------

  def test_rejecting_into_a_named_status_moves_the_issue_there
    @first.update!(:reject_mode => ApprovalRouteStep::REJECT_STATUS,
                   :reject_status_id => 6)

    reject

    assert_equal 6, @issue.reload.status_id
    assert_equal 6, ApprovalSignature.last.to_status_id
  end

  def test_rejecting_into_a_status_the_workflow_denies_is_refused
    @first.update!(:reject_mode => ApprovalRouteStep::REJECT_STATUS,
                   :reject_status_id => 6)
    WorkflowTransition.where(:tracker_id => @issue.tracker_id, :role_id => 1,
                             :old_status_id => 1, :new_status_id => 6).delete_all

    assert_no_difference 'ApprovalSignature.count' do
      reject
    end

    assert_response :forbidden
    assert_equal 1, @issue.reload.status_id
  end

  # --- the default is what it always was --------------------------------------

  def test_the_route_status_still_applies_when_the_step_says_nothing
    @route.update!(:rejected_status_id => 6)

    reject

    assert_equal 6, @issue.reload.status_id
    assert_equal ::I18n.t(:notice_approval_rejected), flash[:notice]
  end

  # --- telling người thực hiện ------------------------------------------------

  def test_the_assignee_is_told_their_work_was_refused
    set_plugin_settings('notify_on_pending_approval' => '1')
    @first.update!(:reject_mode => ApprovalRouteStep::REJECT_KEEP)
    @issue.update_columns(:assigned_to_id => 3)

    reject(:user_id => 2, :comments => 'Làm lại phần dự toán')

    mail = ActionMailer::Base.deliveries.detect do |m|
      m.subject.include?(::I18n.t(:mail_subject_approval_rejected))
    end
    assert_not_nil mail, 'the assignee has to hear about it'
    assert_equal [User.find(3).mail], mail.to
    assert_include 'Làm lại phần dự toán', mail_body(mail)
  end

  def test_an_unassigned_issue_tells_the_author_instead
    set_plugin_settings('notify_on_pending_approval' => '1')
    @first.update!(:reject_mode => ApprovalRouteStep::REJECT_KEEP)
    @issue.update_columns(:assigned_to_id => nil, :author_id => 3)

    reject(:user_id => 2)

    mail = ActionMailer::Base.deliveries.detect do |m|
      m.subject.include?(::I18n.t(:mail_subject_approval_rejected))
    end
    assert_not_nil mail
    assert_equal [User.find(3).mail], mail.to
  end

  def test_the_person_who_refused_is_not_mailed_about_their_own_refusal
    set_plugin_settings('notify_on_pending_approval' => '1')
    @first.update!(:reject_mode => ApprovalRouteStep::REJECT_KEEP)
    @issue.update_columns(:assigned_to_id => 2)

    reject(:user_id => 2)

    rejections = ActionMailer::Base.deliveries.select do |m|
      m.subject.include?(::I18n.t(:mail_subject_approval_rejected))
    end
    assert_empty rejections
  end

  def test_no_rejection_mail_when_the_option_is_off
    set_plugin_settings('notify_on_pending_approval' => '0')
    @first.update!(:reject_mode => ApprovalRouteStep::REJECT_KEEP)
    @issue.update_columns(:assigned_to_id => 3)

    reject(:user_id => 2)

    assert_empty ActionMailer::Base.deliveries
  end

  def test_approving_sends_no_rejection_mail
    set_plugin_settings('notify_on_pending_approval' => '1')
    @issue.update_columns(:assigned_to_id => 3)
    @request.session[:user_id] = 2

    post :create, :params => {:issue_id => @issue.id, :decision => 'approve'}

    rejections = ActionMailer::Base.deliveries.select do |m|
      m.subject.include?(::I18n.t(:mail_subject_approval_rejected))
    end
    assert_empty rejections
  end

  def mail_body(mail)
    mail.parts.any? ? mail.parts.map(&:body).join : mail.body.to_s
  end
end
