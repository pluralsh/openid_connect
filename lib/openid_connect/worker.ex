defmodule OpenIDConnect.Worker do
  use GenServer
  require Logger

  @moduledoc """
  Worker module for OpenID Connect

  This worker will store and periodically update each provider's documents and JWKs according to the lifetimes
  """

  @refresh_time 60 * 60 * 1000

  def start_link(provider_configs, name \\ :openid_connect) do
    GenServer.start_link(__MODULE__, provider_configs, name: name)
  end

  def init(:ignore) do
    :ignore
  end

  def init(provider_configs) do
    state =
      Enum.into(provider_configs, %{}, fn {provider, config} ->
        documents = update_documents!(provider, config)
        {provider, %{config: config, documents: documents}}
      end)

    {:ok, state}
  end

  def handle_call({:discovery_document, provider}, _from, state) do
    discovery_document = get_in(state, [provider, :documents, :discovery_document])
    {:reply, discovery_document, state}
  end

  def handle_call({:jwk, provider}, _from, state) do
    jwk = get_in(state, [provider, :documents, :jwk])
    {:reply, jwk, state}
  end

  def handle_call({:config, provider}, _from, state) do
    config = get_in(state, [provider, :config])
    {:reply, config, state}
  end

  def handle_info({:update_documents, provider}, state) do
    Logger.info "updating oidc configuration for #{provider}"
    config = get_in(state, [provider, :config])
    case update_documents(provider, config) do
      {:ok, docs} -> {:noreply, put_in(state, [provider, :documents], docs)}
      _ ->
        Logger.error "Failed to update oidc configuration for #{provider}"
        jitter = :rand.uniform(15)
        send_doc_update(provider, :timer.seconds(30 + jitter))
        {:noreply, state}
    end
  end

  defp update_documents(provider, config) do
    with {:ok, %{remaining_lifetime: remaining_lifetime} = documents} <- OpenIDConnect.update_documents(config) do
      refresh_time = time_until_next_refresh(remaining_lifetime)
      send_doc_update(provider, refresh_time)

      {:ok, documents}
    end
  end

  def update_documents!(provider, config) do
    {:ok, docs} = update_documents(provider, config)
    docs
  end

  defp send_doc_update(provider, refresh_time),
    do: Process.send_after(self(), {:update_documents, provider}, refresh_time)

  defp time_until_next_refresh(nil), do: @refresh_time

  defp time_until_next_refresh(time_in_seconds) when time_in_seconds > 0,
    do: :timer.seconds(time_in_seconds)

  defp time_until_next_refresh(time_in_seconds) when time_in_seconds <= 0, do: 0
end
