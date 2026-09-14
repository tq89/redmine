# frozen_string_literal: true

require File.expand_path(File.dirname(__FILE__) + '/../../../test/test_helper')

module RedmineApprovalWorkflow
  module TestFixtures
    # Builds a two-step chain on the given tracker, using statuses that the
    # core fixtures already wire into a workflow.
    def build_route(tracker_id: 1, project_id: nil, statuses: [2, 3], rejected_status_id: nil)
      route = ApprovalRoute.create!(
        :name => 'Lưu trình thử',
        :tracker_id => tracker_id,
        :project_id => project_id,
        :rejected_status_id => rejected_status_id
      )
      statuses.each_with_index do |status_id, index|
        route.steps.create!(:name => "Bước #{index + 1}", :position => index, :issue_status_id => status_id)
      end
      route.reload
    end

    # Builds an extension chain. Extension steps carry no status, so each one
    # has to name its approver; +approvers+ is one attribute hash per step.
    def build_extension_route(tracker_id: 1, project_id: nil,
                              approvers: [{:approver_user_id => 2}, {:approver_user_id => 3}])
      route = ApprovalRoute.create!(
        :name => 'Lưu trình gia hạn',
        :tracker_id => tracker_id,
        :project_id => project_id,
        :kind => ApprovalRoute::EXTENSION_KIND
      )
      approvers.each_with_index do |attrs, index|
        route.steps.create!({:name => "Duyệt #{index + 1}", :position => index}.merge(attrs))
      end
      route.reload
    end

    def set_plugin_settings(values)
      Setting.plugin_redmine_approval_workflow = {
        'max_extension_days' => '30',
        'max_extension_count' => '0',
        'require_extension_reason' => '0'
      }.merge(values)
    end
  end
end
