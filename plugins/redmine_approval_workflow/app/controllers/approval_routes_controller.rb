# frozen_string_literal: true

# Approval chains are configured per project, from the project's own settings,
# and only ever govern issues of that project.
class ApprovalRoutesController < ApplicationController
  menu_item :settings

  before_action :find_project_by_project_id
  before_action :authorize
  before_action :find_route, :only => [:edit, :update, :destroy]

  def index
    redirect_to settings_project_path(@project, :tab => 'approval_routes')
  end

  def new
    @route = @project.approval_routes.build(:kind => route_kind)
    3.times {|index| @route.steps.build(:position => index)}
  end

  def create
    @route = @project.approval_routes.build(route_params)
    if @route.save
      renumber_steps
      flash[:notice] = l(:notice_successful_create)
      redirect_to settings_project_path(@project, :tab => 'approval_routes')
    else
      @route.steps.build(:position => 0) if @route.steps.empty?
      render :new
    end
  end

  def edit
    3.times {|index| @route.steps.build(:position => @route.steps.size + index)}
  end

  def update
    @route.assign_attributes(route_params)
    if @route.save
      renumber_steps
      flash[:notice] = l(:notice_successful_update)
      redirect_to settings_project_path(@project, :tab => 'approval_routes')
    else
      render :edit
    end
  end

  def destroy
    @route.destroy
    redirect_to settings_project_path(@project, :tab => 'approval_routes')
  end

  private

  def route_kind
    kind = params[:kind].to_s
    ApprovalRoute::KINDS.include?(kind) ? kind : ApprovalRoute::ISSUE_KIND
  end

  def find_route
    @route = @project.approval_routes.find(params[:id])
  rescue ActiveRecord::RecordNotFound
    render_404
  end

  # Positions drive the whole chain, so they are normalised to 0..n-1 in form
  # order rather than trusting whatever the form posted.
  def renumber_steps
    @route.steps.reload.each_with_index do |step, index|
      step.update_column(:position, index) unless step.position == index
    end
  end

  def route_params
    params.require(:approval_route).permit(
      :name, :kind, :rejected_status_id, :description, :active,
      :tracker_ids => [],
      # approver_tokens is the chip row: one entry per chip, in the order the
      # chips sit in, which is the order an "all" step collects signatures in.
      :steps_attributes => [:id, :name, :issue_status_id, :position,
                            :approval_mode, :button_label, :assign_signer, :_destroy,
                            {:approver_tokens => []}]
    )
  end
end
