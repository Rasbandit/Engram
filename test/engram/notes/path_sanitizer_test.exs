defmodule Engram.Notes.PathSanitizerTest do
  use ExUnit.Case, async: true

  alias Engram.Notes.PathSanitizer

  # ---------------------------------------------------------------------------
  # Illegal character stripping
  # ---------------------------------------------------------------------------

  describe "illegal char stripping" do
    test "strips question mark" do
      assert PathSanitizer.sanitize("Notes/Why?.md") == "Notes/Why.md"
    end

    test "strips asterisk" do
      assert PathSanitizer.sanitize("Notes/Important*.md") == "Notes/Important.md"
    end

    test "strips colon" do
      assert PathSanitizer.sanitize("Notes/HH:MM.md") == "Notes/HHMM.md"
    end

    test "strips angle brackets" do
      assert PathSanitizer.sanitize("Notes/<tag>.md") == "Notes/tag.md"
    end

    test "strips double quotes" do
      assert PathSanitizer.sanitize(~s(Notes/"quoted".md)) == "Notes/quoted.md"
    end

    test "strips pipe" do
      assert PathSanitizer.sanitize("Notes/A|B.md") == "Notes/AB.md"
    end

    test "strips backslash" do
      assert PathSanitizer.sanitize("Notes/A\\B.md") == "Notes/AB.md"
    end

    test "strips multiple illegal chars" do
      assert PathSanitizer.sanitize(~s(Notes/What: A "Great" Day*.md)) ==
               "Notes/What A Great Day.md"
    end

    test "preserves forward slash" do
      assert PathSanitizer.sanitize("A/B/C.md") == "A/B/C.md"
    end

    test "collapses multiple spaces" do
      assert PathSanitizer.sanitize("Notes/Too   Many  Spaces.md") ==
               "Notes/Too Many Spaces.md"
    end

    test "strips leading space per segment" do
      assert PathSanitizer.sanitize("Notes/ Padded.md") == "Notes/Padded.md"
    end

    test "strips trailing slash" do
      assert PathSanitizer.sanitize("Notes/Subfolder/") == "Notes/Subfolder"
    end

    test "no change for clean path" do
      assert PathSanitizer.sanitize("Notes/Clean File.md") == "Notes/Clean File.md"
    end

    test "single segment no folder" do
      assert PathSanitizer.sanitize("Inbox.md") == "Inbox.md"
    end
  end

  # ---------------------------------------------------------------------------
  # Path traversal prevention
  # ---------------------------------------------------------------------------

  describe "path traversal prevention" do
    test "strips parent directory traversal" do
      result = PathSanitizer.sanitize("../../../etc/passwd")
      refute String.contains?(result, "..")
      assert String.contains?(result, "etc")
      assert String.contains?(result, "passwd")
    end

    test "strips .. in middle" do
      result = PathSanitizer.sanitize("Notes/../../../etc/passwd")
      refute String.contains?(result, "..")
    end

    test "strips .. at end" do
      result = PathSanitizer.sanitize("Notes/Subfolder/..")
      refute String.contains?(result, "..")
      assert String.contains?(result, "Notes")
    end

    test "strips leading slash (absolute path)" do
      result = PathSanitizer.sanitize("/etc/passwd")
      refute String.starts_with?(result, "/")
      assert String.contains?(result, "etc")
      assert String.contains?(result, "passwd")
    end

    test "strips windows drive letter colon and backslash" do
      result = PathSanitizer.sanitize("C:\\Windows\\System32")
      refute String.contains?(result, "\\")
      refute String.contains?(result, ":")
      assert String.contains?(result, "Windows")
    end

    test "strips dot-dot with spaces" do
      result = PathSanitizer.sanitize("Notes/. ./. ./secret")
      refute String.contains?(result, ". .")
      assert String.contains?(result, "secret")
    end

    test "strips url-encoded traversal" do
      result = PathSanitizer.sanitize("Notes/..%2F..%2Fetc/passwd")
      refute String.contains?(result, "..")
    end

    test "common traversal payloads neutralized" do
      payloads = [
        "../../../etc/passwd",
        "Notes/../../../../etc/shadow",
        "/etc/passwd",
        "....//....//etc/passwd"
      ]

      for path <- payloads do
        result = PathSanitizer.sanitize(path)
        refute String.contains?(result, ".."), "traversal not stripped from: #{path}"
        refute String.starts_with?(result, "/"), "absolute path not stripped from: #{path}"
      end
    end
  end

  # ---------------------------------------------------------------------------
  # Edge cases
  # ---------------------------------------------------------------------------

  describe "edge cases" do
    test "empty string returns empty string" do
      assert PathSanitizer.sanitize("") == ""
    end

    test "collapses double slashes" do
      result = PathSanitizer.sanitize("Notes//File.md")
      refute String.contains?(result, "//")
      assert String.contains?(result, "Notes")
      assert String.contains?(result, "File.md")
    end

    test "removes single-dot segments" do
      result = PathSanitizer.sanitize("Notes/./File.md")
      refute String.contains?(result, "//")
    end

    test "preserves unicode" do
      assert PathSanitizer.sanitize("Notes/日本語.md") == "Notes/日本語.md"
    end

    test "preserves emoji" do
      assert PathSanitizer.sanitize("Notes/🧠 Brain Dump.md") == "Notes/🧠 Brain Dump.md"
    end

    test "preserves diacritics" do
      assert PathSanitizer.sanitize("Notes/café résumé.md") == "Notes/café résumé.md"
    end

    test "all-illegal-chars segment still produces non-empty result" do
      result = PathSanitizer.sanitize("Notes/***???.md")
      assert result != ""
      assert String.contains?(result, ".md")
    end

    test "truncates segment to 255 bytes" do
      long_name = String.duplicate("A", 300) <> ".md"
      result = PathSanitizer.sanitize("Notes/#{long_name}")
      segment = result |> String.split("/") |> List.last()
      assert byte_size(segment) <= 255
    end

    test "null byte stripped" do
      result = PathSanitizer.sanitize("Notes/file\x00.md")
      refute String.contains?(result, "\x00")
    end

    test "unicode with illegal chars" do
      result = PathSanitizer.sanitize("日記/メモ*?.md")
      assert String.contains?(result, "日記")
      refute String.contains?(result, "*")
      refute String.contains?(result, "?")
    end
  end

  # ---------------------------------------------------------------------------
  # Combined attacks
  # ---------------------------------------------------------------------------

  describe "combined attacks" do
    test "traversal with illegal chars" do
      result = PathSanitizer.sanitize("Notes/../*foo*/file.md")
      refute String.contains?(result, "..")
      refute String.contains?(result, "*")
      assert String.contains?(result, "file.md")
    end

    test "traversal with colon and backslash" do
      result = PathSanitizer.sanitize("../../C:\\Windows\\System32")
      refute String.contains?(result, "..")
      refute String.contains?(result, ":")
      refute String.contains?(result, "\\")
    end

    test "multiple traversal styles" do
      result = PathSanitizer.sanitize("/../../etc/passwd")
      refute String.starts_with?(result, "/")
      refute String.contains?(result, "..")
    end

    test "sql injection payload passes through" do
      result = PathSanitizer.sanitize("Notes/'; DROP TABLE notes; --.md")
      assert is_binary(result)
      assert byte_size(result) > 0
    end
  end
end
