require "pathname"

template_path = Pathname(ARGV.fetch(0, "docs/accessibility/manual-at-validation-v1.md"))
abort "Manual AT template is missing: #{template_path}" unless template_path.file?

template = template_path.read
required_markers = [
  "# Manual assistive technology validation record (v1)",
  "Record format: `campfire-manual-at-v1`",
  "Automation verifies the\ntemplate structure only.",
  "It does not launch, operate, or validate VoiceOver or\nTalkBack.",
  "## VoiceOver",
  "| VO-01 |",
  "| VO-06 |",
  "## TalkBack",
  "| TB-01 |",
  "| TB-06 |",
  "## Defects and exceptions",
  "## Sign-off",
  "Overall result: `<pass|fail|blocked>`"
]
missing = required_markers.reject { |marker| template.include?(marker) }

abort "Manual AT template is missing required markers: #{missing.join(", ")}" if missing.any?

puts "Verified manual AT record template v1: #{template_path}"
