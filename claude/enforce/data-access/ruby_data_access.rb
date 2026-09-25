# frozen_string_literal: true

# ruby_data_access.rb: the deterministic half of the data-access rules for
# Ruby (R-361, R-362), run by hooks/push-rubocop-gate.sh over the outgoing
# diff's Ruby files. Standard library only (Ripper and JSON), because RuboCop
# is not installed in CI and a custom cop would add a dependency. Ripper rather
# than Prism: Prism is stdlib only from Ruby 3.3, while ubuntu-latest ships
# Ruby 3.2 and macOS still carries a 2.6 /usr/bin/ruby; Ripper exists in all of
# them, and this file avoids syntax newer than 2.6.
#
# Usage: ruby ruby_data_access.rb <file>...
# Prints a JSON array of {"file","line","rule","message"} to stdout and exits
# 0 whether or not there are findings; exits 2 on bad usage. A file that does
# not parse, or cannot be read, is skipped.
#
# What it decides:
#   R-361: a data-access call inside the block of an iteration method (each,
#   map, select, find_each, times, loop, ...) or inside a while/until loop
#   (condition and body) or a for loop body. A data-access call is an
#   ActiveRecord query or persistence class method on a model constant
#   (Trip.find, Admin::Trip.where, Trip.includes(:legs).find), a
#   connection-level SQL call (exec_query, select_all, select_value,
#   select_values, select_rows, and execute when it is bare or on a
#   connection), or `.call` on a query object (a constant named *Query or
#   under a Queries namespace). The receiver of the iteration runs once and
#   is not reported: `Trip.where(user_id: id).each { ... }` is fine.
#   R-362: inside a `transaction` or `with_lock` block, network I/O (calls
#   rooted in Net::HTTP, Faraday, HTTParty, RestClient, Excon, Typhoeus, HTTP,
#   a Clients namespace, or a constant named *Client), mailer delivery
#   (deliver_now, deliver_later), and job enqueues (perform_later,
#   perform_async, perform_in, perform_at). Work inside an after_commit /
#   after_rollback block nested in the transaction is the fix, not a finding.
#
# What it does NOT decide:
#   - Lazy association access such as `post.comments` inside a loop. Whether
#     that queries depends on what was preloaded at runtime, so it is not
#     statically decidable; the fix is `includes`/`preload` plus
#     `strict_loading`, which the convention text covers.
#   - A query hidden behind a helper method, a service, or a local variable
#     that holds a model class or a client: calls are not followed.
#   - Whether a group of writes needed a transaction at all (judge territory),
#     and whether a job enqueue is already deferred by Rails 7.2's
#     enqueue_after_transaction_commit (the call is still reported; mark it
#     with the allow comment if the app relies on that setting).
#
# Suppression: a finding is dropped when its line, or the line directly above,
# carries `# data-access-allow: <reason>` with a non-empty reason.
# Exempt paths: spec/, test/, db/, lib/tasks/, script/, scripts/, bin/, and
# files named *_spec.rb or *_test.rb.

require "json"
require "ripper"

