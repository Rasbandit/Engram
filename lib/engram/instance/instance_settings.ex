defmodule Engram.Instance.InstanceSettings do
  use Ecto.Schema
  import Ecto.Changeset

  @modes ~w(closed invite_only open)

  schema "instance_settings" do
    field :registration_mode, :string, default: "invite_only"
    timestamps(type: :utc_datetime)
  end

  def modes, do: @modes

  def changeset(struct, attrs) do
    struct
    |> cast(attrs, [:registration_mode])
    |> validate_required([:registration_mode])
    |> validate_inclusion(:registration_mode, @modes)
  end
end
