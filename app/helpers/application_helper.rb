module ApplicationHelper
  STATUS_CLASSES = { "ok" => "success", "error" => "danger", "unknown" => "secondary" }.freeze

  def status_badge(status)
    tag.span(status, class: "badge text-bg-#{STATUS_CLASSES.fetch(status, 'secondary')}")
  end

  def tool_dom_id(server, tool_name)
    "tool_#{server.id}_#{Digest::SHA256.hexdigest(tool_name)[0, 12]}"
  end

  def time_ago_or_dash(time)
    time ? "#{time_ago_in_words(time)} ago" : "—"
  end

  def nav_link(label, path)
    active = current_page?(path) || (path != root_path && request.path.start_with?(path))
    link_to label, path, class: "nav-link#{' active' if active}"
  end
end
