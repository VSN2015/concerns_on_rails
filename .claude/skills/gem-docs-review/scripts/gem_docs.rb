#!/usr/bin/env ruby
# frozen_string_literal: true

# gem_docs.rb — offline gem-documentation cache + change detection for a Ruby/Rails project.
#
# Run it with the project's bundler so Bundler/RubyGems resolve the locked gems, e.g.:
#   bundle exec ruby .claude/skills/gem-docs-review/scripts/gem_docs.rb <command> [options]
#
# Commands:
#   check                 Diff the current Gemfile.lock against the stored manifest. Read-only. Prints JSON.
#   sync [--all]          Harvest docs for gems whose version changed or are missing from the cache
#                         (--all re-harvests every gem). Updates the manifest. Prints JSON.
#       [--prune]         Also delete cached gem-version dirs no longer referenced by the lockfile.
#   status                Human-readable summary of cache state + pending changes.
#   surface NAME          Print the cache paths (readme/changelog/api/meta) for one gem, for review.
#   changelog NAME        Print the cached CHANGELOG for one gem (capped), for upgrade-impact review.
#
# Global options:
#   --lockfile PATH       Path to Gemfile.lock (default: nearest one walking up from CWD).
#   --cache PATH          Cache dir (default: <project>/.gem-docs-cache, or $GEM_DOCS_CACHE).
#   --json                Force JSON output (default for check/sync; status is human unless set).
#
# Dependencies: Ruby stdlib + Bundler only. No third-party gems required.

require "json"
require "digest"
require "fileutils"
require "time"
require "set"
require "ripper"
require "bundler"
require "bundler/lockfile_parser"

