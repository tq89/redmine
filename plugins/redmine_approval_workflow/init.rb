# frozen_string_literal: true

require 'redmine'

Redmine::Plugin.register :redmine_approval_workflow do
  name 'Redmine Approval Workflow'
  author 'Đỗ Quí'
  description 'Lưu trình ký duyệt và gia hạn công việc'
  version '1.0.0'
  url 'https://trongqui.info'

  requires_redmine :version_or_higher => '6.0.0'

  settings(
    :default => {
      'max_extension_days' => '30',
      'max_extension_count' => '0',
      'require_extension_reason' => '1'
    },
    :partial => 'settings/approval_workflow_settings'
  )

  menu :admin_menu, :approval_routes, {:controller => 'approval_routes', :action => 'index'},
       :caption => :label_approval_route_plural,
       :icon => 'workflows',
       :html => {:class => 'icon icon-workflows'}

  project_module :approval_workflow do
    # Signing itself is NOT gated by a permission of its own: it is gated by the
    # workflow transition the signature performs, so that "who may sign" always
    # equals "who may move the issue into that status" (Issue#new_statuses_allowed_to).
    # This permission only decides who sees the panel at all.
    permission :view_approval_workflow,
               {:approvals => [:index]},
               :read => true
    permission :extend_issue_due_date,
               {:issue_extensions => [:new, :create]}
  end
end

# PluginLoader already evaluates init.rb inside a to_prepare block, so this runs
# once per boot in production and on every reload in development. Nesting
# another to_prepare here would stack a fresh callback on each reload.
unless Issue.included_modules.include?(RedmineApprovalWorkflow::IssuePatch)
  Issue.include RedmineApprovalWorkflow::IssuePatch
end

# config.action_controller.include_all_helpers is false in Redmine, so the
# plugin helper has to be registered explicitly to be reachable from the issue
# page partial rendered by the view hook.
ApplicationController.helper(ApprovalWorkflowHelper)

# Touch the hook class so it registers itself even when it is not eager loaded.
RedmineApprovalWorkflow::Hooks
