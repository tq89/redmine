# frozen_string_literal: true

module RedmineApprovalWorkflow
  # Redmine builds the project settings tabs from a plain helper with no hook,
  # so the tab is appended by wrapping it.
  module ProjectsHelperPatch
    def project_settings_tabs
      tabs = super
      if User.current.allowed_to?(:manage_approval_routes, @project) &&
         @project.module_enabled?(:approval_workflow)
        tabs << {
          :name => 'approval_routes',
          :action => :manage_approval_routes,
          :partial => 'projects/settings/approval_routes',
          :label => :label_approval_route_plural
        }
      end
      tabs
    end
  end
end
