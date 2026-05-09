defmodule Engram.Repo.Migrations.T37AddDekRotationColumns do
  use Ecto.Migration

  def change do
    alter table(:attachments) do
      # T3.7 — non-null only mid-rotation. Marks "we intend to flip this
      # attachment to dek_version_pending; S3 PUT may or may not have
      # happened." Resume logic re-runs the PUT for any row where this
      # is set. NULL after a successful flip-and-clear.
      add :dek_version_pending, :integer, null: true
    end

    alter table(:users) do
      # T3.7 — non-null while a per-user DEK rotation is in flight.
      # Acts as both the lock flag (read by RotationLockCheck plug) and
      # the started-at timestamp (used for stale-lock takeover after
      # 10 minutes).
      add :dek_rotation_locked_at, :utc_datetime_usec, null: true
    end
  end
end