module GemDocs
  SCHEMA_VERSION = 1
  MAX_DOC_BYTES  = 300_000  # per harvested README/CHANGELOG file
  MAX_API_ENTRIES = 8_000   # per gem api.txt
  MAX_SOURCE_BYTES = 1_500_000 # skip Ripper-parsing files larger than this

  README_RE    = /\Areadme/i
  CHANGELOG_RE = /\A(changelog|changes|history|news)(\b|\.|\z)/i

  module_function

  # ---- project / path discovery -------------------------------------------

  def find_lockfile(explicit)
    return File.expand_path(explicit) if explicit
    dir = Dir.pwd
    loop do
      candidate = File.join(dir, "Gemfile.lock")
      return candidate if File.file?(candidate)
      parent = File.dirname(dir)
      break if parent == dir
      dir = parent
    end
    abort "gem_docs: no Gemfile.lock found (searched up from #{Dir.pwd}). Pass --lockfile PATH."
  end

  def cache_dir(opts, lockfile)
    return File.expand_path(opts[:cache]) if opts[:cache]
    return File.expand_path(ENV["GEM_DOCS_CACHE"]) if ENV["GEM_DOCS_CACHE"]
    File.join(File.dirname(lockfile), ".gem-docs-cache")
  end

  def manifest_path(cache) = File.join(cache, "manifest.json")

  # ---- lockfile parsing ----------------------------------------------------

  # => { "rake" => {"version" => "13.2.1", "platform" => "ruby"}, ... }
  def parse_lockfile(lockfile)
    parser = Bundler::LockfileParser.new(File.read(lockfile))
    gems = {}
    parser.specs.each do |spec|
      gems[spec.name] = {
        "version"  => spec.version.to_s,
        "platform" => spec.platform.to_s
      }
    end
    {
      "gems"            => gems,
      "bundler_version" => parser.bundler_version&.to_s,
      "ruby_version"    => parser.ruby_version&.to_s
    }
  rescue StandardError => e
    abort "gem_docs: failed to parse #{lockfile}: #{e.class}: #{e.message}"
  end

  def load_manifest(cache)
    path = manifest_path(cache)
    return nil unless File.file?(path)
    JSON.parse(File.read(path))
  rescue JSON::ParserError
    nil
  end

  # ---- change detection ----------------------------------------------------

  # Compare current lockfile gems against the stored manifest's gems.
  def diff(current_gems, manifest)
    prev = manifest ? (manifest["gems"] || {}) : {}
    prev_versions = prev.transform_values { |g| g["version"] }
    cur_versions  = current_gems.transform_values { |g| g["version"] }

    added   = (cur_versions.keys - prev_versions.keys).sort
    removed = (prev_versions.keys - cur_versions.keys).sort
    changed = []
    (cur_versions.keys & prev_versions.keys).sort.each do |name|
      next if cur_versions[name] == prev_versions[name]
      from = Gem::Version.new(prev_versions[name]) rescue nil
      to   = Gem::Version.new(cur_versions[name]) rescue nil
      direction =
        if from && to
          to > from ? "upgraded" : "downgraded"
        else
          "changed"
        end
      changed << { "name" => name, "from" => prev_versions[name], "to" => cur_versions[name], "direction" => direction }
    end

    # Gems present in the lockfile but not yet harvested into the cache.
    harvested = prev
    stale = cur_versions.keys.select do |name|
      entry = harvested[name]
      entry.nil? || !entry["harvested"] || entry["version"] != cur_versions[name]
    end.sort

    {
      "added"      => added,
      "removed"    => removed,
      "changed"    => changed,
      "stale_cache" => stale,
      "counts" => {
        "added" => added.size, "removed" => removed.size,
        "changed" => changed.size, "stale_cache" => stale.size,
        "total_locked" => cur_versions.size
      }
    }
  end

  # ---- doc harvesting ------------------------------------------------------

  def resolve_path(name, version)
    spec = Gem::Specification.find_by_name(name, version) rescue nil
    return spec.full_gem_path if spec && Dir.exist?(spec.full_gem_path)
    # Fallback: any installed version (path still useful for source/API).
    spec = Gem::Specification.find_by_name(name) rescue nil
    spec && Dir.exist?(spec.full_gem_path) ? spec.full_gem_path : nil
  end

  def gem_spec(name, version)
    Gem::Specification.find_by_name(name, version) rescue (Gem::Specification.find_by_name(name) rescue nil)
  end

  def pick_doc(gem_path, regex)
    candidates = Dir.children(gem_path).select { |f| File.file?(File.join(gem_path, f)) && f =~ regex }
    return nil if candidates.empty?
    # Prefer markdown/rdoc, then the largest file.
    candidates.max_by do |f|
      full = File.join(gem_path, f)
      ext_rank = case File.extname(f).downcase
                 when ".md", ".markdown" then 3
                 when ".rdoc" then 2
                 when ".txt", "" then 1
                 else 0
                 end
      [ext_rank, File.size(full)]
    end
  end

  def copy_capped(src, dest)
    data = File.read(src, mode: "rb")
    truncated = false
    if data.bytesize > MAX_DOC_BYTES
      data = data.byteslice(0, MAX_DOC_BYTES)
      truncated = true
    end
    text = data.force_encoding("UTF-8")
    text = text.scrub("?") unless text.valid_encoding?
    text += "\n\n...[truncated by gem_docs at #{MAX_DOC_BYTES} bytes]...\n" if truncated
    File.write(dest, text)
    truncated
  end

  # Extract a qualified public-API index (Class#method / Module.method) from lib/**/*.rb.
  def extract_api(gem_path)
    libdir = File.join(gem_path, "lib")
    return [] unless Dir.exist?(libdir)
    entries = []
    Dir.glob(File.join(libdir, "**", "*.rb")).sort.each do |file|
      break if entries.size >= MAX_API_ENTRIES
      next if File.size(file) > MAX_SOURCE_BYTES
      src = File.read(file, mode: "rb").force_encoding("UTF-8")
      src = src.scrub("?") unless src.valid_encoding?
      sexp = begin
        Ripper.sexp(src)
      rescue StandardError
        nil
      end
      next unless sexp
      walk(sexp, [], entries)
    end
    entries.uniq.sort
  end

  # Build a fully-qualified name from a const node (const_ref / const_path_ref / @const).
  def const_name(node)
    return nil unless node.is_a?(Array)
    case node[0]
    when :const_ref, :top_const_ref, :var_ref, :var_field
      const_name(node[1])
    when :const_path_ref, :const_path_field
      [const_name(node[1]), const_name(node[2])].compact.join("::")
    when :@const, :@ident
      node[1]
    else
      nil
    end
  end

  def ident_name(node)
    return node.to_s unless node.is_a?(Array)
    node[1].is_a?(String) ? node[1] : nil
  end

  def walk(node, scope, out)
    return unless node.is_a?(Array)
    case node[0]
    when :class
      name = const_name(node[1])
      new_scope = name ? scope + [name] : scope
      out << "class #{new_scope.join('::')}" unless new_scope.empty?
      walk(node[3], new_scope, out) # bodystmt
      return
    when :module
      name = const_name(node[1])
      new_scope = name ? scope + [name] : scope
      out << "module #{new_scope.join('::')}" unless new_scope.empty?
      walk(node[2], new_scope, out)
      return
    when :def
      mname = ident_name(node[1])
      out << "#{scope.empty? ? '' : scope.join('::') + '#'}#{mname}" if mname
      return
    when :defs
      mname = ident_name(node[3])
      out << "#{scope.empty? ? '' : scope.join('::') + '.'}#{mname}" if mname
      return
    end
    node.each { |child| walk(child, scope, out) if child.is_a?(Array) }
  end

  def spec_meta(spec, version, path)
    return { "version" => version, "path" => path } unless spec
    deps = (spec.runtime_dependencies rescue []).map { |d| "#{d.name} #{d.requirement}" }
    {
      "version"      => version,
      "path"         => path,
      "summary"      => (spec.summary rescue nil),
      "homepage"     => (spec.homepage rescue nil),
      "licenses"     => (spec.licenses rescue []),
      "executables"  => (spec.executables rescue []),
      "runtime_deps" => deps,
      "changelog_uri" => (spec.metadata["changelog_uri"] rescue nil),
      "source_uri"    => (spec.metadata["source_code_uri"] rescue nil)
    }.compact
  end

  def harvest_gem(name, version, cache)
    path = resolve_path(name, version)
    rel_dir = File.join("gems", "#{name}-#{version}")
    abs_dir = File.join(cache, rel_dir)
    docs = {}
    unless path
      return { "name" => name, "version" => version, "harvested" => false,
               "error" => "not installed (in lockfile only)", "docs" => docs }
    end
    FileUtils.mkdir_p(abs_dir)

    if (readme = pick_doc(path, README_RE))
      copy_capped(File.join(path, readme), File.join(abs_dir, "README.md"))
      docs["readme"] = File.join(rel_dir, "README.md")
    end
    if (changelog = pick_doc(path, CHANGELOG_RE))
      copy_capped(File.join(path, changelog), File.join(abs_dir, "CHANGELOG.md"))
      docs["changelog"] = File.join(rel_dir, "CHANGELOG.md")
    end

    api = extract_api(path)
    unless api.empty?
      File.write(File.join(abs_dir, "api.txt"), api.join("\n") + "\n")
      docs["api"] = File.join(rel_dir, "api.txt")
    end

    spec = gem_spec(name, version)
    meta = spec_meta(spec, version, path)
    File.write(File.join(abs_dir, "meta.json"), JSON.pretty_generate(meta))
    docs["meta"] = File.join(rel_dir, "meta.json")

    {
      "name" => name, "version" => version, "platform" => nil,
      "harvested" => true, "harvested_at" => Time.now.utc.iso8601,
      "path" => path, "dir" => rel_dir, "docs" => docs,
      "api_entries" => api.size
    }
  end

  # ---- commands ------------------------------------------------------------

  def cmd_check(opts)
    lockfile = find_lockfile(opts[:lockfile])
    cache    = cache_dir(opts, lockfile)
    parsed   = parse_lockfile(lockfile)
    manifest = load_manifest(cache)
    d        = diff(parsed["gems"], manifest)
    lock_sha = Digest::SHA256.file(lockfile).hexdigest
    result = {
      "lockfile"        => lockfile,
      "cache"           => cache,
      "manifest_exists" => !manifest.nil?,
      "lockfile_sha256" => lock_sha,
      "lockfile_changed" => manifest.nil? || manifest["lockfile_sha256"] != lock_sha,
      "up_to_date"      => (d["counts"]["added"].zero? && d["counts"]["removed"].zero? &&
                            d["counts"]["changed"].zero? && d["counts"]["stale_cache"].zero?),
      "diff"            => d
    }
    puts JSON.pretty_generate(result)
  end

  def cmd_sync(opts)
    lockfile = find_lockfile(opts[:lockfile])
    cache    = cache_dir(opts, lockfile)
    parsed   = parse_lockfile(lockfile)
    manifest = load_manifest(cache)
    d        = diff(parsed["gems"], manifest)
    FileUtils.mkdir_p(cache)

    targets =
      if opts[:all]
        parsed["gems"].keys.sort
      else
        (d["added"] + d["changed"].map { |c| c["name"] } + d["stale_cache"]).uniq.sort
      end

    gem_entries = manifest ? (manifest["gems"] || {}).dup : {}
    # Drop removed gems from the manifest.
    (gem_entries.keys - parsed["gems"].keys).each { |name| gem_entries.delete(name) }

    harvested, skipped, errors = [], [], []
    targets.each do |name|
      version = parsed["gems"][name]["version"]
      entry = harvest_gem(name, version, cache)
      entry["platform"] = parsed["gems"][name]["platform"]
      gem_entries[name] = entry
      if entry["harvested"]
        harvested << "#{name} #{version}"
      else
        errors << "#{name} #{version}: #{entry['error']}"
      end
    end
    # Record versions for untouched gems too (so the manifest always mirrors the lockfile).
    parsed["gems"].each do |name, info|
      next if gem_entries[name]
      gem_entries[name] = { "name" => name, "version" => info["version"],
                            "platform" => info["platform"], "harvested" => false }
      skipped << "#{name} #{info['version']}"
    end

    pruned = []
    if opts[:prune]
      keep = parsed["gems"].map { |n, i| "#{n}-#{i['version']}" }.to_set
      Dir.glob(File.join(cache, "gems", "*")).each do |dir|
        base = File.basename(dir)
        next if keep.include?(base)
        FileUtils.rm_rf(dir)
        pruned << base
      end
    end

    new_manifest = {
      "schema"          => SCHEMA_VERSION,
      "generated_at"    => Time.now.utc.iso8601,
      "lockfile"        => lockfile,
      "lockfile_sha256" => Digest::SHA256.file(lockfile).hexdigest,
      "bundler_version" => parsed["bundler_version"],
      "ruby_version"    => parsed["ruby_version"],
      "gems"            => gem_entries
    }
    File.write(manifest_path(cache), JSON.pretty_generate(new_manifest))

    puts JSON.pretty_generate(
      "cache" => cache, "mode" => opts[:all] ? "all" : "changed",
      "harvested" => harvested, "harvested_count" => harvested.size,
      "skipped_count" => skipped.size, "pruned" => pruned, "errors" => errors,
      "manifest" => manifest_path(cache)
    )
  end

  def cmd_status(opts)
    lockfile = find_lockfile(opts[:lockfile])
    cache    = cache_dir(opts, lockfile)
    parsed   = parse_lockfile(lockfile)
    manifest = load_manifest(cache)
    d        = diff(parsed["gems"], manifest)
    harvested_n = manifest ? (manifest["gems"] || {}).values.count { |g| g["harvested"] } : 0

    if opts[:json]
      puts JSON.pretty_generate("cache" => cache, "manifest_exists" => !manifest.nil?,
                                "locked" => parsed["gems"].size, "harvested" => harvested_n, "diff" => d)
      return
    end

    puts "gem-docs cache: #{cache}"
    puts "Lockfile:       #{lockfile}"
    if manifest
      puts "Manifest:       present (generated #{manifest['generated_at']})"
      puts "Harvested:      #{harvested_n} / #{parsed['gems'].size} locked gems"
    else
      puts "Manifest:       MISSING - run `sync` to build the cache."
    end
    c = d["counts"]
    if d["added"].empty? && d["removed"].empty? && d["changed"].empty? && d["stale_cache"].empty?
      puts "Status:         up to date"
    else
      puts "Pending changes:"
      puts "  added:    #{c['added']}  #{d['added'].first(8).join(', ')}" unless d["added"].empty?
      puts "  removed:  #{c['removed']}  #{d['removed'].first(8).join(', ')}" unless d["removed"].empty?
      unless d["changed"].empty?
        puts "  changed:  #{c['changed']}"
        d["changed"].first(12).each { |ch| puts "    - #{ch['name']}: #{ch['from']} -> #{ch['to']} (#{ch['direction']})" }
      end
      puts "  uncached: #{c['stale_cache']}  #{d['stale_cache'].first(8).join(', ')}" unless d["stale_cache"].empty?
      puts "  -> run `sync` to refresh."
    end
  end

  def cmd_surface(opts, name)
    abort "gem_docs surface: gem name required" unless name
    lockfile = find_lockfile(opts[:lockfile])
    cache    = cache_dir(opts, lockfile)
    manifest = load_manifest(cache)
    entry    = manifest && manifest["gems"] && manifest["gems"][name]
    unless entry && entry["harvested"]
      abort "gem_docs surface: #{name} not in cache - run `sync` (or `sync --all`) first."
    end
    docs = entry["docs"] || {}
    result = {
      "name" => name, "version" => entry["version"], "dir" => File.join(cache, entry["dir"].to_s),
      "files" => docs.transform_values { |rel| File.join(cache, rel) }
    }
    puts JSON.pretty_generate(result)
  end

  def cmd_changelog(opts, name)
    abort "gem_docs changelog: gem name required" unless name
    lockfile = find_lockfile(opts[:lockfile])
    cache    = cache_dir(opts, lockfile)
    manifest = load_manifest(cache)
    entry    = manifest && manifest["gems"] && manifest["gems"][name]
    rel      = entry && entry["docs"] && entry["docs"]["changelog"]
    abort "gem_docs changelog: no cached CHANGELOG for #{name} (run `sync`)." unless rel
    path = File.join(cache, rel)
    abort "gem_docs changelog: cached file missing: #{path}" unless File.file?(path)
    puts "# #{name} #{entry['version']} - cached CHANGELOG (#{path})"
    puts File.read(path)
  end
