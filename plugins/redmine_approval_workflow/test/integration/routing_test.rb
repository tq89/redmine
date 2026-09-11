# frozen_string_literal: true

require_relative '../test_helper'

# Redmine evaluates a plugin's config/routes.rb inside Rails.application.routes
# .draw, after every core route. These assertions prove the plugin's own routes
# resolve from there, with no core routes.rb edit.
class RedmineApprovalWorkflowRoutingTest < Redmine::RoutingTest
  def test_service_worker
    should_route 'GET /sw.js' => 'service_worker#show', :format => 'js'
  end

  def test_pending_approvals
    should_route 'GET /pending_approvals' => 'pending_approvals#index'
  end

  def test_project_scoped_approval_routes
    should_route 'GET /projects/foo/approval_routes/new' => 'approval_routes#new',
                 :project_id => 'foo'
    should_route 'POST /projects/foo/approval_routes' => 'approval_routes#create',
                 :project_id => 'foo'
  end

  def test_issue_scoped_actions
    should_route 'POST /issues/1/approvals' => 'approvals#create', :issue_id => '1'
    should_route 'GET /issues/1/extensions/new' => 'issue_extensions#new', :issue_id => '1'
  end
end
