defmodule BuildDistroWeb.CoreComponents do
  @moduledoc "Small UI building blocks shared by every page."

  use Phoenix.Component
  use BuildDistroWeb, :verified_routes

  alias BuildDistro.Builds
  alias BuildDistro.Builds.Build

  attr :flash, :map, required: true

  def flash_group(assigns) do
    ~H"""
    <div class="flashes" aria-live="polite">
      <p
        :for={kind <- [:info, :error]}
        :if={msg = Phoenix.Flash.get(@flash, kind)}
        class={"flash flash-#{kind}"}
      >
        {msg}
      </p>
    </div>
    """
  end

  attr :project, :map, required: true
  attr :build, Build, default: nil
  attr :size, :integer, default: 48

  def app_icon(assigns) do
    ~H"""
    <span class="app-icon" style={"--icon-size: #{@size}px"}>
      <img
        :if={@build && @build.icon_key}
        src={~p"/#{@project.slug}/builds/#{@build.number}/icon.png"}
        alt=""
        loading="lazy"
      />
      <span :if={!(@build && @build.icon_key)} class="app-icon-fallback">
        {String.first((@build && @build.display_name) || @project.name)}
      </span>
    </span>
    """
  end

  attr :build, Build, required: true

  def state_badge(assigns) do
    ~H"""
    <span class={"badge badge-#{@build.state}"}>
      <%= case @build.state do %>
        <% "uploading" -> %>
          Uploading {percent(@build)}%
        <% "processing" -> %>
          Processing
        <% "ready" -> %>
          Ready
        <% "failed" -> %>
          Failed
        <% "expired" -> %>
          Expired
      <% end %>
    </span>
    """
  end

  attr :build, Build, required: true

  def progress_bar(assigns) do
    ~H"""
    <div
      class="progress"
      role="progressbar"
      aria-valuemin="0"
      aria-valuemax="100"
      aria-valuenow={percent(@build)}
    >
      <div class="progress-fill" style={"width: #{percent(@build)}%"}></div>
    </div>
    """
  end

  attr :at, DateTime, required: true
  attr :id, :string, required: true

  def relative_time(assigns) do
    ~H"""
    <time
      id={@id}
      phx-hook="RelativeTime"
      datetime={DateTime.to_iso8601(@at)}
      title={format_datetime(@at)}
    >
      {format_datetime(@at)}
    </time>
    """
  end

  attr :type, :string, default: "submit"
  attr :class, :string, default: "button"
  attr :rest, :global, include: ~w(disabled form name value)
  slot :inner_block, required: true

  def button(assigns) do
    ~H"""
    <button type={@type} class={@class} {@rest}>{render_slot(@inner_block)}</button>
    """
  end

  attr :field, Phoenix.HTML.FormField, required: true
  attr :label, :string, required: true
  attr :type, :string, default: "text"
  attr :hint, :string, default: nil
  attr :rest, :global, include: ~w(autocomplete placeholder required autofocus inputmode)

  def input(assigns) do
    assigns = assign(assigns, :errors, Enum.map(assigns.field.errors, &translate_error/1))

    ~H"""
    <label class="field">
      <span class="field-label">{@label}</span>
      <input
        type={@type}
        name={@field.name}
        id={@field.id}
        value={Phoenix.HTML.Form.normalize_value(@type, @field.value)}
        aria-invalid={@errors != [] && "true"}
        {@rest}
      />
      <span :if={@hint && @errors == []} class="field-hint">{@hint}</span>
      <span :for={error <- @errors} class="field-error">{error}</span>
    </label>
    """
  end

  def percent(%Build{state: "uploading"} = build), do: floor(Builds.progress(build) * 100)
  def percent(%Build{state: state}) when state in ~w(processing ready), do: 100
  def percent(_), do: 0

  # Shown next to "#number", so a build without metadata yet needs no number here.
  def version_label(%Build{version: nil}), do: "New build"
  def version_label(%Build{version: version, build_version: nil}), do: version
  def version_label(%Build{version: v, build_version: b}), do: "#{v} (#{b})"

  def format_bytes(bytes) when bytes >= 1024 * 1024 * 1024,
    do: "#{Float.round(bytes / 1024 ** 3, 2)} GB"

  def format_bytes(bytes) when bytes >= 1024 * 1024, do: "#{Float.round(bytes / 1024 ** 2, 1)} MB"
  def format_bytes(bytes) when bytes >= 1024, do: "#{div(bytes, 1024)} KB"
  def format_bytes(bytes), do: "#{bytes} B"

  def format_datetime(%DateTime{} = at), do: Calendar.strftime(at, "%-d %b %Y, %H:%M UTC")

  def short_sha(nil), do: nil
  def short_sha(sha), do: String.slice(sha, 0, 7)

  def first_line(nil), do: nil
  def first_line(text), do: text |> String.split("\n", parts: 2) |> hd()

  def translate_error({message, opts}) do
    Regex.replace(~r"%{(\w+)}", message, fn _, key ->
      opts |> Keyword.get(String.to_existing_atom(key), key) |> to_string()
    end)
  end
end
