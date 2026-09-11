# frozen_string_literal: true

module RedmineApprovalWorkflow
  # render_on renders through the calling view, so the partial keeps access to
  # the application helpers and to this plugin's own helper.
  class Hooks < Redmine::Hook::ViewListener
    render_on :view_issues_show_description_bottom,
              :partial => 'approval_workflow/issue_panel'

    def view_layouts_base_html_head(context = {})
      stylesheet_link_tag('approval_workflow', :plugin => 'redmine_approval_workflow')
    end
  end
end
