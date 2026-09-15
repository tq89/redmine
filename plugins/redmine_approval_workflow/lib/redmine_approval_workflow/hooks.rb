# frozen_string_literal: true

module RedmineApprovalWorkflow
  # render_on renders through the calling view, so the partials keep access to
  # the application helpers and to this plugin's own helper.
  class Hooks < Redmine::Hook::ViewListener
    # The panel sits at the foot of the issue page, below the notes field, so
    # the page reads in the order the work happens: read the issue, write your
    # note, then sign.
    #
    # issues/show.html.erb has no hook that far down -- its last one is under
    # the description, above the subtasks, the history and the note field --
    # but view_layouts_base_content renders immediately after the whole page
    # content, inside #content, which is the same place. Using it costs nothing
    # on other pages and saves moving a large block of markup with a script.
    def view_layouts_base_content(context = {})
      controller = context[:controller]
      return '' unless controller.is_a?(IssuesController) && controller.action_name == 'show'

      # The hook fires on every page, so the issue comes from the controller
      # rather than from the context, which carries no issue here.
      issue = controller.instance_variable_get(:@issue)
      return '' unless issue&.persisted?

      context[:hook_caller].send(
        :render,
        :partial => 'approval_workflow/issue_panel',
        :locals => context.merge(:issue => issue)
      )
    end

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
