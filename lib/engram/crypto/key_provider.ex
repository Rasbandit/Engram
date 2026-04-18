defmodule Engram.Crypto.KeyProvider do
  @moduledoc """
  Behaviour for wrapping/unwrapping per-user Data Encryption Keys (DEKs).
  Implementations: Local, AwsKms (future), Passphrase (future).

  `ctx` carries per-user state. AwsKms and Local ignore it; Passphrase reads it.
  """

  @type dek :: <<_::256>>
  @type wrapped :: binary()
  @type ctx :: %{:user_id => integer(), optional(:session_token) => String.t()}

  @callback name() :: atom()
  @callback generate_dek() :: dek()
  @callback wrap_dek(dek(), ctx()) :: {:ok, wrapped()} | {:error, term()}
  @callback unwrap_dek(wrapped(), ctx()) ::
              {:ok, dek()} | {:error, :needs_unlock | term()}
  @callback supports_async_workers?() :: boolean()
  @callback rotate_wrapping(wrapped(), ctx()) :: {:ok, wrapped()} | {:error, term()}

  @doc "Default DEK generator — providers may override."
  @spec default_generate_dek() :: dek()
  def default_generate_dek, do: :crypto.strong_rand_bytes(32)
end
