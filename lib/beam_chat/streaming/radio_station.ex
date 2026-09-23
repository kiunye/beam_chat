defmodule BeamChat.Streaming.RadioStation do
  @moduledoc """
  A tenant-scoped radio station: an external audio source published into a
  LiveKit room via the LiveKit Ingress service.

  * `source_type` — how the audio reaches LiveKit Ingress:
      * `"url"`   — Ingress pulls an HLS/SRT/file URL directly
      * `"rtmp"`  — an external encoder (e.g. FFmpeg bridging an Icecast
                    feed) pushes to the RTMP endpoint Ingress provisions
      * `"whip"`  — a live show (e.g. OBS) pushes via WebRTC-HTTP
  * `is_active` — the *desired* state, flipped by an admin via
    `BeamChat.Streaming.start_station/2` / `stop_station/2`.
  * `status` — the *observed* runtime state of the LiveKit Ingress
    (`"offline"` | `"starting"` | `"live"` | `"error"`), driven by
    webhook events, never written by hand.
  * `ingress_id` — the LiveKit Ingress resource id once created.
  * `metadata` — Ingress provisioning details (e.g. the RTMP push URL and
    stream key). Treated as admin-visible only.

  Each station publishes into its own LiveKit room (`"radio-" <> slug`),
  so listeners subscribe to one stream without interfering with chat
  rooms' video sessions.
  """

  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  @source_types ~w(url rtmp whip)
  @statuses ~w(offline starting live error)

  schema "radio_stations" do
    field :name, :string
    field :slug, :string
    field :description, :string
    field :source_type, :string, default: "url"
    field :source_url, :string
    field :status, :string, default: "offline"
    field :is_active, :boolean, default: false
    field :ingress_id, :string
    field :metadata, :map, default: %{}

    belongs_to :tenant, BeamChat.Tenants.Tenant, foreign_key: :tenant_id
    belongs_to :room, BeamChat.Rooms.Room, foreign_key: :room_id

    timestamps(type: :utc_datetime)
  end

  @type t :: %__MODULE__{}

  @doc """
  Creation changeset. `tenant_id` is set by the context when building the
  struct (never cast from params), and the station always starts inactive
  and offline.
  """
  def create_changeset(station, attrs) do
    station
    |> cast(attrs, [:name, :slug, :description, :source_type, :source_url, :is_active])
    |> common_validations()
    |> validate_required([:tenant_id])
  end

  @doc """
  Admin edit changeset: source and display fields only. The slug is
  immutable — the station's LiveKit room name (`"radio-" <> slug`) is
  derived from it, and renaming would orphan running Ingress resources.
  """
  def update_changeset(station, attrs) do
    station
    |> cast(attrs, [:name, :description, :source_type, :source_url, :is_active])
    |> common_validations()
  end

  @doc "Internal status transition; never exposed to admin forms."
  def status_changeset(station, status) when status in @statuses,
    do: change(station, status: status)

  defp common_validations(changeset) do
    changeset
    |> validate_required([:name, :slug, :source_type])
    |> validate_inclusion(:source_type, @source_types)
    |> validate_length(:name, min: 2, max: 120)
    |> validate_format(:slug, ~r/\A[a-z0-9-]+\z/,
      message: "must contain only lowercase letters, numbers, and hyphens"
    )
    |> validate_required_source_url()
    |> foreign_key_constraint(:tenant_id)
    |> foreign_key_constraint(:room_id)
  end

  # A pull source is meaningless without its URL; push sources
  # (rtmp/whip) receive their endpoint FROM LiveKit after provisioning.
  defp validate_required_source_url(changeset) do
    if get_field(changeset, :source_type) == "url" and
         blank?(get_field(changeset, :source_url)) do
      add_error(changeset, :source_url, "is required for url sources")
    else
      changeset
    end
  end

  defp blank?(nil), do: true
  defp blank?(""), do: true
  defp blank?(_), do: false
end
