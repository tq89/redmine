# frozen_string_literal: true

# Tells the people who may sign the pending step that it is their turn.
#
# Subclasses Mailer so the From header, List-Id, delivery job and the
# "do not notify me about my own actions" preference all behave as they do for
# core Redmine mail.
class ApprovalMailer < Mailer
  # The first argument must be a User: Mailer#process switches User.current and
  # the locale to the recipient so the mail is written in their language.
  def approval_pending(user, issue, step_name, target_status_name)
    redmine_headers 'Project' => issue.project.identifier,
                    'Issue-Tracker' => issue.tracker.name,
                    'Issue-Id' => issue.id
    @user = user
    @issue = issue
    @step_name = step_name
    @target_status_name = target_status_name
    @issue_url = url_for(:controller => 'issues', :action => 'show', :id => issue)
    @approve_url = url_for(:controller => 'approvals', :action => 'new',
                           :issue_id => issue, :decision => 'approve')
    @message_id_object = issue

    mail :to => user,
         :subject => "[#{issue.project.name} - #{issue.tracker.name} ##{issue.id}] " \
                     "#{l(:mail_subject_approval_pending)}"
  end

  class << self
    # Notifies whoever can now sign +issue+. +actor+ is the person whose action
    # created this turn and is never notified of their own move.
    def deliver_approval_pending(issue, actor = nil)
      return unless enabled?
      return unless issue.approval_route? && !issue.approval_completed?

      step = issue.current_approval_step
      return if step.nil?

      @author = actor
      recipients(issue, step, actor).each do |user|
        approval_pending(user, issue, step.name, step.issue_status.name).deliver_later
      end
    end

    def enabled?
      values = Setting.plugin_redmine_approval_workflow
      values.is_a?(Hash) && values['notify_on_pending_approval'].to_s == '1'
    end

    # Narrowed by the roles that actually hold the transition before the exact
    # per-user check, so a large project does not mean a check per member.
    def recipients(issue, step, actor = nil)
      role_ids = WorkflowTransition.
                 where(:tracker_id => issue.tracker_id,
                       :old_status_id => issue.status_id,
                       :new_status_id => step.issue_status_id).
                 distinct.pluck(:role_id)
      return [] if role_ids.empty?

      User.active.
        joins(:members => :member_roles).
        where(:members => {:project_id => issue.project_id}).
        where(:member_roles => {:role_id => role_ids}).
        distinct.
        to_a.
        select {|user| notifiable?(user, issue, actor)}
    end

    # Being asked to sign is a direct request rather than a subscription, so
    # the "only things I watch" preferences do not apply; users who switched
    # mail off entirely are still left alone.
    def notifiable?(user, issue, actor)
      return false if actor && user.id == actor.id
      return false if user.mail.blank? || user.mail_notification == 'none'

      issue.visible?(user) && issue.can_approve?(user)
    end
  end
end
