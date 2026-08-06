defmodule BeamChat.Release do
  @moduledoc """
  Release tasks for production (e.g. `bin/beam_chat eval "BeamChat.Release.migrate"`).
  """
  @app :beam_chat

  def migrate do
    load_app()

    for repo <- repos() do
      {:ok, _, _} = Ecto.Migrator.with_repo(repo, &Ecto.Migrator.run(&1, :up, all: true))
    end
  end

  def rollback(repo, version) do
    load_app()
    {:ok, _, _} = Ecto.Migrator.with_repo(repo, &Ecto.Migrator.run(&1, :down, to: version))
  end

  defp repos do
    Application.fetch_env!(@app, :ecto_repos)
  end

  defp load_app do
    # Load the app's configuration WITHOUT starting the full application
    # tree. Application.ensure_all_started/1 must NOT be used here: it boots
    # every application including BeamChatWeb.Endpoint, which binds the HTTP
    # port. CI runs migrations via a one-shot `docker run` container
    # executing `eval 'BeamChat.Release.migrate()'` on the stack's overlay
    # network (see the .gitlab-ci.yml deploy jobs). Application.load/1 only
    # loads the app so that this container never starts a second VM that
    # would bind the endpoint (no ensure_all_started before migrate, so no
    # :eaddrinuse and no port race with the app service). Ecto.Migrator
    # .with_repo/2 starts the repo (and its dependencies) itself, so
    # migrations run fine with the app merely loaded.
    Application.load(@app)
  end
end
