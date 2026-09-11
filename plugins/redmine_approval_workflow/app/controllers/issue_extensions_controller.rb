# frozen_string_literal: true

class IssueExtensionsController < ApplicationController
  helper :issues
  helper :approval_workflow

  before_action :find_extendable_issue
  before_action :authorize

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
        journal = @issue.init_journal(User.current, journal_notes)
        @issue.due_date = @extension.new_due_date
        @issue.save!
        @extension.journal_id = journal.id if journal.persisted?
        @extension.save!
      end
      flash[:notice] = l(:notice_issue_extended, :date => format_date(@extension.new_due_date))
      redirect_to issue_path(@issue)
    else
      render :new
    end
  rescue ActiveRecord::RecordInvalid => e
    @extension.errors.add(:base, e.record.errors.full_messages.join(', '))
    render :new
  end

  private

  def find_extendable_issue
    @issue = Issue.find(params[:issue_id])
    raise Unauthorized unless @issue.visible?

    @project = @issue.project
  rescue ActiveRecord::RecordNotFound
    render_404
  end

  def build_extension(attrs)
    IssueExtension.new(attrs).tap do |extension|
      extension.issue = @issue
      extension.user = User.current
      extension.previous_due_date = @issue.due_date
    end
  end

  def default_new_due_date
    base = @issue.due_date || User.current.today
    limit = IssueExtension.max_days
    limit > 0 ? base + limit : base + 7
  end

  def journal_notes
    header = l(:text_extension_journal,
               :days => @extension.days,
               :date => format_date(@extension.new_due_date))
    [header, @extension.reason.presence].compact.join("\n\n")
  end
end
