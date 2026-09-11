# frozen_string_literal: true

module RedmineApprovalWorkflow
  # Finds the issues waiting for a given user's signature.
  #
  # This runs on every page through the top menu, so the query count must stay
  # flat as the instance grows. Issue#can_approve? costs about ten queries per
  # issue, mostly ApprovalRoute.for_issue and IssueStatus.new_statuses_allowed,
  # so it is not used here. Instead the same rule is evaluated in bulk: routes,
  # signatures and workflow transitions are each fetched once and matched in
  # memory.
  #
  # Issue#can_approve? remains the authority — it is what the controller
  # enforces — and PendingApprovalsTest pins this bulk path to it by asserting
  # both agree over a range of fixtures. Change one, change the other.
  module PendingApprovals
    # Upper bound on how many issues one request will look at.
    CANDIDATE_LIMIT = 100

    module_function

    # Administrators can switch the reminder off entirely; the lookup is cheap
    # but it does run on every page.
    def enabled?
      values = Setting.plugin_redmine_approval_workflow
      !values.is_a?(Hash) || values['show_pending_approvals'].to_s != '0'
    end

    def for_user(user)
      return [] unless user.is_a?(User) && user.logged?
      return [] unless enabled?

      routes = ApprovalRoute.active.preload(:steps => :issue_status).to_a
      return [] if routes.empty?

      # Resolved once and passed down: it costs a query and both the
      # pre-filter and the transition lookup need it.
      role_ids = workflow_role_ids(user)
      issues = candidates(user, routes.map(&:tracker_id).uniq, role_ids)
      return [] if issues.empty?

      steps = pending_steps(routes, issues)
      issues = issues.select {|issue| steps.key?(issue.id)}
      return [] if issues.empty?

      transitions = transition_index(issues, steps, role_ids)
      issues.select {|issue| signable?(user, issue, steps[issue.id], transitions)}
    end

    # SQL pre-filter. The EXISTS clause drops every issue whose current status
    # has no outgoing transition at all for this user, which is most of them.
    def candidates(user, tracker_ids, role_ids)
      Issue.visible(user).open.
        where(:tracker_id => tracker_ids).
        where(transition_exists_sql, :role_ids => role_ids).
        joins(:project).merge(Project.has_module(:approval_workflow)).
        preload(:approval_signatures, :status, :tracker, :project).
        limit(CANDIDATE_LIMIT).
        to_a
    end

    def transition_exists_sql
      "EXISTS (SELECT 1 FROM #{WorkflowRule.table_name} w" \
      " WHERE w.type = 'WorkflowTransition'" \
      " AND w.tracker_id = #{Issue.table_name}.tracker_id" \
      " AND w.old_status_id = #{Issue.table_name}.status_id" \
      " AND w.role_id IN (:role_ids))"
    end

    # Superset of the roles the user can act through. Only used to narrow the
    # SQL; signable? re-checks against the issue's actual workflow roles.
    def workflow_role_ids(user)
      return Role.pluck(:id) if user.admin?

      ids = user.memberships.joins(:member_roles).distinct.pluck('member_roles.role_id')
      ids += [Role.non_member.id, Role.anonymous.id]
      ids.compact.uniq
    end

    # issue id => the step awaiting a signature.
    def pending_steps(routes, issues)
      issues.each_with_object({}) do |issue, result|
        route = route_for(routes, issue)
        next if route.nil?

        step = route.steps.detect {|s| s.position == issue.approval_position}
        result[issue.id] = step if step
      end
    end

    # Mirrors ApprovalRoute.for_issue: a route bound to the issue's project
    # wins over a global one for the same tracker.
    def route_for(routes, issue)
      routes.
        select {|r| r.tracker_id == issue.tracker_id && (r.project_id.nil? || r.project_id == issue.project_id)}.
        min_by {|r| [r.project_id.nil? ? 1 : 0, r.id]}
    end

    def transition_index(issues, steps, role_ids)
      WorkflowTransition.
        where(:tracker_id => issues.map(&:tracker_id).uniq,
              :old_status_id => issues.map(&:status_id).uniq,
              :new_status_id => steps.values.map(&:issue_status_id).uniq,
              :role_id => role_ids).
        pluck(:tracker_id, :old_status_id, :new_status_id, :role_id, :author, :assignee).
        group_by {|row| [row[0], row[1], row[2]]}
    end

    def signable?(user, issue, step, transitions)
      return false unless issue.attributes_editable?(user)
      # A step that names its approver is shown only to them.
      return false unless step.assigned_to?(user, issue.project)

      rows = transitions[[issue.tracker_id, issue.status_id, step.issue_status_id]]
      return false if rows.blank?

      role_ids = issue.send(:roles_for_workflow, user).map(&:id)
      return false if role_ids.empty?

      author = issue.author_id == user.id
      assignee = issue.assigned_to_id.present? &&
                 (user.id == issue.assigned_to_id || user.group_ids.include?(issue.assigned_to_id))

      matched = rows.any? do |(_tracker, _old, _new, role_id, row_author, row_assignee)|
        role_ids.include?(role_id) && flags_match?(row_author, row_assignee, author, assignee)
      end
      return false unless matched

      # new_statuses_allowed_to prunes the result with these two rules; both hit
      # the database, so they only run when they can actually change the answer.
      target = step.issue_status
      return false if target.is_closed? && !issue.closable?
      return false if !target.is_closed? && issue.parent_id.present? && !issue.reopenable?

      true
    end

    # Same selection IssueStatus.new_statuses_allowed applies in SQL to the
    # author/assignee columns of a transition.
    def flags_match?(row_author, row_assignee, author, assignee)
      return true if author && assignee

      if author || assignee
        row_author == author || row_assignee == assignee
      else
        row_author == false && row_assignee == false
      end
    end
  end
end
