# frozen_string_literal: true

class ApprovalsController < ApplicationController
  helper :issues
  helper :approval_workflow

  before_action :find_approval_issue
  before_action :find_route
  before_action :build_decision, :only => [:new, :create]

  def index
    @signatures = @issue.approval_signatures.sorted
  end

  def new
    render :new
  end

  def create
    # Issue#safe_attributes= silently drops a status the workflow does not
    # allow, so the transition is authorised explicitly here and the status is
    # then assigned directly. Without this check a forbidden signature would
    # look like it succeeded while leaving the status untouched.
    unless @issue.approval_signable_by?(User.current, @target_status)
      return deny_access
    end

    @signature = ApprovalSignature.new(
      :issue => @issue,
      :approval_route => @route,
      :approval_route_step => @step,
      :step_position => @position,
      :step_name => @step&.name,
      :user => User.current,
      :action => @approving ? ApprovalSignature::APPROVED : ApprovalSignature::REJECTED,
      :from_status_id => @issue.status_id,
      :to_status_id => @target_status.id,
      :comments => params[:comments].presence
    )

    ApprovalSignature.transaction do
      journal = @issue.init_journal(User.current, journal_notes)
      @issue.status = @target_status
      @issue.save!
      @signature.journal_id = journal.id if journal.persisted?
      @signature.save!
    end

    flash[:notice] = l(@approving ? :notice_approval_signed : :notice_approval_rejected)
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

  def build_decision
    @approving = params[:decision].to_s != 'reject'
    @position = @issue.approval_position
    @step = @route.step_at(@position)
    @target_status = @approving ? @issue.approval_target_status : @issue.approval_reject_target_status

    if @approving && @issue.approval_completed?
      flash[:error] = l(:error_approval_already_completed)
      return redirect_to issue_path(@issue)
    end

    if @target_status.nil?
      flash[:error] = l(:error_approval_no_target_status)
      redirect_to issue_path(@issue)
    end
  end

  def journal_notes
    label = @step ? @step.name : @route.name
    header =
      if @approving
        l(:text_approval_journal_signed, :step => label)
      else
        l(:text_approval_journal_rejected, :step => label)
      end
    [header, params[:comments].presence].compact.join("\n\n")
  end
end
