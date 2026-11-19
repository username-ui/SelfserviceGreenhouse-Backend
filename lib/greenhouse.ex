defmodule Greenhouse do
  @moduledoc """
  Backend service for the Selfservice Greenhouse system.

  Receives telemetry, status, alarms, and config acknowledgements from ESP/MCU
  greenhouse devices over MQTT 3.1.1, maintains in-memory and optional DETS state,
  validates configuration patches against protocol constraints, and exposes a
  REST JSON API.
  """

  @typedoc "Unique identifier of an edge greenhouse device."
  @type device_id :: String.t()

  @typedoc "Unique identifier of a registered user account."
  @type user_id :: String.t()

  @typedoc "Opaque bearer session token issued on login/registration."
  @type session_token :: String.t()

  @typedoc "Unix timestamp in milliseconds."
  @type timestamp_ms :: integer()

  @typedoc "ISO 8601 UTC timestamp string."
  @type iso8601_timestamp :: String.t()

  @typedoc "Generic string-keyed JSON object map."
  @type json_map :: %{optional(String.t()) => term()}

  @typedoc "GenServer reference accepted by client API calls."
  @type server_ref :: GenServer.server()
end
