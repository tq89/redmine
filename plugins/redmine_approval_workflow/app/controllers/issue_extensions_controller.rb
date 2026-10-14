# frozen_string_literal: true

class IssueExtensionsController < ApplicationController
  helper :issues
  helper :approval_workflow

  before_action :find_extendable_issue
  before_action :authorize, :only => [:new, :create]
  before_action :find_extension, :only => [:approve, :reject, :withdraw]

  def new
    @extension = build_extension(:new_due_date => default_new_due_date)
    # The same gate as create. Checking only the permission here rendered a
    # form that create would then refuse.
    deny_access unless requester_allowed?
  end

  def create
    @extension = build_extension(
      :new_due_date => params.dig(:issue_extension, :new_due_date).presence,
      :reason => params.dig(:issue_extension, :reason).presence
    )

    return deny_access unless requester_allowed?

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

  # Taking a request back before anyone decided it. The person who asked may,
  # and so may an administrator; it is the way out for a request nobody on the
  # chain is able to sign, which would otherwise sit pending and keep using up
  # the issue's allowance.
  def withdraw
    return deny_access unless @extension.withdrawable_by?(User.current)

    @extension.update_columns(:status => IssueExtension::WITHDRAWN, :decided_at => Time.current)
    extension_reply(:notice, l(:notice_issue_extension_withdrawn))
  end

  private

  def decide(approving)
    # Said plainly rather than as a bare 403: the approver may sign, it is the
    # request that no longer matches the issue. Refusing it, or the requester
    # withdrawing and asking again from the current date, both still work.
    if approving && @extension.stale? && @extension.signable_by?(User.current)
      return extension_reply(:error,
                             l(:error_issue_extension_stale,
                               :requested => format_date(@extension.previous_due_date),
                               :current => format_date(@issue.due_date)),
                             :status => :unprocessable_entity)
    end

    signature = RedmineApprovalWorkflow::ExtensionApproval.decide(
      @extension, User.current,
      :approve => approving, :comments => params[:comments]
    )
    if signature.nil?
      return deny_access
    end

    notice =
      if @extension.reload.approved?
        l(:notice_issue_extended, :date => format_date(@extension.new_due_date))
      elsif @extension.rejected?
        l(:notice_issue_extension_rejected)
      else
        l(:notice_approval_signed)
      end

    extension_reply(:notice, notice)
  end

  # The bell acts from a background post so the page it is open on stays put;
  # it asks for JSON and shows the message in place. A flash set for it would
  # instead turn up on some unrelated page later on.
  def extension_reply(level, message, status: :ok)
    respond_to do |format|
      format.html do
        flash[level] = message
        redirect_to issue_path(@issue)
      end
      format.json {render :json => {:level => level, :message => message}, :status => status}
    end
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

  # Judges the requester against the path THIS request will take: the route it
  # was built with. A route switched off between loading the form and posting
  # it means an immediate write, and the strict rule then applies -- the check
  # can never pass on the chain rule and then apply without a chain.
  def requester_allowed?
    @issue.extendable_by?(User.current, :route => @extension.approval_route)
  end

  def build_extension(attrs)
    IssueExtension.new(attrs).tap do |extension|
      extension.issue = @issue
      extension.user = User.current
      extension.previous_due_date = @issue.due_date
      # Issue#extension_route is also what the request gate reads, so the rule
      # a requester is judged by and the path the request takes are the same.
      route = @issue.extension_route
      extension.approval_route = route
      extension.status = route ? IssueExtension::PENDING : IssueExtension::APPROVED
    end
  end

  def default_new_due_date
    base = @issue.due_date || User.current.today
    limit = IssueExtension.max_days
    limit > 0 ? base + limit : base + 7
  end
end
