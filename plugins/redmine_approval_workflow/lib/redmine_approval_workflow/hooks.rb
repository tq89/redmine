# frozen_string_literal: true

module RedmineApprovalWorkflow
  # render_on renders through the calling view, so the partials keep access to
  # the application helpers and to this plugin's own helper.
  class Hooks < Redmine::Hook::ViewListener
    render_on :view_issues_show_description_bottom,
              :partial => 'approval_workflow/issue_panel'

    # Sits next to the avatar in the top bar, via a hook added to
    # app/views/layouts/base.html.erb.
    render_on :view_layouts_base_profile_menu_top,
              :partial => 'approval_workflow/bell'

    def view_layouts_base_html_head(context = {})
      stylesheet_link_tag('approval_workflow', :plugin => 'redmine_approval_workflow')
    end
  end
end
