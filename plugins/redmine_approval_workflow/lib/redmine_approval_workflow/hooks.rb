# frozen_string_literal: true

module RedmineApprovalWorkflow
  # render_on renders through the calling view, so the partials keep access to
  # the application helpers and to this plugin's own helper.
  class Hooks < Redmine::Hook::ViewListener
    render_on :view_issues_show_description_bottom,
              :partial => 'approval_workflow/issue_panel'

    # The bell belongs next to the avatar and the credit line in the footer,
    # but Redmine offers no hook in either place. Both are rendered on the stock
    # body_bottom hook and moved into position client-side, which keeps this
    # plugin free of any core file edit.
    render_on :view_layouts_base_body_bottom,
              :partial => 'approval_workflow/layout_additions'

    def view_layouts_base_html_head(context = {})
      stylesheet_link_tag('approval_workflow', :plugin => 'redmine_approval_workflow')
    end
  end
end
