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
