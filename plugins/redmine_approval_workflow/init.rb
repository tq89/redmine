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
      'require_extension_reason' => '1',
      'show_pending_approvals' => '1',
      'notify_on_pending_approval' => '0'
    },
    :partial => 'settings/approval_workflow_settings'
  )

  menu :admin_menu, :approval_routes, {:controller => 'approval_routes', :action => 'index'},
       :caption => :label_approval_route_plural,
       :icon => 'workflows',
       :html => {:class => 'icon icon-workflows'}

  # Reminder of steps waiting for the signed-in user. Menu captions are
  # h-escaped by render_single_menu_node, so the count is plain text rather
  # than badge markup. The item hides itself when there is nothing to sign;
  # both the :if and the caption read the same per-request memo, so the
  # lookup runs once per page.
  menu :top_menu, :pending_approvals,
       {:controller => 'pending_approvals', :action => 'index'},
       # The block runs with the Redmine::Plugin instance as self, which has no
       # view helpers, so translation goes through I18n directly.
       :caption => Proc.new {
         ::I18n.t(:label_pending_approval_with_count,
                  :count => User.current.pending_approval_count)
       },
       :if => Proc.new {User.current.logged? && User.current.pending_approvals?},
       :html => {:class => 'pending-approvals-alert'},
       :last => true

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

unless User.included_modules.include?(RedmineApprovalWorkflow::UserPatch)
  User.include RedmineApprovalWorkflow::UserPatch
end

# config.action_controller.include_all_helpers is false in Redmine, so the
# plugin helper has to be registered explicitly to be reachable from the issue
# page partial rendered by the view hook.
ApplicationController.helper(ApprovalWorkflowHelper)

# Touch the hook class so it registers itself even when it is not eager loaded.
RedmineApprovalWorkflow::Hooks
