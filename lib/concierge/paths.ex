defmodule Concierge.Paths do
  @moduledoc """
  Centralized paths.

  Base directory precedence:
  1) CONCIERGE_HOME environment variable
  2) Config value applied at runtime (via ConfigServer)
  3) Current working directory
  """

  @key {__MODULE__, :home_dir}

  def set_home_dir(dir) when is_binary(dir) do
    :persistent_term.put(@key, dir)
  end

  def set_home_dir(_), do: :ok

  def base_dir do
    env = System.get_env("CONCIERGE_HOME")

    cond do
      is_binary(env) and String.trim(env) != "" ->
        Path.expand(env)

      true ->
        configured =
          try do
            :persistent_term.get(@key, nil)
          catch
            _, _ -> nil
          end

        cond do
          is_binary(configured) and String.trim(configured) != "" ->
            Path.expand(configured)

          true ->
            case File.cwd() do
              {:ok, dir} -> dir
              _ -> Path.expand(".")
            end
        end
    end
  end

  def path(relative) when is_binary(relative) do
    Path.join(base_dir(), relative)
  end
end
