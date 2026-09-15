# frozen_string_literal: true

class ApprovalsController < ApplicationController
  helper :issues
  helper :approval_workflow

  before_action :find_approval_issue
  before_action :find_route
  before_action :authorize_sync, :only => [:sync]
  before_action :build_decision, :only => [:new, :create]

  def index
    @signatures = @issue.approval_signatures.sorted
  end

  def new
    render :new
  end

  # Reconciles this one issue against its status history on demand, for when an
  # administrator does not want to wait for the next status change.
  def sync
    created = RedmineApprovalWorkflow::HistorySync.backfill(@issue, :force => true)
    flash[:notice] =
      if created.any?
        l(:notice_approval_history_synced, :count => created.size)
      else
        l(:notice_approval_history_already_in_sync)
      end
    redirect_to issue_path(@issue)
  end

  def create
    # Issue#safe_attributes= silently drops a status the workflow does not
    # allow, so the transition is authorised explicitly here and the status is
    # then assigned directly. Without this check a forbidden signature would
    # look like it succeeded while leaving the status untouched.
    #
    # @step is passed deliberately: it is what applies the step's approver
    # list. Leaving it out authorised the transition alone, so somebody who
    # held it could sign a step listed to another person by posting here --
    # the buttons were hidden from them, the endpoint was not.
    unless @issue.approval_signable_by?(User.current, @target_status, @step, @collected)
      return deny_access
    end

    @signature = ApprovalSignature.new(
      :issue => @issue,
      :approval_route => @route,
      :approval_route_step => @step,
      :approval_route_approver => @step&.approver_for(User.current, @issue, @collected),
      :step_position => @position,
      :step_name => @step&.name,
      :user => User.current,
      :action => @approving ? ApprovalSignature::APPROVED : ApprovalSignature::REJECTED,
      :from_status_id => @issue.status_id,
      :to_status_id => @target_status.id,
      :comments => params[:comments].presence
    )

    # A step that asks for every signature on its list does not move the issue
    # until it has them all. Until then the signature is recorded and the issue
    # stays where it is.
    @completes_step = !@approving || @step.nil? ||
                      @step.satisfied_by?(@collected + [@signature])

    ApprovalSignature.transaction do
      if @completes_step
        journal = @issue.init_journal(User.current, journal_notes)
        # Before the status moves, and before the save: field permissions are
        # read off the status the issue is IN, so checking after the assignment
        # of @target_status would ask about the wrong status entirely. Being in
        # the same save keeps the handover in one journal entry with the status
        # change rather than as a second, separate edit.
        @assignment_warning = assign_signer_to_issue
        make_signer_the_author
        @issue.status = @target_status
        # This save is the signature itself; letting the history reconciler
        # also see it would advance the chain twice for one decision.
        @issue.skip_approval_sync = true
        @issue.save!
        @signature.journal_id = journal.id if journal.persisted?
      elsif journal_notes.present?
        # Nothing changes on the issue, but a comment the signer typed still
        # belongs in the history.
        journal = @issue.init_journal(User.current, journal_notes)
        @issue.save!
        @signature.journal_id = journal.id if journal.persisted?
      end
      @signature.save!
    end

    # Somebody is always handed the next move: the next name on this step, the
    # next step, or the previous one after a rejection.
    ApprovalMailer.deliver_approval_pending(@issue.reload, User.current)

    flash[:notice] = decision_notice
    flash[:warning] = @assignment_warning if @assignment_warning
    redirect_to issue_path(@issue)
  rescue ActiveRecord::RecordInvalid => e
    flash[:error] = e.record.errors.full_messages.join(', ')
    redirect_to issue_path(@issue)
  end

  private

  def find_approval_issue
    @issue = Issue.find(params[:issue_id])
    raise Unauthorized unless @issue.visible?

    @project = @issue.project
  rescue ActiveRecord::RecordNotFound
    render_404
  end

  def find_route
    @route = @issue.approval_route
    render_404 unless @issue.approval_route?
  end

  def authorize_sync
    deny_access unless User.current.allowed_to?(:sync_approval_history, @project)
  end

  def build_decision
    @approving = params[:decision].to_s != 'reject'
    current_position = @issue.approval_position
    requested = requested_step
    return deny_access if params[:step_id].present? && requested.nil?

    if requested && requested.position != current_position
      # A step other than the one due was asked for. Only a forward, skippable
      # step this user may sign qualifies; anything else is REFUSED rather than
      # quietly signing whatever happened to be due instead. The button named a
      # step, and signing a different one on somebody's behalf would be worse
      # than refusing.
      return deny_access unless @approving && @issue.approval_can_skip_to?(User.current, requested)

      # A step reached over the ones before it has collected nothing, so the
      # "all" bookkeeping starts from empty rather than from the pending step's.
      @skipping = true
      @step = requested
      @position = requested.position
      @collected = []
      @target_status = requested.issue_status
    else
      @skipping = false
      @position = current_position
      @step = @route.step_at(@position)
      @collected = @issue.approval_step_signatures
      @target_status = @approving ? @issue.approval_target_status : @issue.approval_reject_target_status

      if @approving && @issue.approval_completed?
        flash[:error] = l(:error_approval_already_completed)
        return redirect_to issue_path(@issue)
      end
    end

    if @target_status.nil?
      flash[:error] = l(:error_approval_no_target_status)
      redirect_to issue_path(@issue)
    end
  end

  def requested_step
    return nil if params[:step_id].blank?

    @route.steps.detect {|step| step.id == params[:step_id].to_i}
  end

  # "Nhận việc": the signature that finishes the step hands the issue to whoever
  # gave it. Returns a warning to show when the handover could not be made --
  # never silently: somebody pressed a button labelled "take this job" and is
  # entitled to know if the job did not move.
  def assign_signer_to_issue
    return nil unless @approving
    return nil unless @step&.assigns_signer?
    return nil if @issue.assigned_to_id == User.current.id

    # Same principle as everything else here: the workflow's field permissions
    # decide, not the plugin. A role that may not touch assigned_to at this
    # status does not get to change it by pressing a different button.
    if @issue.read_only_attribute_names(User.current).include?('assigned_to_id')
      return l(:warning_signer_not_assigned_readonly)
    end
    # Redmine would reject the save otherwise, taking the signature down with it.
    unless @issue.assignable_users.include?(User.current)
      return l(:warning_signer_not_assignable)
    end

    @issue.assigned_to = User.current
    nil
  end

  # "Giao việc": the signature that finishes the step makes the signer the
  # issue's author. Nothing can refuse it the way a field permission can refuse
  # the assignee -- Redmine has no workflow rule for author_id -- so the only
  # gate is that the admin configured this step and this user may sign it.
  # author_id is journalized, so the change shows in the issue history.
  def make_signer_the_author
    return unless @approving
    return unless @step&.assigns_author?
    return if @issue.author_id == User.current.id

    @issue.author = User.current
  end

  # A step still collecting signatures says so, and names who it is waiting on.
  def decision_notice
    return l(:notice_approval_rejected) unless @approving
    return l(:notice_approval_skipped, :step => @step.name) if @completes_step && @skipping
    return l(:notice_approval_signed) if @completes_step

    waiting = @issue.reload.current_approval_step&.
              next_approver(@issue.approval_step_signatures)
    if waiting
      l(:notice_approval_signed_waiting, :name => waiting.label)
    else
      l(:notice_approval_signed)
    end
  end

  # Only what the signer actually typed. Redmine journals the status change on
  # its own, and the step, the decision and who made it are already in the
  # signature and shown in the panel, so generating a note as well just repeats
  # the same fact in a second place.
  def journal_notes
    params[:comments].to_s
  end
end
