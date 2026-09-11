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
    issue.approval_signatures.select {|s| s.step_position == step.position}.last
  end

  def approval_max_extension_label
    limit = IssueExtension.max_days
    limit > 0 ? l(:label_max_extension_days, :count => limit) : l(:label_no_extension_limit)
  end
end
