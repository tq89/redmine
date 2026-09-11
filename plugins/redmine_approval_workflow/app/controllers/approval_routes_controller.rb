# frozen_string_literal: true

class ApprovalRoutesController < ApplicationController
  layout 'admin'
  self.main_menu = false

  before_action :require_admin
  before_action :find_route, :only => [:edit, :update, :destroy]

  def index
    @routes = ApprovalRoute.sorted.includes(:tracker, :project, :steps)
  end

  def new
    @route = ApprovalRoute.new
    @route.steps.build(:position => 0)
  end

  def create
    @route = ApprovalRoute.new(route_params)
    if @route.save
      renumber_steps
      flash[:notice] = l(:notice_successful_create)
      redirect_to approval_routes_path
    else
      @route.steps.build(:position => 0) if @route.steps.empty?
      render :new
    end
  end

  def edit; end

  def update
    @route.assign_attributes(route_params)
    if @route.save
      renumber_steps
      flash[:notice] = l(:notice_successful_update)
      redirect_to approval_routes_path
    else
      render :edit
    end
  end

  def destroy
    @route.destroy
    redirect_to approval_routes_path
  end

  private

  def find_route
    @route = ApprovalRoute.find(params[:id])
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
      :name, :tracker_id, :project_id, :rejected_status_id, :description, :active,
      :steps_attributes => [:id, :name, :issue_status_id, :position, :_destroy]
    )
  end
end
