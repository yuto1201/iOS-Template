# frozen_string_literal: true

module IOSTemplate
  module ReviewRoute
    class ValidationError < StandardError; end

    DECLARATION_PREFIX = "Opposite-review route:"
    GROK_REVIEWER = "cursor-grok-4.6-xhigh"
    GROK_DECLARATION = /\AOpposite-review route: grok-fallback; Primary: codex; Reviewer: cursor-grok-4\.6-xhigh; Approval: user-explicit; Reason: (?<reason>\S(?:.*\S)?)\z/

    module_function

    def reviewer_for(contract:, primary:)
      reject("primary model is invalid") unless %w[codex claude].include?(primary)
      criteria = contract.is_a?(Hash) ? contract["acceptanceCriteria"] : nil
      reject("Issue contract acceptance criteria are invalid") unless criteria.is_a?(Array) && !criteria.empty?

      declarations = criteria.each_with_object([]) do |criterion, found|
        next unless criterion.is_a?(Hash)

        text = criterion["text"]
        found << text if text.is_a?(String) && text.start_with?(DECLARATION_PREFIX)
      end
      return primary == "codex" ? "claude" : "codex" if declarations.empty?

      reject("exactly one opposite-review route declaration is allowed") unless declarations.length == 1
      match = declarations.first.match(GROK_DECLARATION)
      reject("opposite-review route declaration is malformed or unsupported") unless match && !match[:reason].strip.empty?
      reject("Grok fallback is only authorized for a Codex primary") unless primary == "codex"

      GROK_REVIEWER
    end

    def launcher_for(primary:, reviewer:)
      case [primary, reviewer]
      when ["codex", "claude"]
        "tools/cross-model-review.sh"
      when ["claude", "codex"]
        "tools/request-codex-review.sh"
      when ["codex", GROK_REVIEWER]
        "tools/request-grok-review.sh"
      else
        reject("reviewer is not authorized for the primary model")
      end
    end

    def reject(message)
      raise ValidationError, message
    end
  end
end
