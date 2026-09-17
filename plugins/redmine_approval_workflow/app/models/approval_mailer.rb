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

  # A refusal, to the person who has to do something about it. What they need
  # is which step said no, who said it, and why -- the comment is the whole
  # point of the mail.
  def approval_rejected(user, issue, step_name, comments, actor_id = nil)
    redmine_headers 'Project' => issue.project.identifier,
                    'Issue-Tracker' => issue.tracker.name,
                    'Issue-Id' => issue.id
    @author = User.find_by_id(actor_id)
    @user = user
    @issue = issue
    @step_name = step_name
    @comments = comments
    @status_name = issue.status.name
    @issue_url = url_for(:controller => 'issues', :action => 'show', :id => issue)
    @message_id_object = issue

    mail :to => user,
         :subject => "[#{issue.project.name} - #{issue.tracker.name} ##{issue.id}] " \
                     "#{l(:mail_subject_approval_rejected)}"
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

    # Tells the person whose work it is that a step refused it. Being handed
    # something back is news you need whether or not you are the next signer,
    # so this does not go through the signing queue.
    def deliver_approval_rejected(issue, signature = nil)
      return unless enabled?
      return unless issue.approval_route?

      actor = signature&.user
      rejected_recipients(issue, actor).each do |user|
        approval_rejected(user, issue, signature&.step_name,
                          signature&.comments, actor&.id).deliver_later
      end
    end

    # Người thực hiện, or the person who raised it when it is assigned to
    # nobody -- somebody has to be told, and an unassigned issue still has an
    # author. RejectedApprovals uses the same rule so the bell and the inbox
    # never disagree about who was notified.
    def rejected_recipients(issue, actor = nil)
      targets = assignee_users(issue)
      targets = Array(issue.author) if targets.empty?

      targets.uniq.select do |user|
        next false if actor && user.id == actor.id
        next false if user.mail.blank? || user.mail_notification == 'none'

        user.active? && issue.visible?(user)
      end
    end

    def assignee_users(issue)
      principal = issue.assigned_to
      return [] if principal.nil?
      return principal.users.select(&:active?).to_a if principal.is_a?(Group)

      principal.is_a?(User) && principal.active? ? [principal] : []
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

    # Only the approvers whose turn it actually is: everybody on the list when
    # one signature is enough, and only the next name when the step wants them
    # all. With no list at all, the roles that hold the transition.
    def candidates(issue, step)
      open = step.open_approvers(issue.approval_step_signatures)
      return open.flat_map {|approver| approver.users_for(issue)}.uniq if open.any?
      return [] if step.assigned?

      role_ids =
        WorkflowTransition.
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
        to_a
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

    # An extension step always lists its approvers -- the model refuses to save
    # one that does not -- so the candidate set is already the narrow one and
    # there is no workflow transition to widen it back out.
    def extension_recipients(extension, step, actor = nil)
      issue = extension.issue
      candidates = step.open_approvers(extension.approval_step_signatures).
                   flat_map {|approver| approver.users_for(issue)}.uniq

      candidates.select do |user|
        next false if actor && user.id == actor.id
        next false if user.mail.blank? || user.mail_notification == 'none'

        issue.visible?(user) && extension.signable_by?(user)
      end
    end
  end
end
