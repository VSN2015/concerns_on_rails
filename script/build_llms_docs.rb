#!/usr/bin/env ruby
# frozen_string_literal: true

# Generates the AI/LLM-facing documentation artifacts from the docs manifest
# (docs/assets/js/concerns.js) and the per-concern Markdown files:
#
#   docs/llms.txt       — machine-readable index (llmstxt.org convention); committed
#   docs/llms-full.txt  — every concern doc concatenated; generated at deploy, gitignored
#
# Run from anywhere: ruby script/build_llms_docs.rb
# The Pages workflow runs it before uploading docs/, so the published copies
# are always regenerated from the same files the site itself serves.

ROOT     = File.expand_path("..", __dir__)
DOCS     = File.join(ROOT, "docs")
MANIFEST = File.join(DOCS, "assets", "js", "concerns.js")
SITE     = "https://vsn2015.github.io/concerns_on_rails"
REPO     = "https://github.com/VSN2015/concerns_on_rails"
REPO_RAW = "https://raw.githubusercontent.com/VSN2015/concerns_on_rails/master"

manifest = File.read(MANIFEST)
version  = manifest[/version:\s*"([^"]+)"/, 1] or abort "version not found in #{MANIFEST}"

ENTRY = /\{\s*slug:\s*"(?<slug>[^"]+)",\s*name:\s*"(?<name>[^"]+)",\s*category:\s*"(?<category>[^"]+)",\s*icon:\s*"[^"]*",\s*tagline:\s*"(?<tagline>[^"]+)",\s*include:\s*"(?<include>[^"]+)",\s*src:\s*"(?<src>[^"]+)"/

concerns = manifest.to_enum(:scan, ENTRY).map { Regexp.last_match.named_captures }
abort "no concern entries parsed from #{MANIFEST}" if concerns.empty?

# Drift guard: the manifest and docs/concerns/*.md must agree exactly.
manifest_slugs = concerns.map { |c| c["slug"] }.sort
file_slugs     = Dir[File.join(DOCS, "concerns", "*.md")].map { |f| File.basename(f, ".md") }.sort
unless manifest_slugs == file_slugs
  abort "manifest/docs drift — only in manifest: #{(manifest_slugs - file_slugs).join(', ')}; " \
        "only in docs/concerns: #{(file_slugs - manifest_slugs).join(', ')}"
end

models      = concerns.select { |c| c["category"] == "model" }
controllers = concerns.select { |c| c["category"] == "controller" }

index_lines = ->(list) {
  list.map { |c| "- [#{c['name']}](#{SITE}/concerns/#{c['slug']}.md): #{c['tagline']}" }.join("\n")
}

llms = <<~TXT
  # ConcernsOnRails

  > Plug-and-play ActiveSupport concerns for Rails models and controllers — one `include`, one declarative macro. #{concerns.size} concerns covering slugs, soft delete, publishing, encryption, auditing, pagination, rate limiting, webhooks, params contracts, and more.

  ConcernsOnRails is a Ruby gem (`gem "concerns_on_rails"`; Ruby >= 3.2, Rails 5.0–8.x). Current version: #{version}. Every link below is a standalone plain-Markdown document — fetch it directly, no JavaScript or HTML parsing required.

  ## Model concerns

  #{index_lines.call(models)}

  ## Controller concerns

  #{index_lines.call(controllers)}

  ## Optional

  - [Complete docs in one file](#{SITE}/llms-full.txt): every concern document concatenated (~400 KB)
  - [README](#{REPO_RAW}/README.md): the full single-file reference, including installation and configuration
  - [CHANGELOG](#{REPO_RAW}/CHANGELOG.md): release history
  - [RubyGems](https://rubygems.org/gems/concerns_on_rails): released versions and install stats
TXT

full = +"# ConcernsOnRails #{version} — complete documentation\n\n"
full << "> Plug-and-play ActiveSupport concerns for Rails models and controllers. " \
        "Index: #{SITE}/llms.txt · Source: #{REPO}\n"
concerns.each do |c|
  body = File.read(File.join(DOCS, "concerns", "#{c['slug']}.md")).strip
  full << "\n\n---\n\n# #{c['name']} (#{c['category']} concern)\n\n" \
          "> #{c['tagline']}\n\n" \
          "`include #{c['include']}` — source: `#{c['src']}`\n\n#{body}\n"
end

File.write(File.join(DOCS, "llms.txt"), llms)
File.write(File.join(DOCS, "llms-full.txt"), full)
puts "llms.txt:      #{concerns.size} concerns indexed (v#{version}, #{models.size} model + #{controllers.size} controller)"
puts "llms-full.txt: #{full.bytesize} bytes"
