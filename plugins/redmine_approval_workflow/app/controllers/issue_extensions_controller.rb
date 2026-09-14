# frozen_string_literal: true

class IssueExtensionsController < ApplicationController
  helper :issues
  helper :approval_workflow

  before_action :find_extendable_issue
  before_action :authorize, :only => [:new, :create]
  before_action :find_extension, :only => [:approve, :reject]

  def new
    @extension = build_extension(:new_due_date => default_new_due_date)
  end

  def create
    @extension = build_extension(
      :new_due_date => params.dig(:issue_extension, :new_due_date).presence,
      :reason => params.dig(:issue_extension, :reason).presence
    )

    unless @issue.extendable_by?(User.current)
      return deny_access
    end

    if @extension.valid?
      IssueExtension.transaction do
        if @extension.approval_route
          # Somebody has to say yes first; the deadline stays where it is.
          @extension.save!
        else
          @extension.save!
          RedmineApprovalWorkflow::ExtensionApproval.apply(@extension, User.current)
        end
      end
      RedmineApprovalWorkflow::ExtensionApproval.notify_current_step(@extension, User.current)
      flash[:notice] =
        if @extension.pending?
          l(:notice_issue_extension_requested)
        else
          l(:notice_issue_extended, :date => format_date(@extension.new_due_date))
        end
      redirect_to issue_path(@issue)
    else
      render :new
    end
  rescue ActiveRecord::RecordInvalid => e
    @extension.errors.add(:base, e.record.errors.full_messages.join(', '))
    render :new
  end

  def approve
    decide(true)
  end

  def reject
    decide(false)
  end

  private

  def decide(approving)
    signature = RedmineApprovalWorkflow::ExtensionApproval.decide(
      @extension, User.current,
      :approve => approving, :comments => params[:comments]
    )
    if signature.nil?
      return deny_access
    end

    flash[:notice] =
      if @extension.reload.approved?
        l(:notice_issue_extended, :date => format_date(@extension.new_due_date))
      elsif @extension.rejected?
        l(:notice_issue_extension_rejected)
      else
        l(:notice_approval_signed)
      end
    redirect_to issue_path(@issue)
  end

  def find_extendable_issue
    @issue = Issue.find(params[:issue_id])
    raise Unauthorized unless @issue.visible?

    @project = @issue.project
  rescue ActiveRecord::RecordNotFound
    render_404
  end

  def find_extension
    @extension = @issue.issue_extensions.find(params[:id])
  rescue ActiveRecord::RecordNotFound
    render_404
  end

  def build_extension(attrs)
    IssueExtension.new(attrs).tap do |extension|
      extension.issue = @issue
      extension.user = User.current
      extension.previous_due_date = @issue.due_date
      route = ApprovalRoute.extension_for_issue(@issue)
      if route && route.step_count > 0
        extension.approval_route = route
        extension.status = IssueExtension::PENDING
      else
        extension.status = IssueExtension::APPROVED
      end
    end
  end

  def default_new_due_date
    base = @issue.due_date || User.current.today
    limit = IssueExtension.max_days
    limit > 0 ? base + limit : base + 7
  end
end
