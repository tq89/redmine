# frozen_string_literal: true

module ApprovalWorkflowHelper
  # Renders one chain step with its state: signed, pending or still ahead.
  def approval_step_state(issue, step)
    position = issue.approval_position
    if step.position < position
      :done
    elsif step.position == position
      :current
    else
      :pending
    end
  end

  def approval_step_css(state)
    "approval-step approval-step-#{state}"
  end

  def approval_step_icon(state)
    case state
    when :done    then sprite_icon('checked', l(:label_approval_step_done))
    when :current then sprite_icon('time', l(:label_approval_step_current))
    else               sprite_icon('circle-dot-filled', l(:label_approval_step_pending))
    end
  end

  # Latest signature recorded for a given step, used to show who signed it.
  def last_signature_for(issue, step)
    issue.approval_signatures.reverse.find {|s| s.step_position == step.position}
  end

  # Same three states as an issue chain, read off the extension request instead.
  def extension_step_state(extension, step)
    position = extension.approval_position
    if step.position < position
      :done
    elsif step.position == position
      :current
    else
      :pending
    end
  end

  def last_extension_signature_for(extension, step)
    extension.approval_signatures.reverse.find {|s| s.step_position == step.position}
  end

  def extension_status_label(extension)
    case extension.status
    when IssueExtension::PENDING  then l(:label_extension_status_pending)
    when IssueExtension::REJECTED then l(:label_extension_status_rejected)
    else                               l(:label_extension_status_approved)
    end
  end

  def extension_status_css(extension)
    "extension-status extension-status-#{extension.status}"
  end

  # Roles that can hold a workflow transition; builtin roles are excluded
  # because a step is assigned to people who are members of the project.
  def approval_role_options
    Role.givable.sorted.map {|role| [role.name, role.id]}
  end

  # One picker for all three kinds of approver, so "a role OR a person, not
  # both" is a shape the form cannot express wrongly rather than a rule to
  # enforce afterwards.
  def approval_approver_options(project)
    [
      [l(:label_approver_dynamic), ApprovalRouteStep::DYNAMIC_APPROVERS.map do |kind|
        [l(:"label_approver_#{kind}"), "dynamic:#{kind}"]
      end],
      [l(:label_role_plural), approval_role_options.map {|name, id| [name, "role:#{id}"]}],
      [l(:label_user_plural), approval_member_options(project).map {|name, id| [name, "user:#{id}"]}]
    ]
  end

  # How a step's approver reads wherever a chain is shown. nil when the step
  # leaves it to the workflow.
  def approval_step_approver_label(step)
    if step.approver_user
      "#{l(:label_assigned_person)}: #{step.approver_user.name}"
    elsif step.approver_role
      "#{l(:label_assigned_role)}: #{step.approver_role.name}"
    elsif step.approver_dynamic.present?
      l(:"label_approver_#{step.approver_dynamic}")
    end
  end

  def approval_member_options(project)
    project.members.includes(:principal).map(&:principal).
      select {|principal| principal.is_a?(User)}.
      sort_by(&:name).
      map {|user| [user.name, user.id]}
  end

  def approval_max_extension_label
    limit = IssueExtension.max_days
    limit > 0 ? l(:label_max_extension_days, :count => limit) : l(:label_no_extension_limit)
  end
end
