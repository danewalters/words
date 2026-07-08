defmodule Words.Application do
  # See https://hexdocs.pm/elixir/Application.html
  # for more information on OTP Applications
  @moduledoc false

  use Application

  @impl true
  def start(_type, _args) do
    children = [
      # Owns the ETS tables behind Words.Cache; started first so the
      # cache is available before any lookup can run.
      Words.Cache,
      # Runs the concurrent lookups of Words.lookup_all/1; tasks are
      # spawned unlinked so a crashing provider is isolated from the caller.
      {Task.Supervisor, name: Words.TaskSupervisor}
    ]

    # See https://hexdocs.pm/elixir/Supervisor.html
    # for other strategies and supported options
    opts = [strategy: :one_for_one, name: Words.Supervisor]
    Supervisor.start_link(children, opts)
  end
end
