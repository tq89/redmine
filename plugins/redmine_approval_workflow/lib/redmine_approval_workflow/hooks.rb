# frozen_string_literal: true

module RedmineApprovalWorkflow
  # Everything this plugin adds to a page is rendered from a LAYOUT hook, which
  # means anything raised in here takes down the whole page -- and for the bell,
  # every page on the instance, for everybody. So each hook is wrapped: it logs
  # what went wrong and renders nothing, leaving Redmine itself standing.
  #
  # Partials are rendered through the calling view, so they keep access to the
  # application helpers and to this plugin's own helper.
  class Hooks < Redmine::Hook::ViewListener
    # The panel sits at the foot of the issue page, below the notes field, so
    # the page reads in the order the work happens: read the issue, write your
    # note, then sign.
    #
    # issues/show.html.erb has no hook that far down -- its last one is under
    # the description, above the subtasks, the history and the note field --
    # but view_layouts_base_content renders immediately after the whole page
    # content, inside #content, which is the same place.
    def view_layouts_base_content(context = {})
      controller = context[:controller]
      return '' unless controller.is_a?(IssuesController) && controller.action_name == 'show'

      # The hook fires on every page, so the issue comes from the controller
      # rather than from the context, which carries no issue here.
      issue = controller.instance_variable_get(:@issue)
      return '' unless issue.is_a?(Issue) && issue.persisted?

      # Only the issue as a local. Passing the whole context, as render_on
      # does, would shadow the view's own controller/request/hook_caller
      # methods inside the partial with locals of the same name.
      safely_render(context, 'approval_workflow/issue_panel',
                    {:issue => issue}, "issue panel for issue #{issue.id}")
    end

    # The bell belongs next to the avatar and the credit line in the footer,
    # but Redmine offers no hook in either place. Both are rendered on the stock
    # body_bottom hook and moved into position client-side, which keeps this
    # plugin free of any core file edit.
    def view_layouts_base_body_bottom(context = {})
      safely_render(context, 'approval_workflow/layout_additions', {}, 'layout additions')
    end

    def view_layouts_base_html_head(context = {})
      stylesheet_link_tag('approval_workflow', :plugin => 'redmine_approval_workflow')
    rescue StandardError => e
      log_hook_failure('stylesheet tag', e)
      ''
    end

    private

    def safely_render(context, partial, locals, what)
      view = context[:hook_caller]
      # A controller as the caller would mean the hook was called from
      # somewhere other than a view; rendering there is not ours to do.
      return '' unless view.is_a?(ActionView::Base)

      view.render(:partial => partial, :locals => locals)
    rescue StandardError => e
      log_hook_failure(what, e)
      ''
    end

    def log_hook_failure(what, error)
      Rails.logger.error(
        "[redmine_approval_workflow] #{what} failed to render: " \
        "#{error.class}: #{error.message}\n#{Array(error.backtrace).first(15).join("\n")}"
      )
    end
  end
end
