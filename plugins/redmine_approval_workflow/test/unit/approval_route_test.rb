# frozen_string_literal: true

require_relative '../test_helper'

class ApprovalRouteTest < ActiveSupport::TestCase
  include RedmineApprovalWorkflow::TestFixtures

  def setup
    User.current = nil
    ApprovalRoute.delete_all
    ApprovalRouteStep.delete_all
  end

  def test_for_issue_returns_route_matching_tracker
    route = build_route(:tracker_id => 1)
    issue = Issue.find(1)

    assert_equal 1, issue.tracker_id
    assert_equal route, ApprovalRoute.for_issue(issue)
  end

  def test_for_issue_ignores_other_trackers
    build_route(:tracker_id => 2)

    assert_nil ApprovalRoute.for_issue(Issue.find(1))
  end

  def test_for_issue_ignores_inactive_routes
    route = build_route(:tracker_id => 1)
    route.update!(:active => false)

    assert_nil ApprovalRoute.for_issue(Issue.find(1))
  end

  def test_project_route_wins_over_global_route
    issue = Issue.find(1)
    build_route(:tracker_id => 1, :project_id => nil)
    project_route = build_route(:tracker_id => 1, :project_id => issue.project_id)

    assert_equal project_route, ApprovalRoute.for_issue(issue)
  end

  def test_global_route_applies_when_no_project_route_exists
    issue = Issue.find(1)
    build_route(:tracker_id => 1, :project_id => issue.project_id + 100)
    global_route = build_route(:tracker_id => 1, :project_id => nil)

    assert_equal global_route, ApprovalRoute.for_issue(issue)
  end

  def test_steps_are_ordered_by_position
    route = build_route(:tracker_id => 1, :statuses => [2, 3])
    route.steps.first.update!(:position => 5)

    assert_equal [3, 2], route.reload.steps.map(&:issue_status_id)
  end

  def test_name_and_tracker_are_required
    route = ApprovalRoute.new
    assert_not route.valid?
    assert_includes route.errors.attribute_names, :name
    assert_includes route.errors.attribute_names, :tracker_id
  end

  def test_destroying_route_destroys_steps
    route = build_route(:tracker_id => 1)
    assert_difference 'ApprovalRouteStep.count', -2 do
      route.destroy
    end
  end
end
