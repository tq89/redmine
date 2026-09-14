# frozen_string_literal: true

module RedmineApprovalWorkflow
  # Where a chain stands, replayed from its signatures.
  #
  # Progress is derived from the signature rows rather than from the issue
  # status, so a status changed by hand outside the chain cannot silently skip
  # a step. A step that needs several signatures ("all" mode) stays current
  # until it has collected them, which is why the answer is a pair: the step
  # awaiting a signature, and what that step has collected so far.
  module ChainProgress
    module_function

    # Returns [position, signatures collected at that position].
    #
    # +signatures+ must be in the order they were recorded.
    def compute(route, signatures)
      position = 0
      collected = []

      Array(signatures).each do |signature|
        # A signature recorded elsewhere in the chain moves the cursor there:
        # the last thing that happened is what the chain reflects.
        if signature.step_position != position
          position = signature.step_position
          collected = []
        end

        if signature.approved?
          collected << signature
          step = route&.step_at(position)
          if step.nil? || step.satisfied_by?(collected)
            position += 1
            collected = []
          end
        else
          # Rejecting sends the chain back one step, and whatever that step had
          # collected no longer counts -- it has to be signed again.
          position = [position - 1, 0].max
          collected = []
        end
      end

      [position, collected]
    end
  end
end
