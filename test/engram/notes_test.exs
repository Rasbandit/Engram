defmodule Engram.NotesTest do
  use Engram.DataCase, async: false

  alias Engram.Notes

  setup do
    user = insert(:user)
    other_user = insert(:user)
    %{user: user, other_user: other_user}
  end

  # ---------------------------------------------------------------------------
  # upsert_note/2
  # ---------------------------------------------------------------------------

  describe "upsert_note/2" do
    test "creates a new note", %{user: user} do
      assert {:ok, note} =
               Notes.upsert_note(user, %{
                 "path" => "Test/Hello.md",
                 "content" => "# Hello\nWorld",
                 "mtime" => 1_709_234_567.0
               })

      assert note.path == "Test/Hello.md"
      assert note.title == "Hello"
      assert note.folder == "Test"
      assert note.content == "# Hello\nWorld"
      assert note.version == 1
      assert is_binary(note.content_hash)
    end

    test "upserts existing note, increments version", %{user: user} do
      {:ok, v1} =
        Notes.upsert_note(user, %{
          "path" => "Test/File.md",
          "content" => "# Original",
          "mtime" => 1_000.0
        })

      {:ok, v2} =
        Notes.upsert_note(user, %{
          "path" => "Test/File.md",
          "content" => "# Updated",
          "mtime" => 2_000.0
        })

      assert v2.id == v1.id
      assert v2.version == 2
      assert v2.title == "Updated"
    end

    test "extracts tags from frontmatter", %{user: user} do
      {:ok, note} =
        Notes.upsert_note(user, %{
          "path" => "Test/Tagged.md",
          "content" => "---\ntags: [health, omega]\n---\n# Tagged\nBody",
          "mtime" => 1_000.0
        })

      assert note.tags == ["health", "omega"]
    end

    test "sanitizes path before storing", %{user: user} do
      {:ok, note} =
        Notes.upsert_note(user, %{
          "path" => "Test/Why do I resist?.md",
          "content" => "# Why",
          "mtime" => 1_000.0
        })

      assert note.path == "Test/Why do I resist.md"
    end

    test "computes content_hash", %{user: user} do
      content = "# Hello\nWorld"
      {:ok, note} = Notes.upsert_note(user, %{"path" => "Test/A.md", "content" => content, "mtime" => 1_000.0})

      expected = :crypto.hash(:sha256, content) |> Base.encode16(case: :lower)
      assert note.content_hash == expected
    end

    test "handles empty content", %{user: user} do
      assert {:ok, note} =
               Notes.upsert_note(user, %{
                 "path" => "Test/Empty.md",
                 "content" => "",
                 "mtime" => 1_000.0
               })

      assert note.path == "Test/Empty.md"
    end

    test "returns error for missing path" do
      user = insert(:user)

      assert {:error, changeset} =
               Notes.upsert_note(user, %{"content" => "# Hello", "mtime" => 1_000.0})

      assert errors_on(changeset).path
    end
  end

  # ---------------------------------------------------------------------------
  # get_note/2
  # ---------------------------------------------------------------------------

  describe "get_note/2" do
    test "returns note for correct user", %{user: user} do
      {:ok, created} =
        Notes.upsert_note(user, %{
          "path" => "Test/Readable.md",
          "content" => "# Readable",
          "mtime" => 1_000.0
        })

      assert {:ok, found} = Notes.get_note(user, "Test/Readable.md")
      assert found.id == created.id
    end

    test "returns not_found for wrong user", %{user: user, other_user: other_user} do
      Notes.upsert_note(user, %{
        "path" => "Test/Private.md",
        "content" => "# Private",
        "mtime" => 1_000.0
      })

      assert {:error, :not_found} = Notes.get_note(other_user, "Test/Private.md")
    end

    test "returns not_found for deleted note", %{user: user} do
      Notes.upsert_note(user, %{
        "path" => "Test/ToDelete.md",
        "content" => "# Delete me",
        "mtime" => 1_000.0
      })

      Notes.delete_note(user, "Test/ToDelete.md")

      assert {:error, :not_found} = Notes.get_note(user, "Test/ToDelete.md")
    end

    test "returns not_found for nonexistent path", %{user: user} do
      assert {:error, :not_found} = Notes.get_note(user, "Nope/Missing.md")
    end
  end

  # ---------------------------------------------------------------------------
  # delete_note/2
  # ---------------------------------------------------------------------------

  describe "delete_note/2" do
    test "soft-deletes a note", %{user: user} do
      Notes.upsert_note(user, %{
        "path" => "Test/Bye.md",
        "content" => "# Bye",
        "mtime" => 1_000.0
      })

      assert :ok = Notes.delete_note(user, "Test/Bye.md")
      assert {:error, :not_found} = Notes.get_note(user, "Test/Bye.md")
    end

    test "is idempotent for nonexistent note", %{user: user} do
      assert :ok = Notes.delete_note(user, "Fake/Note.md")
    end

    test "does not affect other user's notes", %{user: user, other_user: other_user} do
      Notes.upsert_note(user, %{
        "path" => "Test/Shared Path.md",
        "content" => "# User A note",
        "mtime" => 1_000.0
      })

      assert :ok = Notes.delete_note(other_user, "Test/Shared Path.md")
      # User A's note should still exist
      assert {:ok, _} = Notes.get_note(user, "Test/Shared Path.md")
    end
  end

  # ---------------------------------------------------------------------------
  # list_changes/2
  # ---------------------------------------------------------------------------

  describe "list_changes/2" do
    test "returns notes updated since timestamp", %{user: user} do
      {:ok, note} =
        Notes.upsert_note(user, %{
          "path" => "Test/Recent.md",
          "content" => "# Recent",
          "mtime" => 1_000.0
        })

      past = DateTime.add(note.updated_at, -60, :second)
      {:ok, changes} = Notes.list_changes(user, past)

      assert Enum.any?(changes, &(&1.path == "Test/Recent.md"))
    end

    test "includes soft-deleted notes with deleted flag", %{user: user} do
      Notes.upsert_note(user, %{
        "path" => "Test/Deleted.md",
        "content" => "# Will be deleted",
        "mtime" => 1_000.0
      })

      Notes.delete_note(user, "Test/Deleted.md")

      past = ~U[2020-01-01 00:00:00Z]
      {:ok, changes} = Notes.list_changes(user, past)

      deleted = Enum.find(changes, &(&1.path == "Test/Deleted.md"))
      assert deleted != nil
      assert deleted.deleted == true
    end

    test "excludes notes from other users", %{user: user, other_user: other_user} do
      Notes.upsert_note(other_user, %{
        "path" => "Test/Other.md",
        "content" => "# Other user",
        "mtime" => 1_000.0
      })

      past = ~U[2020-01-01 00:00:00Z]
      {:ok, changes} = Notes.list_changes(user, past)

      refute Enum.any?(changes, &(&1.path == "Test/Other.md"))
    end

    test "returns empty list when no changes since timestamp", %{user: user} do
      {:ok, changes} = Notes.list_changes(user, ~U[2099-01-01 00:00:00Z])
      assert changes == []
    end
  end

  # ---------------------------------------------------------------------------
  # list_tags/1
  # ---------------------------------------------------------------------------

  describe "list_tags/1" do
    test "returns unique tags across user's notes", %{user: user} do
      Notes.upsert_note(user, %{
        "path" => "A.md",
        "content" => "---\ntags: [health, fitness]\n---",
        "mtime" => 1_000.0
      })

      Notes.upsert_note(user, %{
        "path" => "B.md",
        "content" => "---\ntags: [health, nutrition]\n---",
        "mtime" => 1_000.0
      })

      {:ok, tags} = Notes.list_tags(user)
      assert "health" in tags
      assert "fitness" in tags
      assert "nutrition" in tags
      # health appears in 2 notes but should only show once
      assert Enum.count(tags, &(&1 == "health")) == 1
    end

    test "excludes tags from other users", %{user: user, other_user: other_user} do
      Notes.upsert_note(other_user, %{
        "path" => "A.md",
        "content" => "---\ntags: [secret]\n---",
        "mtime" => 1_000.0
      })

      {:ok, tags} = Notes.list_tags(user)
      refute "secret" in tags
    end
  end

  # ---------------------------------------------------------------------------
  # list_folders/1
  # ---------------------------------------------------------------------------

  describe "list_folders/1" do
    test "returns unique folders for user", %{user: user} do
      Notes.upsert_note(user, %{"path" => "Folder A/Note.md", "content" => "x", "mtime" => 1_000.0})
      Notes.upsert_note(user, %{"path" => "Folder B/Note.md", "content" => "x", "mtime" => 1_000.0})
      Notes.upsert_note(user, %{"path" => "Folder A/Other.md", "content" => "x", "mtime" => 1_000.0})

      {:ok, folders} = Notes.list_folders(user)
      assert "Folder A" in folders
      assert "Folder B" in folders
      assert Enum.count(folders, &(&1 == "Folder A")) == 1
    end

    test "excludes empty folder (root-level notes)", %{user: user} do
      Notes.upsert_note(user, %{"path" => "Root.md", "content" => "x", "mtime" => 1_000.0})

      {:ok, folders} = Notes.list_folders(user)
      refute "" in folders
    end

    test "excludes other users folders", %{user: user, other_user: other_user} do
      Notes.upsert_note(other_user, %{
        "path" => "Private Folder/Note.md",
        "content" => "x",
        "mtime" => 1_000.0
      })

      {:ok, folders} = Notes.list_folders(user)
      refute "Private Folder" in folders
    end
  end
end
