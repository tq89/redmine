# frozen_string_literal: true

module RedmineApprovalWorkflow
  # Finds the issues waiting for a given user's signature, and the ones they
  # could take on out of turn.
  #
  # This runs on every page through the bell, so the query count must stay flat
  # as the instance grows. Issue#can_approve? costs about ten queries per issue,
  # mostly ApprovalRoute.for_issue and IssueStatus.new_statuses_allowed, so it is
  # not used here. Instead the same rule is evaluated in bulk: routes, signatures
  # and workflow transitions are each fetched once and matched in memory.
  #
  # Issue#can_approve? and Issue#approval_can_skip_to? remain the authority --
  # they are what the controller enforces -- and PendingApprovalsTest pins this
  # bulk path to them by asserting they agree over a range of fixtures. Change
  # one, change the other.
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

    # Issues whose pending step this user may sign.
    def for_user(user)
      evaluate(user)[:pending]
    end

    # [issue, step] pairs for work this user can take on without waiting to be
    # given it: a step further down the chain that the administrator marked
    # skippable and that the workflow lets this user reach from here.
    def claimable_for_user(user)
      evaluate(user)[:claimable]
    end

    def empty_result
      {:pending => [], :claimable => []}
    end

    # Both lists come out of one pass. They share the routes, the candidate
    # issues and the transition lookup, so computing them separately would
    # double the query count for no gain.
    def evaluate(user)
      return empty_result unless user.is_a?(User) && user.logged?
      return empty_result unless enabled?

      # Issue chains only. An extension chain has no target status and is not
      # signed from here; ExtensionApproval.pending_for handles those.
      routes = ApprovalRoute.active.of_kind(ApprovalRoute::ISSUE_KIND).
               preload(:approval_route_trackers,
                       :steps => [:issue_status, {:approvers => [:approver_role, :approver_user]}]).to_a
      return empty_result if routes.empty?

      # Resolved once and passed down: it costs a query and both the
      # pre-filter and the transition lookup need it.
      role_ids = workflow_role_ids(user)
      issues = candidates(user, routes.flat_map(&:tracker_ids).uniq, role_ids)
      return empty_result if issues.empty?

      work = pending_steps(routes, issues)
      issues = issues.select {|issue| work.key?(issue.id)}
      return empty_result if issues.empty?

      transitions = transition_index(issues, work, role_ids)
      sort_into_lists(user, issues, work, transitions)
    end

    def sort_into_lists(user, issues, work, transitions)
      pending = []
      claimable = []

      issues.each do |issue|
        step, collected, skippable = work[issue.id]
        # The cheapest gate, and a precondition for both lists, so it runs once
        # per issue rather than once per check.
        next unless issue.attributes_editable?(user)

        if step && step.signable_by?(user, issue, collected) &&
           transition_allowed?(user, issue, step.issue_status, transitions)
          pending << issue
          # Already actionable from the waiting list; listing the same issue
          # again under "can take on" would be the same reminder twice.
          next
        end

        # Almost every instance has no skippable step at all, so this costs
        # nothing until an administrator turns the option on.
        next if skippable.empty?

        claim = skippable.detect do |candidate|
          # A step reached over the ones before it has collected nothing.
          candidate.signable_by?(user, issue, []) &&
            transition_allowed?(user, issue, candidate.issue_status, transitions)
        end
        # The nearest one only. The chain on the issue page offers the rest;
        # the bell is a reminder, not a second copy of the panel.
        claimable << [issue, claim] if claim
      end

      {:pending => pending, :claimable => claimable}
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
    # SQL; transition_allowed? re-checks against the issue's actual workflow
    # roles.
    def workflow_role_ids(user)
      return Role.pluck(:id) if user.admin?

      ids = user.memberships.joins(:member_roles).distinct.pluck('member_roles.role_id')
      ids += [Role.non_member.id, Role.anonymous.id]
      ids.compact.uniq
    end

    # issue id => [step awaiting a signature, signatures it has collected,
    #              steps further along that may be signed out of turn].
    #
    # The collected list is what an "all" step needs to know whose turn it is,
    # so it is carried through rather than recomputed per check. An issue with
    # no pending step -- a finished chain -- is left out entirely: there is
    # nothing ahead of the end of the chain to take on either.
    def pending_steps(routes, issues)
      issues.each_with_object({}) do |issue, result|
        route = route_for(routes, issue)
        next if route.nil?

        position, collected =
          RedmineApprovalWorkflow::ChainProgress.compute(route, issue.approval_signatures.to_a)
        step = route.steps.detect {|s| s.position == position}
        next if step.nil?

        skippable = route.steps.select {|s| s.position > position && s.skippable?}
        result[issue.id] = [step, collected, skippable]
      end
    end

    # Mirrors ApprovalRoute.for_issue: a route bound to the issue's project
    # wins over a global one covering the same tracker.
    def route_for(routes, issue)
      routes.
        select {|r| r.covers_tracker?(issue.tracker_id) && (r.project_id.nil? || r.project_id == issue.project_id)}.
        min_by {|r| [r.project_id.nil? ? 1 : 0, r.id]}
    end

    # Every status any of these issues could be moved into by signing, whether
    # in turn or out of it.
    def transition_index(issues, work, role_ids)
      target_ids = work.values.flat_map do |step, _collected, skippable|
        [step.issue_status_id] + skippable.map(&:issue_status_id)
      end
      WorkflowTransition.
        where(:tracker_id => issues.map(&:tracker_id).uniq,
              :old_status_id => issues.map(&:status_id).uniq,
              :new_status_id => target_ids.compact.uniq,
              :role_id => role_ids).
        pluck(:tracker_id, :old_status_id, :new_status_id, :role_id, :author, :assignee).
        group_by {|row| [row[0], row[1], row[2]]}
    end

    # What Issue#new_statuses_allowed_to would answer for this one status,
    # read out of the index instead of the database.
    def transition_allowed?(user, issue, target, transitions)
      return false if target.nil?

      rows = transitions[[issue.tracker_id, issue.status_id, target.id]]
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