# Scans one parsed file and collects R-361/R-362 findings.
class RubyDataAccessChecker
  ITERATION_METHODS = %w[
    each map flat_map collect collect_concat each_with_object each_with_index
    select filter filter_map reject find detect sum group_by index_by to_h
    times each_slice each_cons find_each find_in_batches in_batches loop
    each_pair each_key each_value upto downto reduce inject any? all? none?
    sort_by min_by max_by partition
  ].freeze

  # ActiveRecord class-level (or relation-level) calls that hit the database.
  AR_QUERY_METHODS = %w[
    find find_by find_by! where exists? count sum pluck first last first!
    last! take take! sole find_sole_by pick ids minimum maximum average
    calculate find_by_sql count_by_sql create create! find_or_create_by
    find_or_create_by! find_or_initialize_by create_or_find_by
    create_or_find_by! update_all delete_all destroy_all delete_by destroy_by
    insert insert! insert_all insert_all! upsert upsert_all update_counters
    increment_counter decrement_counter find_each find_in_batches in_batches
  ].freeze

  # Relation builders: a chain of these from a model constant is still a
  # relation, so `Trip.includes(:legs).find(id)` is a query on Trip.
  RELATION_BUILDERS = %w[
    all where not rewhere order reorder includes preload eager_load joins
    left_joins left_outer_joins limit offset lock unscoped readonly distinct
    group having references extending none strict_loading in_order_of select
    unscope merge
  ].freeze

  CONNECTION_SQL_METHODS = %w[
    exec_query select_all select_value select_values select_rows
  ].freeze

  CORE_CONSTANTS = %w[
    Array Hash Set File Integer JSON Time Date DateTime URI Struct Comparable
    Kernel Math ENV Rails String Symbol Float Rational Complex BigDecimal
    Regexp Range Object Dir IO Process SecureRandom Digest Base64 CSV YAML
    Enumerable ObjectSpace ActiveSupport I18n Pathname Logger
  ].freeze

  # A CamelCase constant with one of these suffixes is a service, client,
  # mailer, or similar collaborator, not an ActiveRecord model.
  NON_MODEL_SUFFIX = /[a-z0-9](Service|Client|Job|Mailer|Serializer|Worker|Controller|Policy|Presenter|Form|Error|Helper|Query|Decorator|Builder)\z/.freeze

  NETWORK_ROOTS = %w[Faraday HTTParty RestClient Excon Typhoeus HTTP].freeze
  DELIVERY_METHODS = %w[deliver_now deliver_later deliver_now! deliver_later!].freeze
  ENQUEUE_METHODS = %w[perform_later perform_async perform_in perform_at].freeze
  TRANSACTION_METHODS = %w[transaction with_lock].freeze
  AFTER_COMMIT_METHODS = %w[after_commit after_rollback after_all_transactions_commit].freeze

  CALL_NODES = %i[method_add_block method_add_arg call command_call command fcall vcall].freeze
  CONST_NODES = %i[var_ref const_ref top_const_ref const_path_ref].freeze

  ALLOW_COMMENT = /\A#\s*data-access-allow:\s*\S/.freeze

  EMPTY_CONTEXT = { loop: nil, txn: false }.freeze

  def initialize(path, source)
    @path = path
    @source = source
    @findings = []
  end

  # Returns the findings for this file, or nil when it does not parse.
  def run
    tree = Ripper.sexp(@source, @path)
    return nil if tree.nil?

    visit(tree, EMPTY_CONTEXT)
    allowed = allowed_lines
    kept = @findings.reject { |f| allowed[f["line"]] || allowed[f["line"] - 1] }
    kept.uniq.sort_by { |f| [f["line"], f["rule"]] }
  end

  private

  def allowed_lines
    lines = {}
    Ripper.lex(@source).each do |(pos, type, text)|
      lines[pos[0]] = true if type == :on_comment && text =~ ALLOW_COMMENT
    end
    lines
  end

  def visit(node, ctx)
    return unless node.is_a?(Array)

    head = node[0]
    unless head.is_a?(Symbol)
      node.each { |child| visit(child, ctx) }
      return
    end
    return if head.to_s.start_with?("@")

    if CALL_NODES.include?(head)
      visit_call(node, ctx, false, false)
      return
    end

    case head
    when :def, :defs
      # A method body runs when it is called, not once per surrounding element.
      node[1..-1].each { |child| visit(child, EMPTY_CONTEXT) }
    when :while, :until, :while_mod, :until_mod
      # The condition runs once per iteration, like the body.
      inner = ctx.merge(loop: "a #{head.to_s.sub('_mod', '')} loop")
      node[1..-1].each { |child| visit(child, inner) }
    when :for
      visit(node[1], ctx)
      visit(node[2], ctx)
      visit(node[3], ctx.merge(loop: "a for loop"))
    else
      node[1..-1].each { |child| visit(child, ctx) }
    end
  end

  # skip361/skip362 are true while walking down the receiver chain of a call
  # already reported, so one chain yields one finding.
  def visit_call(node, ctx, skip361, skip362)
    parts = call_parts(node)
    reported361 = false
    reported362 = false

    if ctx[:loop] && !skip361
      desc = data_access_description(parts)
      if desc
        add_finding(parts[:line] || first_line(node), "R-361",
                    "#{desc} runs inside #{ctx[:loop]}, issuing one query per element (N+1); " \
                    "load the set once before the loop (where(id: ids), includes/preload, or a plural query object) " \
                    "and look rows up in memory, or mark a deliberately bounded loop with `# data-access-allow: <bound>`.")
        reported361 = true
      end
    end

    if ctx[:txn] && !skip362
      message = transaction_message(parts)
      if message
        add_finding(parts[:line] || first_line(node), "R-362", message)
        reported362 = true
      end
    end

    recv = parts[:recv]
    if call_node?(recv)
      visit_call(recv, ctx, skip361 || reported361, skip362 || reported362)
    else
      visit(recv, ctx)
    end
    parts[:args].each { |args| visit(args, ctx) }
    visit(parts[:block], block_context(parts[:name], ctx)) if parts[:block]
  end

  def block_context(name, ctx)
    if ITERATION_METHODS.include?(name)
      ctx.merge(loop: "the .#{name} block")
    elsif TRANSACTION_METHODS.include?(name)
      ctx.merge(txn: true)
    elsif AFTER_COMMIT_METHODS.include?(name)
      ctx.merge(txn: false)
    else
      ctx
    end
  end

  # Normalizes the Ripper call shapes into receiver, method name, line,
  # argument nodes, and block.
  def call_parts(node)
    case node[0]
    when :method_add_block
      parts = call_parts(node[1])
      parts.merge(block: node[2])
    when :method_add_arg
      parts = call_parts(node[1])
      parts.merge(args: parts[:args] + [node[2]])
    when :call
      token_parts(node[1], node[3], []).tap { |p| p[:line] ||= token_line(node[2]) }
    when :command_call
      token_parts(node[1], node[3], [node[4]])
    when :command
      token_parts(nil, node[1], [node[2]])
    else # :fcall, :vcall
      token_parts(nil, node[1], [])
    end
  end

  def token_parts(recv, token, args)
    name = token == :call ? "call" : token_text(token)
    { recv: recv, name: name, line: token_line(token), args: args, block: nil }
  end

  def token_text(token)
    token.is_a?(Array) && token[1].is_a?(String) ? token[1] : nil
  end

  def token_line(token)
    token.is_a?(Array) && token[2].is_a?(Array) ? token[2][0] : nil
  end

  def first_line(node)
    return nil unless node.is_a?(Array)
    return node[2][0] if node[0].is_a?(Symbol) && node[0].to_s.start_with?("@") && node[2].is_a?(Array)

    node.each do |child|
      line = first_line(child)
      return line if line
    end
    nil
  end

  def call_node?(node)
    node.is_a?(Array) && CALL_NODES.include?(node[0])
  end

  def const_name(node)
    return nil unless node.is_a?(Array)

    case node[0]
    when :var_ref, :const_ref, :top_const_ref
      node[1].is_a?(Array) && node[1][0] == :@const ? node[1][1] : nil
    when :const_path_ref
      base = const_name(node[1])
      base && node[2].is_a?(Array) ? "#{base}::#{node[2][1]}" : nil
    end
  end

  def model_constant(node)
    name = const_name(node)
    return nil unless name

    segments = name.split("::")
    return nil if CORE_CONSTANTS.include?(segments.first)

    last = segments.last
    # SCREAMING_CASE constants are values (arrays, hashes), not models.
    return nil unless last =~ /\A[A-Z][A-Za-z0-9]*\z/ && last =~ /[a-z]/
    return nil if last =~ NON_MODEL_SUFFIX || segments.include?("Clients") || segments.include?("Queries")

    name
  end

  # The model a relation chain starts from, or nil when the receiver is not a
  # model constant reached through relation builders only.
  def relation_model(recv)
    model = model_constant(recv)
    return [model, true] if model
    return nil unless call_node?(recv)

    parts = call_parts(recv)
    return nil if parts[:block] || !RELATION_BUILDERS.include?(parts[:name])

    found = relation_model(parts[:recv])
    found ? [found[0], false] : nil
  end

  def query_object?(name)
    return false unless name

    segments = name.split("::")
    segments.last.end_with?("Query") || segments.include?("Queries")
  end

  def connection_receiver?(recv)
    return true if recv.nil?

    name = call_node?(recv) ? call_parts(recv)[:name] : token_text(recv[1])
    !name.nil? && name.include?("conn")
  end

  def data_access_description(parts)
    name = parts[:name]
    recv = parts[:recv]
    return nil unless name
    return name if CONNECTION_SQL_METHODS.include?(name)
    return "execute" if name == "execute" && connection_receiver?(recv)

    if AR_QUERY_METHODS.include?(name)
      found = relation_model(recv)
      return found[1] ? "#{found[0]}.#{name}" : "#{found[0]}...#{name}" if found
    end

    return nil unless name == "call"

    direct = const_name(recv)
    return "#{direct}.call" if query_object?(direct)

    if call_node?(recv)
      inner = call_parts(recv)
      built = const_name(inner[:recv])
      return "#{built}.new(...).call" if inner[:name] == "new" && query_object?(built)
    end
    nil
  end

  def chain_root_constant(node)
    node = call_parts(node)[:recv] while call_node?(node)
    const_name(node)
  end

  def network_constant?(name)
    return false unless name

    segments = name.split("::")
    return true if segments[0, 2] == %w[Net HTTP]
    return true if NETWORK_ROOTS.include?(segments.first)

    segments.include?("Clients") || segments.last.end_with?("Client")
  end

  def transaction_message(parts)
    name = parts[:name]
    return nil unless name

    root = chain_root_constant(parts[:recv])
    separator = const_name(parts[:recv]) ? "." : "..."
    label = root ? "#{root}#{separator}#{name}" : ".#{name}"
    if DELIVERY_METHODS.include?(name) || ENQUEUE_METHODS.include?(name)
      kind = DELIVERY_METHODS.include?(name) ? "mail delivery" : "job enqueue"
      return "#{label} is a #{kind} inside a transaction block, so it can run before the commit or after a rollback; " \
             "trigger it from an after_commit callback, move it after the block, or write an outbox row inside the transaction."
    end
    return nil if name == "new" || !network_constant?(root)

    "#{label} makes a network call inside a transaction block, holding the transaction's locks and connection while it waits; " \
      "move the call after the block, into an after_commit callback, or write an outbox row inside the transaction."
  end

  def add_finding(line, rule, message)
    @findings << { "file" => @path, "line" => line.to_i, "rule" => rule, "message" => message }
  end
end

EXEMPT_SEGMENTS = %w[spec test db script scripts bin].freeze

def exempt_path?(path)
  segments = path.sub(%r{\A(\./)+}, "").split("/")
  base = segments.last.to_s
  return true if base.end_with?("_spec.rb", "_test.rb")

  dirs = segments[0...-1]
  return true if dirs.any? { |segment| EXEMPT_SEGMENTS.include?(segment) }

  dirs.each_cons(2).any? { |pair| pair == %w[lib tasks] }
end

def read_source(path)
  source = File.binread(path).force_encoding(Encoding::UTF_8)
  source.valid_encoding? ? source : source.scrub
rescue SystemCallError, IOError
  nil
end

if ARGV.empty?
  warn "usage: ruby #{File.basename(__FILE__)} <file>..."
  exit 2
end

findings = []
ARGV.each do |path|
  next if exempt_path?(path)

  source = read_source(path)
  next if source.nil?

  begin
    result = RubyDataAccessChecker.new(path, source).run
  rescue StandardError => e
    # One malformed file must not hide the findings for the others.
    warn "ruby_data_access: skipped #{path}: #{e.class}: #{e.message}"
    next
  end
  findings.concat(result) if result
end

puts JSON.generate(findings)
exit 0
