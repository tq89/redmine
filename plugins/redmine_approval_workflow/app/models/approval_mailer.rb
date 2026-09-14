# frozen_string_literal: true

# Tells the people who may sign the pending step that it is their turn.
#
# Subclasses Mailer so the From header, List-Id, delivery job and the
# "do not notify me about my own actions" preference all behave as they do for
# core Redmine mail.
class ApprovalMailer < Mailer
  # The first argument must be a User: Mailer#process switches User.current and
  # the locale to the recipient so the mail is written in their language.
  def approval_pending(user, issue, step_name, target_status_name, actor_id = nil)
    redmine_headers 'Project' => issue.project.identifier,
                    'Issue-Tracker' => issue.tracker.name,
                    'Issue-Id' => issue.id
    # Mailer#mail reads @author off the mailer INSTANCE, for the From display
    # name, the Sender header and the "don't notify me about my own actions"
    # preference. Setting it on the class, as deliver_approval_pending used to,
    # looked right and did nothing.
    @author = User.find_by_id(actor_id)
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

  # Same idea for an extension request. It carries no status change, so what the
  # recipient needs to see is the deadline being asked for and why.
  def extension_pending(user, extension, step_name, actor_id = nil)
    issue = extension.issue
    redmine_headers 'Project' => issue.project.identifier,
                    'Issue-Tracker' => issue.tracker.name,
                    'Issue-Id' => issue.id
    @author = User.find_by_id(actor_id)
    @user = user
    @extension = extension
    @issue = issue
    @step_name = step_name
    @issue_url = url_for(:controller => 'issues', :action => 'show', :id => issue)
    # No @message_id_object: Mailer.token_for reads created_on/updated_on, which
    # an IssueExtension does not have. Referencing the issue is what threads
    # these under it in a mail client, and that is all that was wanted.
    references(issue)

    mail :to => user,
         :subject => "[#{issue.project.name} - #{issue.tracker.name} ##{issue.id}] " \
                     "#{l(:mail_subject_extension_pending)}"
  end

  class << self
    # Notifies whoever can now sign +issue+. +actor+ is the person whose action
    # created this turn and is never notified of their own move.
    def deliver_approval_pending(issue, actor = nil)
      return unless enabled?
      return unless issue.approval_route? && !issue.approval_completed?

      step = issue.current_approval_step
      return if step.nil?

      recipients(issue, step, actor).each do |user|
        approval_pending(user, issue, step.name, step.issue_status.name,
                         actor&.id).deliver_later
      end
    end

    # Notifies whoever can now sign +extension+.
    def deliver_extension_pending(extension, actor = nil)
      return unless enabled?
      return unless extension.pending?

      step = extension.current_approval_step
      return if step.nil?

      extension_recipients(extension, step, actor).each do |user|
        extension_pending(user, extension, step.name, actor&.id).deliver_later
      end
    end

    def enabled?
      values = Setting.plugin_redmine_approval_workflow
      values.is_a?(Hash) && values['notify_on_pending_approval'].to_s == '1'
    end

    # Narrowed before the exact per-user check so a large project does not mean
    # a check per member: to the named approver when the step has one, and
    # otherwise to the roles that actually hold the transition.
    def recipients(issue, step, actor = nil)
      candidates(issue, step).select {|user| notifiable?(user, issue, actor)}
    end

    def candidates(issue, step)
      return Array(User.active.find_by_id(step.approver_user_id)) if step.approver_user_id.present?
      return assignee_candidates(issue) if step.approver_dynamic.present?

      role_ids =
        if step.approver_role_id.present?
          [step.approver_role_id]
        else
          WorkflowTransition.
            where(:tracker_id => issue.tracker_id,
                  :old_status_id => issue.status_id,
                  :new_status_id => step.issue_status_id).
            distinct.pluck(:role_id)
        end
      return [] if role_ids.empty?

      User.active.
        joins(:members => :member_roles).
        where(:members => {:project_id => issue.project_id}).
        where(:member_roles => {:role_id => role_ids}).
        distinct.
        to_a
    end

    # A step assigned to "whoever the issue is assigned to". A group in that
    # field stands for its members, as it does everywhere else in Redmine.
    def assignee_candidates(issue)
      assignee = issue.assigned_to
      return [] if assignee.nil?
      return assignee.users.active.to_a if assignee.is_a?(Group)

      assignee.active? ? [assignee] : []
    end

    # Being asked to sign is a direct request rather than a subscription, so
    # the "only things I watch" preferences do not apply; users who switched
    # mail off entirely are still left alone. can_approve? already applies the
    # step's approver assignment, so a step that names its approver only ever
    # mails that role or that person.
    def notifiable?(user, issue, actor)
      return false if actor && user.id == actor.id
      return false if user.mail.blank? || user.mail_notification == 'none'

      issue.visible?(user) && issue.can_approve?(user)
    end

    # An extension step always names its approver -- the model refuses to save
    # one that does not -- so the candidate set is already the narrow one and
    # there is no workflow transition to widen it back out.
    def extension_recipients(extension, step, actor = nil)
      issue = extension.issue
      candidates =
        if step.approver_user_id.present?
          Array(User.active.find_by_id(step.approver_user_id))
        elsif step.approver_dynamic.present?
          assignee_candidates(issue)
        elsif step.approver_role_id.present?
          User.active.
            joins(:members => :member_roles).
            where(:members => {:project_id => issue.project_id}).
            where(:member_roles => {:role_id => step.approver_role_id}).
            distinct.
            to_a
        else
          []
        end

      candidates.select do |user|
        next false if actor && user.id == actor.id
        next false if user.mail.blank? || user.mail_notification == 'none'

        issue.visible?(user) && extension.signable_by?(user)
      end
    end
  end
end
