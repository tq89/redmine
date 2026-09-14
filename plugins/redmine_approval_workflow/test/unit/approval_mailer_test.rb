# frozen_string_literal: true

require_relative '../test_helper'

class ApprovalMailerTest < ActiveSupport::TestCase
  include RedmineApprovalWorkflow::TestFixtures

  def setup
    User.current = nil
    ActionMailer::Base.deliveries.clear
    ApprovalRoute.delete_all
    ApprovalRouteStep.delete_all
    ApprovalSignature.delete_all
    @issue = Issue.find(1)
    EnabledModule.create!(:project_id => @issue.project_id, :name => 'approval_workflow')
    @route = build_route(:tracker_id => @issue.tracker_id, :statuses => [2, 3])
    set_plugin_settings('notify_on_pending_approval' => '1')
    Setting.default_language = 'en'
  end

  # The test environment runs Active Job inline, so deliver_later sends at once.
  def deliver(actor = nil)
    ApprovalMailer.deliver_approval_pending(@issue.reload, actor)
  end

  def test_mails_the_users_who_may_sign_the_pending_step
    deliver

    assert ActionMailer::Base.deliveries.any?, 'expected at least one notification'
    recipients = ActionMailer::Base.deliveries.flat_map(&:to).uniq
    signers = ApprovalMailer.recipients(@issue, @route.step_at(0)).flat_map(&:mails).uniq

    assert_equal signers.sort, recipients.sort
  end

  def test_sends_nothing_when_the_option_is_off
    set_plugin_settings('notify_on_pending_approval' => '0')

    deliver

    assert_empty ActionMailer::Base.deliveries
  end

  def test_never_mails_the_person_who_just_acted
    actor = ApprovalMailer.recipients(@issue, @route.step_at(0)).first
    assert actor, 'fixture must yield at least one signer'

    deliver(actor)

    assert_not_includes ActionMailer::Base.deliveries.flat_map(&:to), actor.mail
  end

  def test_skips_users_who_turned_mail_off
    signer = ApprovalMailer.recipients(@issue, @route.step_at(0)).first
    signer.update_column(:mail_notification, 'none')

    deliver

    assert_not_includes ActionMailer::Base.deliveries.flat_map(&:to), signer.mail
  end

  def test_only_mails_the_named_person_when_the_step_assigns_one
    @route.step_at(0).update!(:approver_user_id => 2)

    deliver

    assert_equal [User.find(2).mail], ActionMailer::Base.deliveries.flat_map(&:to).uniq
  end

  def test_only_mails_the_named_role_when_the_step_assigns_one
    @route.step_at(0).update!(:approver_role_id => 1)

    deliver

    recipients = ActionMailer::Base.deliveries.flat_map(&:to).uniq
    assert recipients.any?, 'role 1 holds the transition here'
    recipients.each do |mail|
      user = User.find_by_mail(mail)
      assert user.roles_for_project(@issue.project).map(&:id).include?(1),
             "#{mail} is not in role 1"
    end
  end

  def test_sends_nothing_when_the_named_person_cannot_make_the_transition
    @route.step_at(0).update!(:approver_user_id => 2)
    WorkflowTransition.where(:tracker_id => @issue.tracker_id, :old_status_id => 1,
                             :new_status_id => 2).delete_all

    deliver

    assert_empty ActionMailer::Base.deliveries
  end

  def test_sends_nothing_when_nobody_holds_the_transition
    WorkflowTransition.where(:tracker_id => @issue.tracker_id, :old_status_id => 1,
                             :new_status_id => 2).delete_all

    deliver

    assert_empty ActionMailer::Base.deliveries
  end

  def test_sends_nothing_once_the_chain_is_complete
    [0, 1].each do |position|
      ApprovalSignature.create!(:issue => @issue, :approval_route => @route,
                                :step_position => position, :user_id => 2,
                                :action => ApprovalSignature::APPROVED)
    end

    deliver

    assert_empty ActionMailer::Base.deliveries
  end

  def test_sends_nothing_without_a_route
    ApprovalRoute.delete_all

    deliver

    assert_empty ActionMailer::Base.deliveries
  end

  # Mailer#mail builds the From display name and the Sender header from @author,
  # which only works if it is set on the mailer instance.
  def test_mail_is_attributed_to_whoever_triggered_it
    @route.step_at(0).update!(:approver_user_id => 3)
    actor = User.find(2)

    ApprovalMailer.deliver_approval_pending(@issue.reload, actor)

    mail = ActionMailer::Base.deliveries.first
    assert_not_nil mail
    assert_include actor.name, mail.header['From'].to_s
    assert_equal actor.login, mail.header['X-Redmine-Sender'].to_s
  end

  def test_mail_names_the_step_and_the_target_status
    deliver

    mail = ActionMailer::Base.deliveries.first
    assert_not_nil mail
    assert_match(/##{@issue.id}/, mail.subject)
    body = mail.parts.map(&:body).join(' ')
    assert_include @route.step_at(0).name, body
    assert_include IssueStatus.find(2).name, body
    assert_include "/issues/#{@issue.id}/approvals/new", body
  end

  # --- extension chains -----------------------------------------------------

  def build_pending_extension(approvers: [{:approver_user_id => 2}, {:approver_user_id => 3}])
    IssueExtension.delete_all
    Role.find(1).add_permission!(:extend_issue_due_date)
    Role.find(2).add_permission!(:extend_issue_due_date)
    due = @issue.start_date + 30
    @issue.update_columns(:due_date => due)
    @issue.reload
    route = build_extension_route(:tracker_id => @issue.tracker_id, :approvers => approvers)
    IssueExtension.create!(:issue => @issue, :user_id => 2,
                           :approval_route => route,
                           :status => IssueExtension::PENDING,
                           :previous_due_date => due,
                           :new_due_date => due + 10,
                           :reason => 'Chờ vật tư')
  end

  # Applying an extension writes due_date, and Redmine mails its own watchers
  # about that journal, so the turn-to-sign mails have to be picked out.
  def extension_mails
    subject = ::I18n.t(:mail_subject_extension_pending, :locale => :en)
    ActionMailer::Base.deliveries.select {|mail| mail.subject.to_s.include?(subject)}
  end

  def test_mails_the_named_approver_of_the_pending_extension_step
    extension = build_pending_extension

    ApprovalMailer.deliver_extension_pending(extension)

    assert_equal [User.find(2).mail], extension_mails.flat_map(&:to).uniq
  end

  def test_extension_mail_names_the_step_and_the_dates
    extension = build_pending_extension

    ApprovalMailer.deliver_extension_pending(extension)

    mail = extension_mails.first
    assert_not_nil mail
    assert_match(/##{@issue.id}/, mail.subject)
    body = mail.parts.map(&:body).join(' ')
    assert_include 'Duyệt 1', body
    assert_include extension.new_due_date.to_s.split('-').last, body
    assert_include 'Chờ vật tư', body
  end

  def test_extension_mail_goes_to_the_next_approver_after_a_signature
    extension = build_pending_extension

    RedmineApprovalWorkflow::ExtensionApproval.decide(extension, User.find(2), :approve => true)

    # Step 1 was signed by user 2, so the turn -- and the mail -- is user 3's.
    assert_equal [User.find(3).mail], extension_mails.flat_map(&:to).uniq
  end

  def test_no_extension_mail_once_the_request_is_decided
    extension = build_pending_extension(:approvers => [{:approver_user_id => 2}])

    RedmineApprovalWorkflow::ExtensionApproval.decide(extension, User.find(2), :approve => true)

    assert extension.reload.approved?
    assert_empty extension_mails, 'nobody is waiting on this request any more'
  end

  def test_extension_mail_is_off_when_the_setting_is_off
    set_plugin_settings('notify_on_pending_approval' => '0')
    extension = build_pending_extension

    ApprovalMailer.deliver_extension_pending(extension)

    assert_empty extension_mails
  end

  def test_extension_notification_failure_does_not_undo_the_signature
    extension = build_pending_extension
    ApprovalMailer.stubs(:deliver_extension_pending).raises(StandardError, 'smtp down')

    assert_difference 'ApprovalSignature.count', 1 do
      RedmineApprovalWorkflow::ExtensionApproval.decide(extension, User.find(2), :approve => true)
    end
  end

  def test_notification_failure_does_not_break_issue_creation
    ApprovalMailer.stubs(:deliver_approval_pending).raises(StandardError, 'smtp down')

    assert_difference 'Issue.count', 1 do
      Issue.generate!(:project_id => @issue.project_id, :tracker_id => @issue.tracker_id,
                      :status_id => 1, :subject => 'Van chay')
    end
  end
end
