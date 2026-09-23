# frozen_string_literal: true

# Works out who to tell about an approval, away from the request that caused it.
#
# Deciding the recipients is not cheap. A step that names nobody is open to
# every member holding the transition, and each candidate is then asked
# Issue#can_approve?, which is about a dozen queries -- so a hundred-member
# project cost something like fifteen hundred queries and several seconds,
# inside the POST that signed the step. The person pressing the button waited
# for all of it, and on a busy server that is where a gateway timeout comes
# from.
#
# deliver_later already moved the sending off the request; this moves the
# working-out as well, so signing returns as soon as the signature is saved.
class ApprovalNotificationJob < ActiveJob::Base
  queue_as :default

  # +kind+ is :issue or :extension. Ids rather than records: a job may run
  # after the request is long gone, and it should read current state anyway.
  def perform(kind, record_id, actor_id = nil)
    actor = User.find_by_id(actor_id)
    case kind.to_s
    when 'issue'
      issue = Issue.find_by_id(record_id)
      ApprovalMailer.send_approval_pending(issue, actor) if issue
    when 'extension'
      extension = IssueExtension.find_by_id(record_id)
      ApprovalMailer.send_extension_pending(extension, actor) if extension
    end
  rescue StandardError => e
    # A notification must never be the thing that takes a queue down, and the
    # signature it is about is already committed.
    Rails.logger.error(
      "[redmine_approval_workflow] notification job failed (#{kind} #{record_id}): " \
      "#{e.class}: #{e.message}"
    )
  end
end
