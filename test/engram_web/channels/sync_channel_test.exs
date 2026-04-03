defmodule EngramWeb.SyncChannelTest do
  use EngramWeb.ChannelCase, async: false

  alias Engram.Notes

  setup do
    user = insert(:user)
    other_user = insert(:user)
    {:ok, api_key, _} = Engram.Accounts.create_api_key(user, "channel-test")

    socket = user_socket(user)
    {:ok, _, socket} = join_sync(socket, user)

    %{socket: socket, user: user, other_user: other_user, api_key: api_key}
  end

  # ---------------------------------------------------------------------------
  # Connection & auth
  # ---------------------------------------------------------------------------

  describe "connect/3" do
    test "accepts valid API key" do
      user = insert(:user)
      {:ok, api_key, _} = Engram.Accounts.create_api_key(user, "test")

      assert {:ok, socket} =
               connect(EngramWeb.UserSocket, %{"token" => api_key})

      assert socket.assigns.current_user.id == user.id
    end

    test "rejects missing token" do
      assert :error = connect(EngramWeb.UserSocket, %{})
    end

    test "rejects invalid token" do
      assert :error = connect(EngramWeb.UserSocket, %{"token" => "bad_token"})
    end
  end

  describe "join/3" do
    test "accepts join for own user_id", %{user: user} do
      socket = user_socket(user)
      assert {:ok, _, _} = join_sync(socket, user)
    end

    test "rejects join for another user's channel", %{user: user, other_user: other_user} do
      socket = user_socket(user)

      assert {:error, %{reason: "unauthorized"}} =
               subscribe_and_join(socket, EngramWeb.SyncChannel, "sync:#{other_user.id}")
    end
  end

  # ---------------------------------------------------------------------------
  # push_note
  # ---------------------------------------------------------------------------

  describe "push_note" do
    test "creates note and replies with note metadata", %{socket: socket} do
      ref = push(socket, "push_note", %{
        "path" => "Test/Hello.md",
        "content" => "# Hello\n\nWorld.",
        "mtime" => 1_000.0
      })

      assert_reply ref, :ok, %{"note" => note, "indexing" => "queued"}
      assert note["path"] == "Test/Hello.md"
      assert note["title"] == "Hello"
      assert note["version"] == 1
    end

    test "broadcasts note_changed to other subscribers", %{socket: socket, user: user} do
      # Second subscriber on the same channel topic
      other_socket = user_socket(user)
      {:ok, _, _} = join_sync(other_socket, user)

      push(socket, "push_note", %{
        "path" => "Test/Shared.md",
        "content" => "# Shared",
        "mtime" => 1_000.0
      })

      assert_broadcast "note_changed", %{
        "event_type" => "upsert",
        "path" => "Test/Shared.md",
        "kind" => "note"
      }
    end

    test "does not echo note_changed back to sender", %{socket: socket} do
      push(socket, "push_note", %{
        "path" => "Test/Echo.md",
        "content" => "# Echo",
        "mtime" => 1_000.0
      })

      refute_push "note_changed", %{"path" => "Test/Echo.md"}
    end

    test "sanitizes path in push_note", %{socket: socket} do
      ref = push(socket, "push_note", %{
        "path" => "Test/Dirty?.md",
        "content" => "# Dirty",
        "mtime" => 1_000.0
      })

      assert_reply ref, :ok, %{"note" => note}
      assert note["path"] == "Test/Dirty.md"
    end

    test "returns error for missing path", %{socket: socket} do
      ref = push(socket, "push_note", %{"content" => "# No path", "mtime" => 1_000.0})
      assert_reply ref, :error, %{"reason" => _}
    end
  end

  # ---------------------------------------------------------------------------
  # delete_note
  # ---------------------------------------------------------------------------

  describe "delete_note" do
    test "soft-deletes note and replies ok", %{socket: socket, user: user} do
      Notes.upsert_note(user, %{
        "path" => "Test/ToDelete.md",
        "content" => "# Delete me",
        "mtime" => 1_000.0
      })

      ref = push(socket, "delete_note", %{"path" => "Test/ToDelete.md"})
      assert_reply ref, :ok, %{"deleted" => true}

      assert {:error, :not_found} = Notes.get_note(user, "Test/ToDelete.md")
    end

    test "broadcasts note_changed with event_type delete", %{socket: socket, user: user} do
      Notes.upsert_note(user, %{
        "path" => "Test/Gone.md",
        "content" => "# Gone",
        "mtime" => 1_000.0
      })

      push(socket, "delete_note", %{"path" => "Test/Gone.md"})

      assert_broadcast "note_changed", %{
        "event_type" => "delete",
        "path" => "Test/Gone.md"
      }
    end

    test "is idempotent for nonexistent path", %{socket: socket} do
      ref = push(socket, "delete_note", %{"path" => "Fake/Note.md"})
      assert_reply ref, :ok, %{"deleted" => true}
    end
  end

  # ---------------------------------------------------------------------------
  # rename_note
  # ---------------------------------------------------------------------------

  describe "rename_note" do
    test "renames note and replies with updated note", %{socket: socket, user: user} do
      Notes.upsert_note(user, %{
        "path" => "Test/Original.md",
        "content" => "# Original",
        "mtime" => 1_000.0
      })

      ref = push(socket, "rename_note", %{
        "old_path" => "Test/Original.md",
        "new_path" => "Test/Renamed.md"
      })

      assert_reply ref, :ok, %{"note" => note}
      assert note["path"] == "Test/Renamed.md"
    end

    test "broadcasts note_changed for old and new path", %{socket: socket, user: user} do
      Notes.upsert_note(user, %{
        "path" => "Test/MoveSrc.md",
        "content" => "# Move",
        "mtime" => 1_000.0
      })

      push(socket, "rename_note", %{
        "old_path" => "Test/MoveSrc.md",
        "new_path" => "Test/MoveDst.md"
      })

      # Old path tombstone
      assert_broadcast "note_changed", %{"event_type" => "delete", "path" => "Test/MoveSrc.md"}
      # New path created
      assert_broadcast "note_changed", %{"event_type" => "upsert", "path" => "Test/MoveDst.md"}
    end

    test "returns error for nonexistent source", %{socket: socket} do
      ref = push(socket, "rename_note", %{
        "old_path" => "Nope/Missing.md",
        "new_path" => "Nope/New.md"
      })

      assert_reply ref, :error, %{"reason" => _}
    end
  end

  # ---------------------------------------------------------------------------
  # pull_changes
  # ---------------------------------------------------------------------------

  describe "pull_changes" do
    test "returns changes since timestamp", %{socket: socket, user: user} do
      Notes.upsert_note(user, %{
        "path" => "Test/Recent.md",
        "content" => "# Recent",
        "mtime" => 1_000.0
      })

      ref = push(socket, "pull_changes", %{"since" => "2020-01-01T00:00:00Z"})

      assert_reply ref, :ok, %{"changes" => changes, "server_time" => _}
      assert Enum.any?(changes, &(&1["path"] == "Test/Recent.md"))
    end

    test "returns empty changes for future timestamp", %{socket: socket} do
      ref = push(socket, "pull_changes", %{"since" => "2099-01-01T00:00:00Z"})
      assert_reply ref, :ok, %{"changes" => []}
    end

    test "returns error for invalid timestamp", %{socket: socket} do
      ref = push(socket, "pull_changes", %{"since" => "not-a-date"})
      assert_reply ref, :error, %{"reason" => _}
    end

    test "returns error when since is missing", %{socket: socket} do
      ref = push(socket, "pull_changes", %{})
      assert_reply ref, :error, %{"reason" => _}
    end
  end
end