end

# ---- arg parsing -----------------------------------------------------------

def parse_args(argv)
  opts = {}
  positional = []
  i = 0
  while i < argv.length
    arg = argv[i]
    case arg
    when "--all"      then opts[:all] = true
    when "--prune"    then opts[:prune] = true
    when "--json"     then opts[:json] = true
    when "--lockfile" then opts[:lockfile] = argv[i += 1]
    when "--cache"    then opts[:cache] = argv[i += 1]
    when /\A--lockfile=(.*)/ then opts[:lockfile] = $1
    when /\A--cache=(.*)/    then opts[:cache] = $1
    when "-h", "--help" then opts[:help] = true
    else positional << arg
    end
    i += 1
  end
  [positional, opts]
end

USAGE = <<~TXT
  gem_docs.rb - offline gem-doc cache + change detection

  Usage: bundle exec ruby gem_docs.rb <command> [options]

  Commands:
    check               Diff Gemfile.lock vs manifest (read-only JSON)
    sync [--all]        Harvest docs for changed/missing gems (--all = every gem)
         [--prune]      Delete cached dirs no longer in the lockfile
    status [--json]     Cache + pending-change summary
    surface NAME        Print cache file paths for one gem
    changelog NAME      Print cached CHANGELOG for one gem

  Options: --lockfile PATH  --cache PATH  --json
TXT

positional, opts = parse_args(ARGV)
command = positional.shift

if opts[:help] || command.nil?
  puts USAGE
  exit(command.nil? ? 1 : 0)
end

case command
when "check"     then GemDocs.cmd_check(opts)
when "sync"      then GemDocs.cmd_sync(opts)
when "status"    then GemDocs.cmd_status(opts)
when "surface"   then GemDocs.cmd_surface(opts, positional.shift)
when "changelog" then GemDocs.cmd_changelog(opts, positional.shift)
else
  warn "gem_docs: unknown command #{command.inspect}"
  warn USAGE
  exit 1
end
