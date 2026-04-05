defmodule Engram.MCP.Handlers do
  @moduledoc """
  MCP tool handler implementations.
  Each function takes (user, args) and returns a markdown-formatted string.
  """

  alias Engram.{Notes, Search}

  # -- Read tools --

  def search_notes(user, args) do
    query = args["query"] || ""
    limit = min(args["limit"] || 5, 20)
    tags = args["tags"]

    opts = [limit: limit]
    opts = if tags, do: Keyword.put(opts, :tags, tags), else: opts

    case Search.search(user, query, opts) do
      {:ok, results} when results != [] ->
        results
        |> Enum.with_index(1)
        |> Enum.map(fn {r, i} ->
          lines = ["## Result #{i} (score: #{Float.round(r.score, 3)})"]
          lines = if r[:title], do: lines ++ ["**Title:** #{r.title}"], else: lines

          lines =
            if r[:heading_path], do: lines ++ ["**Section:** #{r.heading_path}"], else: lines

          lines = if r[:source_path], do: lines ++ ["**Source:** #{r.source_path}"], else: lines

          lines =
            if r[:tags] && r.tags != [],
              do: lines ++ ["**Tags:** #{Enum.join(r.tags, ", ")}"],
              else: lines

          lines = lines ++ ["\n#{r.text}\n"]
          Enum.join(lines, "\n")
        end)
        |> Enum.join("\n")

      {:ok, []} ->
        "No results found."

      {:error, _reason} ->
        "Search unavailable."
    end
  end

  def list_tags(user, _args) do
    {:ok, tags} = Notes.list_tags_with_counts(user)

    if tags == [] do
      "No tags found."
    else
      lines = ["| Tag | Count |", "|-----|-------|"]

      lines =
        lines ++
          Enum.map(tags, fn t -> "| #{t.name} | #{t.count} |" end)

      Enum.join(lines, "\n")
    end
  end

  def list_folders(user, _args) do
    {:ok, folders} = Notes.list_folders_with_counts(user)

    if folders == [] do
      "No folders found."
    else
      lines = ["| Folder | Notes |", "|--------|-------|"]

      lines =
        lines ++
          Enum.map(folders, fn f ->
            folder_name = if f.folder == "" or is_nil(f.folder), do: "(root)", else: f.folder
            "| #{folder_name} | #{f.count} |"
          end)

      Enum.join(lines, "\n")
    end
  end

  def list_folder(user, args) do
    folder = args["folder"] || ""
    {:ok, notes} = Notes.list_notes_in_folder(user, folder)

    if notes == [] do
      folder_label = if folder == "", do: "(root)", else: folder
      "No notes found in folder: #{folder_label}"
    else
      folder_label = if folder == "", do: "(root)", else: folder

      lines = [
        "**Folder:** #{folder_label}",
        "",
        "| Title | Path | Tags |",
        "|-------|------|------|"
      ]

      lines =
        lines ++
          Enum.map(notes, fn n ->
            tags = if n.tags && n.tags != [], do: Enum.join(n.tags, ", "), else: ""
            "| #{n.title} | #{n.path} | #{tags} |"
          end)

      Enum.join(lines, "\n")
    end
  end

  def suggest_folder(user, args) do
    description = args["description"] || ""
    limit = max(1, min(args["limit"] || 5, 10))

    # Search fallback: find notes similar to description, count folder frequencies
    case Search.search(user, description, limit: 10) do
      {:ok, results} when results != [] ->
        folder_counts =
          results
          |> Enum.map(fn r ->
            path = r[:source_path] || ""

            if String.contains?(path, "/") do
              path |> String.split("/") |> Enum.drop(-1) |> Enum.join("/")
            else
              ""
            end
          end)
          |> Enum.frequencies()
          |> Enum.sort_by(fn {_f, c} -> -c end)
          |> Enum.take(limit)

        if folder_counts == [] do
          "No folders found. The vault may be empty."
        else
          lines = ["| Rank | Folder | Notes |", "|------|--------|-------|"]

          lines =
            (lines ++
               Enum.with_index(folder_counts, 1))
            |> Enum.map(fn {{folder, count}, rank} ->
              folder_name = if folder == "", do: "(root)", else: folder
              "| #{rank} | #{folder_name} | #{count} |"
            end)

          Enum.join(lines, "\n")
        end

      _ ->
        "No folders found. The vault may be empty."
    end
  end

  def get_note(user, args) do
    source_path = args["source_path"] || ""

    case Notes.get_note(user, source_path) do
      {:ok, note} ->
        lines = ["# #{note.title}"]

        lines =
          if note.tags && note.tags != [],
            do: lines ++ ["**Tags:** #{Enum.join(note.tags, ", ")}"],
            else: lines

        lines = lines ++ ["**Path:** #{note.path}"]
        lines = lines ++ ["**Folder:** #{note.folder || ""}\n"]
        lines = lines ++ [note.content]
        Enum.join(lines, "\n")

      {:error, :not_found} ->
        "Note not found: #{source_path}"
    end
  end

  # -- Write tools --

  def create_note(user, args) do
    title = args["title"] || "Untitled"
    content = args["content"] || ""
    suggested_folder = args["suggested_folder"]

    folder =
      if suggested_folder && suggested_folder != "" do
        String.trim_trailing(suggested_folder, "/")
      else
        auto_place_folder(user, title, content)
      end

    filename = String.replace(title, "/", "-") <> ".md"
    path = if folder != "", do: "#{folder}/#{filename}", else: filename

    # Add title as H1 if content doesn't start with one
    content =
      if String.starts_with?(String.trim(content), "# ") do
        content
      else
        "# #{title}\n\n#{content}"
      end

    case Notes.upsert_note(user, %{"path" => path, "content" => content, "mtime" => now()}) do
      {:ok, _note} -> "Note created: #{path}"
      {:error, _} -> "Failed to create note: #{path}"
    end
  end

  def write_note(_user, %{"content" => content}) when byte_size(content) > 10 * 1024 * 1024 do
    "Error: note exceeds maximum size of 10MB"
  end

  def write_note(user, args) do
    path = args["path"] || ""
    content = args["content"] || ""

    case Notes.upsert_note(user, %{"path" => path, "content" => content, "mtime" => now()}) do
      {:ok, _note} -> "Note saved: #{path}"
      {:error, _} -> "Failed to save note: #{path}"
    end
  end

  def append_to_note(user, args) do
    path = args["path"] || ""
    text = args["text"] || ""

    case Notes.get_note(user, path) do
      {:ok, note} ->
        content = String.trim_trailing(note.content, "\n") <> "\n" <> text

        case Notes.upsert_note(user, %{"path" => path, "content" => content, "mtime" => now()}) do
          {:ok, _} -> "Note appended to: #{path}"
          {:error, _} -> "Failed to append to note: #{path}"
        end

      {:error, :not_found} ->
        # Create new note with title from filename
        title =
          path
          |> String.split("/")
          |> List.last()
          |> String.trim_trailing(".md")

        content = "# #{title}\n\n#{text}"

        case Notes.upsert_note(user, %{"path" => path, "content" => content, "mtime" => now()}) do
          {:ok, _} -> "Note created: #{path}"
          {:error, _} -> "Failed to create note: #{path}"
        end
    end
  end

  def patch_note(user, args) do
    path = args["path"] || ""
    find = args["find"] || ""
    replace = args["replace"] || ""
    occurrence = args["occurrence"] || 0

    case Notes.get_note(user, path) do
      {:ok, note} ->
        if not String.contains?(note.content, find) do
          "Text not found in #{path}"
        else
          {new_content, count} = do_replace(note.content, find, replace, occurrence)

          case Notes.upsert_note(user, %{
                 "path" => path,
                 "content" => new_content,
                 "mtime" => now()
               }) do
            {:ok, _} -> "Replaced #{count} occurrence(s) in #{path}"
            {:error, _} -> "Failed to patch note: #{path}"
          end
        end

      {:error, :not_found} ->
        "Note not found: #{path}"
    end
  end

  def update_section(user, args) do
    path = args["path"] || ""
    heading = args["heading"] || ""
    new_content = args["content"] || ""
    level = args["level"] || 2

    case Notes.get_note(user, path) do
      {:ok, note} ->
        prefix = String.duplicate("#", max(1, min(level, 6))) <> " "
        target = prefix <> heading
        lines = String.split(note.content, "\n")

        # Find the heading line
        start_idx =
          Enum.find_index(lines, fn line ->
            String.trim(line) == String.trim(target)
          end)

        if start_idx == nil do
          "Heading not found: #{target}"
        else
          # Find end: next heading of same or higher level, or EOF
          end_idx =
            Enum.find_index(Enum.drop(lines, start_idx + 1), fn line ->
              stripped = String.trim_leading(line)

              if String.starts_with?(stripped, "#") do
                h_level =
                  stripped
                  |> String.graphemes()
                  |> Enum.take_while(&(&1 == "#"))
                  |> length()

                rest = String.slice(stripped, h_level, 1)
                h_level <= level and rest in [" ", ""]
              else
                false
              end
            end)

          end_idx =
            if end_idx == nil,
              do: length(lines),
              else: start_idx + 1 + end_idx

          # Rebuild: heading line + new content + rest
          new_lines =
            Enum.slice(lines, 0, start_idx + 1) ++
              [String.trim_trailing(new_content, "\n")] ++
              Enum.slice(lines, end_idx, length(lines))

          final_content = Enum.join(new_lines, "\n")

          case Notes.upsert_note(user, %{
                 "path" => path,
                 "content" => final_content,
                 "mtime" => now()
               }) do
            {:ok, _} -> "Section '#{heading}' updated in #{path}"
            {:error, _} -> "Failed to update section in #{path}"
          end
        end

      {:error, :not_found} ->
        "Note not found: #{path}"
    end
  end

  def rename_note(user, args) do
    old_path = args["old_path"] || ""
    new_path = args["new_path"] || ""

    case Notes.rename_note(user, old_path, new_path) do
      {:ok, _note} -> "Note renamed: #{old_path} -> #{new_path}"
      {:error, :not_found} -> "Note not found: #{old_path}"
    end
  end

  def rename_folder(user, args) do
    old_folder = args["old_folder"] || ""
    new_folder = args["new_folder"] || ""

    case Notes.rename_folder(user, old_folder, new_folder) do
      {:ok, count} -> "Folder renamed: #{old_folder} -> #{new_folder} (#{count} notes updated)"
    end
  end

  def delete_note(user, args) do
    path = args["path"] || ""
    Notes.delete_note(user, path)
    "Note deleted: #{path}"
  end

  # -- Private helpers --

  defp do_replace(content, find, replace, -1) do
    count = content |> String.split(find) |> length() |> Kernel.-(1)
    {String.replace(content, find, replace), count}
  end

  defp do_replace(content, find, replace, occurrence) do
    parts = String.split(content, find)

    if occurrence >= length(parts) - 1 do
      {content, 0}
    else
      before = Enum.take(parts, occurrence + 1) |> Enum.join(find)
      after_parts = Enum.drop(parts, occurrence + 1) |> Enum.join(find)
      {before <> replace <> after_parts, 1}
    end
  end

  defp auto_place_folder(user, title, content) do
    query =
      "#{title} #{String.slice(content, 0, 300)}" |> String.replace("\n", " ") |> String.trim()

    if query == "" do
      ""
    else
      case Search.search(user, query, limit: 10) do
        {:ok, results} when results != [] ->
          folder_counts =
            results
            |> Enum.map(fn r ->
              path = r[:source_path] || ""

              if String.contains?(path, "/") do
                path |> String.split("/") |> Enum.drop(-1) |> Enum.join("/")
              else
                ""
              end
            end)
            |> Enum.frequencies()
            |> Enum.sort_by(fn {_f, c} -> -c end)

          case folder_counts do
            [{folder, _} | _] -> folder
            _ -> ""
          end

        _ ->
          ""
      end
    end
  end

  defp now, do: :os.system_time(:second) |> Kernel./(1) |> Float.round(1)
end
